import Foundation

protocol RecorderInterface: AnyObject {
    var options: RecordOptions! { get }
    func startRecording(recordOptions: RecordOptions) -> RecordingResult
    func stopRecording()
    func pauseRecording() -> Bool
    func resumeRecording() -> Bool
    func getOutputFile() -> URL?
    func getCurrentStatus() -> CurrentRecordingStatus
    func getDiagnostics() -> [String: Any]
}

extension RecorderInterface {
    func getDiagnostics() -> [String: Any] { return [:] }
}
