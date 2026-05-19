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

export type RecordingOptions =
  | never
  | {
      directory: Directory;
      subDirectory?: string;
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
  reason: 'system_interruption' | 'audio_focus_loss' | 'phone_call' | 'other_app';
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
  reason?: 'system_available' | 'other_app_finished' | 'phone_call_ended' | 'system_unavailable' | 'other_app_started' | 'phone_call_started';
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
   * Remove all listeners for this plugin
   */
  removeAllListeners(): Promise<void>;
}
