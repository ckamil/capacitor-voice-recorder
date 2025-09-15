import Foundation
import AVFoundation

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

    func startRecording(recordOptions: RecordOptions) -> Bool {
        NSLog("CustomMediaRecorder: startRecording called")

        do {
            options = recordOptions
            recordingSession = AVAudioSession.sharedInstance()

            // Enhanced logging for diagnostics
            NSLog("CustomMediaRecorder: Audio session state - category: %@, otherAudioPlaying: %@, availableInputs: %d",
                  recordingSession.category.rawValue,
                  recordingSession.isOtherAudioPlaying ? "true" : "false",
                  recordingSession.availableInputs?.count ?? 0)

            if recordingSession.isOtherAudioPlaying {
                NSLog("CustomMediaRecorder: CANNOT_RECORD - Other audio is playing")
                return false
            }

            if recordingSession.availableInputs?.isEmpty == true {
                NSLog("CustomMediaRecorder: CANNOT_RECORD - No available inputs")
                return false
            }

            originalRecordingSessionCategory = recordingSession.category
            try recordingSession.setCategory(AVAudioSession.Category.playAndRecord)
            try recordingSession.setActive(true)

            NSLog("CustomMediaRecorder: Audio session configured - new category: %@", recordingSession.category.rawValue)

            audioFilePath = getDirectoryToSaveAudioFile().appendingPathComponent("recording-\(Int(Date().timeIntervalSince1970 * 1000)).aac")

            // Check file path accessibility
            let parentDir = audioFilePath.deletingLastPathComponent()
            if !FileManager.default.isWritableFile(atPath: parentDir.path) {
                NSLog("CustomMediaRecorder: CANNOT_RECORD - Cannot write to directory: %@", parentDir.path)
                return false
            }

            audioRecorder = try AVAudioRecorder(url: audioFilePath, settings: settings)

            if audioRecorder == nil {
                NSLog("CustomMediaRecorder: CANNOT_RECORD - Failed to create AVAudioRecorder")
                return false
            }

            if !audioRecorder.prepareToRecord() {
                NSLog("CustomMediaRecorder: CANNOT_RECORD - AVAudioRecorder.prepareToRecord failed")
                return false
            }

            NSLog("CustomMediaRecorder: AudioRecorder prepared, calling record()")

            let recordResult = audioRecorder.record()
            if !recordResult {
                NSLog("CustomMediaRecorder: CANNOT_RECORD - AVAudioRecorder.record() returned false")
                return false
            }

            status = CurrentRecordingStatus.RECORDING
            NSLog("CustomMediaRecorder: Recording started successfully")
            return true

        } catch let error {
            NSLog("CustomMediaRecorder: CANNOT_RECORD - Exception: %@ (domain: %@, code: %ld)",
                  error.localizedDescription,
                  (error as NSError).domain,
                  (error as NSError).code)
            return false
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
