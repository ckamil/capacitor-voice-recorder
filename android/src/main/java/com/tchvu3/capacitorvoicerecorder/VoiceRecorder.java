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
    private boolean wasInterruptedAndStopped = false; // Tracks if we stopped recording due to interruption
    private AudioManager globalAudioManager;
    private AudioFocusRequest globalAudioFocusRequest;
    private boolean isMicrophoneCurrentlyAvailable = true;
    // Whether the microphone foreground service was up for the recording currently in progress,
    // and why not when it is not. Carried to the stop diagnostics so a recording that could only
    // capture on screen says so in person_app_logs instead of being diagnosed months later.
    private boolean micServiceStarted;
    private String micServiceError;
    // Whether the platform will actually hand that service the microphone. Separate from
    // `micServiceStarted` on purpose: up to Android 13 a service started from the background comes
    // up fine and gets no capability (measured on Android 12L), so collapsing the two would log a
    // reassuring `true` for exactly the recordings that come back silent. From Android 14 the
    // start from the background throws SecurityException instead (measured on Android 16): both
    // flags are false and `micServiceError` carries the class name, reported as
    // mic_foreground_service_error.
    private boolean micCapabilityGranted;

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

    // Screen-capture detection is an iOS/ReplayKit concern (Zoom screen-share crash). Android has
    // no equivalent audio-session hijack, so this is a no-op that always reports false.
    @PluginMethod
    public void isScreenCaptured(PluginCall call) {
        call.resolve(ResponseGenerator.fromBoolean(false));
    }

    // Reports the same condition startRecording already refuses on (MICROPHONE_BEING_USED), so the
    // JS layer can ask BEFORE starting and show the user why, instead of surfacing a native
    // rejection. Answering here changes nothing about what the device will or will not record —
    // the native gate below is unchanged and remains the authority.
    @PluginMethod
    public void isMicrophoneBusy(PluginCall call) {
        AudioManager audioManager = (AudioManager) getContext().getSystemService(Context.AUDIO_SERVICE);
        int mode = audioManager != null ? audioManager.getMode() : -1;
        boolean busy = isMicrophoneOccupied();
        JSObject result = new JSObject();
        result.put("value", busy);
        result.put("reason", busy ? "call" : "none");
        result.put("audioMode", mode);
        call.resolve(result);
    }

    @PluginMethod
    public void startRecording(PluginCall call) {
        if (!CustomMediaRecorder.canPhoneCreateMediaRecorder(getContext())) {
            rejectWithDiagnostics(call, Messages.CANNOT_RECORD_ON_THIS_PHONE,
                    "Device cannot create MediaRecorder", null);
            return;
        }

        if (!doesUserGaveAudioRecordingPermission()) {
            rejectWithDiagnostics(call, Messages.MISSING_PERMISSION,
                    "Audio recording permission not granted", null);
            return;
        }

        if (this.isMicrophoneOccupied()) {
            AudioManager audioManager = (AudioManager) getContext().getSystemService(Context.AUDIO_SERVICE);
            JSObject details = new JSObject();
            details.put("audioMode", audioManager != null ? audioManager.getMode() : -1);
            rejectWithDiagnostics(call, Messages.MICROPHONE_BEING_USED,
                    "Microphone is occupied by another application", details);
            return;
        }

        if (mediaRecorder != null) {
            rejectWithDiagnostics(call, Messages.ALREADY_RECORDING,
                    "Recording is already in progress", null);
            return;
        }

        try {
            // Skip audio focus handling on Android - microphone works independently of audio focus.
            // Requesting audio focus causes MediaRecorder to lose mic data when WebView video
            // plays and triggers AUDIOFOCUS_LOSS. Without focus request, MediaRecorder records
            // uninterrupted (mic + ambient speaker audio from video).
            // setupAudioFocusHandling();

            String directory = call.getString("directory");
            String subDirectory = call.getString("subDirectory");
            RecordOptions options = new RecordOptions(directory, subDirectory);
            options.setStreaming(StreamingConfig.fromJSObject(call.getObject("streaming")));
            // Android-only capture tuning. Both are optional and remote-controlled from
            // SettingsService; omitted (iOS never sends them) means the safe defaults.
            options.setAudioSource(call.getString("androidAudioSource"));
            Integer silenceThreshold = call.getInt("androidSilenceThreshold", CustomMediaRecorder.DEFAULT_SILENCE_THRESHOLD);
            if (silenceThreshold != null) {
                options.setSilenceThreshold(silenceThreshold);
            }
            Double minCaptureRatio = call.getDouble("androidMinCaptureRatio");
            if (minCaptureRatio != null) {
                options.setMinCaptureRatio(minCaptureRatio);
            }
            mediaRecorder = new CustomMediaRecorder(getContext(), options);

            // Take the microphone foreground service BEFORE opening the recorder. RECORD_AUDIO is a
            // while-in-use permission: without a service of type `microphone` the platform stops
            // feeding the microphone the moment the app leaves the screen — with no error, so the
            // recorder happily encodes zeros for the rest of the session (AMA-393). Deliberately
            // fail-open: if the service cannot start we still record, because capture on screen
            // beats no capture at all, and the reason is reported at stop.
            //
            // The visibility check has to happen BEFORE the start: the capability is decided at
            // that instant, and a service started from the background never gets it.
            boolean visibleAtStart = RecordingForegroundService.isAppVisible(getContext());
            micServiceError = RecordingForegroundService.start(getContext());
            micServiceStarted = micServiceError == null;
            micCapabilityGranted = micServiceStarted && visibleAtStart;
            if (!micCapabilityGranted) {
                android.util.Log.w(
                    "VoiceRecorder",
                    "microphone capability not held (started=" + micServiceStarted +
                    ", error=" + micServiceError + ", visible=" + visibleAtStart +
                    ") — this recording can only capture while the app is on screen"
                );
            }
            // Forward live-streaming lifecycle events to JS for logging. Set before startRecording
            // so connect/error events emitted during setup are delivered.
            mediaRecorder.setStreamEventListener(event -> notifyListeners("recordingStreamEvent", event));
            mediaRecorder.startRecording();
            isInterrupted = false;
            wasInterruptedAndStopped = false;
            JSObject started = ResponseGenerator.successResponse();
            // Reported at start as well as at stop: a recording that begins without the service is
            // already doomed to lose everything off screen, and waiting hours for the stop log to
            // say so is how this went unnoticed in the first place.
            started.put("micForegroundService", micServiceStarted);
            started.put("micCapability", micCapabilityGranted);
            if (micServiceError != null) {
                started.put("micForegroundServiceError", micServiceError);
            }
            call.resolve(started);
        } catch (Exception exp) {
            mediaRecorder = null;
            RecordingForegroundService.stop(getContext());
            micServiceStarted = false;
            micCapabilityGranted = false;
            releaseAudioFocus();
            JSObject details = new JSObject();
            details.put("exceptionType", exp.getClass().getSimpleName());
            details.put("exceptionMessage", exp.getMessage());
            rejectWithDiagnostics(call, Messages.FAILED_TO_RECORD,
                    "Exception during recording setup: " + exp.getMessage(), details);
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
            JSObject streamingDiagnostics = mediaRecorder.getStreamingDiagnostics();
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
            recordData.setFileSize(recordedFile.length());
            recordData.setStreamingDiagnostics(streamingDiagnostics);

            // Best-effort audio config + actual input (mic) route. Each block is isolated in
            // try/catch: if anything is unreadable the field is simply omitted — never crashes
            // the stop. Values mirror the encoder config set in CustomMediaRecorder.
            try {
                JSObject audioConfig = new JSObject();
                audioConfig.put("sample_rate", 44100);
                audioConfig.put("channels", 1);
                audioConfig.put("bitrate", 96000);
                audioConfig.put("format", "aac");
                recordData.setAudioConfig(audioConfig);
            } catch (Exception ignored) {}
            try {
                // Actual input (mic) route captured by the recorder before release — normalized
                // to the vocabulary shared with iOS (builtin_mic/bluetooth/wired_headset/usb/other).
                String route = mediaRecorder.getInputRoute();
                if (route != null) {
                    recordData.setRoute(route);
                }
            } catch (Exception ignored) {}
            try {
                // Capture path + measured level. A recording whose peak never leaves the floor is
                // the exact signature of the AMA-338 UNPROCESSED regression: correct duration,
                // correct file size, no audio. Reporting it makes that state detectable server-side.
                recordData.setAudioSourceInfo(
                    mediaRecorder.getResolvedAudioSourceName(),
                    mediaRecorder.getRequestedAudioSource(),
                    mediaRecorder.isUnprocessedSupportedOnDevice()
                );
                recordData.setPeakAmplitude(mediaRecorder.getPeakAmplitude(), mediaRecorder.isSilent());
                // The continuous measurement behind that flag, plus whether the microphone
                // foreground service was actually holding the capability. Together these answer
                // "did this recording hear anything, and if not, why" from the log alone.
                recordData.setCaptureStats(
                    mediaRecorder.getCaptureRatio(),
                    mediaRecorder.getMutedRatio(),
                    mediaRecorder.getLongestMutedMs(),
                    mediaRecorder.getCaptureSamples(),
                    mediaRecorder.getSilenceReason()
                );
                recordData.setMicForegroundService(micServiceStarted, micCapabilityGranted, micServiceError);
            } catch (Exception ignored) {}

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
            // Release the microphone capability with the recorder. Leaving the service up would
            // keep an "app is recording" notification and the mic indicator on screen for a
            // recording that no longer exists.
            RecordingForegroundService.stop(getContext());
            micServiceStarted = false;
            micCapabilityGranted = false;
            micServiceError = null;
            releaseAudioFocus();

            // If we were interrupted, mark that we stopped due to interruption
            if (isInterrupted) {
                wasInterruptedAndStopped = true;
            }
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
            // Use AUDIOFOCUS_GAIN_TRANSIENT instead of EXCLUSIVE
            // This allows other apps to play audio in background while we record
            audioFocusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setOnAudioFocusChangeListener(audioFocusChangeListener)
                .build();
            audioManager.requestAudioFocus(audioFocusRequest);
        } else {
            // Use AUDIOFOCUS_GAIN_TRANSIENT instead of EXCLUSIVE
            // This allows other apps to play audio in background while we record
            audioManager.requestAudioFocus(
                audioFocusChangeListener,
                AudioManager.STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
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
        if (mediaRecorder == null) {
            return;
        }

        AudioManager audioManager = (AudioManager) getContext().getSystemService(Context.AUDIO_SERVICE);
        if (audioManager == null) {
            return;
        }

        int currentMode = audioManager.getMode();

        // Check if microphone is TRULY blocked by system (phone call, VoIP)
        // not just audio playback in background (video, music)
        boolean microphoneBlockedBySystem = (
            currentMode == AudioManager.MODE_IN_CALL ||           // Phone call
            currentMode == AudioManager.MODE_IN_COMMUNICATION ||  // VoIP (WhatsApp, Zoom)
            currentMode == AudioManager.MODE_RINGTONE            // Incoming call ringing
        );

        android.util.Log.d("VoiceRecorder",
            "Audio focus lost - mode: " + currentMode +
            " (0=NORMAL, 1=RINGTONE, 2=IN_CALL, 3=IN_COMMUNICATION), " +
            "microphone blocked: " + microphoneBlockedBySystem);

        // If mode is NORMAL, it's only background audio (video, music)
        // Microphone is free - continue recording
        if (!microphoneBlockedBySystem) {
            android.util.Log.d("VoiceRecorder", "Audio focus lost but microphone is free - continuing recording in background");
            return;
        }

        // Microphone is blocked by system - stop recording
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

        // Notify JavaScript layer about the microphone being blocked
        JSObject interruptionData = new JSObject();
        JSObject data = new JSObject();
        data.put("reason", getModeReason(currentMode));
        data.put("audioMode", currentMode);
        data.put("timestamp", java.time.Instant.now().toString());
        interruptionData.put("data", data);

        android.util.Log.d("VoiceRecorder", "Sending recordingInterrupted - microphone blocked by: " + getModeReason(currentMode));
        notifyListeners("recordingInterrupted", interruptionData);
    }

    private void handleAudioFocusGain() {
        android.util.Log.d("VoiceRecorder", "handleAudioFocusGain called - isInterrupted: " + isInterrupted + ", mediaRecorder: " + (mediaRecorder != null));

        // Handle recording resumption if we have an interrupted recording
        // Note: mediaRecorder might be null if recording was stopped after interruption
        if (isInterrupted || wasInterruptedAndStopped) {
            // Notify JavaScript layer that interruption ended
            JSObject interruptionEndedData = new JSObject();
            interruptionEndedData.put("canResume", true);

            android.util.Log.d("VoiceRecorder", "Sending interruptionEnded event to JavaScript");
            notifyListeners("interruptionEnded", interruptionEndedData);

            // Reset interruption state
            isInterrupted = false;
            wasInterruptedAndStopped = false;
        }
    }

    private String getModeReason(int audioMode) {
        switch (audioMode) {
            case AudioManager.MODE_IN_CALL:
                return "phone_call";
            case AudioManager.MODE_IN_COMMUNICATION:
                return "voip_call";
            case AudioManager.MODE_RINGTONE:
                return "incoming_call";
            default:
                return "unknown";
        }
    }

    @Override
    public void load() {
        super.load();
        setupGlobalAudioFocusListener();
    }

    @Override
    public void handleOnDestroy() {
        // Release any active recording when the Activity/Bridge is destroyed. The OS process can
        // outlive the Activity (Android keeps it warm; a "close + reopen" recreates the Activity ->
        // handleOnDestroy() then load() on the SAME process). Without this, the old plugin instance's
        // MediaRecorder keeps capturing and holding the microphone, while the freshly loaded instance
        // has mediaRecorder=null and can never reach it again (getCurrentStatus()=NONE, stopRecording()
        // rejects on null) -> orphaned native recorder, the OS mic indicator stays on forever. There
        // is no JS owner for a recording whose Bridge was destroyed, so stopping it here is correct.
        if (mediaRecorder != null) {
            try {
                mediaRecorder.stopRecording();
            } catch (Exception ignored) {
                // stopRecording() already guarantees release() in its finally; swallow any stop error.
            }
            mediaRecorder = null;
        }
        // Unconditional: the service outlives the Bridge unless something stops it, and an
        // orphaned foreground service holds the microphone for a recording nobody owns.
        RecordingForegroundService.stop(getContext());
        micServiceStarted = false;
        micCapabilityGranted = false;
        micServiceError = null;
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
                        // Check if we have an interrupted recording that needs to be notified
                        if (isInterrupted || wasInterruptedAndStopped) {
                            android.util.Log.d("VoiceRecorder", "Global listener detected AUDIOFOCUS_GAIN with interrupted recording");
                            
                            // Notify JavaScript layer that interruption ended
                            JSObject interruptionEndedData = new JSObject();
                            interruptionEndedData.put("canResume", true);

                            android.util.Log.d("VoiceRecorder", "Global - Sending interruptionEnded event to JavaScript");
                            notifyListeners("interruptionEnded", interruptionEndedData);

                            isInterrupted = false;
                            wasInterruptedAndStopped = false;
                        }
                        
                        // Only send availability event if microphone was unavailable and we're not the cause
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

    // Enhanced error reporting method
    private void rejectWithDiagnostics(PluginCall call, String baseMessage, String reason, JSObject details) {
        AudioManager audioManager = (AudioManager) getContext().getSystemService(Context.AUDIO_SERVICE);

        JSObject diagnosticInfo = new JSObject();
        diagnosticInfo.put("baseError", baseMessage);
        diagnosticInfo.put("reason", reason);
        diagnosticInfo.put("timestamp", java.time.Instant.now().toString());
        diagnosticInfo.put("platform", "android");
        diagnosticInfo.put("hasPermission", doesUserGaveAudioRecordingPermission());
        diagnosticInfo.put("canCreateMediaRecorder", CustomMediaRecorder.canPhoneCreateMediaRecorder(getContext()));

        if (audioManager != null) {
            diagnosticInfo.put("audioMode", audioManager.getMode());
            diagnosticInfo.put("isMicrophoneOccupied", isMicrophoneOccupied());
        }

        if (details != null) {
            diagnosticInfo.put("details", details);
        }

        String fullMessage = baseMessage + ": " + reason;
        call.reject(fullMessage, fullMessage, null, diagnosticInfo);
    }
}
