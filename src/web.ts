import { WebPlugin, PluginListenerHandle } from '@capacitor/core';

import { VoiceRecorderImpl } from './VoiceRecorderImpl';
import type {
  CurrentRecordingStatus,
  GenericResponse,
  LifecycleSnapshot,
  RecordingData,
  RecordingOptions,
  StartRecordingResponse,
  VoiceRecorderPlugin,
  MicrophoneAvailabilityEvent,
  RecordingInterruptionEvent,
  InterruptionEndedEvent,
} from './definitions';

export class VoiceRecorderWeb extends WebPlugin implements VoiceRecorderPlugin {
  private voiceRecorderInstance = new VoiceRecorderImpl();

  public canDeviceVoiceRecord(): Promise<GenericResponse> {
    return VoiceRecorderImpl.canDeviceVoiceRecord();
  }

  public hasAudioRecordingPermission(): Promise<GenericResponse> {
    return VoiceRecorderImpl.hasAudioRecordingPermission();
  }

  public requestAudioRecordingPermission(): Promise<GenericResponse> {
    return VoiceRecorderImpl.requestAudioRecordingPermission();
  }

  public async startRecording(options?: RecordingOptions): Promise<StartRecordingResponse> {
    const result = await this.voiceRecorderInstance.startRecording(options);
    return { ...result, engineFallback: null };
  }

  public stopRecording(): Promise<RecordingData> {
    return this.voiceRecorderInstance.stopRecording();
  }

  public pauseRecording(): Promise<GenericResponse> {
    return this.voiceRecorderInstance.pauseRecording();
  }

  public resumeRecording(): Promise<GenericResponse> {
    return this.voiceRecorderInstance.resumeRecording();
  }

  public getCurrentStatus(): Promise<CurrentRecordingStatus> {
    return this.voiceRecorderInstance.getCurrentStatus();
  }

  public getLifecycleSnapshot(): Promise<LifecycleSnapshot> {
    return Promise.resolve({
      last_background_at_ms: 0,
      last_clean_termination_at_ms: 0,
      last_active_at_ms: 0,
      last_resign_active_at_ms: 0,
      abnormal_restart_pending: false,
    });
  }

  public clearAbnormalRestartFlag(): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Web implementation doesn't need interruption handling as it's not applicable
   */
  addListener(
    eventName: 'microphoneAvailabilityChanged',
    listenerFunc: (event: MicrophoneAvailabilityEvent) => void,
  ): Promise<PluginListenerHandle> & PluginListenerHandle;

  addListener(
    eventName: 'recordingInterrupted',
    listenerFunc: (event: RecordingInterruptionEvent) => void,
  ): Promise<PluginListenerHandle> & PluginListenerHandle;

  addListener(
    eventName: 'interruptionEnded',
    listenerFunc: (event: InterruptionEndedEvent) => void,
  ): Promise<PluginListenerHandle> & PluginListenerHandle;

  addListener(
    _eventName: 'microphoneAvailabilityChanged' | 'recordingInterrupted' | 'interruptionEnded',
    _listenerFunc: (event: any) => void,
  ): Promise<PluginListenerHandle> & PluginListenerHandle {
    // Create a dummy listener handle for web
    const handle: PluginListenerHandle = {
      remove: () => Promise.resolve(),
    };

    // For web, we return a handle that satisfies both Promise<PluginListenerHandle> and PluginListenerHandle
    return Object.assign(Promise.resolve(handle), handle);
  }

  removeAllListeners(): Promise<void> {
    return Promise.resolve();
  }
}
