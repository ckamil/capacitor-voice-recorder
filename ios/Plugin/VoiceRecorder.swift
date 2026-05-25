import Foundation
import AVFoundation
import Capacitor
import CallKit
import UIKit

@objc(VoiceRecorder)
public class VoiceRecorder: CAPPlugin {

    private var customMediaRecorder: RecorderInterface?
    // Held for the whole duration of an active recording so iOS treats the app as doing
    // important work and is less likely to suspend it in the background. The `audio`
    // background mode is the primary keep-alive; this is a belt-and-suspenders that also
    // protects the start handshake when a recording is launched into the background by a
    // location event.
    private var recordingBgTaskId: UIBackgroundTaskIdentifier = .invalid
    // When true, ambiguous interruptions (no reason / unknown reason / iOS < 14.5) let the
    // recording CONTINUE (rely on the engine auto-restart) instead of stopping. Set per
    // startRecording from the JS layer (`recording.continue_on_ambiguous_interruption`), which
    // keeps this remotely controllable. Default false → current (cautious-stop) behaviour.
    private var continueOnAmbiguousInterruption: Bool = false
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

        let directory: String? = call.getString("directory")
        let subDirectory: String? = call.getString("subDirectory")
        self.continueOnAmbiguousInterruption = call.getBool("continueOnAmbiguousInterruption") ?? false
        let streamingOptions = parseStreamingOptions(call)

        // Heavy work (audio session activation, Thread.sleep retries) runs off main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                call.reject(Messages.CANNOT_RECORD_ON_THIS_PHONE)
                return
            }

            // Check audio session state before creating recorder
            let audioSession = AVAudioSession.sharedInstance()

            if audioSession.isOtherAudioPlaying {
                NSLog("VoiceRecorder: Other audio is playing (category: %@), proceeding - likely WebView presentation",
                      audioSession.category.rawValue)
                if audioSession.category == .playAndRecord {
                    NSLog("VoiceRecorder: Detected orphaned .playAndRecord with otherAudioPlaying, cleaning up")
                    try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                    try? audioSession.setCategory(.ambient)
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }

            if audioSession.availableInputs?.isEmpty == true {
                self.rejectWithDiagnostics(call,
                                     Messages.CANNOT_RECORD_ON_THIS_PHONE,
                                     "No microphone input available",
                                     ["availableInputs": 0])
                return
            }

            // Setup audio session interruption handling
            self.setupAudioSessionInterruptionHandling()

            let recordOptions = RecordOptions(directory: directory, subDirectory: subDirectory, streaming: streamingOptions)

            // Try AVAudioEngine first, fall back to AVAudioRecorder if Engine fails.
            let engineRecorder = AudioEngineRecorder()
            // Forward live-streaming lifecycle events to the JS layer for logging. Set before
            // startRecording so connect/error events emitted during setup are delivered.
            engineRecorder.onStreamEvent = { [weak self] event in
                self?.notifyListeners("recordingStreamEvent", data: event)
            }
            let engineResult = engineRecorder.startRecording(recordOptions: recordOptions)

            if engineResult.success {
                self.customMediaRecorder = engineRecorder
                NSLog("VoiceRecorder: Recording started with AudioEngineRecorder")
                self.beginRecordingBackgroundTask()
                self.isInterrupted = false
                self.wasInterruptedAndStopped = false
                call.resolve([
                    "value": true,
                    "engine": "audio_engine",
                    "engineFallback": NSNull()
                ])
                return
            }

            NSLog("VoiceRecorder: AudioEngine failed (%@), falling back to AVAudioRecorder",
                  engineResult.error?.errorDescription ?? "unknown")

            // Nuclear reset: if Engine failed on session_activation, aggressively reset the
            // audio session before Legacy gets its chance. Uses .soloAmbient to force-release
            // all audio session conflicts, then leaves session clean for Legacy to configure.
            if let engineError = engineResult.error, engineError.stage == "session_activation" {
                NSLog("VoiceRecorder: Engine failed on session_activation, performing nuclear reset before Legacy attempt")
                let audioSession = AVAudioSession.sharedInstance()
                try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                try? audioSession.setCategory(.soloAmbient)
                Thread.sleep(forTimeInterval: 1.0)
                try? audioSession.setActive(false)
                try? audioSession.setCategory(.ambient)

                // Verify input routing settled after reset
                Thread.sleep(forTimeInterval: 0.3)
                if let builtInMic = audioSession.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                    try? audioSession.setPreferredInput(builtInMic)
                }
                NSLog("VoiceRecorder: Nuclear reset done, inputs=%@, availableInputs=%@",
                      audioSession.currentRoute.inputs.map { $0.portType.rawValue }.description,
                      audioSession.availableInputs?.map { $0.portType.rawValue }.description ?? "nil")
            }

            // Fallback: AVAudioRecorder (legacy, well-tested path)
            let legacyRecorder = CustomMediaRecorder()
            let recordingResult = legacyRecorder.startRecording(recordOptions: recordOptions)

            if recordingResult.success {
                self.customMediaRecorder = legacyRecorder
                NSLog("VoiceRecorder: Recording started with CustomMediaRecorder (fallback)")
                self.beginRecordingBackgroundTask()
                self.isInterrupted = false
                self.wasInterruptedAndStopped = false

                let audioSession = AVAudioSession.sharedInstance()
                var fallback: [String: Any] = [
                    "stage": engineResult.error?.stage ?? "unknown",
                    "error": engineResult.error?.errorDescription ?? "unknown",
                    "isOtherAudioPlaying": audioSession.isOtherAudioPlaying,
                    "deviceIdiom": UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
                ]
                if let activationErrors = engineResult.error?.details["activationErrors"] as? [[String: Any]] {
                    fallback["activationErrors"] = activationErrors
                }
                if let stageDetails = engineResult.error?.details {
                    fallback["details"] = stageDetails
                }

                call.resolve([
                    "value": true,
                    "engine": "legacy",
                    "engineFallback": fallback
                ])
                return
            }

            self.customMediaRecorder = nil

            var errorDetails: [String: Any] = [
                "requestedDirectory": directory ?? "DOCUMENTS",
                "requestedSubDirectory": subDirectory ?? "none"
            ]

            if let recordingError = recordingResult.error {
                errorDetails["stage"] = recordingError.stage
                errorDetails["stageDetails"] = recordingError.details
                errorDetails["stageError"] = recordingError.errorDescription ?? "Unknown error"
            }

            if let engineError = engineResult.error {
                errorDetails["engineFailure"] = [
                    "stage": engineError.stage,
                    "error": engineError.errorDescription ?? "Unknown",
                    "details": engineError.details
                ]
            }

            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "unknown"
            let isDocumentsWritable = FileManager.default.isWritableFile(atPath: documentsPath)
            errorDetails["documentsPath"] = documentsPath
            errorDetails["documentsWritable"] = isDocumentsWritable

            let errorMessage = recordingResult.error?.errorDescription ?? "Recording setup failed"

            self.rejectWithDiagnostics(call,
                           Messages.CANNOT_RECORD_ON_THIS_PHONE,
                           errorMessage,
                           errorDetails)
        }
    }

    @objc func stopRecording(_ call: CAPPluginCall) {
        guard let recorder = customMediaRecorder else {
            call.reject(Messages.RECORDING_HAS_NOT_STARTED)
            return
        }

        // Recording is ending — release the long-lived recording background task. The
        // separate stop background task below covers the finalize/flush window.
        endRecordingBackgroundTask()

        // Remove audio session interruption observer
        removeAudioSessionInterruptionHandling()

        // Begin background task so iOS gives us up to ~30 s (or more, depending on iOS
        // policy) to finish PCM→AAC conversion + base64 encoding even when the app has
        // moved to the background between the user pressing stop and the conversion
        // finishing. Without this, iOS may suspend the process mid-conversion and the
        // .aac file is left without a finalized header → app layer sees file_missing.
        let bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "VoiceRecorderStop") {
            NSLog("VoiceRecorder: stopRecording background task expired before completion")
        }

        NSLog("VoiceRecorder: stopRecording [1] dispatching to background (bgTaskId=%lu)",
              UInt(bgTaskId.rawValue))

        // Heavy work (PCM→AAC conversion, base64 encoding) must run off the main thread
        // to avoid freezing the UI.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer {
                if bgTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskId)
                }
            }

            guard let self = self else {
                NSLog("VoiceRecorder: stopRecording [ERR] self is nil")
                call.reject(Messages.FAILED_TO_FETCH_RECORDING)
                return
            }

            NSLog("VoiceRecorder: stopRecording [2] calling recorder.stopRecording()")
            recorder.stopRecording()
            NSLog("VoiceRecorder: stopRecording [3] recorder.stopRecording() done")

            guard let audioFileUrl = recorder.getOutputFile(),
                  FileManager.default.fileExists(atPath: audioFileUrl.path) else {
                NSLog("VoiceRecorder: Recording file does not exist at expected path: %@",
                      recorder.getOutputFile()?.path ?? "nil")
                self.customMediaRecorder = nil
                call.reject(Messages.FAILED_TO_FETCH_RECORDING)
                return
            }
            NSLog("VoiceRecorder: stopRecording [4] outputFile=%@", audioFileUrl.path)

            var path = audioFileUrl.lastPathComponent
            if let subDirectory = recorder.options?.subDirectory {
                path = subDirectory + "/" + path
            }

            // Build diagnostics for the app layer
            var diagnostics: [String: Any] = [:]
            if let attrs = try? FileManager.default.attributesOfItem(atPath: audioFileUrl.path),
               let size = attrs[.size] as? UInt64 {
                diagnostics["fileSize"] = size
                NSLog("VoiceRecorder: stopRecording [5] fileSize=%llu", size)
            }

            if let engineRecorder = recorder as? AudioEngineRecorder {
                diagnostics["recorderType"] = "engine"
                // AAC is now encoded live from the tap (ADTS) — no separate PCM→AAC conversion
                // step. Keep the `conversion.status` key populated for log continuity.
                diagnostics["conversion"] = ["status": "streamed_adts"]
                diagnostics["engine"] = engineRecorder.getDiagnostics()
                if let streaming = engineRecorder.streamingDiagnostics() {
                    diagnostics["streaming"] = streaming
                }
            } else {
                diagnostics["recorderType"] = "legacy"
                let extra = recorder.getDiagnostics()
                if !extra.isEmpty { diagnostics["legacy"] = extra }
            }

            let sendDataAsBase64 = recorder.options?.directory == nil
            NSLog("VoiceRecorder: stopRecording [6] sendDataAsBase64=%@, directory=%@",
                  sendDataAsBase64 ? "true" : "false",
                  recorder.options?.directory ?? "nil")

            NSLog("VoiceRecorder: stopRecording [7] reading base64/duration...")
            let recordData = RecordData(
                recordDataBase64: sendDataAsBase64 ? self.readFileAsBase64(audioFileUrl) : nil,
                mimeType: "audio/aac",
                msDuration: self.getMsDurationOfAudioFile(audioFileUrl),
                path: sendDataAsBase64 ? nil : path,
                diagnostics: diagnostics
            )
            NSLog("VoiceRecorder: stopRecording [8] recordData ready, msDuration=%d, base64len=%d",
                  recordData.msDuration,
                  recordData.recordDataBase64?.count ?? 0)

            // If we were interrupted, mark that we stopped due to interruption
            if self.isInterrupted {
                self.wasInterruptedAndStopped = true
            }

            self.customMediaRecorder = nil
            self.isInterrupted = false
            if (sendDataAsBase64 && recordData.recordDataBase64 == nil) || recordData.msDuration < 0 {
                NSLog("VoiceRecorder: stopRecording [9] rejecting - empty recording")
                call.reject(Messages.EMPTY_RECORDING)
            } else {
                NSLog("VoiceRecorder: stopRecording [9] resolving with data")
                call.resolve(ResponseGenerator.dataResponse(recordData.toDictionary()))
                NSLog("VoiceRecorder: stopRecording [10] resolve done")
            }
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

    /// Returns timestamps recorded by AppDelegate lifecycle hooks plus a derived
    /// abnormal_restart flag. JS layer polls this once on app start to log the
    /// previous process's outcome to person_app_logs. After reading, JS calls
    /// clearAbnormalRestartFlag() so the flag does not re-fire on the next resume.
    @objc func getLifecycleSnapshot(_ call: CAPPluginCall) {
        let defaults = UserDefaults.standard
        // See AppDelegate.applicationDidBecomeActive for why we use `integer(forKey:)`
        // instead of `object(forKey:) as? Int64` — NSNumber bridging issue.
        let lastBg = Int64(defaults.integer(forKey: "vr_last_background_at_ms"))
        let lastClean = Int64(defaults.integer(forKey: "vr_clean_termination_at_ms"))
        let lastActive = Int64(defaults.integer(forKey: "vr_last_active_at_ms"))
        let lastResign = Int64(defaults.integer(forKey: "vr_last_resign_active_at_ms"))
        let abnormal = defaults.bool(forKey: "vr_abnormal_restart_pending")

        call.resolve([
            "last_background_at_ms": NSNumber(value: lastBg),
            "last_clean_termination_at_ms": NSNumber(value: lastClean),
            "last_active_at_ms": NSNumber(value: lastActive),
            "last_resign_active_at_ms": NSNumber(value: lastResign),
            "abnormal_restart_pending": abnormal,
            "thermal_state": self.thermalStateString(),
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "is_protected_data_available": UIApplication.shared.isProtectedDataAvailable
        ])
    }

    @objc func clearAbnormalRestartFlag(_ call: CAPPluginCall) {
        UserDefaults.standard.set(false, forKey: "vr_abnormal_restart_pending")
        call.resolve()
    }

    private func thermalStateString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
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
        } catch {
            NSLog("VoiceRecorder: readFileAsBase64 failed: %@", error.localizedDescription)
        }

        return nil
    }

    func getMsDurationOfAudioFile(_ filePath: URL?) -> Int {
        if filePath == nil {
            return -1
        }
        return Int(CMTimeGetSeconds(AVURLAsset(url: filePath!).duration) * 1000)
    }

    // MARK: - Streaming options

    /// Parse the optional `streaming` object from startRecording. Returns nil (streaming disabled)
    /// when absent or when the URL is missing/invalid. The whole block is read per call, so each
    /// recording connects to whatever server the active profile passed.
    private func parseStreamingOptions(_ call: CAPPluginCall) -> StreamingConfig? {
        guard let obj = call.getObject("streaming") else { return nil }
        guard let urlString = obj["url"] as? String, let url = URL(string: urlString) else {
            NSLog("VoiceRecorder: streaming option present but url missing/invalid — streaming disabled")
            return nil
        }

        let token = obj["token"] as? String

        var headers: [String: String] = [:]
        if let rawHeaders = obj["headers"] as? JSObject {
            for (key, value) in rawHeaders {
                if let stringValue = value as? String { headers[key] = stringValue }
            }
        }

        var configPayload: [String: Any] = [:]
        if let rawConfig = obj["config"] as? JSObject {
            for (key, value) in rawConfig { configPayload[key] = value }
        }

        // Coerce via NSNumber so a JS number bridged as the "other" numeric type is still honoured
        // (matches Android's optInt/optDouble); `as? Int` alone would silently fall back to default.
        let reconnect = obj["reconnect"] as? JSObject
        let initialDelayMs = (reconnect?["initialDelayMs"] as? NSNumber)?.intValue ?? 1000
        let maxDelayMs = (reconnect?["maxDelayMs"] as? NSNumber)?.intValue ?? 8000
        let maxAttempts = (reconnect?["maxAttempts"] as? NSNumber)?.intValue ?? 0
        let maxBufferSeconds = (obj["maxBufferSeconds"] as? NSNumber)?.doubleValue ?? 10
        let pingIntervalMs = (obj["pingIntervalMs"] as? NSNumber)?.intValue ?? 20000
        let requireReachability = (obj["requireReachability"] as? Bool) ?? true

        return StreamingConfig(
            url: url,
            token: token,
            headers: headers,
            config: configPayload,
            reconnectInitialDelayMs: initialDelayMs,
            reconnectMaxDelayMs: maxDelayMs,
            reconnectMaxAttempts: maxAttempts,
            maxBufferSeconds: maxBufferSeconds,
            pingIntervalMs: pingIntervalMs,
            requireReachability: requireReachability
        )
    }


    // MARK: - Audio Session Interruption Handling
    //
    // DESIGN NOTE — there are intentionally TWO interruption observers, on different planes.
    // Do NOT "deduplicate" them by removing one; they cover different cases:
    //
    //  1. Per-recording observer (this section, `object: AVAudioSession.sharedInstance()`,
    //     added in startRecording / removed in stopRecording). Plane: "should THIS active
    //     recording stop?" — the smart decision via CallKit (real phone call → stop; WebView
    //     video / background music → keep recording), mic-muted, etc. Exists only WHILE recording.
    //
    //  2. Global observer (`setupGlobalAudioSessionListener`, `object: nil`, alive from load()).
    //     Plane: microphone-availability tracking even when we are NOT recording (so the app
    //     learns when another app grabs/releases the mic → `microphoneAvailabilityChanged`),
    //     route changes, and a deliberate BACKUP `interruptionEnded` for the case the
    //     per-recording observer missed the `.ended` (e.g. it was already removed during stop).
    //     Its guard `customMediaRecorder == nil || isInterrupted` means it does NOTHING during a
    //     healthy active recording — no overlap there; the two planes only meet in the narrow
    //     `interrupted → .ended` window, where the global one is an on-purpose safety net.
    //
    // The only artifact of that overlap is a possible double `interruptionEnded`, which the JS
    // layer already tolerates (it guards re-entry / auto-resume). Removing the `|| isInterrupted`
    // guard or deleting the global observer would reintroduce a missed-event window during stop —
    // exactly what the backup was added to prevent (commit 79a196f "add interruption events").

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

    private func gatherInterruptionContext() -> [String: Any] {
        var ctx: [String: Any] = [:]

        let readMainThreadValues: () -> (String, Double, Bool) = {
            let stateStr: String
            switch UIApplication.shared.applicationState {
            case .active:     stateStr = "active"
            case .inactive:   stateStr = "inactive"
            case .background: stateStr = "background"
            @unknown default: stateStr = "unknown"
            }
            return (
                stateStr,
                UIApplication.shared.backgroundTimeRemaining,
                UIApplication.shared.isProtectedDataAvailable
            )
        }

        let (appState, bgTime, protectedDataAvailable): (String, Double, Bool)
        if Thread.isMainThread {
            (appState, bgTime, protectedDataAvailable) = readMainThreadValues()
        } else {
            var tuple: (String, Double, Bool) = ("unknown", -1, false)
            DispatchQueue.main.sync { tuple = readMainThreadValues() }
            (appState, bgTime, protectedDataAvailable) = tuple
        }
        ctx["app_state"] = appState
        // backgroundTimeRemaining is .greatestFiniteMagnitude when in foreground — cap for JSON safety.
        ctx["background_time_remaining_s"] = bgTime.isFinite && bgTime < 1_000_000 ? bgTime : nil
        ctx["is_protected_data_available"] = protectedDataAvailable

        let processInfo = ProcessInfo.processInfo
        switch processInfo.thermalState {
        case .nominal:  ctx["thermal_state"] = "nominal"
        case .fair:     ctx["thermal_state"] = "fair"
        case .serious:  ctx["thermal_state"] = "serious"
        case .critical: ctx["thermal_state"] = "critical"
        @unknown default: ctx["thermal_state"] = "unknown"
        }
        ctx["low_power_mode"] = processInfo.isLowPowerModeEnabled

        let callObserver = CXCallObserver()
        let activeCalls = callObserver.calls
        ctx["has_active_call"] = !activeCalls.isEmpty
        ctx["active_calls_count"] = activeCalls.count

        let session = AVAudioSession.sharedInstance()
        ctx["other_audio_playing"] = session.isOtherAudioPlaying
        ctx["audio_session_category"] = session.category.rawValue
        ctx["audio_session_mode"] = session.mode.rawValue
        ctx["is_input_available"] = session.isInputAvailable
        ctx["available_inputs"] = (session.availableInputs ?? []).map { $0.portType.rawValue }
        ctx["current_route_inputs"] = session.currentRoute.inputs.map { $0.portType.rawValue }
        ctx["current_route_outputs"] = session.currentRoute.outputs.map { $0.portType.rawValue }
        ctx["is_microphone_currently_available"] = isMicrophoneCurrentlyAvailable

        return ctx
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
                    // Unknown reason — ambiguous. Default: cautious STOP. With the engine
                    // auto-restart in place, the app can opt to ride it through instead.
                    shouldStopRecording = !continueOnAmbiguousInterruption
                    reason = continueOnAmbiguousInterruption ? "unknown_continued" : "unknown"
                    NSLog("VoiceRecorder: Interruption reason: unknown (%d) - %@", reasonValue,
                          shouldStopRecording ? "stopping" : "continuing (ambiguous-continue enabled)")
                }
            } else {
                // No reason provided — ambiguous (see @unknown above).
                shouldStopRecording = !continueOnAmbiguousInterruption
                reason = continueOnAmbiguousInterruption ? "no_reason_continued" : "no_reason_provided"
                NSLog("VoiceRecorder: No interruption reason provided - %@",
                      shouldStopRecording ? "stopping" : "continuing (ambiguous-continue enabled)")
            }
        } else {
            // iOS < 14.5 - no InterruptionReason API available — ambiguous (see @unknown above).
            shouldStopRecording = !continueOnAmbiguousInterruption
            reason = continueOnAmbiguousInterruption ? "ios_version_too_old_continued" : "ios_version_too_old"
            NSLog("VoiceRecorder: iOS < 14.5 - no interruption reason API - %@",
                  shouldStopRecording ? "stopping" : "continuing (ambiguous-continue enabled)")
        }

        // Send event ONLY if we're actually stopping the recording
        if shouldStopRecording {
            isInterrupted = true

            var payload: [String: Any] = [
                "reason": reason,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "source": "audio_session_interruption"
            ]
            for (k, v) in gatherInterruptionContext() { payload[k] = v }

            NSLog("VoiceRecorder: Sending recordingInterrupted - reason: %@, app_state: %@", reason, String(describing: payload["app_state"] ?? "unknown"))
            notifyListeners("recordingInterrupted", data: ["data": payload])
        } else {
            NSLog("VoiceRecorder: Interruption ignored - recording continues")
        }
    }

    private func handleRecordingInterruption() {
        NSLog("VoiceRecorder: handleRecordingInterruption called - customMediaRecorder: %@", customMediaRecorder != nil ? "exists" : "nil")

        // Handle recording interruption if we have an active recording
        if customMediaRecorder != nil {
            isInterrupted = true

            var payload: [String: Any] = [
                "reason": "system_interruption",
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "source": "global_audio_session"
            ]
            for (k, v) in gatherInterruptionContext() { payload[k] = v }

            NSLog("VoiceRecorder: Sending recordingInterrupted event to JavaScript - reason: system_interruption, app_state: %@", String(describing: payload["app_state"] ?? "unknown"))
            notifyListeners("recordingInterrupted", data: ["data": payload])
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

    // MARK: - Recording background task

    /// Begin a background task held for the whole recording. UIApplication APIs must run on
    /// the main thread (startRecording runs on a background queue), hence the dispatch.
    private func beginRecordingBackgroundTask() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // End any previous one first so we never leak across recordings.
            if self.recordingBgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(self.recordingBgTaskId)
                self.recordingBgTaskId = .invalid
            }
            self.recordingBgTaskId = UIApplication.shared.beginBackgroundTask(withName: "VoiceRecorderActive") { [weak self] in
                // Expiration: iOS is reclaiming the assertion. End it so we aren't force-killed
                // for holding it; the `audio` background mode keeps the recording itself alive.
                NSLog("VoiceRecorder: recording background task expired")
                self?.endRecordingBackgroundTask()
            }
            NSLog("VoiceRecorder: recording background task begun (id=%lu)", UInt(self.recordingBgTaskId.rawValue))
        }
    }

    private func endRecordingBackgroundTask() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.recordingBgTaskId != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.recordingBgTaskId)
            self.recordingBgTaskId = .invalid
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
    //
    // Second interruption plane — see the DESIGN NOTE above `setupAudioSessionInterruptionHandling`.
    // This observer is the global / not-recording plane (mic availability, route changes) plus a
    // deliberate `interruptionEnded` backup. It is NOT redundant with the per-recording observer.

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

        // mediaserverd can crash/reset; this invalidates the whole audio stack (session +
        // engine), so an active recording cannot continue. Notify the JS layer so it stops,
        // saves what was captured (the ADTS .aac is playable up to the reset) and may restart.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesWereReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    private func removeGlobalAudioSessionListener() {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    @objc private func handleMediaServicesWereReset(_ notification: Notification) {
        NSLog("VoiceRecorder: mediaServicesWereReset — audio stack invalidated")
        guard customMediaRecorder != nil else { return }

        isInterrupted = true
        var payload: [String: Any] = [
            "reason": "media_services_reset",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "source": "media_services_reset"
        ]
        for (k, v) in gatherInterruptionContext() { payload[k] = v }

        NSLog("VoiceRecorder: Sending recordingInterrupted - reason: media_services_reset")
        notifyListeners("recordingInterrupted", data: ["data": payload])
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

        // Device identification for diagnostics
        var systemInfo = utsname()
        uname(&systemInfo)
        let modelCode = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }

        var diagnosticInfo: [String: Any] = [
            "baseError": baseMessage,
            "reason": reason,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "platform": "ios",
            "audioSessionCategory": audioSession.category.rawValue,
            "isOtherAudioPlaying": audioSession.isOtherAudioPlaying,
            "availableInputs": audioSession.availableInputs?.count ?? 0,
            "hasRecordPermission": doesUserGaveAudioRecordingPermission(),
            "deviceModel": modelCode,
            "iosVersion": UIDevice.current.systemVersion,
            "deviceIdiom": UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"
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
