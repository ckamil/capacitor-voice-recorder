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

class CustomMediaRecorder {

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

    func startRecording(recordOptions: RecordOptions) -> RecordingResult {
        do {
            options = recordOptions
            recordingSession = AVAudioSession.sharedInstance()

            let audioSessionDetails: [String: Any] = [
                "category": recordingSession.category.rawValue,
                "otherAudioPlaying": recordingSession.isOtherAudioPlaying,
                "availableInputsCount": recordingSession.availableInputs?.count ?? 0,
                "currentInputs": recordingSession.currentRoute.inputs.map { $0.portType.rawValue },
                "currentOutputs": recordingSession.currentRoute.outputs.map { $0.portType.rawValue },
                "availableInputs": recordingSession.availableInputs?.map { $0.portType.rawValue } ?? []
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

            originalRecordingSessionCategory = recordingSession.category
            // Fix for OSStatus error 560557684 (AVAudioSessionErrorCodeCannotInterruptOthers)
            // Use .mixWithOthers to allow WebView/other apps to play audio while recording
            // Removed .defaultToSpeaker from setCategory to avoid routing conflicts with WebView audio session
            try recordingSession.setCategory(.playAndRecord, options: .mixWithOthers)
            try recordingSession.setActive(true)

            // Only override output to speaker on iPhone (has receiver/earpiece).
            // iPads don't have a receiver so this call is unnecessary and can
            // destabilise the audio session, causing AVAudioRecorder.record() to
            // return false.  See: https://developer.apple.com/documentation/avfaudio/avaudiosession/1616443-overrideoutputaudioport
            let isIPad = UIDevice.current.userInterfaceIdiom == .pad
            if !isIPad {
                do {
                    try recordingSession.overrideOutputAudioPort(.speaker)
                } catch {
                    NSLog("CustomMediaRecorder: Failed to override output to speaker (non-critical): \(error.localizedDescription)")
                }
            } else {
                NSLog("CustomMediaRecorder: Skipping overrideOutputAudioPort on iPad (no receiver)")
            }

            // Small stabilisation delay – gives the audio session time to settle
            // after category/route changes before we attempt to record.
            Thread.sleep(forTimeInterval: 0.15)

            // Get updated session info after configuration
            let updatedAudioSessionDetails: [String: Any] = [
                "newCategory": recordingSession.category.rawValue,
                "currentInputsAfterSetup": recordingSession.currentRoute.inputs.map { $0.portType.rawValue },
                "currentOutputsAfterSetup": recordingSession.currentRoute.outputs.map { $0.portType.rawValue }
            ]

            audioFilePath = getDirectoryToSaveAudioFile().appendingPathComponent("recording-\(Int(Date().timeIntervalSince1970 * 1000)).aac")

            // Check file path accessibility
            let parentDir = audioFilePath.deletingLastPathComponent()
            let filePathDetails: [String: Any] = [
                "audioFilePath": audioFilePath.path,
                "parentDir": parentDir.path,
                "parentDirWritable": FileManager.default.isWritableFile(atPath: parentDir.path),
                "parentDirExists": FileManager.default.fileExists(atPath: parentDir.path)
            ]

            if !FileManager.default.isWritableFile(atPath: parentDir.path) {
                return RecordingResult.failure(
                    stage: "file_path_check",
                    details: filePathDetails,
                    errorDescription: "Cannot write to directory: \(parentDir.path)"
                )
            }

            audioRecorder = try AVAudioRecorder(url: audioFilePath, settings: settings)

            if audioRecorder == nil {
                return RecordingResult.failure(
                    stage: "recorder_creation",
                    details: [
                        "settings": settings,
                        "audioFilePath": audioFilePath.path
                    ],
                    errorDescription: "Failed to create AVAudioRecorder"
                )
            }

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

            // Retry record() with audio session reset between attempts.
            // AVAudioRecorder.record() can return false when the audio session
            // is transiently busy (e.g. WKWebView audio conflict on iPad).
            let maxRecordAttempts = 3
            var recordResult = false
            for attempt in 1...maxRecordAttempts {
                recordResult = audioRecorder.record()
                if recordResult {
                    if attempt > 1 {
                        NSLog("CustomMediaRecorder: record() succeeded on attempt %d", attempt)
                    }
                    break
                }

                NSLog("CustomMediaRecorder: record() returned false on attempt %d/%d", attempt, maxRecordAttempts)

                if attempt < maxRecordAttempts {
                    // Reset audio session and re-prepare before retrying
                    audioRecorder.stop()
                    try recordingSession.setActive(false)
                    Thread.sleep(forTimeInterval: 0.3)
                    try recordingSession.setActive(true)
                    audioRecorder.prepareToRecord()
                }
            }

            if !recordResult {
                let finalRecorderDetails: [String: Any] = [
                    "isRecording": audioRecorder.isRecording,
                    "currentTime": audioRecorder.currentTime,
                    "totalAttempts": maxRecordAttempts,
                    "isIPad": isIPad
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
            let errorDetails: [String: Any] = [
                "errorDescription": error.localizedDescription,
                "domain": (error as NSError).domain,
                "code": (error as NSError).code,
                "userInfo": (error as NSError).userInfo
            ]
            return RecordingResult.failure(
                stage: "exception",
                details: errorDetails,
                errorDescription: error.localizedDescription
            )
        }
    }

    func stopRecording() {
        do {
            audioRecorder.stop()
            try recordingSession.setActive(false)
            try recordingSession.setCategory(originalRecordingSessionCategory)
            originalRecordingSessionCategory = nil
            audioRecorder = nil
            recordingSession = nil
            status = CurrentRecordingStatus.NONE
        } catch {}
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
