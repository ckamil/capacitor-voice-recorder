package com.tchvu3.capacitorvoicerecorder;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

/**
 * Regression cover for AMA-393: a promoter recording of 4 h 28 min 53 s that held ~20 seconds of
 * audio at the start, ~30 seconds at the end, and exact digital zeros for the 99.7% in between.
 * The recording was stored as healthy because the silence check was a single peak over the whole
 * file, and those 20 seconds set the peak to 32754 out of 32767.
 *
 * The first test below is that recording, reconstructed at the sampler's own resolution. It must
 * come out silent.
 *
 * CaptureStats carries no Android dependency, so these run as plain JVM tests.
 */
public class CaptureStatsTest {

    private static final int THRESHOLD = CustomMediaRecorder.DEFAULT_SILENCE_THRESHOLD;
    private static final double MIN_RATIO = CustomMediaRecorder.DEFAULT_MIN_CAPTURE_RATIO;
    private static final long INTERVAL_MS = 250L;

    /** Speech-level reading, comfortably above the floor. */
    private static final int LOUD = 20000;

    private static CaptureStats stats() {
        return new CaptureStats(THRESHOLD, INTERVAL_MS);
    }

    private static void feed(CaptureStats stats, int amplitude, int samples) {
        for (int i = 0; i < samples; i++) {
            stats.add(amplitude);
        }
    }

    @Test
    public void theReportedRecordingIsSilent() {
        // 4 h 28 min 53 s at one sample per 250 ms, with the mic alive only for the first 20 s and
        // the last 30 s — the app was off screen for everything in between.
        CaptureStats stats = stats();
        feed(stats, 32754, 80); // 20 s on screen
        feed(stats, 0, 64332); // 4 h 28 min 3 s off screen: exact zeros
        feed(stats, 18000, 120); // 30 s back on screen

        assertEquals("no_capture", stats.getSilenceReason(32754, MIN_RATIO));
        assertTrue("captured share must be a sliver", stats.getCaptureRatio() < 0.01d);
        assertTrue("almost everything was digital silence", stats.getMutedRatio() > 0.99d);
        // The gap itself, not just its share — this is what makes the shape readable in the log.
        assertEquals(64332L * INTERVAL_MS, stats.getLongestMutedMs());
    }

    @Test
    public void aPeakAloneNoLongerClearsARecording() {
        // The exact hole this closes: one full-scale instant used to make any amount of silence
        // invisible. The peak is at maximum here and the recording is still silent.
        CaptureStats stats = stats();
        feed(stats, 32767, 1);
        feed(stats, 0, 3599);

        assertEquals("no_capture", stats.getSilenceReason(32767, MIN_RATIO));
    }

    @Test
    public void aNormalRecordingIsNotSilent() {
        // Conversation with ordinary pauses: two thirds of the samples carry signal.
        CaptureStats stats = stats();
        for (int i = 0; i < 3000; i++) {
            stats.add(i % 3 == 0 ? 30 : LOUD);
        }

        assertNull(stats.getSilenceReason(LOUD, MIN_RATIO));
        assertTrue(stats.getCaptureRatio() > 0.6d);
    }

    @Test
    public void aQuietMeetingIsNotFlagged() {
        // The false positive worth caring about: somebody speaks for ~4 minutes in an hour and the
        // room is otherwise near-silent but alive (non-zero). At 2% the recording stays healthy.
        CaptureStats stats = stats();
        feed(stats, LOUD, 1000); // ~4 min of speech
        feed(stats, 40, 13400); // ~56 min of quiet room, above zero and below the floor

        assertNull(stats.getSilenceReason(LOUD, MIN_RATIO));
        assertTrue(stats.getCaptureRatio() > MIN_RATIO);
        assertEquals("a live room never returns exact zeros", 0d, stats.getMutedRatio(), 0.0001d);
    }

    @Test
    public void anUngainedCapturePathIsStillCaught() {
        // AMA-338's shape: the mic is feeding us, but nothing ever leaves the floor. The muted
        // counter cannot see this one — the threshold check is what catches it.
        CaptureStats stats = stats();
        feed(stats, 30, 4000);

        assertEquals("below_threshold", stats.getSilenceReason(30, MIN_RATIO));
        assertEquals(0d, stats.getCaptureRatio(), 0.0001d);
        assertEquals(0d, stats.getMutedRatio(), 0.0001d);
    }

    @Test
    public void aDeadMicIsCaught() {
        // Nothing at all, from the first sample. Both signatures agree.
        CaptureStats stats = stats();
        feed(stats, 0, 4000);

        assertEquals("below_threshold", stats.getSilenceReason(0, MIN_RATIO));
        assertEquals(1d, stats.getMutedRatio(), 0.0001d);
        assertEquals(4000L * INTERVAL_MS, stats.getLongestMutedMs());
    }

    @Test
    public void anUnsampledRecordingIsUnknownNotSilent() {
        // A recording too short for the sampler to run must never be reported as proven silent:
        // there is nothing to prove it with.
        CaptureStats stats = stats();

        assertNull(stats.getSilenceReason(-1, MIN_RATIO));
        assertEquals(0, stats.getSamples());
        assertEquals(-1d, stats.getCaptureRatio(), 0.0001d);
        assertEquals(-1d, stats.getMutedRatio(), 0.0001d);
        assertEquals(-1L, stats.getLongestMutedMs());
    }

    @Test
    public void sampledButPeakNeverReadIsAlsoUnknown() {
        // Defensive: samples exist but the peak was never established. Report unknown rather than
        // guessing, the same direction the rest of the diagnostics take.
        CaptureStats stats = stats();
        feed(stats, 0, 100);

        assertNull(stats.getSilenceReason(-1, MIN_RATIO));
    }

    @Test
    public void longestMutedRunIsTheLongestNotTheLast() {
        CaptureStats stats = stats();
        feed(stats, 0, 40); // 10 s
        feed(stats, LOUD, 4);
        feed(stats, 0, 200); // 50 s — the longest
        feed(stats, LOUD, 4);
        feed(stats, 0, 12); // 3 s

        assertEquals(200L * INTERVAL_MS, stats.getLongestMutedMs());
    }

    @Test
    public void negativeReadingsAreTreatedAsZero() {
        // getMaxAmplitude() is documented as non-negative, but a released recorder has been seen
        // returning junk. Clamp rather than letting it corrupt the ratios.
        CaptureStats stats = stats();
        feed(stats, -5, 10);

        assertEquals(1d, stats.getMutedRatio(), 0.0001d);
        assertEquals(0d, stats.getCaptureRatio(), 0.0001d);
    }

    @Test
    public void thresholdIsInclusive() {
        // A reading exactly at the floor counts as captured, matching isSilent()'s peak comparison
        // (`peak < threshold`), so the two checks cannot disagree about the same value.
        CaptureStats stats = stats();
        feed(stats, THRESHOLD, 100);

        assertEquals(1d, stats.getCaptureRatio(), 0.0001d);
        assertNull(stats.getSilenceReason(THRESHOLD, MIN_RATIO));
    }

    // ---------------------------------------------------------------------------------------------
    // Live alert: the RS tablets that delivered exact zeros for hours with the app on screen, the
    // microphone service running and the permission granted. The stop-time numbers only said so
    // once the recording ended; the live signal says it after ALERT_MS of zeros.
    // ---------------------------------------------------------------------------------------------

    private static final long ALERT_MS = 20000L;
    private static final int ALERT_SAMPLES = (int) (ALERT_MS / INTERVAL_MS);

    private static CaptureStats alerting() {
        return new CaptureStats(THRESHOLD, INTERVAL_MS, ALERT_MS);
    }

    /** Feeds `samples` readings and counts the non-NONE signals they produced. */
    private static int signals(CaptureStats stats, int amplitude, int samples, CaptureStats.LiveSignal wanted) {
        int count = 0;
        for (int i = 0; i < samples; i++) {
            if (stats.add(amplitude) == wanted) {
                count++;
            }
        }
        return count;
    }

    @Test
    public void aLongRunOfZerosIsReportedOnceWhenItReachesTheAlertLength() {
        CaptureStats stats = alerting();
        feed(stats, LOUD, 40);

        assertEquals(0, signals(stats, 0, ALERT_SAMPLES - 1, CaptureStats.LiveSignal.SILENCED));
        assertEquals(CaptureStats.LiveSignal.SILENCED, stats.add(0));
        assertEquals(ALERT_MS, stats.getLastSignalRunMs());
        // An hour more of zeros is the same episode, not another alert.
        assertEquals(0, signals(stats, 0, 4 * 3600, CaptureStats.LiveSignal.SILENCED));
    }

    @Test
    public void signalComingBackEndsTheEpisodeWithItsFullLength() {
        CaptureStats stats = alerting();
        feed(stats, 0, ALERT_SAMPLES + 20);

        assertEquals(CaptureStats.LiveSignal.RESTORED, stats.add(LOUD));
        assertEquals((ALERT_SAMPLES + 20) * INTERVAL_MS, stats.getLastSignalRunMs());
        // Further speech is not another restore.
        assertEquals(0, signals(stats, LOUD, 100, CaptureStats.LiveSignal.RESTORED));
    }

    @Test
    public void aSecondRunIsASecondEpisode() {
        CaptureStats stats = alerting();
        assertEquals(1, signals(stats, 0, ALERT_SAMPLES, CaptureStats.LiveSignal.SILENCED));
        assertEquals(CaptureStats.LiveSignal.RESTORED, stats.add(LOUD));
        assertEquals(1, signals(stats, 0, ALERT_SAMPLES, CaptureStats.LiveSignal.SILENCED));
    }

    @Test
    public void pausesBetweenWordsNeverAlert() {
        // A quiet room is not exact zeros, and a short dropout is shorter than the alert length.
        CaptureStats stats = alerting();
        for (int i = 0; i < 1000; i++) {
            assertEquals(CaptureStats.LiveSignal.NONE, stats.add(i % 50 == 0 ? LOUD : 30));
        }
        assertEquals(0, signals(stats, 0, ALERT_SAMPLES - 1, CaptureStats.LiveSignal.SILENCED));
        assertEquals(CaptureStats.LiveSignal.NONE, stats.add(LOUD));
    }

    @Test
    public void zeroAlertLengthTurnsTheLiveSignalOff() {
        CaptureStats stats = new CaptureStats(THRESHOLD, INTERVAL_MS, 0L);
        assertEquals(0, signals(stats, 0, 10000, CaptureStats.LiveSignal.SILENCED));
        assertEquals(CaptureStats.LiveSignal.NONE, stats.add(LOUD));
        // The stop-time measurement is unaffected.
        assertEquals(10000L * INTERVAL_MS, stats.getLongestMutedMs());
    }

    @Test
    public void theTwoArgumentConstructorKeepsTheOldBehaviour() {
        CaptureStats stats = stats();
        assertEquals(0, signals(stats, 0, 10000, CaptureStats.LiveSignal.SILENCED));
    }

    @Test
    public void anAlertLengthShorterThanOneSampleStillNeedsOneZero() {
        CaptureStats stats = new CaptureStats(THRESHOLD, INTERVAL_MS, 1L);
        assertEquals(CaptureStats.LiveSignal.NONE, stats.add(LOUD));
        assertEquals(CaptureStats.LiveSignal.SILENCED, stats.add(0));
    }
}
