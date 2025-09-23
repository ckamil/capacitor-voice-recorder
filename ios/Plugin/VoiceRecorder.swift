import Foundation
import AVFoundation
import Capacitor

@objc(VoiceRecorder)
public class VoiceRecorder: CAPPlugin {

    private var customMediaRecorder: CustomMediaRecorder?
    private var isInterrupted: Bool = false
    private var wasInterruptedAndStopped: Bool = false // Tracks if we stopped recording due to interruption
    private var isMicrophoneCurrentlyAvailable: Bool = true

    @objc func canDeviceVoiceRecord(_ call: CAPPluginCall) {
        call.resolve(ResponseGenerator.successResponse())
    }

    @objc func requestAudioRecordingPermission(_ call: CAPPluginCall) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            if granted {
                call.resolve(ResponseGenerator.successResponse())
            } else {
                call.resolve(ResponseGenerator.failResponse())
            }
        }
    }

    @objc func hasAudioRecordingPermission(_ call: CAPPluginCall) {
        call.resolve(ResponseGenerator.fromBoolean(doesUserGaveAudioRecordingPermission()))
    }

    @objc func startRecording(_ call: CAPPluginCall) {
        if !doesUserGaveAudioRecordingPermission() {
            rejectWithDiagnostics(call,
                                 Messages.MISSING_PERMISSION,
                                 "Microphone permission not granted")
            return
        }

        if customMediaRecorder != nil {
            rejectWithDiagnostics(call,
                                 Messages.ALREADY_RECORDING,
                                 "Recording is already in progress")
            return
        }

        // Check audio session state before creating recorder
        let audioSession = AVAudioSession.sharedInstance()

        if audioSession.isOtherAudioPlaying {
            // Try cleanup first if it might be our orphaned session
            if audioSession.category == .playAndRecord {
                NSLog("VoiceRecorder: Detected playAndRecord with otherAudioPlaying, attempting cleanup")
                try? audioSession.setActive(false)
                try? audioSession.setCategory(.ambient)
                Thread.sleep(forTimeInterval: 0.1)
            }

            // Check again after cleanup attempt
            if audioSession.isOtherAudioPlaying {
                rejectWithDiagnostics(call,
                                     Messages.CANNOT_RECORD_ON_THIS_PHONE,
                                     "Other audio application is active",
                                     ["otherAudioPlaying": true, "cleanupAttempted": audioSession.category == .playAndRecord])
                return
            }
        }

        if audioSession.availableInputs?.isEmpty == true {
            rejectWithDiagnostics(call,
                                 Messages.CANNOT_RECORD_ON_THIS_PHONE,
                                 "No microphone input available",
                                 ["availableInputs": 0])
            return
        }

        // Setup audio session interruption handling
        setupAudioSessionInterruptionHandling()

        customMediaRecorder = CustomMediaRecorder()
        if customMediaRecorder == nil {
            rejectWithDiagnostics(call,
                                 Messages.CANNOT_RECORD_ON_THIS_PHONE,
                                 "Failed to initialize CustomMediaRecorder")
            return
        }

        let directory: String? = call.getString("directory")
        let subDirectory: String? = call.getString("subDirectory")
        let recordOptions = RecordOptions(directory: directory, subDirectory: subDirectory)
        let recordingResult = customMediaRecorder!.startRecording(recordOptions: recordOptions)

        if !recordingResult.success {
            customMediaRecorder = nil

            // Build comprehensive error details
            var errorDetails: [String: Any] = [
                "requestedDirectory": directory ?? "DOCUMENTS",
                "requestedSubDirectory": subDirectory ?? "none"
            ]

            if let recordingError = recordingResult.error {
                errorDetails["stage"] = recordingError.stage
                errorDetails["stageDetails"] = recordingError.details
                errorDetails["stageError"] = recordingError.errorDescription ?? "Unknown error"
            }

            // Add basic document directory info for compatibility
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "unknown"
            let isDocumentsWritable = FileManager.default.isWritableFile(atPath: documentsPath)
            errorDetails["documentsPath"] = documentsPath
            errorDetails["documentsWritable"] = isDocumentsWritable

            let errorMessage = recordingResult.error?.errorDescription ?? "Recording setup failed"

            rejectWithDiagnostics(call,
                           Messages.CANNOT_RECORD_ON_THIS_PHONE,
                           errorMessage,
                           errorDetails)
        } else {
            isInterrupted = false
            wasInterruptedAndStopped = false
            call.resolve(ResponseGenerator.successResponse())
        }
    }

    @objc func stopRecording(_ call: CAPPluginCall) {
        if customMediaRecorder == nil {
            call.reject(Messages.RECORDING_HAS_NOT_STARTED)
            return
        }

        // Remove audio session interruption observer
        removeAudioSessionInterruptionHandling()

        customMediaRecorder?.stopRecording()

        let audioFileUrl = customMediaRecorder?.getOutputFile()
        if audioFileUrl == nil {
            customMediaRecorder = nil
            call.reject(Messages.FAILED_TO_FETCH_RECORDING)
            return
        }

        var path = audioFileUrl!.lastPathComponent
        if let subDirectory = customMediaRecorder?.options?.subDirectory {
            path = subDirectory + "/" + path
        }

        let sendDataAsBase64 = customMediaRecorder?.options?.directory == nil
        let recordData = RecordData(
            recordDataBase64: sendDataAsBase64 ? readFileAsBase64(audioFileUrl) : nil,
            mimeType: "audio/aac",
            msDuration: getMsDurationOfAudioFile(audioFileUrl),
            path: sendDataAsBase64 ? nil : path
        )

        // If we were interrupted, mark that we stopped due to interruption
        if isInterrupted {
            wasInterruptedAndStopped = true
        }

        customMediaRecorder = nil
        isInterrupted = false
        if (sendDataAsBase64 && recordData.recordDataBase64 == nil) || recordData.msDuration < 0 {
            call.reject(Messages.EMPTY_RECORDING)
        } else {
            call.resolve(ResponseGenerator.dataResponse(recordData.toDictionary()))
        }
    }

    @objc func pauseRecording(_ call: CAPPluginCall) {
        if customMediaRecorder == nil {
            call.reject(Messages.RECORDING_HAS_NOT_STARTED)
        } else {
            call.resolve(ResponseGenerator.fromBoolean(customMediaRecorder?.pauseRecording() ?? false))
        }
    }

    @objc func resumeRecording(_ call: CAPPluginCall) {
        if customMediaRecorder == nil {
            call.reject(Messages.RECORDING_HAS_NOT_STARTED)
        } else {
            call.resolve(ResponseGenerator.fromBoolean(customMediaRecorder?.resumeRecording() ?? false))
        }
    }

    @objc func getCurrentStatus(_ call: CAPPluginCall) {
        if customMediaRecorder == nil {
            call.resolve(ResponseGenerator.statusResponse(CurrentRecordingStatus.NONE))
        } else {
            call.resolve(ResponseGenerator.statusResponse(customMediaRecorder?.getCurrentStatus() ?? CurrentRecordingStatus.NONE))
        }
    }


    func doesUserGaveAudioRecordingPermission() -> Bool {
        return AVAudioSession.sharedInstance().recordPermission == AVAudioSession.RecordPermission.granted
    }

    func readFileAsBase64(_ filePath: URL?) -> String? {
        if filePath == nil {
            return nil
        }

        do {
            let fileData = try Data.init(contentsOf: filePath!)
            let fileStream = fileData.base64EncodedString(options: NSData.Base64EncodingOptions.init(rawValue: 0))
            return fileStream
        } catch {}

        return nil
    }

    func getMsDurationOfAudioFile(_ filePath: URL?) -> Int {
        if filePath == nil {
            return -1
        }
        return Int(CMTimeGetSeconds(AVURLAsset(url: filePath!).duration) * 1000)
    }


    // MARK: - Audio Session Interruption Handling

    private func setupAudioSessionInterruptionHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    private func removeAudioSessionInterruptionHandling() {
        NotificationCenter.default.removeObserver(
            self,
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            NSLog("VoiceRecorder: Invalid interruption notification")
            return
        }

        NSLog("VoiceRecorder: Audio session interruption type: %d (isInterrupted: %@)", typeValue, isInterrupted ? "true" : "false")

        switch type {
        case .began:
            // Recording was interrupted
            NSLog("VoiceRecorder: Interruption began")
            handleRecordingInterruption()

        case .ended:
            // Interruption ended
            NSLog("VoiceRecorder: Interruption ended")
            handleInterruptionEnded(userInfo)

        @unknown default:
            NSLog("VoiceRecorder: Unknown interruption type: %d", typeValue)
            break
        }
    }

    private func handleRecordingInterruption() {
        NSLog("VoiceRecorder: handleRecordingInterruption called - customMediaRecorder: %@", customMediaRecorder != nil ? "exists" : "nil")

        // Handle recording interruption if we have an active recording
        if customMediaRecorder != nil {
            isInterrupted = true

            // Notify JavaScript layer about the recording interruption
            let interruptionData = [
                "data": [
                    "reason": "system_interruption",
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            ]

            NSLog("VoiceRecorder: Sending recordingInterrupted event to JavaScript - reason: system_interruption")
            notifyListeners("recordingInterrupted", data: interruptionData)
        }

        // Handle global microphone availability changes
        if isMicrophoneCurrentlyAvailable {
            isMicrophoneCurrentlyAvailable = false

            let availabilityData: [String: Any] = [
                "available": false,
                "reason": "other_app_started",
                "ourAppRecording": customMediaRecorder != nil,
                "otherAppActive": true
            ]

            NSLog("VoiceRecorder: Sending microphoneAvailabilityChanged: false - other_app_started")
            notifyListeners("microphoneAvailabilityChanged", data: availabilityData)
        }
    }

    private func handleInterruptionEnded(_ userInfo: [AnyHashable: Any]) {
        NSLog("VoiceRecorder: handleInterruptionEnded called - isInterrupted: %@, customMediaRecorder: %@",
              isInterrupted ? "true" : "false",
              customMediaRecorder != nil ? "exists" : "nil")

        // Handle recording resumption if we have an interrupted recording
        // Note: customMediaRecorder might be nil if recording was stopped after interruption
        if isInterrupted || wasInterruptedAndStopped {
            // Check if we should resume recording
            var canResume = false
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                canResume = options.contains(.shouldResume)
            }

            // Notify JavaScript layer that interruption ended
            let interruptionEndedData = [
                "canResume": canResume
            ]

            NSLog("VoiceRecorder: Sending interruptionEnded event to JavaScript - canResume: %@", canResume ? "true" : "false")
            notifyListeners("interruptionEnded", data: interruptionEndedData)

            // Don't auto-resume - let JavaScript layer decide
            isInterrupted = false
            wasInterruptedAndStopped = false
        }

        // Handle global microphone availability changes
        if !isMicrophoneCurrentlyAvailable {
            isMicrophoneCurrentlyAvailable = true

            let availabilityData: [String: Any] = [
                "available": true,
                "reason": "other_app_finished",
                "ourAppRecording": customMediaRecorder != nil,
                "otherAppActive": false
            ]

            NSLog("VoiceRecorder: Sending microphoneAvailabilityChanged: true - other_app_finished")
            notifyListeners("microphoneAvailabilityChanged", data: availabilityData)
        }
    }

    // MARK: - Plugin Lifecycle

    public override func load() {
        super.load()

        // Simple orphaned session cleanup
        let audioSession = AVAudioSession.sharedInstance()
        if audioSession.category == .playAndRecord && customMediaRecorder == nil {
            NSLog("VoiceRecorder: Detected orphaned audio session, cleaning up")
            try? audioSession.setActive(false)
            try? audioSession.setCategory(.ambient)
        }

        setupGlobalAudioSessionListener()
    }

    deinit {
        removeGlobalAudioSessionListener()
    }

    // MARK: - Global Audio Session Monitoring

    private func setupGlobalAudioSessionListener() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGlobalAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    private func removeGlobalAudioSessionListener() {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
    }

    @objc private func handleGlobalAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        // Only handle global events when not actively recording or when recording is interrupted
        if customMediaRecorder == nil || isInterrupted {
            switch type {
            case .began:
                handleRecordingInterruption() // Now handles both recording and global availability

            case .ended:
                // Check if we have an interrupted recording that the main handler might have missed
                if isInterrupted || wasInterruptedAndStopped {
                    NSLog("VoiceRecorder: Global listener detected interruption ended with active interrupted recording")

                    let interruptionEndedData = [
                        "canResume": true
                    ]

                    NSLog("VoiceRecorder: Global - Sending interruptionEnded event to JavaScript")
                    notifyListeners("interruptionEnded", data: interruptionEndedData)

                    isInterrupted = false
                    wasInterruptedAndStopped = false
                }

                handleInterruptionEnded(userInfo) // Now handles both recording and global availability

            @unknown default:
                break
            }
        }
    }

    @objc private func handleAudioSessionRouteChange(_ notification: Notification) {
        // Monitor route changes to detect when other apps start/stop using audio
        let audioSession = AVAudioSession.sharedInstance()
        let wasAvailable = isMicrophoneCurrentlyAvailable
        let isNowAvailable = !audioSession.isOtherAudioPlaying

        if wasAvailable != isNowAvailable {
            isMicrophoneCurrentlyAvailable = isNowAvailable

            let reason = isNowAvailable ? "other_app_finished" : "other_app_started"
            let availabilityData: [String: Any] = [
                "available": isNowAvailable,
                "reason": reason,
                "ourAppRecording": customMediaRecorder != nil,
                "otherAppActive": !isNowAvailable
            ]

            NSLog("VoiceRecorder: Route change - microphoneAvailabilityChanged: %@ - %@", isNowAvailable ? "true" : "false", reason)
            notifyListeners("microphoneAvailabilityChanged", data: availabilityData)
        }
    }

    // Helper method to determine if our app is causing the interruption
    private func isOurAppCausingInterruption() -> Bool {
        // If we have an active recording that's not interrupted, we are using the microphone
        // If recording is interrupted, we're not actively using the microphone anymore
        return customMediaRecorder != nil && !isInterrupted
    }

    // MARK: - Enhanced Error Reporting

    private func rejectWithDiagnostics(_ call: CAPPluginCall, _ baseMessage: String, _ reason: String, _ details: [String: Any] = [:]) {
        let audioSession = AVAudioSession.sharedInstance()

        var diagnosticInfo: [String: Any] = [
            "baseError": baseMessage,
            "reason": reason,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "platform": "ios",
            "audioSessionCategory": audioSession.category.rawValue,
            "isOtherAudioPlaying": audioSession.isOtherAudioPlaying,
            "availableInputs": audioSession.availableInputs?.count ?? 0,
            "hasRecordPermission": doesUserGaveAudioRecordingPermission()
        ]

        // Add specific details if provided
        if !details.isEmpty {
            diagnosticInfo["details"] = details
        }

        // Add input route information
        if let availableInputs = audioSession.availableInputs {
            diagnosticInfo["inputRoutes"] = availableInputs.map { $0.portType.rawValue }
        }

        let currentRoute = audioSession.currentRoute
        diagnosticInfo["currentInputs"] = currentRoute.inputs.map { $0.portType.rawValue }
        diagnosticInfo["currentOutputs"] = currentRoute.outputs.map { $0.portType.rawValue }

        let fullMessage = "\(baseMessage): \(reason)"
        call.reject(fullMessage, nil, nil, diagnosticInfo)
    }

}
