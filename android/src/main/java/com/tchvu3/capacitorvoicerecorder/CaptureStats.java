package com.tchvu3.capacitorvoicerecorder;

/**
 * Running account of what the microphone actually delivered, sampled at a fixed interval for the
 * whole length of a recording.
 *
 * The check this replaces was a single peak over the entire file, and that is how AMA-393 passed
 * for healthy: the reported recording captured ~20 seconds of real audio before the app left the
 * screen, which set the peak to 32754 out of 32767, and the remaining 4 hours 27 minutes of exact
 * zeros never moved it. One loud instant makes any amount of silence invisible to a maximum.
 *
 * Two counters, because there are two different failures with the same symptom:
 *
 * - `muted` — samples of EXACTLY zero. Ambient noise is never exactly zero, so this is the
 *   fingerprint of the platform substituting digital silence for the microphone feed (AMA-393).
 * - `aboveFloor` — samples at or above the silence threshold. An ungained capture path delivers a
 *   non-zero but inaudible signal, so it is invisible to the muted counter and only this one sees
 *   it (AMA-338).
 *
 * Deliberately free of any Android dependency — this is the piece the JVM unit tests cover.
 * Synchronised because the sampler thread writes and the stop path reads.
 */
public final class CaptureStats {

    private final int silenceThreshold;
    private final long sampleIntervalMs;

    private int samples;
    private int aboveFloor;
    private int muted;
    private int longestMutedRun;
    private int currentMutedRun;

    public CaptureStats(int silenceThreshold, long sampleIntervalMs) {
        this.silenceThreshold = Math.max(0, silenceThreshold);
        this.sampleIntervalMs = Math.max(1, sampleIntervalMs);
    }

    /** Feeds one MediaRecorder.getMaxAmplitude() reading (0..32767). */
    public synchronized void add(int amplitude) {
        int value = Math.max(0, amplitude);
        samples++;
        if (value >= silenceThreshold) {
            aboveFloor++;
        }
        if (value == 0) {
            muted++;
            currentMutedRun++;
            if (currentMutedRun > longestMutedRun) {
                longestMutedRun = currentMutedRun;
            }
        } else {
            currentMutedRun = 0;
        }
    }

    public synchronized int getSamples() {
        return samples;
    }

    /**
     * Share of the recording that carried audible signal, 0..1. -1 when nothing was ever sampled,
     * which is "unknown" and must not be confused with "silent".
     */
    public synchronized double getCaptureRatio() {
        return samples == 0 ? -1d : (double) aboveFloor / (double) samples;
    }

    /** Share of the recording where the microphone returned exact zeros, 0..1; -1 when unsampled. */
    public synchronized double getMutedRatio() {
        return samples == 0 ? -1d : (double) muted / (double) samples;
    }

    /** Longest uninterrupted stretch of digital silence, in ms; -1 when unsampled. */
    public synchronized long getLongestMutedMs() {
        return samples == 0 ? -1L : longestMutedRun * sampleIntervalMs;
    }

    /**
     * Why this recording holds no usable audio, or null when it does.
     *
     * @param peakAmplitude peak seen over the whole recording, or -1 when never sampled
     * @param minCaptureRatio share of audible samples below which a recording counts as empty
     */
    public synchronized String getSilenceReason(int peakAmplitude, double minCaptureRatio) {
        if (samples == 0 || peakAmplitude < 0) {
            return null; // never sampled — unknown, not proven silent
        }
        if (peakAmplitude < silenceThreshold) {
            // The level never left the floor anywhere: an ungained or dead capture path.
            return "below_threshold";
        }
        double captured = (double) aboveFloor / (double) samples;
        if (captured < minCaptureRatio) {
            // Real audio exists somewhere, but for almost the whole recording the microphone gave
            // us nothing. This is the AMA-393 shape.
            return "no_capture";
        }
        return null;
    }
}
