import type { Directory } from '@capacitor/filesystem';
import type { PluginListenerHandle } from '@capacitor/core';

export type Base64String = string;

export interface EngineFallbackDetails {
  stage: string;
  error: string;
  isOtherAudioPlaying?: boolean;
  deviceIdiom?: string;
  activationErrors?: Array<Record<string, any>>;
  details?: Record<string, any>;
}

export interface StartRecordingResponse {
  value: boolean;
  engine?: 'audio_engine' | 'legacy';
  engineFallback?: EngineFallbackDetails | null;
}

export interface RecordingData {
  value: {
    recordDataBase64?: Base64String;
    msDuration: number;
    mimeType: string;
    path?: string;
    diagnostics?: Record<string, any>;
  };
}

/**
 * iOS and Android. Configures the optional live audio stream that runs alongside (and never
 * affects) the on-disk recording. The whole block travels with each `startRecording`
 * call, so multi-profile apps just pass a different server per call — there is no
 * persistent native-side server state. See docs/websocket-audio-streaming.md.
 */
export interface StreamingReconnectOptions {
  /** Delay before the first reconnect attempt, in ms. Default 1000. */
  initialDelayMs?: number;
  /** Maximum backoff delay between attempts, in ms (exponential, capped here). Default 8000. */
  maxDelayMs?: number;
  /** Max reconnect attempts before giving up for this recording. 0 = unlimited. Default 0. */
  maxAttempts?: number;
}

/**
 * Auto-suspend: when the link is dead-but-reachable (handshake storms, or frames dropping faster
 * than they send), park the WebSocket on a doubling cooldown with periodic probes instead of
 * churning the radio. Self-regulating natively (JS is suspended in the background, where this
 * matters). Purely additive — never affects the on-disk recording. All optional; when `enabled`
 * is false the sink behaves exactly as before.
 */
export interface StreamingAutosuspendOptions {
  /** Master switch. Default false (legacy behaviour, byte-for-byte). */
  enabled?: boolean;
  /** Consecutive reconnect attempts before suspending. Default 4. */
  afterReconnects?: number;
  /** Sustained drop rate (frames/s, while connected) that triggers suspend. Default 30. */
  dropRateFps?: number;
  /** Window (s) over which the drop rate is measured. Default 20. */
  dropWindowSec?: number;
  /** First cooldown (s) before a probe reconnect; doubles each failed probe. Default 60. */
  cooldownSec?: number;
  /** Cap on the doubling cooldown (s). Default 600. */
  maxCooldownSec?: number;
  /** Fail-open backstop: total suspended time (s) before giving up streaming for this recording. Default 1800. */
  maxTotalSec?: number;
}

export interface StreamingOptions {
  /** WebSocket URL of the transcription/audio server for the active profile. `wss://` required. */
  url: string;
  /** Optional bearer token; sent as `Authorization: Bearer <token>` on the upgrade request. Never logged. */
  token?: string;
  /** Optional extra headers added to the WebSocket upgrade request. */
  headers?: Record<string, string>;
  /** Arbitrary, JSON-serializable app/profile payload forwarded verbatim in the `start` control message. */
  config?: Record<string, any>;
  /** Reconnect / backoff tuning. */
  reconnect?: StreamingReconnectOptions;
  /** Seconds of audio buffered while disconnected before the oldest frames are dropped. Default 10. */
  maxBufferSeconds?: number;
  /** WebSocket keepalive ping interval in ms; detects dead connections. 0 disables. Default 20000. */
  pingIntervalMs?: number;
  /** When true (default), only attempt/await connections while the OS reports network reachability. */
  requireReachability?: boolean;
  /**
   * iOS only. How the streamed AAC frames are produced. Android always tails the on-disk ADTS
   * file and ignores this. Default 'file_tail'.
   * - 'hardware'  — re-encode the mic PCM with AVAudioConverter (default codec, may pick the
   *                 hardware AAC encoder). NOTE: the hardware encoder yields SILENCE on some
   *                 devices (e.g. iPhone) while the session uses `.mixWithOthers`.
   * - 'software'  — re-encode the mic PCM forcing the software AAC codec
   *                 (AudioConverterNewSpecific + kAppleSoftwareAudioCodecManufacturer); not
   *                 affected by `.mixWithOthers`.
   * - 'file_tail' — do not re-encode; read the ADTS frames the recorder already writes to disk
   *                 (same approach as Android). Works on all devices, no double encode.
   */
  encodeMode?: 'hardware' | 'software' | 'file_tail';
  /** Auto-suspend on a dead-but-reachable link. Omit / `enabled:false` → legacy behaviour. */
  autosuspend?: StreamingAutosuspendOptions;
}

/**
 * Android only. Which `MediaRecorder.AudioSource` to open.
 *
 * `UNPROCESSED` is an OPTIONAL source — a device only really provides it when it advertises
 * `AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED`. Asking for it on a device that does
 * not results in an ungained raw capture path: the file has the right duration, the right size
 * and no speech in it. Hence the default never selects it.
 *
 * - `auto` (default) / `voice_recognition` — VOICE_RECOGNITION. Mandatory-supported, and specified
 *   to run without AGC or noise suppression, so speaker audio from presentations is not filtered
 *   and there are no AGC artifacts.
 * - `unprocessed` — UNPROCESSED, but only when the device advertises support; otherwise falls back
 *   to VOICE_RECOGNITION.
 * - `unprocessed_force` — UNPROCESSED unconditionally. On-device diagnosis only; this is the
 *   configuration that produced silent recordings in the field.
 * - `mic` — MIC. The processed path, with AGC.
 * - `voice_communication` — VOICE_COMMUNICATION. AEC-tuned, for call-like capture.
 */
export type AndroidAudioSource = 'auto' | 'voice_recognition' | 'unprocessed' | 'unprocessed_force' | 'mic' | 'voice_communication';

export type RecordingOptions =
  | never
  | {
      directory: Directory;
      subDirectory?: string;
      /**
       * Android only (iOS ignores it and should not send it). Capture source for MediaRecorder.
       * Drive from SettingsService for remote control. Default 'auto'.
       */
      androidAudioSource?: AndroidAudioSource;
      /**
       * Android only. Peak PCM amplitude (0..32767) below which the finished recording is reported
       * as `silent` in the stop diagnostics. Observability only — it never alters the recording.
       * Default 200.
       */
      androidSilenceThreshold?: number;
      // When true, ambiguous audio-session interruptions (no reason / unknown reason /
      // iOS < 14.5) let the recording CONTINUE (relying on the native engine auto-restart)
      // instead of stopping. Default false. Drive from SettingsService for remote control.
      continueOnAmbiguousInterruption?: boolean;
      // iOS and Android. When present, the recording is additionally streamed live as AAC
      // ADTS frames over a WebSocket. Purely additive: streaming failures never affect the
      // recording or the saved file. Omit to disable (default).
      streaming?: StreamingOptions;
    };

export interface GenericResponse {
  value: boolean;
}

export const RecordingStatus = {
  RECORDING: 'RECORDING',
  PAUSED: 'PAUSED',
  NONE: 'NONE',
} as const;

export interface CurrentRecordingStatus {
  status: (typeof RecordingStatus)[keyof typeof RecordingStatus];
}

export interface LifecycleSnapshot {
  last_background_at_ms: number;
  last_clean_termination_at_ms: number;
  last_active_at_ms: number;
  last_resign_active_at_ms: number;
  abnormal_restart_pending: boolean;
  /** Filename of the recording finalized in willTerminate (user force-quit mid-recording); "" when none. */
  terminated_recording_file?: string;
  /** When the willTerminate finalize ran (epoch ms); 0 when none. */
  terminated_recording_at_ms?: number;
  thermal_state?: 'nominal' | 'fair' | 'serious' | 'critical' | 'unknown';
  low_power_mode?: boolean;
  is_protected_data_available?: boolean;
}

export interface InterruptionData {
  reason: 'system_interruption' | 'audio_focus_loss' | 'phone_call' | 'other_app' | 'media_services_reset';
  timestamp: string;
}

export interface RecordingInterruptionEvent {
  data: InterruptionData;
}

export interface InterruptionEndedEvent {
  canResume: boolean;
}

export interface MicrophoneAvailabilityEvent {
  available: boolean;
  reason?:
    | 'system_available'
    | 'other_app_finished'
    | 'phone_call_ended'
    | 'system_unavailable'
    | 'other_app_started'
    | 'phone_call_started';
}

export type RecordingStreamEventType =
  | 'connecting'
  | 'connected'
  | 'reconnecting'
  | 'disconnected'
  | 'error'
  | 'dropped'
  // auto-suspend: streaming parked on a dead link (`suspended`) / link recovered (`resumed`)
  | 'suspended'
  | 'resumed'
  | 'finished';

/**
 * iOS and Android. Lifecycle of the optional live WebSocket audio stream. Emitted via the
 * `recordingStreamEvent` listener so the app can log when streaming connected,
 * disconnected, reconnected, dropped frames, or errored. Never contains the token.
 */
export interface RecordingStreamEvent {
  type: RecordingStreamEventType;
  /** ISO-8601 timestamp of the event. */
  timestamp: string;
  /** Server host (for correlation); never the full URL with credentials. */
  host?: string;
  /** `reconnecting`: 1-based attempt number. */
  attempt?: number;
  /** `reconnecting`: delay in ms before this attempt. */
  backoffMs?: number;
  /** `disconnected`: WebSocket close code. */
  code?: number;
  /** `disconnected` / `error` / `dropped`: short machine reason. */
  reason?: string;
  /** `error`: human-readable description. */
  message?: string;
  /** `dropped` / `suspended` / `resumed`: cumulative frames discarded due to buffer overflow. */
  droppedFrames?: number;
  /** `suspended`: cooldown (ms) before the next probe reconnect. */
  cooldownMs?: number;
  /** `finished`: total frames sent over the session. */
  framesSent?: number;
  /** `finished`: total bytes sent over the session. */
  bytesSent?: number;
  /** `finished`: number of reconnects during the session. */
  reconnects?: number;
}

export interface VoiceRecorderPlugin {
  canDeviceVoiceRecord(): Promise<GenericResponse>;

  requestAudioRecordingPermission(): Promise<GenericResponse>;

  hasAudioRecordingPermission(): Promise<GenericResponse>;

  startRecording(options?: RecordingOptions): Promise<StartRecordingResponse>;

  stopRecording(): Promise<RecordingData>;

  pauseRecording(): Promise<GenericResponse>;

  resumeRecording(): Promise<GenericResponse>;

  getCurrentStatus(): Promise<CurrentRecordingStatus>;

  /**
   * iOS only (Android/web always resolve `{ value: false }`). Returns whether the device screen
   * is currently being captured/broadcast/mirrored — ReplayKit screen-share (Zoom/Teams), AirPlay
   * mirroring, or Control Center screen recording. This is a SCREEN signal, orthogonal to audio:
   * our own microphone recording never sets it, nor does another app merely playing audio. The app
   * uses it to skip auto-starting a recording while true, avoiding the ReplayKit audio-session crash.
   */
  isScreenCaptured(): Promise<GenericResponse>;

  /**
   * Returns timestamps captured by the native AppDelegate lifecycle hooks plus a
   * derived abnormal_restart_pending flag. Used once on cold start to log the
   * previous process's outcome to person_app_logs. Web stub returns zeros.
   */
  getLifecycleSnapshot(): Promise<LifecycleSnapshot>;

  /**
   * Clears the abnormal_restart_pending flag after the JS layer has logged it.
   * Without clearing, the flag would persist and re-fire on the next resume.
   */
  clearAbnormalRestartFlag(): Promise<void>;

  /**
   * Listen for microphone availability changes (e.g., other apps start/stop using audio)
   */
  addListener(
    eventName: 'microphoneAvailabilityChanged',
    listenerFunc: (event: MicrophoneAvailabilityEvent) => void,
  ): Promise<PluginListenerHandle> & PluginListenerHandle;

  /**
   * Listen for recording interruption events (e.g., phone calls, other apps taking audio focus)
   */
  addListener(
    eventName: 'recordingInterrupted',
    listenerFunc: (event: RecordingInterruptionEvent) => void,
  ): Promise<PluginListenerHandle> & PluginListenerHandle;

  /**
   * Listen for interruption ended events (recording can potentially be resumed)
   */
  addListener(
    eventName: 'interruptionEnded',
    listenerFunc: (event: InterruptionEndedEvent) => void,
  ): Promise<PluginListenerHandle> & PluginListenerHandle;

  /**
   * iOS and Android. Listen for live-streaming lifecycle events (WebSocket connect / disconnect /
   * reconnect / dropped frames / error / finished). Use these for logging streaming health.
   * These events never affect recording.
   */
  addListener(
    eventName: 'recordingStreamEvent',
    listenerFunc: (event: RecordingStreamEvent) => void,
  ): Promise<PluginListenerHandle> & PluginListenerHandle;

  /**
   * Remove all listeners for this plugin
   */
  removeAllListeners(): Promise<void>;
}
