package com.tchvu3.capacitorvoicerecorder;

import android.Manifest;
import android.content.Context;
import android.media.AudioManager;
import android.media.AudioFocusRequest;
import android.media.MediaPlayer;
import android.net.Uri;
import android.os.Build;
import android.util.Base64;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;
import com.getcapacitor.JSObject;
import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;

@CapacitorPlugin(
    name = "VoiceRecorder",
    permissions = { @Permission(alias = VoiceRecorder.RECORD_AUDIO_ALIAS, strings = { Manifest.permission.RECORD_AUDIO }) }
)
public class VoiceRecorder extends Plugin {

    static final String RECORD_AUDIO_ALIAS = "voice recording";
    private CustomMediaRecorder mediaRecorder;
    private AudioManager audioManager;
    private AudioFocusRequest audioFocusRequest;
    private boolean isInterrupted = false;
    private AudioManager globalAudioManager;
    private AudioFocusRequest globalAudioFocusRequest;
    private boolean isMicrophoneCurrentlyAvailable = true;

    @PluginMethod
    public void canDeviceVoiceRecord(PluginCall call) {
        if (CustomMediaRecorder.canPhoneCreateMediaRecorder(getContext())) {
            call.resolve(ResponseGenerator.successResponse());
        } else {
            call.resolve(ResponseGenerator.failResponse());
        }
    }

    @PluginMethod
    public void requestAudioRecordingPermission(PluginCall call) {
        if (doesUserGaveAudioRecordingPermission()) {
            call.resolve(ResponseGenerator.successResponse());
        } else {
            requestPermissionForAlias(RECORD_AUDIO_ALIAS, call, "recordAudioPermissionCallback");
        }
    }

    @PermissionCallback
    private void recordAudioPermissionCallback(PluginCall call) {
        this.hasAudioRecordingPermission(call);
    }

    @PluginMethod
    public void hasAudioRecordingPermission(PluginCall call) {
        call.resolve(ResponseGenerator.fromBoolean(doesUserGaveAudioRecordingPermission()));
    }

    @PluginMethod
    public void startRecording(PluginCall call) {
        if (!CustomMediaRecorder.canPhoneCreateMediaRecorder(getContext())) {
            call.reject(Messages.CANNOT_RECORD_ON_THIS_PHONE);
            return;
        }

        if (!doesUserGaveAudioRecordingPermission()) {
            call.reject(Messages.MISSING_PERMISSION);
            return;
        }

        if (this.isMicrophoneOccupied()) {
            call.reject(Messages.MICROPHONE_BEING_USED);
            return;
        }

        if (mediaRecorder != null) {
            call.reject(Messages.ALREADY_RECORDING);
            return;
        }

        try {
            // Setup audio focus handling
            setupAudioFocusHandling();

            String directory = call.getString("directory");
            String subDirectory = call.getString("subDirectory");
            RecordOptions options = new RecordOptions(directory, subDirectory);
            mediaRecorder = new CustomMediaRecorder(getContext(), options);
            mediaRecorder.startRecording();
            isInterrupted = false;
            call.resolve(ResponseGenerator.successResponse());
        } catch (Exception exp) {
            mediaRecorder = null;
            releaseAudioFocus();
            call.reject(Messages.FAILED_TO_RECORD, exp);
        }
    }

    @PluginMethod
    public void stopRecording(PluginCall call) {
        if (mediaRecorder == null) {
            call.reject(Messages.RECORDING_HAS_NOT_STARTED);
            return;
        }

        try {
            mediaRecorder.stopRecording();
            File recordedFile = mediaRecorder.getOutputFile();
            RecordOptions options = mediaRecorder.getRecordOptions();

            String path = null;
            String recordDataBase64 = null;
            if (options.getDirectory() != null) {
                path = recordedFile.getName();
                if (options.getSubDirectory() != null) {
                    path = options.getSubDirectory() + "/" + path;
                }
            } else {
                recordDataBase64 = readRecordedFileAsBase64(recordedFile);
            }

            RecordData recordData = new RecordData(
                recordDataBase64,
                getMsDurationOfAudioFile(recordedFile.getAbsolutePath()),
                "audio/aac",
                path
            );
            if ((recordDataBase64 == null && path == null) || recordData.getMsDuration() < 0) {
                call.reject(Messages.EMPTY_RECORDING);
            } else {
                call.resolve(ResponseGenerator.dataResponse(recordData.toJSObject()));
            }
        } catch (Exception exp) {
            call.reject(Messages.FAILED_TO_FETCH_RECORDING, exp);
        } finally {
            RecordOptions options = mediaRecorder.getRecordOptions();
            if (options.getDirectory() == null) {
                mediaRecorder.deleteOutputFile();
            }

            mediaRecorder = null;
            releaseAudioFocus();
            isInterrupted = false;
        }
    }

    @PluginMethod
    public void pauseRecording(PluginCall call) {
        if (mediaRecorder == null) {
            call.reject(Messages.RECORDING_HAS_NOT_STARTED);
            return;
        }
        try {
            call.resolve(ResponseGenerator.fromBoolean(mediaRecorder.pauseRecording()));
        } catch (NotSupportedOsVersion exception) {
            call.reject(Messages.NOT_SUPPORTED_OS_VERSION);
        }
    }

    @PluginMethod
    public void resumeRecording(PluginCall call) {
        if (mediaRecorder == null) {
            call.reject(Messages.RECORDING_HAS_NOT_STARTED);
            return;
        }
        try {
            call.resolve(ResponseGenerator.fromBoolean(mediaRecorder.resumeRecording()));
        } catch (NotSupportedOsVersion exception) {
            call.reject(Messages.NOT_SUPPORTED_OS_VERSION);
        }
    }

    @PluginMethod
    public void getCurrentStatus(PluginCall call) {
        if (mediaRecorder == null) {
            call.resolve(ResponseGenerator.statusResponse(CurrentRecordingStatus.NONE));
        } else {
            call.resolve(ResponseGenerator.statusResponse(mediaRecorder.getCurrentStatus()));
        }
    }

    private boolean doesUserGaveAudioRecordingPermission() {
        return getPermissionState(VoiceRecorder.RECORD_AUDIO_ALIAS).equals(PermissionState.GRANTED);
    }

    private String readRecordedFileAsBase64(File recordedFile) {
        BufferedInputStream bufferedInputStream;
        byte[] bArray = new byte[(int) recordedFile.length()];
        try {
            bufferedInputStream = new BufferedInputStream(new FileInputStream(recordedFile));
            bufferedInputStream.read(bArray);
            bufferedInputStream.close();
        } catch (IOException exp) {
            return null;
        }
        return Base64.encodeToString(bArray, Base64.DEFAULT);
    }

    private int getMsDurationOfAudioFile(String recordedFilePath) {
        try {
            MediaPlayer mediaPlayer = new MediaPlayer();
            mediaPlayer.setDataSource(recordedFilePath);
            mediaPlayer.prepare();
            return mediaPlayer.getDuration();
        } catch (Exception ignore) {
            return -1;
        }
    }

    private boolean isMicrophoneOccupied() {
        AudioManager audioManager = (AudioManager) this.getContext().getSystemService(Context.AUDIO_SERVICE);
        if (audioManager == null) return true;
        return audioManager.getMode() != AudioManager.MODE_NORMAL;
    }

    // Audio Focus Handling Methods
    private void setupAudioFocusHandling() {
        audioManager = (AudioManager) getContext().getSystemService(Context.AUDIO_SERVICE);
        if (audioManager == null) return;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                .setOnAudioFocusChangeListener(audioFocusChangeListener)
                .build();
            audioManager.requestAudioFocus(audioFocusRequest);
        } else {
            audioManager.requestAudioFocus(
                audioFocusChangeListener,
                AudioManager.STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE
            );
        }
    }

    private void releaseAudioFocus() {
        if (audioManager == null) return;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (audioFocusRequest != null) {
                audioManager.abandonAudioFocusRequest(audioFocusRequest);
                audioFocusRequest = null;
            }
        } else {
            audioManager.abandonAudioFocus(audioFocusChangeListener);
        }
        audioManager = null;
    }

    private final AudioManager.OnAudioFocusChangeListener audioFocusChangeListener =
        new AudioManager.OnAudioFocusChangeListener() {
        @Override
        public void onAudioFocusChange(int focusChange) {
            android.util.Log.d("VoiceRecorder", "onAudioFocusChange: " + focusChange + " (isInterrupted: " + isInterrupted + ", recording: " + (mediaRecorder != null) + ")");

            // Handle recording interruption if we have an active recording
            if (mediaRecorder != null) {
                switch (focusChange) {
                    case AudioManager.AUDIOFOCUS_LOSS:
                    case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT:
                        handleAudioFocusLoss(false);
                        break;
                    case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK:
                        handleAudioFocusLoss(true);
                        break;
                    case AudioManager.AUDIOFOCUS_GAIN:
                        handleAudioFocusGain();
                        break;
                }
            }
        }
    };

    private void handleAudioFocusLoss(boolean canDuck) {
        android.util.Log.d("VoiceRecorder", "handleAudioFocusLoss called - canDuck: " + canDuck + ", mediaRecorder: " + (mediaRecorder != null));

        // Handle recording interruption if we have an active recording
        if (mediaRecorder != null) {
            isInterrupted = true;

            // Pause recording when we lose audio focus
            CurrentRecordingStatus currentStatus = mediaRecorder.getCurrentStatus();
            if (currentStatus == CurrentRecordingStatus.RECORDING) {
                try {
                    mediaRecorder.pauseRecording();
                } catch (NotSupportedOsVersion ignored) {
                    // If pause is not supported, we can't handle interruption gracefully
                    return;
                }
            }

            // Notify JavaScript layer about the recording interruption
            JSObject interruptionData = new JSObject();
            JSObject data = new JSObject();
            data.put("reason", canDuck ? "other_app" : "audio_focus_loss");
            data.put("timestamp", java.time.Instant.now().toString());
            interruptionData.put("data", data);

            android.util.Log.d("VoiceRecorder", "Sending recordingInterrupted event to JavaScript - reason: " + data.getString("reason"));
            notifyListeners("recordingInterrupted", interruptionData);
        }
    }

    private void handleAudioFocusGain() {
        android.util.Log.d("VoiceRecorder", "handleAudioFocusGain called - isInterrupted: " + isInterrupted + ", mediaRecorder: " + (mediaRecorder != null));

        // Handle recording resumption if we have an interrupted recording
        if (isInterrupted && mediaRecorder != null) {
            // Notify JavaScript layer that interruption ended
            JSObject interruptionEndedData = new JSObject();
            interruptionEndedData.put("canResume", true);

            android.util.Log.d("VoiceRecorder", "Sending interruptionEnded event to JavaScript");
            notifyListeners("interruptionEnded", interruptionEndedData);

            // Auto-resume if recording is paused
            CurrentRecordingStatus currentStatus = mediaRecorder.getCurrentStatus();
            if (currentStatus == CurrentRecordingStatus.PAUSED) {
                try {
                    mediaRecorder.resumeRecording();
                    isInterrupted = false;
                } catch (NotSupportedOsVersion ignored) {
                    // If resume is not supported, keep interruption state
                }
            }
        }
    }


    @Override
    public void load() {
        super.load();
        setupGlobalAudioFocusListener();
    }

    @Override
    public void handleOnDestroy() {
        releaseGlobalAudioFocusListener();
        super.handleOnDestroy();
    }

    // Global Audio Focus Listener for Microphone Availability Detection

    private void setupGlobalAudioFocusListener() {
        globalAudioManager = (AudioManager) getContext().getSystemService(Context.AUDIO_SERVICE);
        if (globalAudioManager == null) return;

        android.util.Log.d("VoiceRecorder", "Setting up global audio focus listener");

        // Create a separate listener that maintains audio focus to monitor changes
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            globalAudioFocusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setOnAudioFocusChangeListener(globalAudioFocusChangeListener)
                .setAcceptsDelayedFocusGain(true)
                .build();
            int result = globalAudioManager.requestAudioFocus(globalAudioFocusRequest);
            android.util.Log.d("VoiceRecorder", "Global audio focus request result: " + result);
        } else {
            int result = globalAudioManager.requestAudioFocus(
                globalAudioFocusChangeListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
            );
            android.util.Log.d("VoiceRecorder", "Global audio focus request result: " + result);
        }
    }

    private void releaseGlobalAudioFocusListener() {
        if (globalAudioManager == null) return;

        android.util.Log.d("VoiceRecorder", "Releasing global audio focus listener");

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (globalAudioFocusRequest != null) {
                globalAudioManager.abandonAudioFocusRequest(globalAudioFocusRequest);
                globalAudioFocusRequest = null;
            }
        } else {
            globalAudioManager.abandonAudioFocus(globalAudioFocusChangeListener);
        }
        globalAudioManager = null;
    }

    // Separate global audio focus listener for microphone availability monitoring
    private final AudioManager.OnAudioFocusChangeListener globalAudioFocusChangeListener =
        new AudioManager.OnAudioFocusChangeListener() {
        @Override
        public void onAudioFocusChange(int focusChange) {
            android.util.Log.d("VoiceRecorder", "Global onAudioFocusChange: " + focusChange + " (recording: " + (mediaRecorder != null) + ", available: " + isMicrophoneCurrentlyAvailable + ")");

            // Handle microphone availability when not actively recording 
            // or when recording is interrupted (paused due to other app)
            if (mediaRecorder == null || isInterrupted) {
                switch (focusChange) {
                    case AudioManager.AUDIOFOCUS_LOSS:
                    case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT:
                    case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK:
                        // Only send event if microphone was available and we're not the cause
                        if (isMicrophoneCurrentlyAvailable && !isOurAppCausingFocusChange()) {
                            isMicrophoneCurrentlyAvailable = false;

                            String reason = isMicrophoneOccupied() ? "phone_call_started" : "other_app_started";
                            JSObject availabilityData = new JSObject();
                            availabilityData.put("available", false);
                            availabilityData.put("reason", reason);

                            android.util.Log.d("VoiceRecorder", "Global - Sending microphoneAvailabilityChanged: false - " + reason);
                            notifyListeners("microphoneAvailabilityChanged", availabilityData);
                        }
                        break;

                    case AudioManager.AUDIOFOCUS_GAIN:
                        // Only send event if microphone was unavailable and we're not the cause
                        if (!isMicrophoneCurrentlyAvailable && !isOurAppCausingFocusChange()) {
                            isMicrophoneCurrentlyAvailable = true;

                            JSObject availabilityData = new JSObject();
                            availabilityData.put("available", true);
                            availabilityData.put("reason", "other_app_finished");

                            android.util.Log.d("VoiceRecorder", "Global - Sending microphoneAvailabilityChanged: true - other_app_finished");
                            notifyListeners("microphoneAvailabilityChanged", availabilityData);
                        }
                        break;
                }
            }
        }
    };

    // Helper method to determine if our app is causing the audio focus change
    private boolean isOurAppCausingFocusChange() {
        // If we have an active recording that's not interrupted, we are using the microphone
        // If recording is interrupted, we're not actively using the microphone anymore
        return mediaRecorder != null && !isInterrupted;
    }
}
