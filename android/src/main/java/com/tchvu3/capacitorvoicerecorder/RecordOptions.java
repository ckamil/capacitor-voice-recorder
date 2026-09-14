package com.tchvu3.capacitorvoicerecorder;

public class RecordOptions {

    private String directory;
    private String subDirectory;
    private StreamingConfig streaming;
    private String audioSource;
    private int silenceThreshold = CustomMediaRecorder.DEFAULT_SILENCE_THRESHOLD;
    private double minCaptureRatio = CustomMediaRecorder.DEFAULT_MIN_CAPTURE_RATIO;

    public RecordOptions(String directory, String subDirectory) {
        this.directory = directory;
        this.subDirectory = subDirectory;
    }

    public StreamingConfig getStreaming() {
        return streaming;
    }

    public void setStreaming(StreamingConfig streaming) {
        this.streaming = streaming;
    }

    /**
     * Requested MediaRecorder audio source, as one of the tokens understood by
     * {@link CustomMediaRecorder#resolveAudioSource(String, boolean)}. Null / unknown means "auto".
     */
    public String getAudioSource() {
        return audioSource;
    }

    public void setAudioSource(String audioSource) {
        this.audioSource = audioSource;
    }

    /** Peak PCM amplitude (0..32767) below which a recording is reported as silent in diagnostics. */
    public int getSilenceThreshold() {
        return silenceThreshold;
    }

    public void setSilenceThreshold(int silenceThreshold) {
        if (silenceThreshold >= 0) {
            this.silenceThreshold = silenceThreshold;
        }
    }

    /**
     * Share of the recording (0..1) that must carry audible signal before it counts as real audio.
     * Below it the recording is reported as silent with reason `no_capture` — the shape a recording
     * has when the platform muted the microphone for everything but the moments on screen.
     */
    public double getMinCaptureRatio() {
        return minCaptureRatio;
    }

    public void setMinCaptureRatio(double minCaptureRatio) {
        if (minCaptureRatio >= 0d && minCaptureRatio <= 1d) {
            this.minCaptureRatio = minCaptureRatio;
        }
    }

    public String getDirectory() {
        return directory;
    }

    public String getSubDirectory() {
        return subDirectory;
    }

    public void setSubDirectory(String subDirectory) {
        this.subDirectory = subDirectory;
    }
}
