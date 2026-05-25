# Custom Changes Log

## iOS — streaming AAC capture + recovery removal (2026-05-25)

### Why this fork diverges from upstream (tchvu3/capacitor-voice-recorder)
Upstream records on iOS with a single `AVAudioRecorder` that encodes AAC in real time.
On **iPad during Keynote presentations** (audio + video playing inside a `WKWebView`)
that path breaks: with `.mixWithOthers` active, `AVAudioRecorder.record()` returns
`false` / the session throws error `560557684`, so the recording silently never starts.
Our core scenario is exactly that — a salesperson recording while a presentation with
audio/video plays in the WebView — so we replaced the recorder with **`AVAudioEngine` +
`installTap`**, which is unaffected by that bug. The legacy `AVAudioRecorder` is kept only
as a fallback when the engine fails to start. Upstream's interruption handling was also
inadequate for us (see upstream issues #119 "status stays RECORDING after interruption",
#130 "emit an event when interrupted", #108 "intermittent EMPTY_RECORDING"), which is why
we send our own `recordingInterrupted` / `interruptionEnded` events and use CallKit to tell
a real phone call (→ stop) from WebView/background audio (→ keep recording).

### Removed: crash-recovery of orphaned recordings
The earlier design wrote raw float32 **PCM (`-pcm.wav`)** during capture and converted it
to AAC only at stop, specifically so a recording killed mid-flight could be salvaged
(`recoverOrphanedRecordings`, WAV-header repair, `.meta.json` sidecar). Production logs
(`person_app_logs`, rs+ahd) showed this never paid off: **`recording_recovered` = 0** — the
recovery wiring was never actually shipped, while the real loss vector (`system_app_restart`,
~445 cases) is iOS reclaiming the app after **hours** in the background, not a disk/size
issue (devices had ~99 GB free). Recovery was therefore removed in full (JS, native Swift,
`VoiceRecorderPlugin.m` registration, `definitions.ts`).

### Changed: PCM intermediate → streaming AAC (ADTS)
With recovery gone, the PCM intermediate had no remaining justification and became pure
cost: ~180 KB/s on disk (≈22× the AAC, e.g. 102 MB vs 4.5 MB for a 9-min clip), a
conversion step at stop (its own kill window), a fallback bug (a failed conversion copied
the WAV bytes into a `.aac` file → `AVURLAsset` could not read its duration → recording
rejected as `EMPTY_RECORDING`; observed 6× on rs), and — after recovery removal — **leaked
orphaned `-pcm.wav` files** on every mid-recording kill (nothing cleaned them up anymore).

`AudioEngineRecorder` now encodes AAC **live in the tap** via `ExtAudioFile`
(`kAudioFileAAC_ADTSType`), with no PCM file and no conversion at stop. The output is the
**same `.aac` (ADTS) / `audio/aac`** as before, so the JS layer, upload and server are
unchanged. This keeps the iPad/WebView fix (still `installTap` + `.mixWithOthers`) while
eliminating the disk overhead, the conversion-fallback bug and the orphaned-PCM leak.

Implementation notes:
- Client (PCM) format for the encoder is taken from the **same `AVAudioFormat` used to
  install the tap** (`recordingFormat.streamDescription.pointee`) — required for correct
  non-interleaved/float32 flags.
- `ExtAudioFileDispose` runs **inside `writeQueue.sync`** after `engine.stop()`, so the file
  is never finalized while a queued write is still in flight.
- The output file is set to `.completeUntilFirstUserAuthentication` data protection so
  **background, location-triggered recordings keep writing even with the screen locked**.
- A failure to open the AAC file returns `stage: "engine_aac_open"` → falls back to the
  legacy `AVAudioRecorder`.

### Added: engine auto-restart on configuration change (robustness)
`AVAudioEngine` is **stopped by iOS** whenever the audio route or format changes mid-capture
(Bluetooth/headset connect or disconnect, the WebView reconfiguring the shared session for
presentation audio, a hardware sample-rate change). Previously nothing restarted it, so the
tap went silent and the rest of the recording was lost — a likely cause of the upstream
"only ~1 second recorded" report (#37). `AudioEngineRecorder` now observes
`AVAudioEngineConfigurationChange` and, while still RECORDING, reactivates the session,
re-installs the tap and restarts the engine **into the same open AAC file**, so capture
continues seamlessly. The tap is always installed with a fixed `recordingFormat`, so the
engine resamples for us if the new route runs at a different rate. Restarts are counted in
diagnostics (`engine_restarts`). Best-effort: if the restart throws, the recording ends at
the change point (no worse than before).

### Restored / added: background continuity hardening
- **Long-lived recording background task** (`VoiceRecorderActive`) is begun on every
  successful start (engine and legacy) and ended at stop. It had been dropped during the
  recovery rollback; it is a belt-and-suspenders on top of the `audio` background mode and
  also protects the start handshake when a recording is launched into the background by a
  location event.
- **`AVAudioSession.mediaServicesWereReset` handler** — when `mediaserverd` resets, the whole
  audio stack (session + engine) is invalidated and capture cannot continue. We now emit a
  `recordingInterrupted` (reason `media_services_reset`) so the JS layer stops, saves what was
  captured (ADTS `.aac` is playable up to the reset) and may restart. Previously this was an
  unhandled, total, silent loss.
- **Configurable ambiguous-interruption policy** — previously a `no_reason_provided` /
  `@unknown` / `iOS < 14.5` interruption always STOPPED the recording (over-cautious). Now,
  with the engine auto-restart in place, the app can let these ambiguous cases CONTINUE. Driven
  by `startRecording`'s `continueOnAmbiguousInterruption` option, fed from
  `SettingsService` key `recording.continue_on_ambiguous_interruption` (**default 0 = keep the
  current cautious-stop behaviour**; flip to 1 remotely after on-device validation). Confirmed
  reasons (`phone_call`, `microphone_muted`) still always stop.

### Unchanged (deliberately)
Audio-session config (`.playAndRecord` + `.mixWithOthers`, `setPreferredInput`, activation
retries), `installTap`, `UIBackgroundModes: audio`, the legacy fallback, and the
`recordingInterrupted` / `interruptionEnded` / `microphoneAvailabilityChanged` events.
Background recording and recording-during-WebView
behave exactly as before — they depend on the session + tap + background mode, not on the
on-disk file format.

### Known trade-off
A kill mid-recording now leaves a truncated `.aac` instead of a recoverable WAV. That audio
was already lost in practice (recovery was never live), and in exchange we drop the disk
overhead, the conversion-fallback bug and the PCM leak.

### Design note — the two interruption observers are intentional (not a bug)
`VoiceRecorder` registers two `interruptionNotification` observers on different planes, and
this is **by design** (commit 79a196f "add interruption events") — see the DESIGN NOTE comment
above `setupAudioSessionInterruptionHandling` in `VoiceRecorder.swift`:
- **per-recording** (`object: shared`, only while recording) — the smart stop/continue decision
  (CallKit phone-call vs WebView audio, mic-muted);
- **global** (`object: nil`, always) — microphone-availability tracking when NOT recording,
  route changes, and a deliberate `interruptionEnded` backup for the case the per-recording
  observer missed `.ended` (e.g. it was already removed during stop).
They only overlap in the narrow `interrupted → .ended` window (a possible double
`interruptionEnded`, which JS already tolerates). **Do not "deduplicate" by removing an
observer or the `|| isInterrupted` guard** — that reintroduces the missed-event window the
backup was added to prevent. If ever needed, make the emission idempotent (emit-once flag)
while keeping both observers.

---

## v7.1.0-interruption.1 (2024-08-19)

### 🎯 Added
- **iOS interruption handling** via AVAudioSessionInterruptionNotification
- **Android audio focus management** with AudioFocusRequest and OnAudioFocusChangeListener
- **TypeScript events**: `recordingInterrupted` and `interruptionEnded`
- **Automatic pause/resume** on system interruptions (phone calls, other apps)
- **User notification system** for interruption states
- **Recording status monitoring** to detect unexpected stops
- **Graceful degradation** for older Android versions

### 📱 Platform Support
- **iOS**: Full interruption handling with AVAudioSession
- **Android**: Audio focus handling (SDK 24+ for pause/resume)
- **Web**: Event structure defined (native handling not applicable)

### 🔧 Technical Implementation
- Added interruption data interfaces with reason tracking
- Integrated with Capacitor's plugin listener system
- Automatic cleanup of audio session resources
- Background-compatible audio session management

### 🎛️ New Events
```typescript
// Listen for recording interruptions
VoiceRecorder.addListener('recordingInterrupted', (event) => {
  console.log('Interrupted:', event.data.reason); // 'system_interruption', 'audio_focus_loss', etc.
});

// Listen for interruption end
VoiceRecorder.addListener('interruptionEnded', (event) => {
  console.log('Can resume:', event.canResume);
});
```

### 🐛 Fixed
- Recording continues when device goes to sleep (iOS)
- Recording lost when phone call interrupts (iOS/Android)
- No notification when other apps take audio focus (Android)
- App unaware of recording state changes

### 🔄 Upstream Sync
- Based on upstream v7.0.5 (tchvu3/capacitor-voice-recorder)
- Maintains full backward compatibility
- No breaking changes to existing API

### ⚠️ Breaking Changes
- None - all new features are opt-in via event listeners

### 📚 Migration Guide  
- Existing code works without changes
- Add event listeners for enhanced interruption handling
- Update TypeScript imports to include new event types

### 🧪 Testing
- Tested on iOS (iPad)
- Verified phone call interruptions
- Confirmed app backgrounding scenarios
- Android audio focus validation pending

---

## Upstream Compatibility
- Synced with upstream v7.0.5 (2024-08-19)
- All upstream features preserved
- Can be merged back to upstream with minor adjustments