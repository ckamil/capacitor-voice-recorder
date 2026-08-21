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
        toReturn.put("diagnostics", diagnostics);

        return toReturn;
    }
}
