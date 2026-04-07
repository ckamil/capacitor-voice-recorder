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
            let maxActivationAttempts = 3
            var activationSuccess = false

            for attempt in 1...maxActivationAttempts {
                do {
                    if attempt > 1 {
                        NSLog("AudioEngineRecorder: setActive retry %d - hard reset", attempt)
                        try? recordingSession.setActive(false, options: .notifyOthersOnDeactivation)
                        try? recordingSession.setCategory(.ambient)
                        Thread.sleep(forTimeInterval: isIPad ? 0.8 : 0.3)
                    }

                    try recordingSession.setCategory(.playAndRecord, options: .mixWithOthers)
                    try recordingSession.setActive(true)

                    // Explicitly route mic input — critical for .mixWithOthers on iPad
                    if let builtInMic = recordingSession.availableInputs?.first(where: { $0.portType == .builtInMicrophone }) {
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
            let stabilisationDelay: TimeInterval = isIPad ? 1.0 : 0.15
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
                guard let self = self, !self.isPaused else { return }
                self.writeQueue.async {
                    do {
                        try self.pcmFile?.write(from: buffer)
                    } catch {
                        NSLog("AudioEngineRecorder: Failed to write buffer: %@", error.localizedDescription)
                    }
                }
            }

            // Start the engine
            audioEngine.prepare()
            try audioEngine.start()

            isPaused = false
            status = CurrentRecordingStatus.RECORDING

            NSLog("AudioEngineRecorder: Recording started (sampleRate=%.0f, channels=%d, format=%@)",
                  inputFormat.sampleRate, inputFormat.channelCount,
                  inputFormat.description)

            return RecordingResult.success()

        } catch {
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
        // Stop engine and remove tap
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        // Wait for all pending writes to complete, then finalize PCM file.
        // pcmFile is accessed on writeQueue (tap callback), so it must be
        // set to nil on the same queue to avoid a race condition.
        writeQueue.sync {
            self.pcmFile = nil
        }

        // Convert PCM to AAC
        lastConversionResult = .notAttempted
        if let pcmURL = pcmFileURL, FileManager.default.fileExists(atPath: pcmURL.path) {
            lastConversionResult = convertPCMtoAAC(inputURL: pcmURL, outputURL: aacFileURL)

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
        }

        // Restore audio session
        do {
            try recordingSession?.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("AudioEngineRecorder: stopRecording setActive(false) failed: %@", error.localizedDescription)
        }

        if let orig = originalRecordingSessionCategory {
            do {
                try recordingSession?.setCategory(orig)
            } catch {
                NSLog("AudioEngineRecorder: stopRecording setCategory failed: %@", error.localizedDescription)
            }
        }

        originalRecordingSessionCategory = nil
        audioEngine = nil
        recordingSession = nil
        isPaused = false
        status = CurrentRecordingStatus.NONE
    }

    func getOutputFile() -> URL {
        return aacFileURL
    }

    func pauseRecording() -> Bool {
        if status == CurrentRecordingStatus.RECORDING {
            isPaused = true
            status = CurrentRecordingStatus.PAUSED
            return true
        }
        return false
    }

    func resumeRecording() -> Bool {
        if status == CurrentRecordingStatus.PAUSED {
            isPaused = false
            status = CurrentRecordingStatus.RECORDING
            return true
        }
        return false
    }

    func getCurrentStatus() -> CurrentRecordingStatus {
        return status
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
            let frameCount = AVAudioFrameCount(inputFile.length)

            guard frameCount > 0 else {
                NSLog("AudioEngineRecorder: No audio frames to convert")
                return .failed(reason: "no_audio_frames")
            }

            // Read all PCM data
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
                NSLog("AudioEngineRecorder: Failed to create PCM buffer for conversion")
                return .failed(reason: "pcm_buffer_creation_failed")
            }
            try inputFile.read(into: pcmBuffer)

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

            // Use AVAudioConverter for PCM → AAC
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                NSLog("AudioEngineRecorder: Failed to create audio converter")
                return fallbackCopyPCM(from: inputURL, to: outputURL, reason: "converter_creation_failed")
            }
            converter.bitRate = 96000

            // Allocate output buffer
            let outputBufferSize = AVAudioFrameCount(1024)
            guard let outputBuffer = AVAudioCompressedBuffer(format: outputFormat,
                                                             packetCapacity: 1,
                                                             maximumPacketSize: converter.maximumOutputPacketSize) else {
                NSLog("AudioEngineRecorder: Failed to create compressed buffer")
                return fallbackCopyPCM(from: inputURL, to: outputURL, reason: "compressed_buffer_failed")
            }

            // Create output file (ExtAudioFile via AudioToolbox)
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

            // Set client format to match input
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

            // Write PCM data — ExtAudioFile handles the encoding
            let audioBufferList = pcmBuffer.audioBufferList
            status = ExtAudioFileWrite(outputFile, frameCount, audioBufferList)

            if status != noErr {
                NSLog("AudioEngineRecorder: Failed to write AAC data: %d", status)
            }

            ExtAudioFileDispose(outputFile)

            let outputSize = getFileSize(outputURL)
            NSLog("AudioEngineRecorder: PCM→AAC conversion complete (%d frames, %.1fs, %llu bytes)",
                  frameCount, Double(frameCount) / inputFormat.sampleRate, outputSize)

            return .success(fileSize: outputSize)

        } catch {
            NSLog("AudioEngineRecorder: Conversion failed: %@", error.localizedDescription)
            return fallbackCopyPCM(from: inputURL, to: outputURL, reason: "exception_\(error.localizedDescription)")
        }
    }
}
