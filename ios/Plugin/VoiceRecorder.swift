import Foundation
import AVFoundation
import Capacitor

@objc(VoiceRecorder)
public class VoiceRecorder: CAPPlugin {

    private var customMediaRecorder: CustomMediaRecorder?
    private var isInterrupted: Bool = false
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
            call.reject(Messages.MISSING_PERMISSION)
            return
        }

        if customMediaRecorder != nil {
            call.reject(Messages.ALREADY_RECORDING)
            return
        }

        // Setup audio session interruption handling
        setupAudioSessionInterruptionHandling()

        customMediaRecorder = CustomMediaRecorder()
        if customMediaRecorder == nil {
            call.reject(Messages.CANNOT_RECORD_ON_THIS_PHONE)
            return
        }

        let directory: String? = call.getString("directory")
        let subDirectory: String? = call.getString("subDirectory")
        let recordOptions = RecordOptions(directory: directory, subDirectory: subDirectory)
        let successfullyStartedRecording = customMediaRecorder!.startRecording(recordOptions: recordOptions)
        if successfullyStartedRecording == false {
            customMediaRecorder = nil
            call.reject(Messages.CANNOT_RECORD_ON_THIS_PHONE)
        } else {
            isInterrupted = false
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
              let type = AVAudioSessionInterruptionType(rawValue: typeValue) else {
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

            // Pause recording if it's active
            let currentStatus = customMediaRecorder?.getCurrentStatus()
            if currentStatus == CurrentRecordingStatus.RECORDING {
                let _ = customMediaRecorder?.pauseRecording()
            }

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

        // Handle global microphone availability only when not recording and not caused by our app
        if customMediaRecorder == nil && isMicrophoneCurrentlyAvailable && !isOurAppCausingInterruption() {
            isMicrophoneCurrentlyAvailable = false
            
            let availabilityData: [String: Any] = [
                "available": false,
                "reason": "other_app_started"
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
        if isInterrupted && customMediaRecorder != nil {
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

            // Auto-resume if system suggests it and recording is still paused
            if canResume && customMediaRecorder != nil {
                let currentStatus = customMediaRecorder?.getCurrentStatus()
                if currentStatus == CurrentRecordingStatus.PAUSED {
                    let _ = customMediaRecorder?.resumeRecording()
                }
            }

            isInterrupted = false
        }

        // Handle global microphone availability only when not recording and not caused by our app
        if customMediaRecorder == nil && !isMicrophoneCurrentlyAvailable && !isOurAppCausingInterruption() {
            isMicrophoneCurrentlyAvailable = true
            
            let availabilityData: [String: Any] = [
                "available": true,
                "reason": "other_app_finished"
            ]

            NSLog("VoiceRecorder: Sending microphoneAvailabilityChanged: true - other_app_finished")
            notifyListeners("microphoneAvailabilityChanged", data: availabilityData)
        }
    }

    // MARK: - Plugin Lifecycle

    public override func load() {
        super.load()
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
              let type = AVAudioSessionInterruptionType(rawValue: typeValue) else {
            return
        }

        // Only handle global events when not actively recording or when recording is interrupted
        if customMediaRecorder == nil || isInterrupted {
            switch type {
            case .began:
                handleRecordingInterruption() // Now handles both recording and global availability
                
            case .ended:
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
        
        if wasAvailable != isNowAvailable && (customMediaRecorder == nil || isInterrupted) && !isOurAppCausingInterruption() {
            isMicrophoneCurrentlyAvailable = isNowAvailable
            
            let reason = isNowAvailable ? "other_app_finished" : "other_app_started"
            let availabilityData: [String: Any] = [
                "available": isNowAvailable,
                "reason": reason
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

}
