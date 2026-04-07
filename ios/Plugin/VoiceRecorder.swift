import Foundation
import AVFoundation
import Capacitor
import CallKit

@objc(VoiceRecorder)
public class VoiceRecorder: CAPPlugin {

    private var customMediaRecorder: RecorderInterface?
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

        // Note: isOtherAudioPlaying is NOT a blocking condition.
        // WebView presentations with audio+video run during recording — iOS reports
        // them as "other audio playing" but recording must proceed alongside them.
        // CustomMediaRecorder handles this via .mixWithOthers fallback strategy.
        if audioSession.isOtherAudioPlaying {
            NSLog("VoiceRecorder: Other audio is playing (category: %@), proceeding - likely WebView presentation",
                  audioSession.category.rawValue)
            // Cleanup orphaned .playAndRecord session if detected
            if audioSession.category == .playAndRecord {
                NSLog("VoiceRecorder: Detected orphaned .playAndRecord with otherAudioPlaying, cleaning up")
                try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                try? audioSession.setCategory(.ambient)
                Thread.sleep(forTimeInterval: 0.2)
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

        let directory: String? = call.getString("directory")
        let subDirectory: String? = call.getString("subDirectory")
        let recordOptions = RecordOptions(directory: directory, subDirectory: subDirectory)

        // Try AVAudioEngine first (resilient to record()=false with .mixWithOthers on iPad),
        // fall back to AVAudioRecorder if Engine fails.
        let engineRecorder = AudioEngineRecorder()
        let engineResult = engineRecorder.startRecording(recordOptions: recordOptions)

        if engineResult.success {
            customMediaRecorder = engineRecorder
            NSLog("VoiceRecorder: Recording started with AudioEngineRecorder")
            isInterrupted = false
            wasInterruptedAndStopped = false
            call.resolve(ResponseGenerator.successResponse())
            return
        }

        NSLog("VoiceRecorder: AudioEngine failed (%@), falling back to AVAudioRecorder",
              engineResult.error?.errorDescription ?? "unknown")

        // Fallback: AVAudioRecorder (legacy, well-tested path)
        let legacyRecorder = CustomMediaRecorder()
        let recordingResult = legacyRecorder.startRecording(recordOptions: recordOptions)

        if recordingResult.success {
            customMediaRecorder = legacyRecorder
            NSLog("VoiceRecorder: Recording started with CustomMediaRecorder (fallback)")
            isInterrupted = false
            wasInterruptedAndStopped = false
            call.resolve(ResponseGenerator.successResponse())
            return
        }

        customMediaRecorder = nil

        // Build comprehensive error details from the fallback failure
        // (include Engine failure info for diagnostics)
        var errorDetails: [String: Any] = [
            "requestedDirectory": directory ?? "DOCUMENTS",
            "requestedSubDirectory": subDirectory ?? "none"
        ]

        if let recordingError = recordingResult.error {
            errorDetails["stage"] = recordingError.stage
            errorDetails["stageDetails"] = recordingError.details
            errorDetails["stageError"] = recordingError.errorDescription ?? "Unknown error"
        }

        // Include Engine failure info for diagnostics
        if let engineError = engineResult.error {
            errorDetails["engineFailure"] = [
                "stage": engineError.stage,
                "error": engineError.errorDescription ?? "Unknown",
                "details": engineError.details
            ]
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
    }

    @objc func stopRecording(_ call: CAPPluginCall) {
        if customMediaRecorder == nil {
            call.reject(Messages.RECORDING_HAS_NOT_STARTED)
            return
        }

        // Remove audio session interruption observer
        removeAudioSessionInterruptionHandling()

        customMediaRecorder?.stopRecording()

        guard let audioFileUrl = customMediaRecorder?.getOutputFile(),
              FileManager.default.fileExists(atPath: audioFileUrl.path) else {
            NSLog("VoiceRecorder: Recording file does not exist at expected path: %@",
                  customMediaRecorder?.getOutputFile()?.path ?? "nil")
            customMediaRecorder = nil
            call.reject(Messages.FAILED_TO_FETCH_RECORDING)
            return
        }

        var path = audioFileUrl.lastPathComponent
        if let subDirectory = customMediaRecorder?.options?.subDirectory {
            path = subDirectory + "/" + path
        }

        // Build diagnostics for the app layer
        var diagnostics: [String: Any] = [:]
        if let attrs = try? FileManager.default.attributesOfItem(atPath: audioFileUrl.path),
           let size = attrs[.size] as? UInt64 {
            diagnostics["fileSize"] = size
        }

        if let engineRecorder = customMediaRecorder as? AudioEngineRecorder {
            diagnostics["recorderType"] = "engine"
            diagnostics["conversion"] = engineRecorder.lastConversionResult.toDictionary()
        } else {
            diagnostics["recorderType"] = "legacy"
        }

        let sendDataAsBase64 = customMediaRecorder?.options?.directory == nil
        let recordData = RecordData(
            recordDataBase64: sendDataAsBase64 ? readFileAsBase64(audioFileUrl) : nil,
            mimeType: "audio/aac",
            msDuration: getMsDurationOfAudioFile(audioFileUrl),
            path: sendDataAsBase64 ? nil : path,
            diagnostics: diagnostics
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
            // Recording was interrupted - check reason before deciding to stop
            NSLog("VoiceRecorder: Interruption began")
            handleRecordingInterruptionWithReason(userInfo)

        case .ended:
            // Interruption ended
            NSLog("VoiceRecorder: Interruption ended")
            handleInterruptionEnded(userInfo)

        @unknown default:
            NSLog("VoiceRecorder: Unknown interruption type: %d", typeValue)
            break
        }
    }

    private func handleRecordingInterruptionWithReason(_ userInfo: [AnyHashable: Any]) {
        guard customMediaRecorder != nil else {
            return
        }

        var shouldStopRecording = false
        var reason = "unknown"

        // iOS 14.5+ - check interruption reason
        if #available(iOS 14.5, *) {
            if let reasonValue = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt,
               let interruptionReason = AVAudioSession.InterruptionReason(rawValue: reasonValue) {

                NSLog("VoiceRecorder: Interruption reason value: %d", reasonValue)

                switch interruptionReason {
                case .default:
                    // .default can mean:
                    // 1. Phone call / VoIP call (microphone occupied)
                    // 2. Video playback in WebView (only audio playback, microphone free)

                    // Use CallKit to check if there's an actual phone call
                    let callObserver = CXCallObserver()
                    let activeCalls = callObserver.calls
                    let hasActivePhoneCall = !activeCalls.isEmpty

                    NSLog("VoiceRecorder: Interruption reason: default - checking for phone call, active calls: %d", activeCalls.count)

                    if hasActivePhoneCall {
                        // Real phone call detected - STOP recording
                        shouldStopRecording = true
                        reason = "phone_call"
                        NSLog("VoiceRecorder: Active phone call detected - stopping recording")
                    } else {
                        // No phone call - likely WebView video or background music - CONTINUE recording
                        shouldStopRecording = false
                        reason = "background_audio"
                        NSLog("VoiceRecorder: No phone call detected - continuing recording (likely WebView video/music)")
                    }

                case .appWasSuspended:
                    // App went to background - CONTINUE recording in background
                    shouldStopRecording = false
                    reason = "app_background"
                    NSLog("VoiceRecorder: Interruption reason: appWasSuspended - continuing recording in background")

                case .builtInMicMuted:
                    // Microphone muted by hardware - STOP recording
                    shouldStopRecording = true
                    reason = "microphone_muted"
                    NSLog("VoiceRecorder: Interruption reason: microphone muted - stopping recording")

                @unknown default:
                    // Unknown reason - be cautious, STOP recording
                    shouldStopRecording = true
                    reason = "unknown"
                    NSLog("VoiceRecorder: Interruption reason: unknown (%d) - stopping recording", reasonValue)
                }
            } else {
                // No reason provided - be cautious, STOP recording
                shouldStopRecording = true
                reason = "no_reason_provided"
                NSLog("VoiceRecorder: No interruption reason provided - stopping recording")
            }
        } else {
            // iOS < 14.5 - no InterruptionReason API available
            // Be cautious, STOP recording
            shouldStopRecording = true
            reason = "ios_version_too_old"
            NSLog("VoiceRecorder: iOS < 14.5 - no interruption reason API available - stopping recording")
        }

        // Send event ONLY if we're actually stopping the recording
        if shouldStopRecording {
            isInterrupted = true

            let interruptionData: [String: Any] = [
                "data": [
                    "reason": reason,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            ]

            NSLog("VoiceRecorder: Sending recordingInterrupted - reason: %@", reason)
            notifyListeners("recordingInterrupted", data: interruptionData)
        } else {
            NSLog("VoiceRecorder: Interruption ignored - recording continues")
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
