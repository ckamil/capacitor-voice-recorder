import Foundation
import AVFoundation
import UIKit

struct RecordingError {
    let stage: String
    let details: [String: Any]
    let errorDescription: String?

    init(stage: String, details: [String: Any] = [:], errorDescription: String? = nil) {
        self.stage = stage
        self.details = details
        self.errorDescription = errorDescription
    }
}

struct RecordingResult {
    let success: Bool
    let error: RecordingError?

    static func success() -> RecordingResult {
        return RecordingResult(success: true, error: nil)
    }

    static func failure(stage: String, details: [String: Any] = [:], errorDescription: String? = nil) -> RecordingResult {
        let error = RecordingError(stage: stage, details: details, errorDescription: errorDescription)
        return RecordingResult(success: false, error: error)
    }
}

class CustomMediaRecorder: NSObject, AVAudioRecorderDelegate {

    var options: RecordOptions!
    private var recordingSession: AVAudioSession!
    private var audioRecorder: AVAudioRecorder!
    private var audioFilePath: URL!
    private var originalRecordingSessionCategory: AVAudioSession.Category!
    private var status = CurrentRecordingStatus.NONE

    private let settings = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    private func getDirectoryToSaveAudioFile() -> URL {
        if let directory = getDirectory(directory: options.directory),
           var outputDirURL = FileManager.default.urls(for: directory, in: .userDomainMask).first {
            if let subDirectory = options.subDirectory?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
                options.setSubDirectory(to: subDirectory)
                outputDirURL = outputDirURL.appendingPathComponent(subDirectory, isDirectory: true)

                do {
                    if !FileManager.default.fileExists(atPath: outputDirURL.path) {
                        try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)
                    }
                } catch {
                    print("Error creating directory: \(error)")
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

    // MARK: - AVAudioRecorderDelegate

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        NSLog("CustomMediaRecorder: Encode error occurred: %@", error?.localizedDescription ?? "unknown")
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            NSLog("CustomMediaRecorder: Recording finished unsuccessfully")
        }
    }

    func startRecording(recordOptions: RecordOptions) -> RecordingResult {
        do {
            options = recordOptions
            recordingSession = AVAudioSession.sharedInstance()
            let isIPad = UIDevice.current.userInterfaceIdiom == .pad
            let deviceInfo = getDeviceInfo()

            // Proactive cleanup: if session is stuck in .playAndRecord from a previous failed stop, reset it
            let needsCleanup = recordingSession.category == .playAndRecord
            if needsCleanup {
                NSLog("CustomMediaRecorder: Detected leftover .playAndRecord category, cleaning up")
                try? recordingSession.setActive(false, options: .notifyOthersOnDeactivation)
                try? recordingSession.setCategory(.ambient)
                Thread.sleep(forTimeInterval: 0.2)
            }

            let audioSessionDetails: [String: Any] = [
                "category": recordingSession.category.rawValue,
                "otherAudioPlaying": recordingSession.isOtherAudioPlaying,
                "availableInputsCount": recordingSession.availableInputs?.count ?? 0,
                "currentInputs": recordingSession.currentRoute.inputs.map { $0.portType.rawValue },
                "currentOutputs": recordingSession.currentRoute.outputs.map { $0.portType.rawValue },
                "availableInputs": recordingSession.availableInputs?.map { $0.portType.rawValue } ?? [],
                "deviceInfo": deviceInfo
            ]

            if recordingSession.isOtherAudioPlaying {
                return RecordingResult.failure(
                    stage: "audio_session_check",
                    details: audioSessionDetails,
                    errorDescription: "Other audio is playing"
                )
            }

            if recordingSession.availableInputs?.isEmpty == true {
                return RecordingResult.failure(
                    stage: "audio_session_check",
                    details: audioSessionDetails,
                    errorDescription: "No available inputs"
                )
            }

            // If cleanup was needed, always restore to .ambient regardless of whether
            // setCategory(.ambient) succeeded — prevents a cycle where
            // originalRecordingSessionCategory captures .playAndRecord from a stuck session,
            // stopRecording() restores it back, and the next start is stuck again (Pattern B).
            originalRecordingSessionCategory = needsCleanup ? .ambient : recordingSession.category
            // Step 1: Pure .playAndRecord — claim exclusive mic access on iPad
            // Do NOT use .mixWithOthers here — it prevents priority mic access on iPad
            try recordingSession.setCategory(.playAndRecord)
            try recordingSession.setActive(true)

            // Stabilisation delay – gives the audio session time to settle
            // after category/route changes before we attempt to record.
            // iPad needs a longer delay due to WKWebView audio session conflicts.
            let stabilisationDelay: TimeInterval = isIPad ? 0.5 : 0.15
            Thread.sleep(forTimeInterval: stabilisationDelay)

            let outputDir = getDirectoryToSaveAudioFile()
            audioFilePath = outputDir.appendingPathComponent("recording-\(Int(Date().timeIntervalSince1970 * 1000)).aac")

            // Check file path accessibility
            let parentDir = audioFilePath.deletingLastPathComponent()
            let parentDirWritable = FileManager.default.isWritableFile(atPath: parentDir.path)
            if !parentDirWritable {
                let filePathDetails: [String: Any] = [
                    "audioFilePath": audioFilePath.path,
                    "parentDir": parentDir.path,
                    "parentDirWritable": parentDirWritable,
                    "parentDirExists": FileManager.default.fileExists(atPath: parentDir.path)
                ]
                return RecordingResult.failure(
                    stage: "file_path_check",
                    details: filePathDetails,
                    errorDescription: "Cannot write to directory: \(parentDir.path)"
                )
            }

            audioRecorder = try AVAudioRecorder(url: audioFilePath, settings: settings)
            audioRecorder.delegate = self

            if !audioRecorder.prepareToRecord() {
                let recorderDetails: [String: Any] = [
                    "isRecording": audioRecorder.isRecording,
                    "format": audioRecorder.format.description,
                    "url": audioRecorder.url.path
                ]
                return RecordingResult.failure(
                    stage: "recorder_prepare",
                    details: recorderDetails,
                    errorDescription: "AVAudioRecorder.prepareToRecord failed"
                )
            }

            // Retry record() with hard audio session reset between attempts.
            // AVAudioRecorder.record() can return false when the audio session
            // is transiently busy (e.g. WKWebView audio session conflict on iPad).
            let maxRecordAttempts = 3
            var recordResult = false
            for attempt in 1...maxRecordAttempts {
                NSLog("CustomMediaRecorder: [attempt %d] inputAvailable=%@, category=%@, mode=%@, sampleRate=%.0f",
                    attempt, recordingSession.isInputAvailable ? "true" : "false",
                    recordingSession.category.rawValue, recordingSession.mode.rawValue,
                    recordingSession.sampleRate)

                recordResult = audioRecorder.record()

                // Fallback: try record(atTime:forDuration:) if record() returns false
                if !recordResult {
                    recordResult = audioRecorder.record(atTime: audioRecorder.deviceCurrentTime + 0.1, forDuration: 36000)
                    if recordResult {
                        NSLog("CustomMediaRecorder: record(atTime:forDuration:) worked as fallback on attempt %d", attempt)
                    }
                }

                if recordResult {
                    if attempt > 1 {
                        NSLog("CustomMediaRecorder: record() succeeded on attempt %d", attempt)
                    }
                    // Step 2: Enable mixing so WebView can play presentations alongside recording
                    try? recordingSession.setCategory(.playAndRecord, options: .mixWithOthers)
                    break
                }

                NSLog("CustomMediaRecorder: record() returned false on attempt %d/%d – inputs: %@, outputs: %@, category: %@",
                      attempt, maxRecordAttempts,
                      recordingSession.currentRoute.inputs.map { $0.portType.rawValue }.description,
                      recordingSession.currentRoute.outputs.map { $0.portType.rawValue }.description,
                      recordingSession.category.rawValue)

                if attempt < maxRecordAttempts {
                    // Hard reset: tear down recorder, switch to .ambient to fully
                    // release the audio session, then reconfigure from scratch.
                    audioRecorder.stop()
                    audioRecorder = nil

                    try recordingSession.setActive(false, options: .notifyOthersOnDeactivation)
                    try recordingSession.setCategory(.ambient)
                    Thread.sleep(forTimeInterval: isIPad ? 0.8 : 0.3)

                    // Use pure .playAndRecord without .mixWithOthers for retry
                    try recordingSession.setCategory(.playAndRecord)
                    try recordingSession.setActive(true)

                    Thread.sleep(forTimeInterval: isIPad ? 0.5 : 0.15)

                    // Recreate AVAudioRecorder with a fresh file path
                    audioFilePath = outputDir.appendingPathComponent("recording-\(Int(Date().timeIntervalSince1970 * 1000)).aac")
                    audioRecorder = try AVAudioRecorder(url: audioFilePath, settings: settings)
                    audioRecorder.delegate = self
                    if !audioRecorder.prepareToRecord() {
                        NSLog("CustomMediaRecorder: prepareToRecord() failed on retry attempt %d", attempt)
                        // Don't continue — tear down and retry from scratch on next iteration
                    }
                }
            }

            if !recordResult {
                let finalRecorderDetails: [String: Any] = [
                    "isRecording": audioRecorder?.isRecording ?? false,
                    "currentTime": audioRecorder?.currentTime ?? -1,
                    "totalAttempts": maxRecordAttempts,
                    "isIPad": isIPad,
                    "categoryAfterRetries": recordingSession.category.rawValue,
                    "isOtherAudioPlayingAfterRetries": recordingSession.isOtherAudioPlaying,
                    "inputsAfterRetries": recordingSession.currentRoute.inputs.map { $0.portType.rawValue },
                    "outputsAfterRetries": recordingSession.currentRoute.outputs.map { $0.portType.rawValue },
                    "availableInputsAfterRetries": recordingSession.availableInputs?.map { $0.portType.rawValue } ?? [],
                    "stabilisationDelay": isIPad ? 0.5 : 0.15,
                    "deviceModel": deviceInfo["model"] ?? "unknown",
                    "iosVersion": deviceInfo["systemVersion"] ?? "unknown",
                    "deviceIdiom": deviceInfo["idiom"] ?? "unknown"
                ]
                return RecordingResult.failure(
                    stage: "recorder_start",
                    details: finalRecorderDetails,
                    errorDescription: "AVAudioRecorder.record() returned false after \(maxRecordAttempts) attempts"
                )
            }

            status = CurrentRecordingStatus.RECORDING
            return RecordingResult.success()

        } catch let error {
            let catchDeviceInfo = getDeviceInfo()
            let errorDetails: [String: Any] = [
                "errorDescription": error.localizedDescription,
                "domain": (error as NSError).domain,
                "code": (error as NSError).code,
                "userInfo": (error as NSError).userInfo,
                "deviceModel": catchDeviceInfo["model"] ?? "unknown",
                "iosVersion": catchDeviceInfo["systemVersion"] ?? "unknown",
                "deviceIdiom": catchDeviceInfo["idiom"] ?? "unknown"
            ]
            return RecordingResult.failure(
                stage: "exception",
                details: errorDetails,
                errorDescription: error.localizedDescription
            )
        }
    }

    func stopRecording() {
        audioRecorder?.stop()

        // Attempt each cleanup step independently so a failure in one
        // doesn't skip the others (root cause of orphaned session / Pattern A).
        do {
            try recordingSession?.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("CustomMediaRecorder: stopRecording setActive(false) failed: %@", error.localizedDescription)
        }

        if let orig = originalRecordingSessionCategory {
            do {
                try recordingSession?.setCategory(orig)
            } catch {
                NSLog("CustomMediaRecorder: stopRecording setCategory failed: %@", error.localizedDescription)
            }
        }

        originalRecordingSessionCategory = nil
        audioRecorder = nil
        recordingSession = nil
        status = CurrentRecordingStatus.NONE
    }

    func getOutputFile() -> URL {
        return audioFilePath
    }

    func getDirectory(directory: String?) -> FileManager.SearchPathDirectory? {
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

    func pauseRecording() -> Bool {
        if status == CurrentRecordingStatus.RECORDING {
            audioRecorder.pause()
            status = CurrentRecordingStatus.PAUSED
            return true
        } else {
            return false
        }
    }

    func resumeRecording() -> Bool {
        if status == CurrentRecordingStatus.PAUSED {
            audioRecorder.record()
            status = CurrentRecordingStatus.RECORDING
            return true
        } else {
            return false
        }
    }

    func getCurrentStatus() -> CurrentRecordingStatus {
        return status
    }

}
