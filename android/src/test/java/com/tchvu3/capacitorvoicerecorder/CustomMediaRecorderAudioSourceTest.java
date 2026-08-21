package com.tchvu3.capacitorvoicerecorder;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;

import android.media.MediaRecorder;
import org.junit.Test;

/**
 * Regression cover for the AMA-338 silent-capture bug: MediaRecorder was opened with
 * AudioSource.UNPROCESSED on every device, including the ones that do not support it, which
 * yields a file of the right size and duration containing no speech.
 *
 * resolveAudioSource() is deliberately free of Android runtime calls (the AudioSource constants
 * are compile-time ints), so these run as plain JVM tests.
 */
public class CustomMediaRecorderAudioSourceTest {

    @Test
    public void defaultNeverPicksUnprocessed() {
        // The bug in one assertion: with no explicit preference we must not land on UNPROCESSED,
        // whatever the device claims.
        assertEquals(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            CustomMediaRecorder.resolveAudioSource(null, false)
        );
        assertEquals(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            CustomMediaRecorder.resolveAudioSource("auto", false)
        );
        assertEquals(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            CustomMediaRecorder.resolveAudioSource("auto", true)
        );
    }

    @Test
    public void unprocessedIsGatedOnDeviceSupport() {
        // Opt in explicitly and the device backs it — honour the request.
        assertEquals(
            MediaRecorder.AudioSource.UNPROCESSED,
            CustomMediaRecorder.resolveAudioSource("unprocessed", true)
        );
        // Opt in on a device that does not advertise support — fall back rather than capture silence.
        assertEquals(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            CustomMediaRecorder.resolveAudioSource("unprocessed", false)
        );
    }

    @Test
    public void unprocessedForceBypassesTheGate() {
        // On-device diagnosis escape hatch: reproduce the broken path on demand.
        assertEquals(
            MediaRecorder.AudioSource.UNPROCESSED,
            CustomMediaRecorder.resolveAudioSource("unprocessed_force", false)
        );
    }

    @Test
    public void explicitSourcesAreHonoured() {
        assertEquals(MediaRecorder.AudioSource.MIC, CustomMediaRecorder.resolveAudioSource("mic", false));
        assertEquals(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            CustomMediaRecorder.resolveAudioSource("voice_communication", false)
        );
        assertEquals(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            CustomMediaRecorder.resolveAudioSource("voice_recognition", false)
        );
    }

    @Test
    public void tokensAreCaseAndWhitespaceInsensitive() {
        // Values arrive from a hand-edited tenant config; sloppy casing must not silently change
        // the capture path.
        assertEquals(MediaRecorder.AudioSource.MIC, CustomMediaRecorder.resolveAudioSource("  MIC ", false));
        assertEquals(
            MediaRecorder.AudioSource.UNPROCESSED,
            CustomMediaRecorder.resolveAudioSource("Unprocessed", true)
        );
    }

    @Test
    public void unknownTokenFallsBackToTheSafeSource() {
        // A typo in the tenant config must never open UNPROCESSED.
        int resolved = CustomMediaRecorder.resolveAudioSource("unprocesed", true);
        assertEquals(MediaRecorder.AudioSource.VOICE_RECOGNITION, resolved);
        assertNotEquals(MediaRecorder.AudioSource.UNPROCESSED, resolved);
    }

    @Test
    public void sourceNamesAreStableForDiagnostics() {
        assertEquals("mic", CustomMediaRecorder.audioSourceName(MediaRecorder.AudioSource.MIC));
        assertEquals(
            "voice_recognition",
            CustomMediaRecorder.audioSourceName(MediaRecorder.AudioSource.VOICE_RECOGNITION)
        );
        assertEquals("unprocessed", CustomMediaRecorder.audioSourceName(MediaRecorder.AudioSource.UNPROCESSED));
        assertEquals(
            "voice_communication",
            CustomMediaRecorder.audioSourceName(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
        );
    }

    @Test
    public void silenceThresholdDefaultsAndRejectsNegatives() {
        RecordOptions options = new RecordOptions(null, null);
        assertEquals(CustomMediaRecorder.DEFAULT_SILENCE_THRESHOLD, options.getSilenceThreshold());

        options.setSilenceThreshold(500);
        assertEquals(500, options.getSilenceThreshold());

        // A negative value would make isSilent() unreachable — keep the last sane setting.
        options.setSilenceThreshold(-1);
        assertEquals(500, options.getSilenceThreshold());

        // Zero is legitimate: "only a bit-exact dead mic counts as silent".
        options.setSilenceThreshold(0);
        assertEquals(0, options.getSilenceThreshold());
    }

    @Test
    public void audioSourceDefaultsToAutoWhenUnset() {
        RecordOptions options = new RecordOptions(null, null);
        assertEquals(null, options.getAudioSource());
        assertEquals(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            CustomMediaRecorder.resolveAudioSource(options.getAudioSource(), true)
        );
    }
}
