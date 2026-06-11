import Foundation
import AVFoundation
import AudioToolbox
import UIKit

class AudioEngineRecorder: NSObject, RecorderInterface {

    var options: RecordOptions!
    private var audioEngine: AVAudioEngine!
    // AAC (ADTS) output written live from the tap — no intermediate PCM file.
    private var aacExtFile: ExtAudioFileRef?
    private var aacFileURL: URL!
    private var recordingSession: AVAudioSession!
    private var originalRecordingSessionCategory: AVAudioSession.Category!
    private var status = CurrentRecordingStatus.NONE
    private var isPaused = false
    private let writeQueue = DispatchQueue(label: "com.capacitor.voicerecorder.enginewriter")

    // Optional live WebSocket stream — additive, never affects the file. The encoder + sink run on
    // their own queue so a slow/failing network cannot delay the file writes on writeQueue.
    // Set by VoiceRecorder before startRecording so streaming lifecycle events reach the JS layer.
    var onStreamEvent: (([String: Any]) -> Void)?
    private var streamEncoder: AacFrameEncoder?
    private var streamSink: AudioStreamSink?
    private var streamTailReader: AdtsFileTailReader?   // used only in .fileTail mode
    private let streamQueue = DispatchQueue(label: "com.capacitor.voicerecorder.streamencode")
    private var streamSeq: UInt32 = 0               // mutated only on streamQueue
    private var streamFramesEnqueued: UInt64 = 0    // mutated only on streamQueue (AAC frames sent to sink)
    private var lastStreamingDiagnostics: [String: Any]?

    // Fixed tap/encoder PCM format, kept so the tap can be re-installed after an engine
    // configuration change (route/sample-rate change) without breaking the AAC client format.
    private var recordingFormat: AVAudioFormat?
    private var engineConfigObserver: NSObjectProtocol?

    // Engine-internal counters updated during recording and consumed by getDiagnostics().
    // All mutations happen on writeQueue (same queue as the AAC writes) so reads via
    // writeQueue.sync are consistent. Reset on each startRecording().
    private var tapCallbacksCount: UInt64 = 0           // number of tap buffer deliveries from iOS
    private var framesWrittenCount: UInt64 = 0          // total frames successfully encoded to AAC
    private var writeErrorsCount: UInt64 = 0            // failed ExtAudioFileWrite calls
    private var lastWriteError: String? = nil           // most recent write error description
    private var inputSampleRate: Double = 0             // hardware input rate at engine start
    private var inputChannelCount: UInt32 = 0
    private var recordingFormatDescription: String? = nil
    private var engineStartedAt: Date? = nil
    private var engineStoppedAt: Date? = nil
    private var pauseStartedAt: Date? = nil
    private var pausedTotalMs: Double = 0
    private var engineRestartCount: Int = 0     // times the engine was auto-restarted after a config change
    private var activationErrorsForDiagnostics: [[String: Any]] = []

    private func getDirectoryToSaveAudioFile() throws -> URL {
        if let directory = getDirectory(directory: options.directory),
           var outputDirURL = FileManager.default.urls(for: directory, in: .userDomainMask).first {
            if let subDirectory = options.subDirectory?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
                options.setSubDirectory(to: subDirectory)
                outputDirURL = outputDirURL.appendingPathComponent(subDirectory, isDirectory: true)

                if !FileManager.default.fileExists(atPath: outputDirURL.path) {
                    try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)
                }
            }

            return outputDirURL
        }

        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    private func getDeviceInfo() -> [String: String] {
        let device = UIDevice.current
        return [
            "model": device.model,
            "systemVersion": device.systemVersion,
            "name": device.name,
            "idiom": device.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        ]
    }

    private func getDirectory(directory: String?) -> FileManager.SearchPathDirectory? {
        if let directory = directory {
            switch directory {
            case "CACHE":
                return .cachesDirectory
            case "LIBRARY":
                return .libraryDirectory
            default:
                return .documentDirectory
            }
        }
        return nil
    }

    func startRecording(recordOptions: RecordOptions) -> RecordingResult {
        var activationErrors: [[String: Any]] = []

        // Reset per-session diagnostics counters
        tapCallbacksCount = 0
        framesWrittenCount = 0
        writeErrorsCount = 0
        lastWriteError = nil
        inputSampleRate = 0
        inputChannelCount = 0
        recordingFormatDescription = nil
        engineStartedAt = nil
        engineStoppedAt = nil
        pauseStartedAt = nil
        pausedTotalMs = 0
        engineRestartCount = 0
        activationErrorsForDiagnostics = []
        streamSeq = 0
        streamFramesEnqueued = 0
        streamEncoder = nil
        streamSink = nil
        streamTailReader = nil
        lastStreamingDiagnostics = nil

        do {
            options = recordOptions
            recordingSession = AVAudioSession.sharedInstance()
            let isIPad = UIDevice.current.userInterfaceIdiom == .pad
            let deviceInfo = getDeviceInfo()

            // Proactive cleanup: if session is stuck in .playAndRecord from a previous failed stop
            let needsCleanup = recordingSession.category == .playAndRecord
            if needsCleanup {
                NSLog("AudioEngineRecorder: Detected leftover .playAndRecord category, cleaning up")
                try? recordingSession.setActive(false, options: .notifyOthersOnDeactivation)
                try? recordingSession.setCategory(.ambient)
                Thread.sleep(forTimeInterval: 0.2)
            }

            if recordingSession.availableInputs?.isEmpty == true {
                return RecordingResult.failure(
                    stage: "audio_session_check",
                    details: [
                        "recorderType": "engine",
                        "availableInputs": recordingSession.availableInputs?.map { $0.portType.rawValue } ?? [],
                        "deviceInfo": deviceInfo
                    ],
                    errorDescription: "No available inputs"
                )
            }

            originalRecordingSessionCategory = needsCleanup ? .ambient : recordingSession.category

            // AVAudioEngine works well with .mixWithOthers — use it from the start.
            // Unlike AVAudioRecorder, installTap does not suffer from record()=false
            // when .mixWithOthers is active.
            let maxActivationAttempts = 2
            var activationSuccess = false

            for attempt in 1...maxActivationAttempts {
                do {
                    if attempt > 1 {
                        NSLog("AudioEngineRecorder: setActive retry %d - hard reset", attempt)
                        try? recordingSession.setActive(false, options: .notifyOthersOnDeactivation)
                        try? recordingSession.setCategory(.ambient)
                        Thread.sleep(forTimeInterval: isIPad ? 0.5 : 0.2)
                    }

                    try recordingSession.setCategory(.playAndRecord, options: .mixWithOthers)
                    try recordingSession.setActive(true)

                    // Explicitly route mic input — critical for .mixWithOthers on iPad
                    if let builtInMic = recordingSession.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                        try? recordingSession.setPreferredInput(builtInMic)
                    }

                    activationSuccess = true
                    NSLog("AudioEngineRecorder: setActive succeeded on attempt %d/%d, inputs=%@, preferredInput=%@",
                          attempt, maxActivationAttempts,
                          recordingSession.currentRoute.inputs.map { $0.portType.rawValue }.description,
                          recordingSession.preferredInput?.portName ?? "none")
                    break

                } catch {
                    activationErrors.append([
                        "attempt": attempt,
                        "error": error.localizedDescription,
                        "domain": (error as NSError).domain,
                        "code": (error as NSError).code
                    ])
                    NSLog("AudioEngineRecorder: setActive failed attempt %d/%d: %@",
                          attempt, maxActivationAttempts, error.localizedDescription)
                }
            }

            if !activationSuccess {
                cleanupAfterFailedStart()
                return RecordingResult.failure(
                    stage: "session_activation",
                    details: [
                        "recorderType": "engine",
                        "totalAttempts": maxActivationAttempts,
                        "activationErrors": activationErrors,
                        "isIPad": isIPad,
                        "needsCleanup": needsCleanup,
                        "deviceModel": deviceInfo["model"] ?? "unknown",
                        "iosVersion": deviceInfo["systemVersion"] ?? "unknown",
                        "deviceIdiom": deviceInfo["idiom"] ?? "unknown"
                    ],
                    errorDescription: "Session activation failed after \(maxActivationAttempts) attempts"
                )
            }

            // Stabilisation delay
            let stabilisationDelay: TimeInterval = isIPad ? 0.5 : 0.1
            Thread.sleep(forTimeInterval: stabilisationDelay)

            // Prepare output directory and file path
            let outputDir = try getDirectoryToSaveAudioFile()
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            aacFileURL = outputDir.appendingPathComponent("recording-\(timestamp).aac")

            // Set up AVAudioEngine
            audioEngine = AVAudioEngine()
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
                cleanupAfterFailedStart()
                return RecordingResult.failure(
                    stage: "engine_start",
                    details: [
                        "recorderType": "engine",
                        "sampleRate": inputFormat.sampleRate,
                        "channelCount": inputFormat.channelCount,
                        "currentInputs": recordingSession.currentRoute.inputs.map { $0.portType.rawValue },
                        "preferredInput": recordingSession.preferredInput?.portName ?? "none"
                    ],
                    errorDescription: "Invalid input format: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)"
                )
            }

            // Create mono format for the tap (match input sample rate). This is also the
            // client (PCM) data format we feed into the AAC encoder below. Kept fixed for the
            // whole recording so it survives a route/sample-rate change (the engine resamples
            // into this format when the tap is re-installed after a configuration change).
            guard let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                      sampleRate: inputFormat.sampleRate,
                                                      channels: 1,
                                                      interleaved: false) else {
                cleanupAfterFailedStart()
                return RecordingResult.failure(
                    stage: "engine_start",
                    details: [
                        "recorderType": "engine",
                        "sampleRate": inputFormat.sampleRate,
                        "channelCount": inputFormat.channelCount
                    ],
                    errorDescription: "Failed to create PCM recording format (sampleRate=\(inputFormat.sampleRate))"
                )
            }
            self.recordingFormat = recordingFormat

            // Open the AAC (ADTS) output file and encode the tap's PCM directly to AAC,
            // streamed (no intermediate WAV, no conversion step at stop). Any failure here
            // is treated as an engine-start failure so VoiceRecorder falls back to legacy.
            if let openFailure = openAacFile(clientFormat: recordingFormat, sampleRate: inputFormat.sampleRate) {
                cleanupAfterFailedStart()
                return openFailure
            }

            // Install tap to capture audio buffers and encode them to AAC.
            installInputTap()

            // Start the engine
            audioEngine.prepare()
            try audioEngine.start()

            // Recover from route/sample-rate changes (Bluetooth/headphones connect, WebView
            // reconfiguring the shared session, etc.) which make iOS STOP the engine. Without
            // this the tap goes silent and capture is lost mid-recording (a classic cause of
            // "only ~1s recorded"). On the notification we re-install the tap and restart the
            // engine into the SAME open AAC file, so recording continues seamlessly.
            engineConfigObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: audioEngine,
                queue: nil
            ) { [weak self] _ in
                self?.handleEngineConfigurationChange()
            }

            isPaused = false
            status = CurrentRecordingStatus.RECORDING
            inputSampleRate = inputFormat.sampleRate
            inputChannelCount = inputFormat.channelCount
            recordingFormatDescription = inputFormat.description
            engineStartedAt = Date()
            activationErrorsForDiagnostics = activationErrors

            // Optional, additive: start the live stream once the engine is confirmed running.
            // Any failure here only disables streaming — the recording is already live.
            setupStreamingIfNeeded(pcmFormat: recordingFormat)

            NSLog("AudioEngineRecorder: Recording started (sampleRate=%.0f, channels=%d, format=%@)",
                  inputFormat.sampleRate, inputFormat.channelCount,
                  inputFormat.description)

            return RecordingResult.success()

        } catch {
            cleanupAfterFailedStart()
            let catchDeviceInfo = getDeviceInfo()
            return RecordingResult.failure(
                stage: "exception",
                details: [
                    "recorderType": "engine",
                    "errorDescription": error.localizedDescription,
                    "domain": (error as NSError).domain,
                    "code": (error as NSError).code,
                    "activationErrors": activationErrors,
                    "preferredInput": recordingSession?.preferredInput?.portName ?? "none",
                    "currentInputs": recordingSession?.currentRoute.inputs.map { $0.portType.rawValue } ?? [],
                    "deviceModel": catchDeviceInfo["model"] ?? "unknown",
                    "iosVersion": catchDeviceInfo["systemVersion"] ?? "unknown",
                    "deviceIdiom": catchDeviceInfo["idiom"] ?? "unknown"
                ],
                errorDescription: error.localizedDescription
            )
        }
    }

    /// Open the ADTS AAC output file and set its client (input) data format to the tap's PCM
    /// format. Returns a RecordingResult.failure on any error (so the caller falls back to
    /// legacy), or nil on success (`aacExtFile` is then ready for writes).
    private func openAacFile(clientFormat: AVAudioFormat, sampleRate: Double) -> RecordingResult? {
        var outputDescription = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var extFileRef: ExtAudioFileRef?
        var st = ExtAudioFileCreateWithURL(
            aacFileURL as CFURL,
            kAudioFileAAC_ADTSType,
            &outputDescription,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &extFileRef
        )

        guard st == noErr, let extFile = extFileRef else {
            NSLog("AudioEngineRecorder: ExtAudioFileCreateWithURL failed: %d", st)
            return RecordingResult.failure(
                stage: "engine_aac_open",
                details: ["recorderType": "engine", "step": "create", "status": Int(st), "sampleRate": sampleRate],
                errorDescription: "ExtAudioFileCreateWithURL failed: \(st)"
            )
        }

        // C1: client format MUST come from the same AVAudioFormat used to install the tap,
        // so non-interleaved/float32/packed flags and byte counts are correct.
        var clientASBD = clientFormat.streamDescription.pointee
        st = ExtAudioFileSetProperty(
            extFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
        )

        if st != noErr {
            NSLog("AudioEngineRecorder: set ClientDataFormat failed: %d", st)
            ExtAudioFileDispose(extFile)
            return RecordingResult.failure(
                stage: "engine_aac_open",
                details: ["recorderType": "engine", "step": "client_format", "status": Int(st)],
                errorDescription: "ExtAudioFileSetProperty(ClientDataFormat) failed: \(st)"
            )
        }

        aacExtFile = extFile

        // Allow writes while the device is locked in the background — proximity-triggered
        // recordings can start with the screen locked, and the default data-protection class
        // would otherwise block disk writes until the next unlock.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: aacFileURL.path
        )

        return nil
    }

    /// (Re)install the input tap that encodes PCM buffers to AAC. Uses the fixed
    /// `recordingFormat`, so the engine resamples for us if the hardware route changed its
    /// rate. The AVAudioPCMBuffer is captured (retained) into the async block, keeping its
    /// backing store valid for ExtAudioFileWrite.
    private func installInputTap() {
        guard let engine = audioEngine, let fmt = recordingFormat else { return }
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        // Captured by value (immutable) so the real-time render thread never reads the mutable
        // streamSink/streamEncoder references; those are confined to streamQueue.
        let streamingEnabled = (options?.streaming != nil)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.writeQueue.async {
                self.tapCallbacksCount &+= 1
                if self.isPaused { return }
                guard let ext = self.aacExtFile else { return }
                let st = ExtAudioFileWrite(ext, buffer.frameLength, buffer.audioBufferList)
                if st == noErr {
                    self.framesWrittenCount &+= UInt64(buffer.frameLength)
                } else {
                    self.writeErrorsCount &+= 1
                    self.lastWriteError = "ExtAudioFileWrite \(st)"
                    NSLog("AudioEngineRecorder: Failed to encode AAC buffer: %d", st)
                }
            }

            // Additive live stream: encode + enqueue on a SEPARATE queue so a slow/failing
            // network never delays the file writes above. Skipped while paused (like the file).
            if streamingEnabled {
                self.streamQueue.async {
                    guard !self.isPaused,
                          let encoder = self.streamEncoder,
                          let sink = self.streamSink else { return }
                    let frames = encoder.encode(buffer)
                    guard !frames.isEmpty else { return }
                    let rate = UInt64(fmt.sampleRate > 0 ? fmt.sampleRate : 48000)
                    for frame in frames {
                        // Integer math + truncating cast: avoids a UInt32(Double) overflow trap on
                        // extremely long recordings and matches Android's 32-bit wrap behaviour.
                        let ms = self.streamFramesEnqueued &* 1024 &* 1000 / max(1, rate)
                        let tsMs = UInt32(truncatingIfNeeded: ms)
                        sink.enqueue(seq: self.streamSeq, timestampMs: tsMs, adts: frame)
                        self.streamSeq = self.streamSeq &+ 1
                        self.streamFramesEnqueued &+= 1
                    }
                }
            }
        }
    }

    /// Engine stopped because the audio route/format changed (Bluetooth/headset connect or
    /// disconnect, WebView reconfiguring the shared session for presentation audio, sample
    /// rate change, etc.). Re-establish the tap and restart the engine so capture continues
    /// into the SAME open AAC file. Best-effort: if restart fails the recording ends at the
    /// change point (no worse than before this handler existed).
    private func handleEngineConfigurationChange() {
        // Restart while RECORDING *or* PAUSED: pause does not stop the engine (it only drops
        // buffers via isPaused), so a route/format change during a pause would otherwise leave
        // the engine stopped — and resumeRecording does not restart it — making the rest of the
        // recording silent after resume. Keeping the engine alive while paused writes nothing
        // (the tap still honours isPaused) but means resume has a live engine to capture into.
        guard status == CurrentRecordingStatus.RECORDING || status == CurrentRecordingStatus.PAUSED,
              let engine = audioEngine else { return }
        if engine.isRunning { return } // engine survived the change — nothing to do
        NSLog("AudioEngineRecorder: configuration change — engine stopped, attempting restart")
        try? recordingSession?.setActive(true)
        installInputTap()
        engine.prepare()
        do {
            try engine.start()
            engineRestartCount += 1
            NSLog("AudioEngineRecorder: engine restarted after configuration change (#%d)", engineRestartCount)
        } catch {
            NSLog("AudioEngineRecorder: engine restart FAILED after configuration change: %@", error.localizedDescription)
            lastWriteError = "engine_restart_failed: \(error.localizedDescription)"
        }
    }

    private func removeEngineConfigObserver() {
        if let obs = engineConfigObserver {
            NotificationCenter.default.removeObserver(obs)
            engineConfigObserver = nil
        }
    }

    func stopRecording() {
        // Stop reacting to configuration changes before we tear the engine down, so a late
        // notification cannot restart an engine we are finalizing.
        removeEngineConfigObserver()

        engineStoppedAt = Date()
        // Finalize pause accounting if we were paused at stop time.
        if let pauseStart = pauseStartedAt {
            pausedTotalMs += Date().timeIntervalSince(pauseStart) * 1000
            pauseStartedAt = nil
        }

        NSLog("AudioEngineRecorder: stop [A] removing tap")
        // Stop engine and remove tap
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            NSLog("AudioEngineRecorder: stop [B] tap removed, stopping engine")
            engine.stop()
            NSLog("AudioEngineRecorder: stop [C] engine stopped")
        }

        // C2: drain any queued writes and finalize the AAC file on the SAME queue the tap
        // writes on, so the file is never disposed while a queued ExtAudioFileWrite is still
        // in flight (would write to a freed ref). Dispose flushes the trailing AAC packet.
        NSLog("AudioEngineRecorder: stop [D] writeQueue.sync (finalize AAC)")
        writeQueue.sync {
            if let ext = self.aacExtFile {
                ExtAudioFileDispose(ext)
                self.aacExtFile = nil
            }
        }
        NSLog("AudioEngineRecorder: stop [E] AAC finalized")

        // Finish the live stream (if any). The tap is already removed, so streamQueue.sync acts as
        // a barrier draining the last encodes before we read the final frame count and close.
        // Read the counters and clear the references on streamQueue (their only owner), then
        // finalize the sink off-queue. Tap is already removed, so this also drains any last encode.
        var totalStreamFrames: UInt64 = 0
        var sinkToFinish: AudioStreamSink?
        var readerToStop: AdtsFileTailReader?
        streamQueue.sync {
            totalStreamFrames = self.streamFramesEnqueued
            sinkToFinish = self.streamSink
            readerToStop = self.streamTailReader
            self.streamSink = nil
            self.streamEncoder = nil
            self.streamTailReader = nil
        }
        // .fileTail: stop the reader (final synchronous drain) and take its frame count — the
        // tap-side counter (streamFramesEnqueued) is 0 in that mode.
        if let reader = readerToStop {
            reader.stop()
            totalStreamFrames = reader.framesEnqueued
        }
        if let sink = sinkToFinish {
            let rate = inputSampleRate > 0 ? inputSampleRate : 48000
            let msDuration = Int((Double(totalStreamFrames) * 1024.0 / rate * 1000.0).rounded())
            sink.finish(framesEnqueued: totalStreamFrames, msDuration: msDuration)
            lastStreamingDiagnostics = sink.diagnosticsSnapshot()
        }

        // Restore audio session — retry deactivation to prevent orphaned .playAndRecord
        NSLog("AudioEngineRecorder: stop [H] restoring audio session")
        var deactivated = false
        for attempt in 1...2 {
            do {
                try recordingSession?.setActive(false, options: .notifyOthersOnDeactivation)
                deactivated = true
                break
            } catch {
                NSLog("AudioEngineRecorder: stopRecording setActive(false) failed attempt %d: %@", attempt, error.localizedDescription)
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }
        if !deactivated {
            NSLog("AudioEngineRecorder: stopRecording WARNING - deactivation failed, forcing via .soloAmbient")
            try? recordingSession?.setCategory(.soloAmbient)
            Thread.sleep(forTimeInterval: 0.2)
            try? recordingSession?.setActive(false, options: .notifyOthersOnDeactivation)
        }

        if let orig = originalRecordingSessionCategory {
            do {
                try recordingSession?.setCategory(orig)
            } catch {
                NSLog("AudioEngineRecorder: stopRecording setCategory(%@) failed: %@", orig.rawValue, error.localizedDescription)
                try? recordingSession?.setCategory(.ambient)
            }
        }

        originalRecordingSessionCategory = nil
        audioEngine = nil
        recordingFormat = nil
        recordingSession = nil
        isPaused = false
        status = CurrentRecordingStatus.NONE
        NSLog("AudioEngineRecorder: stop [I] done")
    }

    func getOutputFile() -> URL? {
        return aacFileURL
    }

    func pauseRecording() -> Bool {
        if status == CurrentRecordingStatus.RECORDING {
            isPaused = true
            pauseStartedAt = Date()
            status = CurrentRecordingStatus.PAUSED
            return true
        }
        return false
    }

    func resumeRecording() -> Bool {
        if status == CurrentRecordingStatus.PAUSED {
            isPaused = false
            if let pauseStart = pauseStartedAt {
                pausedTotalMs += Date().timeIntervalSince(pauseStart) * 1000
                pauseStartedAt = nil
            }
            status = CurrentRecordingStatus.RECORDING
            return true
        }
        return false
    }

    func getCurrentStatus() -> CurrentRecordingStatus {
        return status
    }

    func getDiagnostics() -> [String: Any] {
        // Read counters on the write queue so we see a consistent snapshot
        // (tap + mutations happen there).
        var tapCalls: UInt64 = 0
        var frames: UInt64 = 0
        var writeErrs: UInt64 = 0
        var lastErr: String? = nil
        writeQueue.sync {
            tapCalls = self.tapCallbacksCount
            frames = self.framesWrittenCount
            writeErrs = self.writeErrorsCount
            lastErr = self.lastWriteError
        }

        var diag: [String: Any] = [
            "tap_callbacks": tapCalls,
            "frames_written": frames,
            "write_errors": writeErrs,
            "input_sample_rate": inputSampleRate,
            "input_channels": inputChannelCount,
            "paused_total_ms": Int(pausedTotalMs),
            "engine_restarts": engineRestartCount,
            "activation_errors_count": activationErrorsForDiagnostics.count,
        ]
        if let lastErr = lastErr { diag["last_write_error"] = lastErr }
        if let fmt = recordingFormatDescription { diag["input_format"] = fmt }
        if !activationErrorsForDiagnostics.isEmpty {
            diag["activation_errors"] = activationErrorsForDiagnostics
        }

        if let started = engineStartedAt {
            let ended = engineStoppedAt ?? Date()
            let runMs = ended.timeIntervalSince(started) * 1000
            let activeMs = max(0, runMs - pausedTotalMs)
            diag["engine_run_time_ms"] = Int(runMs)
            diag["engine_active_time_ms"] = Int(activeMs)
            if inputSampleRate > 0 && frames > 0 {
                let audioMs = Double(frames) / inputSampleRate * 1000
                diag["audio_captured_ms"] = Int(audioMs)
                if activeMs > 0 {
                    // Ratio of captured audio vs time engine was running (non-paused).
                    // <1.0 means mic delivered fewer buffers than expected (silence/dropouts).
                    diag["audio_capture_ratio"] = audioMs / activeMs
                }
            }
        }

        return diag
    }

    // MARK: - Streaming (optional, additive)

    /// Final streaming diagnostics, captured at stopRecording. nil when streaming was not requested.
    func streamingDiagnostics() -> [String: Any]? {
        return lastStreamingDiagnostics
    }

    /// Build the AAC encoder + WebSocket sink for the live stream. Best-effort: on any failure the
    /// stream is simply disabled (recording continues; file is unaffected).
    private func setupStreamingIfNeeded(pcmFormat: AVAudioFormat) {
        guard let cfg = options.streaming else { return }

        // Build the AAC frame producer for the chosen mode. `.fileTail` does not re-encode — it
        // tails the on-disk ADTS file — so no tap-side encoder is created in that case.
        var encoder: AacFrameEncoder?
        switch cfg.encodeMode {
        case .hardware:
            encoder = AacAdtsStreamEncoder(pcmFormat: pcmFormat)
        case .software:
            encoder = AacAdtsSoftwareEncoder(pcmFormat: pcmFormat)
        case .fileTail:
            encoder = nil
        }

        if cfg.encodeMode != .fileTail && encoder == nil {
            lastStreamingDiagnostics = ["enabled": true, "finalState": "encoder_init_failed", "encodeMode": cfg.encodeMode.rawValue]
            onStreamEvent?(streamEvent([
                "type": "error",
                "reason": "encoder_init_failed",
                "message": "Unable to initialise AAC encoder for streaming (mode \(cfg.encodeMode.rawValue))"
            ]))
            NSLog("AudioEngineRecorder: streaming disabled — AAC encoder init failed (mode %@)", cfg.encodeMode.rawValue)
            return
        }

        lastStreamingDiagnostics = ["enabled": true, "finalState": "init", "encodeMode": cfg.encodeMode.rawValue]
        let sink = AudioStreamSink(
            config: cfg,
            sampleRate: pcmFormat.sampleRate,
            channels: Int(pcmFormat.channelCount),
            recordingId: UUID().uuidString
        ) { [weak self] event in
            self?.onStreamEvent?(event)
        }
        sink.start()

        if cfg.encodeMode == .fileTail {
            // No tap encoder; tail the ADTS file the recorder is already writing.
            let reader = AdtsFileTailReader(fileURL: aacFileURL, sink: sink, sampleRate: pcmFormat.sampleRate)
            streamQueue.async {
                self.streamEncoder = nil
                self.streamSink = sink
                self.streamTailReader = reader
            }
            reader.start()
            return
        }

        // hardware / software: encode the tap's PCM. Assign on streamQueue so these references
        // are only ever touched there (the tap reads them on streamQueue, stop nils them there).
        streamQueue.async {
            self.streamEncoder = encoder
            self.streamSink = sink
        }
    }

    private func streamEvent(_ payload: [String: Any]) -> [String: Any] {
        var enriched = payload
        enriched["timestamp"] = ISO8601DateFormatter().string(from: Date())
        return enriched
    }

    // MARK: - Cleanup

    private func cleanupAfterFailedStart() {
        NSLog("AudioEngineRecorder: cleanupAfterFailedStart")
        removeEngineConfigObserver()
        streamTailReader?.stop()
        streamTailReader = nil
        if let sink = streamSink {
            sink.cancel()
            streamSink = nil
            streamEncoder = nil
        }
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        recordingFormat = nil
        if let ext = aacExtFile {
            ExtAudioFileDispose(ext)
            aacExtFile = nil
        }

        // Restore audio session to original state so legacy recorder can use it cleanly
        do {
            try recordingSession?.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("AudioEngineRecorder: cleanup setActive(false) failed: %@", error.localizedDescription)
        }
        if let orig = originalRecordingSessionCategory {
            try? recordingSession?.setCategory(orig)
        }
        originalRecordingSessionCategory = nil
        recordingSession = nil
        status = CurrentRecordingStatus.NONE
    }
}
