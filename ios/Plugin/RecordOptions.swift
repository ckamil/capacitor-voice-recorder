import Foundation

/// How the streamed AAC frames are produced on iOS. See `StreamingOptions.encodeMode` (definitions.ts).
enum StreamEncodeMode: String {
    case hardware            // AVAudioConverter, default codec (may be silent under .mixWithOthers)
    case software            // AVAudioConverter forced to the software AAC codec
    case fileTail = "file_tail" // tail the on-disk ADTS file (no re-encode), like Android

    static func from(_ raw: String?) -> StreamEncodeMode {
        guard let raw = raw, let mode = StreamEncodeMode(rawValue: raw) else { return .fileTail }
        return mode
    }
}

/// Configuration for the optional live audio stream. Parsed from the JS `streaming` option on
/// each `startRecording` call (so multi-profile apps simply pass a different server per call).
struct StreamingConfig {
    let url: URL
    let token: String?
    let headers: [String: String]
    let config: [String: Any]
    let reconnectInitialDelayMs: Int
    let reconnectMaxDelayMs: Int
    let reconnectMaxAttempts: Int      // 0 = unlimited
    let maxBufferSeconds: Double
    let pingIntervalMs: Int            // 0 = disabled
    let requireReachability: Bool
    let encodeMode: StreamEncodeMode   // iOS encode strategy; default .fileTail
}

struct RecordOptions {

    let directory: String?
    var subDirectory: String?
    let streaming: StreamingConfig?

    init(directory: String?, subDirectory: String?, streaming: StreamingConfig? = nil) {
        self.directory = directory
        self.subDirectory = subDirectory
        self.streaming = streaming
    }

    mutating func setSubDirectory(to subDirectory: String) {
      self.subDirectory = subDirectory
    }

}
