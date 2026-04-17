import Foundation
import AVFoundation
import UIKit

enum ConversionResult {
    case success(fileSize: UInt64)
    case fallbackToPCMCopy(reason: String, fileSize: UInt64)
    case failed(reason: String)
    case notAttempted

    func toDictionary() -> [String: Any] {
        switch self {
        case .success(let fileSize):
            return ["status": "success", "fileSize": fileSize]
        case .fallbackToPCMCopy(let reason, let fileSize):
            return ["status": "fallback_pcm_copy", "reason": reason, "fileSize": fileSize]
        case .failed(let reason):
            return ["status": "failed", "reason": reason]
        case .notAttempted:
            return ["status": "not_attempted"]
        }
    }
}

class AudioEngineRecorder: NSObject, RecorderInterface {

    var options: RecordOptions!
    var lastConversionResult: ConversionResult = .notAttempted
    private var audioEngine: AVAudioEngine!
    private var pcmFile: AVAudioFile!
    private var pcmFileURL: URL!
    private var aacFileURL: URL!
    private var recordingSession: AVAudioSession!
    private var originalRecordingSessionCategory: AVAudioSession.Category!
    private var status = CurrentRecordingStatus.NONE
    private var isPaused = false
    private let writeQueue = DispatchQueue(label: "com.capacitor.voicerecorder.enginewriter")

    // Engine-internal counters updated during recording and consumed by getDiagnostics().
    // All mutations happen on writeQueue (same queue as pcmFile writes) so reads via
    // writeQueue.sync are consistent. Reset on each startRecording().
    private var tapCallbacksCount: UInt64 = 0           // number of tap buffer deliveries from iOS
    private var framesWrittenCount: UInt64 = 0          // total frames successfully written to PCM file
    private var writeErrorsCount: UInt64 = 0            // failed pcmFile.write(from:) calls
    private var lastWriteError: String? = nil           // most recent write error description
    private var inputSampleRate: Double = 0             // hardware input rate at engine start
    private var inputChannelCount: UInt32 = 0
    private var recordingFormatDescription: String? = nil
    private var engineStartedAt: Date? = nil
    private var engineStoppedAt: Date? = nil
    private var pauseStartedAt: Date? = nil
    private var pausedTotalMs: Double = 0
    private var pcmFileSizeAtStop: UInt64 = 0
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
        pcmFileSizeAtStop = 0
        activationErrorsForDiagnostics = []

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

            // Prepare output directory and file paths
            let outputDir = try getDirectoryToSaveAudioFile()
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            pcmFileURL = outputDir.appendingPathComponent("recording-\(timestamp)-pcm.wav")
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

            // Create mono format for recording (match input sample rate)
            let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: inputFormat.sampleRate,
                                                channels: 1,
                                                interleaved: false)!

            // Create PCM file for writing
            pcmFile = try AVAudioFile(forWriting: pcmFileURL,
                                      settings: recordingFormat.settings,
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: false)

            // Install tap on input node to capture audio buffers
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
                guard let self = self else { return }
                self.writeQueue.async {
                    self.tapCallbacksCount &+= 1
                    if self.isPaused { return }
                    do {
                        try self.pcmFile?.write(from: buffer)
                        self.framesWrittenCount &+= UInt64(buffer.frameLength)
                    } catch {
                        self.writeErrorsCount &+= 1
                        self.lastWriteError = error.localizedDescription
                        NSLog("AudioEngineRecorder: Failed to write buffer: %@", error.localizedDescription)
                    }
                }
            }

            // Start the engine
            audioEngine.prepare()
            try audioEngine.start()

            isPaused = false
            status = CurrentRecordingStatus.RECORDING
            inputSampleRate = inputFormat.sampleRate
            inputChannelCount = inputFormat.channelCount
            recordingFormatDescription = inputFormat.description
            engineStartedAt = Date()
            activationErrorsForDiagnostics = activationErrors

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

    func stopRecording() {
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

        // Wait for all pending writes to complete, then finalize PCM file.
        NSLog("AudioEngineRecorder: stop [D] writeQueue.sync")
        writeQueue.sync {
            self.pcmFile = nil
        }
        NSLog("AudioEngineRecorder: stop [E] writeQueue done")

        // Convert PCM to AAC
        lastConversionResult = .notAttempted
        if let pcmURL = pcmFileURL, FileManager.default.fileExists(atPath: pcmURL.path) {
            let pcmSize = getFileSize(pcmURL)
            pcmFileSizeAtStop = pcmSize
            NSLog("AudioEngineRecorder: stop [F] converting PCM→AAC (%llu bytes)", pcmSize)
            lastConversionResult = convertPCMtoAAC(inputURL: pcmURL, outputURL: aacFileURL)
            NSLog("AudioEngineRecorder: stop [G] conversion done: %@",
                  String(describing: lastConversionResult.toDictionary()))

            // If conversion failed entirely, attempt last-resort PCM copy
            if case .failed = lastConversionResult {
                if !FileManager.default.fileExists(atPath: aacFileURL.path) {
                    if let _ = try? FileManager.default.copyItem(at: pcmURL, to: aacFileURL),
                       let attrs = try? FileManager.default.attributesOfItem(atPath: aacFileURL.path),
                       let size = attrs[.size] as? UInt64 {
                        lastConversionResult = .fallbackToPCMCopy(reason: "last_resort_copy", fileSize: size)
                        NSLog("AudioEngineRecorder: Last resort PCM copy succeeded (%llu bytes)", size)
                    } else {
                        NSLog("AudioEngineRecorder: Last resort PCM copy also failed")
                    }
                }
            }

            // Clean up temp PCM file
            try? FileManager.default.removeItem(at: pcmURL)
        } else {
            NSLog("AudioEngineRecorder: stop [F] no PCM file to convert")
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
            "pcm_file_size_bytes": pcmFileSizeAtStop,
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

    // MARK: - Cleanup

    private func cleanupAfterFailedStart() {
        NSLog("AudioEngineRecorder: cleanupAfterFailedStart")
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        pcmFile = nil

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

    // MARK: - PCM to AAC Conversion

    private func getFileSize(_ url: URL) -> UInt64 {
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    private func fallbackCopyPCM(from inputURL: URL, to outputURL: URL, reason: String) -> ConversionResult {
        NSLog("AudioEngineRecorder: Falling back to PCM copy (%@)", reason)
        if let _ = try? FileManager.default.copyItem(at: inputURL, to: outputURL) {
            let size = getFileSize(outputURL)
            return .fallbackToPCMCopy(reason: reason, fileSize: size)
        }
        return .failed(reason: reason)
    }

    private func convertPCMtoAAC(inputURL: URL, outputURL: URL) -> ConversionResult {
        do {
            let inputFile = try AVAudioFile(forReading: inputURL)
            let inputFormat = inputFile.processingFormat
            let totalFrames = AVAudioFrameCount(inputFile.length)

            guard totalFrames > 0 else {
                NSLog("AudioEngineRecorder: No audio frames to convert")
                return .failed(reason: "no_audio_frames")
            }

            NSLog("AudioEngineRecorder: Converting %d frames (%.1fs) PCM→AAC",
                  totalFrames, Double(totalFrames) / inputFormat.sampleRate)

            // Set up AAC output format
            var outputDescription = AudioStreamBasicDescription(
                mSampleRate: inputFormat.sampleRate,
                mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: 1024,
                mBytesPerFrame: 0,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 0,
                mReserved: 0
            )

            guard let outputFormat = AVAudioFormat(streamDescription: &outputDescription) else {
                NSLog("AudioEngineRecorder: Failed to create AAC output format")
                return fallbackCopyPCM(from: inputURL, to: outputURL, reason: "aac_format_creation_failed")
            }

            // Create output file (ExtAudioFile handles PCM→AAC encoding internally)
            var outputFileRef: ExtAudioFileRef?
            var status = ExtAudioFileCreateWithURL(
                outputURL as CFURL,
                kAudioFileAAC_ADTSType,
                &outputDescription,
                nil,
                AudioFileFlags.eraseFile.rawValue,
                &outputFileRef
            )

            guard status == noErr, let outputFile = outputFileRef else {
                NSLog("AudioEngineRecorder: Failed to create output AAC file: %d", status)
                return fallbackCopyPCM(from: inputURL, to: outputURL, reason: "output_file_creation_failed_\(status)")
            }

            // Set client format to match input PCM format
            var clientFormat = inputFormat.streamDescription.pointee
            status = ExtAudioFileSetProperty(
                outputFile,
                kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &clientFormat
            )

            if status != noErr {
                NSLog("AudioEngineRecorder: Failed to set client format: %d", status)
                ExtAudioFileDispose(outputFile)
                return fallbackCopyPCM(from: inputURL, to: outputURL, reason: "client_format_failed_\(status)")
            }

            // Process in chunks to avoid OOM — ~1 second of audio per chunk
            let chunkSize = AVAudioFrameCount(inputFormat.sampleRate)
            guard let chunkBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunkSize) else {
                NSLog("AudioEngineRecorder: Failed to create chunk buffer")
                ExtAudioFileDispose(outputFile)
                return fallbackCopyPCM(from: inputURL, to: outputURL, reason: "chunk_buffer_failed")
            }

            var framesWritten: AVAudioFrameCount = 0
            var chunkIndex = 0
            while framesWritten < totalFrames {
                let framesToRead = min(chunkSize, totalFrames - framesWritten)

                try inputFile.read(into: chunkBuffer, frameCount: framesToRead)
                let actualFrames = chunkBuffer.frameLength

                NSLog("AudioEngineRecorder: chunk %d: requested=%d, read=%d, position=%lld/%d",
                      chunkIndex, framesToRead, actualFrames, inputFile.framePosition, totalFrames)

                let bufferList = chunkBuffer.audioBufferList
                status = ExtAudioFileWrite(outputFile, actualFrames, bufferList)

                if status != noErr {
                    NSLog("AudioEngineRecorder: Failed to write AAC chunk %d at frame %d: %d",
                          chunkIndex, framesWritten, status)
                    ExtAudioFileDispose(outputFile)
                    return fallbackCopyPCM(from: inputURL, to: outputURL, reason: "write_failed_\(status)")
                }

                framesWritten += actualFrames
                chunkIndex += 1

                if actualFrames == 0 {
                    NSLog("AudioEngineRecorder: read returned 0 frames, breaking")
                    break
                }
            }

            ExtAudioFileDispose(outputFile)

            let outputSize = getFileSize(outputURL)
            NSLog("AudioEngineRecorder: PCM→AAC conversion complete (%d frames, %.1fs, %llu bytes)",
                  totalFrames, Double(totalFrames) / inputFormat.sampleRate, outputSize)

            return .success(fileSize: outputSize)

        } catch {
            NSLog("AudioEngineRecorder: Conversion failed: %@", error.localizedDescription)
            return fallbackCopyPCM(from: inputURL, to: outputURL, reason: "exception_\(error.localizedDescription)")
        }
    }
}
