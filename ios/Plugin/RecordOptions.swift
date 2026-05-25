import Foundation

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
