# WebSocket Live Audio Streaming — Integration Guide

Status: **design / contract spec** (iOS only). This document describes how the
optional live audio stream works, what the app (frontend) must do, what the
backend must implement, the event/logging contract, and how frame loss is
handled. No behaviour changes unless a recording is started with a `streaming`
option.

---

## 1. Guiding principles

1. **Streaming is purely additive.** It must never affect the core recording.
   If the socket is down, slow, or errors out, the recording to disk continues
   exactly as before.
2. **The file on disk is the source of truth.** The complete recording is always
   saved locally (ADTS `.aac`). The live stream is *best-effort* low-latency
   audio; the canonical/complete transcription can always be produced from the
   final file.
3. **The audio thread never blocks on the network.** Encoding for the network
   and sending happen off the capture path; if buffers back up, frames are
   dropped — back-pressure is never applied to recording.
4. **Per-recording connection, per-call configuration.** The WebSocket opens on
   `startRecording` and closes on `stopRecording`. All connection parameters are
   read fresh from each `startRecording` call, so multi-profile apps just pass a
   different server per call — there is no persistent native-side server state.

---

## 2. Data flow (iOS)

```
                         ┌─────────────────────────────────────────┐
 microphone ─► AVAudioEngine input tap (PCM float32, mono)          │
                         │                                          │
                         ├─► ExtAudioFile  ─► AAC ADTS .aac on disk  │  (UNCHANGED, source of truth)
                         │                                          │
                         └─► AVAudioConverter ─► ADTS frame ─► ring  │  (NEW, additive)
                                                          buffer     │
                                                            │        │
                                                            ▼        │
                                              WebSocket sender (own queue)
                                                            │
                                                            ▼
                                                     backend server
```

The file path (`ExtAudioFile`) is untouched. A **second, parallel**
`AVAudioConverter` encodes the same PCM buffers into AAC and the resulting ADTS
frames are pushed to a bounded buffer drained by the WebSocket sender. The two
encoders are independent: a streaming failure cannot corrupt or stall the file.

> Why encode twice? `ExtAudioFileWrite` emits AAC straight to disk and does not
> hand back the encoded bytes. Re-encoding for the network keeps the hardened
> file path byte-for-byte identical and fully isolated from streaming. The extra
> cost is one mono AAC encode — negligible.

---

## 3. Enabling streaming (frontend / app)

`streaming` is an optional block on `startRecording`. When omitted, nothing
changes.

```ts
await VoiceRecorder.startRecording({
  directory: Directory.Library,        // existing options unchanged
  subDirectory: 'recordings',
  streaming: {
    url: 'wss://transcribe.profile-a.example.com/v1/audio',
    token: '<bearer token for the active profile>',   // optional
    headers: { 'X-Profile-Id': 'profile-a' },          // optional extra headers
    config: {                                          // optional, arbitrary
      profileId: 'profile-a',
      userId: 'u_123',
      sessionToken: '<login session token>',
      language: 'pl-PL',
    },
    // All of the following are optional and have safe defaults:
    reconnect: { initialDelayMs: 1000, maxDelayMs: 8000, maxAttempts: 0 }, // 0 = unlimited
    maxBufferSeconds: 10,        // audio buffered while offline before dropping oldest frames
    pingIntervalMs: 20000,       // keepalive ping; 0 disables
    requireReachability: true,   // gate attempts on OS network reachability (NWPathMonitor)
  },
});
```

### Tuning (all optional)

| Option | Default | Meaning |
| --- | --- | --- |
| `reconnect.initialDelayMs` | `1000` | Delay before the first reconnect attempt. |
| `reconnect.maxDelayMs` | `8000` | Backoff cap (exponential: 1s → 2s → 4s → 8s …). |
| `reconnect.maxAttempts` | `0` | Attempts before giving up; `0` = unlimited (retry for the whole recording). |
| `maxBufferSeconds` | `10` | Seconds of audio buffered while disconnected before the oldest frames are dropped. |
| `pingIntervalMs` | `20000` | WebSocket keepalive ping interval; `0` disables. |
| `requireReachability` | `true` | Only attempt/await connections while the OS reports a network path. |

### Multi-profile

Because the whole `streaming` block travels with each `startRecording` call,
switching profiles requires **no special handling**: the next recording simply
carries the new profile's `url` / `token` / `config` and connects there. The
plugin never remembers a previous server.

The `config` object is sent verbatim to the backend in the `start` control
message (see §4.2) — that is the channel for "send configuration during login":
put profile id, user id, session token, language, etc. there.

---

## 4. WebSocket wire protocol (backend contract)

### 4.1 Connection

* Client opens a WebSocket to `streaming.url`. **`wss://` is required.**
* `streaming.token`, if present, is sent as an `Authorization: Bearer <token>`
  header on the upgrade request. The token is **never** placed in the URL query
  string and is **never** included in any emitted log event.
* Any key/value in `streaming.headers` is added to the upgrade request.

### 4.2 `start` — control message (client → server, text/JSON, once after open)

The first message after the socket opens. Establishes the session and audio
format.

```json
{
  "type": "start",
  "recordingId": "5b1f…-uuid",
  "codec": "aac_adts",
  "profile": "aac_lc",
  "sampleRate": 48000,
  "channels": 1,
  "framesPerPacket": 1024,
  "frameHeader": { "seqBytes": 4, "timestampMsBytes": 4, "endian": "big" },
  "startedAt": "2026-05-25T12:00:00.000Z",
  "config": { "profileId": "profile-a", "userId": "u_123", "language": "pl-PL" }
}
```

* `sampleRate` is **device-dependent** (commonly 48000 or 44100). The
  authoritative rate is also encoded in every ADTS header; trust either.
* `config` is whatever the app passed in `streaming.config`.

### 4.3 Audio — binary messages (client → server, repeated)

Audio is sent as **WebSocket binary frames**. Control messages are **text/JSON**
— the two are distinguished by the WebSocket opcode, so the server routes by
frame type (text = control, binary = audio).

**Each binary message = exactly one complete ADTS frame, prefixed by an 8-byte
header.** The plugin never splits an ADTS frame across messages, so the server
never sees a partial frame.

```
byte offset   type        field
-----------   ---------   ---------------------------------------------------
0 .. 3        uint32 BE   seq         0-based, +1 per frame, monotonic
4 .. 7        uint32 BE   timestampMs ms from recording start (first sample)
8 .. EOF      bytes       one ADTS AAC frame (7-byte ADTS header + payload)
```

Server handling:

1. Read first 8 bytes → `seq`, `timestampMs`.
2. Feed bytes `[8 ..]` (the raw ADTS frame) to the AAC decoder / transcriber.
3. Use `seq` to detect gaps (see §6) and `timestampMs` to align with the final
   file's timeline.

> One ADTS frame is 1024 samples. At 48 kHz that is ~21.3 ms, i.e. ~47 binary
> messages/second. The 8-byte header overhead is negligible.

### 4.4 `end` — control message (client → server, text/JSON, on stop)

Sent on `stopRecording`, just before the client closes the socket with code
`1000` (normal closure).

```json
{
  "type": "end",
  "recordingId": "5b1f…-uuid",
  "framesSent": 12345,
  "msDuration": 263000,
  "reason": "user_stop"
}
```

### 4.5 `gap` — control message (client → server, text/JSON, optional)

Emitted when the client drops frames due to buffer overflow during a server
outage. This is **advisory only** — the authoritative gap signal is the jump in
`seq` on the binary stream. A server that tracks `seq` does not need to handle
`gap` explicitly.

```json
{ "type": "gap", "fromSeq": 100, "toSeq": 137, "droppedFrames": 37, "reason": "buffer_overflow" }
```

### 4.6 Server → client (text/JSON)

The connection is bidirectional. A server **may** push text/JSON. The v1 client
acts on exactly one case, to avoid wasting bandwidth/battery when the server has
rejected the stream at the application level:

```json
{ "type": "error", "reason": "invalid_session" }   // or { "type": "close" }
```

On receiving `type: "error"` or `type: "close"`, the client treats streaming as
**fatal**: it stops sending, does **not** reconnect for the rest of the
recording, and emits a terminal `error` event (`reason: "server_<reason>"`). Any
other server→client message is currently ignored (reserved for a future
"live transcript" surface). Recording and the saved file are unaffected.

### 4.7 Keepalive

The client sends WebSocket pings every `pingIntervalMs` (default 20 s; `0`
disables) to detect dead/half-open connections and keep NAT mappings alive. A
failed ping triggers a reconnect. The server should respond to pings and must not
treat an idle control channel (while audio still flows as binary) as dead.

---

## 5. Resilience — connect, disconnect, retry, background

This is the concrete behaviour behind principle #1/#2.

### 5.1 Buffering (don't lose frames)

* **Bounded buffer.** ADTS frames are queued in a FIFO sized to `maxBufferSeconds`
  (default 10 s, derived to a frame count from the sample rate). Frames produced
  while connecting/reconnecting are buffered and flushed on connect — not lost.
* **Drop-oldest on overflow.** If an outage outlasts the buffer, the **oldest**
  frames are dropped so memory stays bounded and live latency does not grow. Drops
  are counted, reported via `dropped` events (§7), and visible to the server as a
  `seq` jump (§6).
* **In-flight frame is never lost.** If a send fails, the frame is re-queued at the
  front before reconnecting.
* **Flush on stop.** On `stopRecording` the client drains remaining buffered frames
  (bounded, ~3 s) before sending `end` and closing.

### 5.2 Reconnect — timer-driven, never per-frame

* Reconnect is driven by a **single backoff timer**, never by incoming frames.
  While disconnected, frames only accumulate in the buffer; they do **not** each
  trigger a connection attempt.
* Exponential backoff from `reconnect.initialDelayMs` doubling up to
  `reconnect.maxDelayMs` (default 1s → 2s → 4s → 8s …). Gives up after
  `reconnect.maxAttempts` (default `0` = unlimited, i.e. for the whole recording).

### 5.3 Reachability (don't retry into a dead network)

* An `NWPathMonitor` tracks network availability. With `requireReachability: true`
  (default), the client does **not** burn reconnect attempts while offline — it
  parks in a `waiting_network` state.
* When the path returns, it reconnects **immediately** and resets the backoff
  (emits `reconnecting` with `reason: "network_restored"`). A lost path while
  connected proactively drops the socket and parks until the network is back.

### 5.4 Error classification (don't send when the server rejects us)

Not every failure is worth retrying:

* **Retryable → backoff reconnect:** network errors, timeouts, HTTP `408`/`429`,
  HTTP `5xx`, abnormal/`going-away` closes, ping failures.
* **Fatal → stop, no reconnect:** HTTP `4xx` auth/bad-request (`401`, `403`, `400`,
  `404`, …), WebSocket policy/protocol closes, a normal server-initiated close, or
  a server→client `{type:"error"|"close"}` (§4.6). The client emits a terminal
  `error` event and stops streaming for the rest of the recording.

In all cases the recording and the saved file are unaffected.

### 5.5 Background operation

Streaming **must and does** continue when the app is backgrounded:

* It rides on the recording's existing `audio` background mode + background task —
  while a recording is active the app process stays alive, so the WebSocket,
  `NWPathMonitor`, backoff timers and pings keep running in the background.
* It deliberately uses a **`.default`** `URLSession`. WebSocket tasks are **not**
  supported on background-configuration sessions, and they are not needed here:
  the audio background mode is the keep-alive.
* The stop sequence (drain + `end` + close) runs inside the plugin's
  `stopRecording` background task, so it completes even if the app is in the
  background when the user stops.

**Mental model:** live stream = best-effort, low-latency, may have gaps during
outages or after a fatal rejection. Final file = guaranteed complete. Reconcile
the two on the backend if exact, gap-free transcripts are required.

> Possible future enhancement (not in v1): on reconnect, backfill the missed
> byte range from the on-disk file so the server can close live gaps. Deferred to
> keep v1 simple.

---

## 6. Frame loss & independent decoding

**Question: if a frame is skipped, what happens server-side — can each frame be
decoded independently?**

**Short answer: yes — keep decoding. A dropped frame causes a tiny (~one-frame)
gap, never a desync and never corruption of later frames.**

Details:

* **Self-describing frames.** Every ADTS frame carries a 7-byte header with the
  profile (AAC-LC), sampling-frequency index, channel configuration and the
  frame length. A decoder needs no external state to parse a frame.
* **Self-synchronizing stream.** Each ADTS frame begins with a 12-bit syncword
  (`0xFFF`). A decoder can resynchronize at the next frame boundary after any
  loss. There is **no inter-frame entropy/prediction chain** (unlike video
  I/P/B frames), so losing frame *N* does **not** corrupt frames *N+1, N+2, …*.
* **One nuance — MDCT overlap.** AAC-LC uses a 2048-sample MDCT with 50%
  overlap-add (TDAC); each frame outputs 1024 new samples but the seam between
  two frames is reconstructed from both. So a single lost frame produces a short
  gap (~21–23 ms) plus a minor transient at the seam — **not** a cascading error.
  For speech/transcription this is at most a fraction of a syllable.
* **Start-of-stream priming.** AAC has a decoder priming delay (~2112 samples at
  the very start of a stream). This is a one-time start-of-stream effect, not a
  per-frame concern. If the server creates a fresh decoder per `start`, it should
  expect the first ~tens of ms to be priming.

### Recommended server behaviour on a `seq` gap

When the received `seq` jumps (e.g. `…, 100, 137, …`), 37 frames were dropped
during an outage. Choose based on whether you need timeline alignment:

* **Timeline-accurate (recommended for transcription):** insert silence for the
  missing duration (`(toSeq − fromSeq) × framesPerPacket / sampleRate`), then
  continue decoding. This keeps `timestampMs` aligned with the final file.
* **Simplest:** just keep feeding new ADTS frames; the decoder resyncs at the
  next syncword. The only consequence is the decoded timeline is shorter by the
  missing duration (fine if you rely on `timestampMs` rather than sample counts).

In both cases: **always feed whole ADTS frames** — never a partial frame. The
protocol guarantees one complete frame per binary message, so this holds as long
as the server treats each binary message as one frame.

---

## 7. Events & logging contract (frontend)

The app must be able to log when the socket connected, disconnected, and whether
there were errors. The plugin emits a Capacitor listener event
**`recordingStreamEvent`** for every streaming lifecycle transition. The app
subscribes and writes these to its logs.

```ts
VoiceRecorder.addListener('recordingStreamEvent', (e: RecordingStreamEvent) => {
  appLogger.info('vr_stream', e);   // e.g. push to person_app_logs
});
```

### Event shape

```ts
export interface RecordingStreamEvent {
  type:
    | 'connecting'     // opening the socket
    | 'connected'      // socket open + `start` sent
    | 'reconnecting'   // retrying (see attempt/backoffMs/reason)
    | 'disconnected'   // socket closed (see code/reason)
    | 'error'          // a streaming error occurred; may be terminal (see reason)
    | 'dropped'        // frames dropped due to buffer overflow
    | 'finished';      // clean end after stopRecording (`end` sent + closed)
  timestamp: string;          // ISO-8601
  host?: string;              // server host only (never the token / full URL with creds)
  attempt?: number;           // reconnecting: 1-based attempt number (0 = immediate, e.g. network restored)
  backoffMs?: number;         // reconnecting: delay before this attempt
  code?: number;              // disconnected/error: WebSocket close code or HTTP status
  reason?: string;            // disconnected / error / reconnecting / dropped: short machine reason
  message?: string;           // error: human-readable description
  droppedFrames?: number;     // dropped: cumulative frames discarded
  framesSent?: number;        // finished: total frames sent
  bytesSent?: number;         // finished: total bytes sent
  reconnects?: number;        // finished: number of reconnects during the session
}
```

`reason` values you may see: `no_network`, `network_restored`, `ping`, `receive`,
`send`, `connect`, `start_send`, `close_<code>` (WebSocket close), `http_<status>`,
`max_attempts`, `server_rejected`, `server_<reason>` (from §4.6), `start_serialize`.

A **terminal `error`** (reason `server_rejected`, `server_<reason>`, `max_attempts`
or `start_serialize`) means streaming has stopped for the rest of the recording —
no further reconnects. Everything else is transient.

### Guarantees

* Events are **best-effort and never block recording**.
* Events **never** contain the bearer token or any secret. `host` carries the
  server host for correlation; the full URL with credentials is not emitted.
* The minimum guaranteed sequence for a healthy recording is:
  `connecting → connected → … → finished`.
* A transient outage looks like:
  `connected → disconnected → reconnecting(attempt=1) → … → connected → finished`,
  with `dropped` events in between if the buffer overflowed.
* An offline stretch looks like:
  `disconnected(reason="no_network") → … → reconnecting(reason="network_restored", attempt=0) → connected`.
* `finalState` in the diagnostics block (and the absence of `finished`) reflects a
  terminal state such as `fatal` when the server rejected the stream.

### End-of-recording summary (diagnostics)

`stopRecording`'s resolved `RecordingData.diagnostics` gains a `streaming` block,
so the final outcome can be logged in one place alongside the existing engine
diagnostics:

```json
"diagnostics": {
  "recorderType": "engine",
  "engine": { "...": "existing engine diagnostics" },
  "streaming": {
    "enabled": true,
    "finalState": "finished",
    "framesSent": 12345,
    "framesDropped": 37,
    "bytesSent": 1048576,
    "reconnects": 1,
    "lastError": null
  }
}
```

---

## 8. Minimal backend reference (Node, `ws`)

Illustrative only — strip the 8-byte header, track `seq`, feed ADTS to your
decoder/transcriber.

```js
import { WebSocketServer } from 'ws';

const wss = new WebSocketServer({ port: 8080 });

wss.on('connection', (socket, req) => {
  // Authenticate from req.headers['authorization'] before accepting audio.
  let session = null;
  let expectedSeq = 0;

  socket.on('message', (data, isBinary) => {
    if (!isBinary) {
      const msg = JSON.parse(data.toString());
      if (msg.type === 'start') {
        session = startSession(msg);          // open decoder for msg.sampleRate, etc.
        expectedSeq = 0;
      } else if (msg.type === 'end') {
        finishSession(session, msg);
      }
      return;
    }

    // Binary = one framed ADTS packet.
    const seq = data.readUInt32BE(0);
    const tsMs = data.readUInt32BE(4);
    const adts = data.subarray(8);            // raw ADTS frame

    if (seq > expectedSeq) {
      // Gap: seq - expectedSeq frames were dropped during an outage.
      session.insertSilenceFrames(seq - expectedSeq);   // optional, keeps timeline
    }
    expectedSeq = seq + 1;

    session.decodeAndTranscribe(adts, tsMs);  // feed whole frame; decoder resyncs on gaps
  });

  socket.on('close', (code) => finalize(session, code));
});
```

---

## 9. Scope & non-goals (v1)

* **iOS only.** Android and the web stub ignore the `streaming` option.
* **Engine path only.** The legacy `AVAudioRecorder` fallback does **not** stream
  (it engages only when the audio engine fails to start). The file is still
  recorded normally; no live stream is produced in that case. A
  `recordingStreamEvent` of type `error`/`disconnected` is **not** emitted for
  the legacy path — instead `diagnostics.streaming.enabled` is `false`.
* **No live gap backfill.** Gaps during an outage are not re-sent in v1; reconcile
  from the final file if needed (see §5).

## 10. Security notes

* `wss://` only; reject `ws://`.
* Token travels in the `Authorization` header, never the URL or any log event.
* The backend must authenticate on the upgrade request (and/or validate
  `config`) before accepting audio frames.
