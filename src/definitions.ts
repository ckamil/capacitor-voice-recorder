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
}

export type RecordingOptions =
  | never
  | {
      directory: Directory;
      subDirectory?: string;
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
  /** `dropped`: cumulative frames discarded due to buffer overflow. */
  droppedFrames?: number;
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
