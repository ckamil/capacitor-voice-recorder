package com.tchvu3.capacitorvoicerecorder;

import com.getcapacitor.JSObject;

public class RecordData {

    private String path;
    private String recordDataBase64;
    private String mimeType;
    private int msDuration;

    public RecordData() {}

    public RecordData(String recordDataBase64, int msDuration, String mimeType, String path) {
        this.recordDataBase64 = recordDataBase64;
        this.msDuration = msDuration;
        this.mimeType = mimeType;
        this.path = path;
    }

    public String getRecordDataBase64() {
        return recordDataBase64;
    }

    public void setRecordDataBase64(String recordDataBase64) {
        this.recordDataBase64 = recordDataBase64;
    }

    public int getMsDuration() {
        return msDuration;
    }

    public void setMsDuration(int msDuration) {
        this.msDuration = msDuration;
    }

    public String getMimeType() {
        return mimeType;
    }

    public void setMimeType(String mimeType) {
        this.mimeType = mimeType;
    }

    private long fileSize;
    private JSObject streamingDiagnostics;
    private JSObject audioConfig;
    private String route;
    private String audioSource;
    private String audioSourceRequested;
    private Boolean unprocessedSupported;
    private Integer peakAmplitude;
    private Boolean silent;
    private String silenceReason;
    private Double captureRatio;
    private Double mutedRatio;
    private Long longestMutedMs;
    private Integer captureSamples;
    private JSObject micForegroundService;
    private JSObject audioEnvironment;

    public void setFileSize(long fileSize) {
        this.fileSize = fileSize;
    }

    public void setStreamingDiagnostics(JSObject streamingDiagnostics) {
        this.streamingDiagnostics = streamingDiagnostics;
    }

    public void setAudioConfig(JSObject audioConfig) {
        this.audioConfig = audioConfig;
    }

    public void setRoute(String route) {
        this.route = route;
    }

    /**
     * Capture-path diagnostics: which MediaRecorder.AudioSource was actually opened, which one was
     * asked for, and whether the device advertises UNPROCESSED support. Surfaced so a repeat of the
     * silent-capture regression is visible in recordings.diagnostics, not only in the audio.
     */
    public void setAudioSourceInfo(String resolved, String requested, boolean unprocessedSupported) {
        this.audioSource = resolved;
        this.audioSourceRequested = requested;
        this.unprocessedSupported = unprocessedSupported;
    }

    /** Peak PCM amplitude over the recording (0..32767); pass -1 for "never sampled". */
    public void setPeakAmplitude(int peakAmplitude, boolean silent) {
        if (peakAmplitude >= 0) {
            this.peakAmplitude = peakAmplitude;
            this.silent = silent;
        }
    }

    /**
     * The continuous measurement behind `silent`. A peak alone cannot tell a healthy recording from
     * one that captured 20 seconds and then nothing for four hours — these fields can, and they say
     * which of the two silent-capture shapes it is (`below_threshold` vs `no_capture`).
     *
     * Ratios are -1 when the recording was never sampled; those are dropped rather than reported as
     * zero, because "unknown" and "captured nothing" are different states.
     */
    public void setCaptureStats(double captureRatio, double mutedRatio, long longestMutedMs, int samples, String silenceReason) {
        if (samples > 0) {
            this.captureSamples = samples;
        }
        if (captureRatio >= 0d) {
            this.captureRatio = captureRatio;
        }
        if (mutedRatio >= 0d) {
            this.mutedRatio = mutedRatio;
        }
        if (longestMutedMs >= 0L) {
            this.longestMutedMs = longestMutedMs;
        }
        this.silenceReason = silenceReason;
    }

    /**
     * Whether this recording actually held the microphone while off screen.
     *
     * Two fields rather than one, because they fail apart: `started` says the foreground service
     * came up, `capability` says the platform gave that service the microphone. A service started
     * while the app was in the background reports `started:true, capability:false` — it runs, it
     * logs nothing, and the recording is still digital silence off screen. That is the AMA-393
     * condition, and it belongs in the logs rather than being inferred from the audio months later.
     */
    public void setMicForegroundService(boolean started, boolean capability, String error) {
        JSObject info = new JSObject();
        info.put("started", started);
        // `started` without `capability` is the case worth reading carefully: the service is up,
        // but it was started while the app was in the background, and the platform hands the
        // microphone only to a service started on screen. That recording will be silent off screen
        // however healthy the service looks.
        info.put("capability", capability);
        if (error != null) {
            info.put("error", error);
        }
        this.micForegroundService = info;
    }

    /**
     * Who had the microphone when the recording stopped: the audio mode (a call or VoIP session
     * silences every other capture), whether the platform was feeding this recording silence
     * (Android 10+), and how many recordings the platform listed. Answers "why is this file
     * silent" from the log, where the peak and ratios only say THAT it is.
     */
    public void setAudioEnvironment(JSObject audioEnvironment) {
        this.audioEnvironment = audioEnvironment;
    }

    public JSObject toJSObject() {
        JSObject toReturn = new JSObject();
        toReturn.put("recordDataBase64", recordDataBase64);
        toReturn.put("msDuration", msDuration);
        toReturn.put("mimeType", mimeType);
        toReturn.put("path", path);

        // Add diagnostics matching iOS plugin format
        JSObject diagnostics = new JSObject();
        diagnostics.put("recorderType", "MediaRecorder");
        diagnostics.put("fileSize", fileSize);
        if (streamingDiagnostics != null) {
            diagnostics.put("streaming", streamingDiagnostics);
        }
        // Best-effort extras; only included when populated (see VoiceRecorder stop). Absence here
        // never crashes — toJSObject simply omits the keys.
        if (audioConfig != null) {
            diagnostics.put("audioConfig", audioConfig);
        }
        if (route != null) {
            diagnostics.put("route", route);
        }
        if (audioSource != null) {
            diagnostics.put("audioSource", audioSource);
            diagnostics.put("audioSourceRequested", audioSourceRequested);
            diagnostics.put("unprocessedSupported", unprocessedSupported);
        }
        if (peakAmplitude != null) {
            diagnostics.put("peakAmplitude", (int) peakAmplitude);
            diagnostics.put("silent", (boolean) silent);
        }
        if (captureSamples != null) {
            diagnostics.put("captureSamples", (int) captureSamples);
        }
        if (captureRatio != null) {
            diagnostics.put("captureRatio", (double) captureRatio);
        }
        if (mutedRatio != null) {
            diagnostics.put("mutedRatio", (double) mutedRatio);
        }
        if (longestMutedMs != null) {
            diagnostics.put("longestMutedMs", (long) longestMutedMs);
        }
        if (silenceReason != null) {
            diagnostics.put("silenceReason", silenceReason);
        }
        if (micForegroundService != null) {
            diagnostics.put("micForegroundService", micForegroundService);
        }
        if (audioEnvironment != null) {
            diagnostics.put("audioEnvironment", audioEnvironment);
        }
        toReturn.put("diagnostics", diagnostics);

        return toReturn;
    }
}
