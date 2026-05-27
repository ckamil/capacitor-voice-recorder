import Foundation

/// Streams the recording by tailing the on-disk ADTS (.aac) file the recorder already writes via
/// ExtAudioFile — the same approach Android uses. No re-encode, so it is unaffected by the
/// `.mixWithOthers` hardware-encoder limitation that silences AVAudioConverter on some devices.
///
/// The recorder keeps appending complete ADTS frames to the file; this reader periodically reads
/// the newly-appended bytes, splits them on ADTS frame boundaries, and hands each complete frame
/// to the sink with a monotonically increasing sequence number and a timestamp derived from the
/// frame index (1024 samples per AAC frame).
final class AdtsFileTailReader {

    private let fileURL: URL
    private let sink: AudioStreamSink
    private let sampleRate: Double
    private let queue = DispatchQueue(label: "voicerecorder.adts.tail")
    private let pollInterval: TimeInterval = 0.2

    private var timer: DispatchSourceTimer?
    private var handle: FileHandle?
    private var carry = Data()          // bytes read but not yet forming a complete frame
    private var seq: UInt32 = 0
    private var frameIndex: UInt64 = 0
    private var stopped = false

    /// Total ADTS frames enqueued to the sink. Read only after `stop()` returns.
    private(set) var framesEnqueued: UInt64 = 0

    init(fileURL: URL, sink: AudioStreamSink, sampleRate: Double) {
        self.fileURL = fileURL
        self.sink = sink
        self.sampleRate = sampleRate > 0 ? sampleRate : 48000
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.handle = try? FileHandle(forReadingFrom: self.fileURL)
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + self.pollInterval, repeating: self.pollInterval)
            t.setEventHandler { [weak self] in self?.drain() }
            self.timer = t
            t.resume()
        }
    }

    /// Final drain + cleanup. Synchronous so the caller can read `framesEnqueued` afterwards.
    /// Safe to call more than once. Must NOT be called from `queue`.
    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            drain()                     // pick up any frames written just before stop
            timer?.cancel()
            timer = nil
            try? handle?.close()
            handle = nil
            carry.removeAll()
        }
    }

    // MARK: - Private (all on `queue`)

    private func drain() {
        guard let handle = handle else { return }

        // Read everything appended since the last position. FileHandle keeps its own offset, so
        // each readDataToEndOfFile() returns only the new bytes.
        let chunk = handle.readDataToEndOfFile()
        if chunk.isEmpty && carry.isEmpty { return }

        carry.append(chunk)
        emitCompleteFrames()
    }

    /// Split `carry` into complete ADTS frames; keep any trailing partial frame for next time.
    private func emitCompleteFrames() {
        let n = carry.count
        let rate = UInt64(max(1, Int(sampleRate)))

        // Extract frames into local Data copies first (do not touch `carry` inside its own
        // withUnsafeBytes — that would be an overlapping-access violation).
        var frames: [Data] = []
        var offset = 0
        carry.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            while offset + 7 <= n {
                // ADTS syncword: 0xFFF + layer 00.
                guard base[offset] == 0xFF, (base[offset + 1] & 0xF6) == 0xF0 else {
                    offset += 1   // resync (should not happen on a clean ExtAudioFile stream)
                    continue
                }
                let frameLength = (Int(base[offset + 3] & 0x3) << 11)
                    | (Int(base[offset + 4]) << 3)
                    | (Int(base[offset + 5] >> 5) & 0x7)
                if frameLength < 7 { offset += 1; continue }
                if offset + frameLength > n { break }   // incomplete trailing frame — wait for more
                frames.append(Data(bytes: base + offset, count: frameLength))
                offset += frameLength
            }
        }

        for frame in frames {
            let ms = frameIndex &* 1024 &* 1000 / rate
            sink.enqueue(seq: seq, timestampMs: UInt32(truncatingIfNeeded: ms), adts: frame)
            seq = seq &+ 1
            frameIndex &+= 1
        }

        if offset > 0 {
            carry.removeSubrange(0..<offset)
        }
        framesEnqueued = frameIndex
    }
}
