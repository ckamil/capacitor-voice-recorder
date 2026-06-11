import Foundation
import Network

/// Best-effort live audio sink over a WebSocket. It NEVER blocks the audio path and NEVER throws
/// into the recorder: every failure is swallowed, surfaced as an event, and (for *transient*
/// failures) retried with exponential backoff. The on-disk recording is the source of truth; this
/// stream is purely additive.
///
/// Design:
/// - All mutable state lives on `queue` (serial). URLSession delegate callbacks and ping/path
///   handlers hop onto it before touching state.
/// - Connect/disconnect use `URLSessionWebSocketDelegate` (didOpen / didClose) plus the task's
///   HTTP response, so we can classify failures as fatal (stop — e.g. 401/403/policy) vs retryable
///   (network/timeout/5xx → backoff).
/// - `NWPathMonitor` gates attempts on real reachability: no pointless retries while offline, and
///   an immediate reconnect (backoff reset) the moment the network returns.
/// - A keepalive ping detects dead/half-open connections.
/// - Works in the background because it rides on the recording's `audio` background mode (the app
///   process stays alive while recording); it deliberately uses a `.default` URLSession — WebSocket
///   tasks are not supported on background-configuration sessions.
final class AudioStreamSink: NSObject, URLSessionWebSocketDelegate {

    private let config: StreamingConfig
    private let sampleRate: Double
    private let channels: Int
    private let recordingId: String
    private let onEvent: ([String: Any]) -> Void

    // Tunables (resolved from config).
    private let initialDelay: Double      // seconds
    private let maxDelay: Double          // seconds
    private let maxAttempts: Int          // 0 = unlimited
    private let pingInterval: Double      // seconds, 0 = off
    private let requireReachability: Bool
    private let maxBufferedFrames: Int

    // Auto-suspend tunables (resolved from config; all no-ops when !autosuspendEnabled).
    private let autosuspendEnabled: Bool
    private let suspendAfterReconnects: Int
    private let suspendDropRateFps: Double
    private let suspendDropWindowSec: Double
    private let suspendCooldownSec: Double
    private let suspendMaxCooldownSec: Double
    private let suspendMaxTotalSec: Double

    private let queue = DispatchQueue(label: "com.capacitor.voicerecorder.streamsink")
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private let pathMonitor = NWPathMonitor()

    /// Bounded FIFO of framed payloads ([8-byte header][ADTS]) waiting to be sent.
    private var pending: [Data] = []

    private var isConnected = false
    private var isSending = false
    private var isFinishing = false
    private var isClosed = false
    private var isFatal = false           // server rejected us — stop retrying for this recording
    private var hasNetwork = true
    private var reconnectAttempt = 0
    private var reconnectScheduled = false
    private var didReportFinished = false
    private var endMsDuration = 0

    // Diagnostics (read at stop via diagnosticsSnapshot()).
    private var framesSent: UInt64 = 0
    private var bytesSent: UInt64 = 0
    private var framesDropped: UInt64 = 0
    private var reconnects: Int = 0
    private var lastError: String?
    private var finalState = "init"
    private var lastDropEventAt: Date?

    // Auto-suspend runtime state (all on `queue`).
    private var isSuspended = false
    private var isProbing = false
    private var probeScheduled = false
    private var currentCooldown: Double = 0     // grows ×2 per failed probe, capped
    private var totalSuspendedSec: Double = 0    // accumulates toward suspendMaxTotalSec
    private var suspends: Int = 0
    private var dropWindowStart: Date?           // start of the current drop-rate measurement window
    private var dropWindowStartCount: UInt64 = 0 // framesDropped at window start

    init(config: StreamingConfig,
         sampleRate: Double,
         channels: Int,
         recordingId: String,
         onEvent: @escaping ([String: Any]) -> Void) {
        self.config = config
        self.sampleRate = sampleRate
        self.channels = channels
        self.recordingId = recordingId
        self.onEvent = onEvent

        self.initialDelay = max(0.05, Double(config.reconnectInitialDelayMs) / 1000.0)
        self.maxDelay = max(self.initialDelay, Double(config.reconnectMaxDelayMs) / 1000.0)
        self.maxAttempts = max(0, config.reconnectMaxAttempts)
        self.pingInterval = max(0, Double(config.pingIntervalMs) / 1000.0)
        self.requireReachability = config.requireReachability

        self.autosuspendEnabled = config.autosuspendEnabled
        self.suspendAfterReconnects = max(1, config.suspendAfterReconnects)
        self.suspendDropRateFps = max(1, config.suspendDropRateFps)
        self.suspendDropWindowSec = max(1, config.suspendDropWindowSec)
        self.suspendCooldownSec = max(1, config.suspendCooldownSec)
        self.suspendMaxCooldownSec = max(config.suspendCooldownSec, config.suspendMaxCooldownSec)
        self.suspendMaxTotalSec = max(0, config.suspendMaxTotalSec)

        let framesPerSecond = sampleRate > 0 ? sampleRate / 1024.0 : 47.0
        let frames = Int((max(1.0, config.maxBufferSeconds) * framesPerSecond).rounded())
        self.maxBufferedFrames = min(max(frames, 8), 200_000)

        super.init()

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.waitsForConnectivity = false
        self.session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public API (called from the recorder)

    func start() {
        // Only observe reachability when asked to (parity with Android, which skips the network
        // callback entirely when requireReachability is false).
        if requireReachability {
            pathMonitor.pathUpdateHandler = { [weak self] path in
                // Delivered on `queue` (we start the monitor on it).
                self?.handlePathUpdate(path)
            }
            pathMonitor.start(queue: queue)
        }
        queue.async { [weak self] in
            guard let self = self, !self.isClosed else { return }
            self.emit(["type": "connecting"])
            self.connect()
        }
    }

    /// Enqueue one ADTS frame. Non-blocking; drops the oldest frame if the buffer is full so memory
    /// stays bounded during an outage (the file remains complete on disk).
    func enqueue(seq: UInt32, timestampMs: UInt32, adts: Data) {
        queue.async { [weak self] in
            guard let self = self, !self.isClosed, !self.isFinishing, !self.isFatal else { return }

            // Suspended: don't buffer or send — just count the loss (bounded, no growth). The
            // on-disk file is unaffected; we resume on probe / network return.
            if self.isSuspended {
                self.framesDropped &+= 1
                self.noteDropThrottled()
                return
            }

            var payload = Data(capacity: 8 + adts.count)
            var beSeq = seq.bigEndian
            var beTs = timestampMs.bigEndian
            withUnsafeBytes(of: &beSeq) { payload.append(contentsOf: $0) }
            withUnsafeBytes(of: &beTs) { payload.append(contentsOf: $0) }
            payload.append(adts)

            if self.pending.count >= self.maxBufferedFrames {
                self.pending.removeFirst()
                self.framesDropped &+= 1
                self.noteDropThrottled()
                self.evaluateDropTrigger()
            }
            self.pending.append(payload)
            self.pumpIfPossible()
        }
    }

    /// Best-effort: flush remaining buffered frames (bounded), send `end`, then close.
    func finish(framesEnqueued: UInt64, msDuration: Int) {
        queue.async { [weak self] in
            guard let self = self, !self.isClosed else { return }
            self.isFinishing = true
            self.endMsDuration = msDuration
            self.finalState = "finished"
            if self.isConnected, self.task != nil {
                self.drainThenEnd(deadline: Date().addingTimeInterval(3.0))
            } else {
                self.reportFinished()
                self.teardown(closeCode: .normalClosure)
            }
        }
    }

    /// Tear down without reporting a clean finish (used on a failed recording start).
    func cancel() {
        queue.async { [weak self] in
            guard let self = self, !self.isClosed else { return }
            self.finalState = "cancelled"
            self.teardown(closeCode: .goingAway)
        }
    }

    func diagnosticsSnapshot() -> [String: Any] {
        var snapshot: [String: Any] = [:]
        queue.sync {
            snapshot = [
                "enabled": true,
                "finalState": self.finalState,
                "framesSent": self.framesSent,
                "framesDropped": self.framesDropped,
                "bytesSent": self.bytesSent,
                "reconnects": self.reconnects,
                "suspends": self.suspends
            ]
            if let lastError = self.lastError { snapshot["lastError"] = lastError }
        }
        return snapshot
    }

    // MARK: - Connection (all on `queue`)

    private func connect() {
        guard !isClosed, !isFinishing, !isFatal else { return }
        reconnectScheduled = false

        if requireReachability && !hasNetwork {
            // Don't burn an attempt offline; handlePathUpdate will reconnect when the path returns.
            finalState = "waiting_network"
            return
        }

        var request = URLRequest(url: config.url)
        if let token = config.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop(task)
        // "connected" is signalled by the delegate's didOpenWithProtocol.
    }

    private func markConnected() {
        guard !isClosed, !isFinishing, !isFatal else { return }
        isConnected = true
        if reconnectAttempt > 0 { reconnects += 1 }
        reconnectAttempt = 0
        finalState = "connected"
        // A probe (or network-restored wake) that lands here means the link is back: reset the
        // backoff/cooldown and tell the JS layer streaming resumed.
        if isProbing {
            isProbing = false
            currentCooldown = 0
            emit(["type": "resumed", "droppedFrames": framesDropped, "reconnects": reconnects])
        }
        // Start a fresh drop-rate window for the (re)connected session.
        dropWindowStart = nil
        sendStart()
        emit(["type": "connected"])
        pumpIfPossible()
        schedulePing()
    }

    private func sendStart() {
        var start: [String: Any] = [
            "type": "start",
            "recordingId": recordingId,
            "codec": "aac_adts",
            "profile": "aac_lc",
            "sampleRate": sampleRate,
            "channels": channels,
            "framesPerPacket": 1024,
            "frameHeader": ["seqBytes": 4, "timestampMsBytes": 4, "endian": "big"],
            "startedAt": AudioStreamSink.iso8601(Date()),
            "encodeMode": config.encodeMode.rawValue
        ]
        if !config.config.isEmpty { start["config"] = config.config }

        guard let text = encodeControl(start), let task = task else {
            // A non-serializable `start` (e.g. bad config) is fatal for the stream, not retryable.
            handleFatal(reason: "start_serialize", httpStatus: nil)
            return
        }
        task.send(.string(text)) { [weak self] error in
            guard let self = self, let error = error else { return }
            self.queue.async {
                guard task === self.task else { return }
                self.handleDisconnect(reason: "start_send", fatal: false, httpStatus: nil, error: error)
            }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                guard task === self.task, !self.isClosed, !self.isFinishing else { return }
                switch result {
                case .failure(let error):
                    self.handleDisconnect(reason: "receive", fatal: false, httpStatus: nil, error: error)
                case .success(let message):
                    if case let .string(text) = message { self.handleInbound(text) }
                    self.receiveLoop(task)
                }
            }
        }
    }

    /// A server → client control message. v1 only acts on an explicit error/close so we stop wasting
    /// bandwidth when the server has rejected the stream at the application level.
    private func handleInbound(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        if type == "error" || type == "close" {
            let reason = (obj["reason"] as? String) ?? type
            handleFatal(reason: "server_\(reason)", httpStatus: nil)
        }
    }

    private func pumpIfPossible() {
        guard isConnected, !isSending, !isFinishing, !isClosed, !isFatal,
              let task = task, !pending.isEmpty else { return }
        isSending = true
        let payload = pending.removeFirst()
        task.send(.data(payload)) { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                guard task === self.task, !self.isClosed else { return }
                self.isSending = false
                if let error = error {
                    // Don't lose the in-flight frame: put it back at the front, then reconnect.
                    self.pending.insert(payload, at: 0)
                    self.handleDisconnect(reason: "send", fatal: false, httpStatus: nil, error: error)
                } else {
                    self.framesSent &+= 1
                    self.bytesSent &+= UInt64(payload.count)
                    self.pumpIfPossible()
                }
            }
        }
    }

    private func schedulePing() {
        guard pingInterval > 0 else { return }
        queue.asyncAfter(deadline: .now() + pingInterval) { [weak self] in
            guard let self = self, self.isConnected, !self.isClosed, !self.isFinishing,
                  let task = self.task else { return }
            task.sendPing { [weak self] error in
                guard let self = self else { return }
                self.queue.async {
                    guard task === self.task, !self.isClosed, !self.isFinishing else { return }
                    if let error = error {
                        self.handleDisconnect(reason: "ping", fatal: false, httpStatus: nil, error: error)
                    } else {
                        self.schedulePing()
                    }
                }
            }
        }
    }

    // MARK: - Failure handling (on `queue`)

    private func handleDisconnect(reason: String, fatal: Bool, httpStatus: Int?, error: Error?) {
        guard !isClosed, !isFinishing else { return }
        guard task != nil || isConnected else { return } // already torn down by a prior callback

        let wasConnected = isConnected
        isConnected = false
        isSending = false
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        if let error = error {
            lastError = "\(reason): \(error.localizedDescription)"
        } else {
            lastError = reason
        }

        var payload: [String: Any] = ["type": wasConnected ? "disconnected" : "error", "reason": reason]
        if let httpStatus = httpStatus { payload["code"] = httpStatus }
        if let error = error { payload["message"] = error.localizedDescription }
        emit(payload)

        if fatal {
            isFatal = true
            finalState = "fatal"
            emit(["type": "error", "reason": "server_rejected"])
            return
        }
        scheduleReconnect()
    }

    private func handleFatal(reason: String, httpStatus: Int?) {
        guard !isClosed else { return }
        lastError = reason
        isFatal = true
        isConnected = false
        finalState = "fatal"
        var payload: [String: Any] = ["type": "error", "reason": reason]
        if let httpStatus = httpStatus { payload["code"] = httpStatus }
        emit(payload)
        teardown(closeCode: .normalClosure)
    }

    private func scheduleReconnect() {
        guard !isClosed, !isFinishing, !isFatal, !reconnectScheduled else { return }

        // A failed PROBE while suspended: re-suspend (cooldown already doubling) instead of the
        // normal backoff cycle.
        if isProbing {
            isProbing = false
            enterSuspend(reason: "probe_failed")
            return
        }

        // Reconnect storm: after N consecutive attempts the link is effectively dead — stop churning
        // TLS/WS handshakes and drop into the suspend/cooldown cycle. Opt-in.
        if autosuspendEnabled && !isSuspended && reconnectAttempt >= suspendAfterReconnects {
            enterSuspend(reason: "reconnect_storm")
            return
        }

        if maxAttempts > 0 && reconnectAttempt >= maxAttempts {
            isFatal = true
            finalState = "fatal"
            emit(["type": "error", "reason": "max_attempts", "attempt": reconnectAttempt])
            return
        }
        if requireReachability && !hasNetwork {
            // Wait for the network to return (handlePathUpdate triggers connect) — no wasted attempt.
            finalState = "waiting_network"
            return
        }

        reconnectAttempt += 1
        let backoff = min(maxDelay, initialDelay * pow(2.0, Double(reconnectAttempt - 1)))
        reconnectScheduled = true
        finalState = "reconnecting"
        emit(["type": "reconnecting", "attempt": reconnectAttempt, "backoffMs": Int(backoff * 1000)])
        queue.asyncAfter(deadline: .now() + backoff) { [weak self] in
            guard let self = self, !self.isClosed, !self.isFinishing, !self.isFatal else { return }
            self.reconnectScheduled = false
            self.connect()
        }
    }

    // MARK: - Auto-suspend (all on `queue`)

    /// Enter the suspended state: tear down the live task, stop pinging, park for a cooldown, then
    /// probe once. Cooldown doubles per failed probe (capped). Streaming only — recording untouched.
    private func enterSuspend(reason: String) {
        guard !isClosed, !isFinishing, !isFatal, !isSuspended else { return }
        isSuspended = true
        isProbing = false
        suspends += 1
        finalState = "suspended"

        // Drop the live connection but keep the sink alive.
        isConnected = false
        isSending = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        reconnectScheduled = false
        dropWindowStart = nil

        currentCooldown = currentCooldown <= 0
            ? suspendCooldownSec
            : min(suspendMaxCooldownSec, currentCooldown * 2)

        emit([
            "type": "suspended",
            "reason": reason,
            "droppedFrames": framesDropped,
            "reconnects": reconnects,
            "cooldownMs": Int(currentCooldown * 1000)
        ])
        scheduleProbe()
    }

    private func scheduleProbe() {
        guard !isClosed, !isFinishing, !isFatal, isSuspended, !probeScheduled else { return }

        // Fail-open backstop: after too long churning the suspend/probe cycle, give up streaming for
        // this recording rather than tying up the radio forever. The file on disk is the truth.
        if suspendMaxTotalSec > 0 && totalSuspendedSec >= suspendMaxTotalSec {
            finalState = "suspend_gave_up"
            emit(["type": "error", "reason": "suspend_gave_up", "droppedFrames": framesDropped])
            teardown(closeCode: .normalClosure)
            return
        }

        probeScheduled = true
        let cooldown = currentCooldown
        finalState = "suspended"
        queue.asyncAfter(deadline: .now() + cooldown) { [weak self] in
            guard let self = self, !self.isClosed, !self.isFinishing, !self.isFatal, self.isSuspended else { return }
            self.probeScheduled = false
            self.totalSuspendedSec += cooldown
            // Still offline: don't waste a probe (connect() would early-return on waiting_network and
            // leave us in limbo). Stay suspended and re-arm — handlePathUpdate also wakes on return,
            // and totalSuspendedSec keeps climbing toward the fail-open backstop.
            if self.requireReachability && !self.hasNetwork {
                self.scheduleProbe()
                return
            }
            // One probe attempt. Success → markConnected resets cooldown + emits "resumed".
            // Failure → handleDisconnect → scheduleReconnect sees isProbing and re-suspends.
            self.isSuspended = false
            self.isProbing = true
            self.reconnectAttempt = 0
            self.finalState = "probing"
            self.emit(["type": "reconnecting", "attempt": 0, "reason": "probe", "backoffMs": 0])
            self.connect()
        }
    }

    /// Suspend when, while connected, frames are dropping faster than the configured rate over a
    /// sustained window (connection up but throughput below audio production). Connected-only so the
    /// pre-connect buffer warm-up never false-triggers.
    private func evaluateDropTrigger() {
        guard autosuspendEnabled, isConnected, !isSuspended, !isProbing else { return }
        let now = Date()
        guard let windowStart = dropWindowStart else {
            dropWindowStart = now
            dropWindowStartCount = framesDropped
            return
        }
        let elapsed = now.timeIntervalSince(windowStart)
        guard elapsed >= suspendDropWindowSec else { return }
        let droppedInWindow = framesDropped &- dropWindowStartCount
        let rate = Double(droppedInWindow) / elapsed
        if rate >= suspendDropRateFps {
            enterSuspend(reason: "sustained_drops")
        } else {
            dropWindowStart = now
            dropWindowStartCount = framesDropped
        }
    }

    private func handlePathUpdate(_ path: NWPath) {
        let nowHas = path.status == .satisfied
        let cameBack = nowHas && !hasNetwork
        hasNetwork = nowHas
        guard !isClosed, !isFinishing, !isFatal else { return }

        if cameBack {
            // Network restored — reconnect immediately and reset backoff.
            reconnectAttempt = 0
            reconnectScheduled = false
            if isSuspended {
                // Physical network return always overrides the cooldown. Leave suspend and probe
                // now; the queued probe closure will bail (guards on isSuspended). isProbing=true
                // so a failure re-enters suspend rather than the normal backoff.
                isSuspended = false
                isProbing = true
                probeScheduled = false
                currentCooldown = 0
                emit(["type": "reconnecting", "attempt": 0, "reason": "network_restored", "backoffMs": 0])
                connect()
            } else if !isConnected {
                emit(["type": "reconnecting", "attempt": 0, "reason": "network_restored", "backoffMs": 0])
                connect()
            }
        } else if !nowHas && (isConnected || task != nil) {
            // Network lost — drop now and wait (scheduleReconnect parks on !hasNetwork).
            handleDisconnect(reason: "no_network", fatal: false, httpStatus: nil, error: nil)
        }
    }

    // MARK: - Finish / teardown (on `queue`)

    private func drainThenEnd(deadline: Date) {
        guard !isClosed else { return }
        guard isConnected, let task = task, !pending.isEmpty, Date() < deadline else {
            sendEndAndClose()
            return
        }
        let payload = pending.removeFirst()
        task.send(.data(payload)) { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                guard task === self.task, !self.isClosed else { return }
                if error != nil {
                    self.sendEndAndClose()
                    return
                }
                self.framesSent &+= 1
                self.bytesSent &+= UInt64(payload.count)
                self.drainThenEnd(deadline: deadline)
            }
        }
    }

    private func sendEndAndClose() {
        guard !isClosed else { return }
        reportFinished()
        if isConnected, let task = task,
           let text = encodeControl([
            "type": "end",
            "recordingId": recordingId,
            "framesSent": framesSent,
            "msDuration": endMsDuration,
            "reason": "user_stop"
           ]) {
            task.send(.string(text)) { [weak self] _ in
                self?.queue.async { self?.teardown(closeCode: .normalClosure) }
            }
            // Safety net if the send completion never fires.
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.teardown(closeCode: .normalClosure)
            }
        } else {
            teardown(closeCode: .normalClosure)
        }
    }

    private func reportFinished() {
        guard !didReportFinished else { return }
        didReportFinished = true
        finalState = "finished"
        emit([
            "type": "finished",
            "framesSent": framesSent,
            "bytesSent": bytesSent,
            "reconnects": reconnects
        ])
    }

    private func teardown(closeCode: URLSessionWebSocketTask.CloseCode) {
        guard !isClosed else { return }
        isClosed = true
        isConnected = false
        pathMonitor.cancel()
        task?.cancel(with: closeCode, reason: nil)
        task = nil
        pending.removeAll()
        session.invalidateAndCancel()
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        queue.async { [weak self] in
            guard let self = self, webSocketTask === self.task else { return }
            self.markConnected()
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let fatal = AudioStreamSink.isFatalCloseCode(closeCode)
        queue.async { [weak self] in
            guard let self = self, webSocketTask === self.task else { return }
            self.handleDisconnect(reason: "close_\(closeCode.rawValue)", fatal: fatal, httpStatus: nil, error: nil)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        queue.async { [weak self] in
            guard let self = self, task === self.task else { return }
            if error == nil && status == nil { return }
            let fatal = status.map { AudioStreamSink.isFatalHTTPStatus($0) } ?? false
            let reason = error?.localizedDescription ?? "http_\(status ?? 0)"
            self.handleDisconnect(reason: reason, fatal: fatal, httpStatus: status, error: error)
        }
    }

    // MARK: - Helpers

    /// 4xx are fatal (auth / bad request / not found) except 408 (timeout) and 429 (rate-limited),
    /// which are worth retrying. 5xx are transient → retryable.
    private static func isFatalHTTPStatus(_ status: Int) -> Bool {
        if status == 408 || status == 429 { return false }
        return (400...499).contains(status)
    }

    private static func isFatalCloseCode(_ code: URLSessionWebSocketTask.CloseCode) -> Bool {
        switch code {
        case .normalClosure, .protocolError, .unsupportedData, .policyViolation,
             .mandatoryExtensionMissing, .tlsHandshakeFailure, .invalidFramePayloadData:
            return true
        default:
            return false
        }
    }

    private func noteDropThrottled() {
        let now = Date()
        if let last = lastDropEventAt, now.timeIntervalSince(last) < 1.0 { return }
        lastDropEventAt = now
        emit(["type": "dropped", "droppedFrames": framesDropped])
    }

    private func encodeControl(_ dict: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private func emit(_ payload: [String: Any]) {
        var enriched = payload
        enriched["timestamp"] = AudioStreamSink.iso8601(Date())
        if let host = config.url.host { enriched["host"] = host }
        onEvent(enriched)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
