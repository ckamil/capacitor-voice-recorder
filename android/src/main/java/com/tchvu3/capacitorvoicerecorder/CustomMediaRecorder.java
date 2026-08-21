package com.tchvu3.capacitorvoicerecorder;

import android.content.Context;
import android.media.AudioManager;
import android.media.MediaRecorder;
import android.os.Build;
import android.os.Environment;
import com.getcapacitor.JSObject;
import java.io.File;
import java.io.IOException;
import java.util.Locale;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class CustomMediaRecorder {

    private final Context context;
    private final RecordOptions options;
    private MediaRecorder mediaRecorder;
    private File outputFile;
    private CurrentRecordingStatus currentRecordingStatus = CurrentRecordingStatus.NONE;

    // Optional live WebSocket stream — additive, never touches the MediaRecorder file path.
    private AudioStreamSink streamSink;
    private AdtsStreamReader streamReader;
    private AudioStreamSink.EventListener streamEventListener;
    private JSObject streamingDiagnostics;
    private String inputRoute;

    // Which MediaRecorder.AudioSource we actually opened, and what the device says about
    // UNPROCESSED support. Both are surfaced in the stop diagnostics so a silent-capture
    // regression is visible in person_app_logs instead of only in the audio file.
    private int resolvedAudioSource = MediaRecorder.AudioSource.VOICE_RECOGNITION;
    private boolean unprocessedSupported;

    // Peak PCM amplitude (0..32767) seen across the whole recording, sampled off-thread via
    // MediaRecorder.getMaxAmplitude(). -1 means "never sampled" — distinct from 0 ("dead mic").
    private volatile int peakAmplitude = -1;
    private volatile boolean amplitudeMonitorRunning;
    private Thread amplitudeMonitorThread;
    // Guards every MediaRecorder call that can race the monitor thread against stop()/release().
    private final Object recorderLock = new Object();
    private volatile boolean recorderReleased;

    public CustomMediaRecorder(Context context, RecordOptions options) throws IOException {
        android.util.Log.d("CustomMediaRecorder", "Constructor called");
        this.context = context;
        this.options = options;
        generateMediaRecorder();
    }

    private void generateMediaRecorder() throws IOException {
        android.util.Log.d("CustomMediaRecorder", "generateMediaRecorder called");

        try {
            mediaRecorder = new MediaRecorder();
            // AudioSource.UNPROCESSED is OPTIONAL: a device only really provides it when it
            // advertises AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED. On the devices in
            // this fleet that property is "false", and asking for UNPROCESSED anyway hands back a
            // raw, ungained capture path — MediaRecorder then faithfully encodes ~40 dB of nothing
            // at the configured bitrate, so the file size still tracks the duration exactly while
            // the audio holds no speech at all. VOICE_RECOGNITION is mandatory-supported and is
            // likewise specified to run without AGC or noise suppression, so it keeps the reason
            // UNPROCESSED was picked in the first place (no AGC artifacts, speaker audio from
            // presentations not filtered out) while staying on the calibrated mic path.
            unprocessedSupported = isUnprocessedSupported(context);
            resolvedAudioSource = resolveAudioSource(options.getAudioSource(), unprocessedSupported);
            mediaRecorder.setAudioSource(resolvedAudioSource);
            android.util.Log.d(
                "CustomMediaRecorder",
                "Audio source requested=" + options.getAudioSource() +
                " resolved=" + audioSourceName(resolvedAudioSource) +
                " unprocessedSupported=" + unprocessedSupported
            );
            mediaRecorder.setOutputFormat(MediaRecorder.OutputFormat.AAC_ADTS);
            mediaRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
            mediaRecorder.setAudioEncodingBitRate(96000);
            mediaRecorder.setAudioSamplingRate(44100);

            mediaRecorder.setOnErrorListener((mr, what, extra) -> {
                android.util.Log.e("CustomMediaRecorder", "MediaRecorder error: what=" + what + " extra=" + extra);
            });
            mediaRecorder.setOnInfoListener((mr, what, extra) -> {
                android.util.Log.d("CustomMediaRecorder", "MediaRecorder info: what=" + what + " extra=" + extra);
            });

            android.util.Log.d("CustomMediaRecorder", "MediaRecorder configured, setting output file");

            setRecorderOutputFile();

            android.util.Log.d("CustomMediaRecorder", "Output file set, preparing MediaRecorder");

            mediaRecorder.prepare();

            android.util.Log.d("CustomMediaRecorder", "MediaRecorder prepared successfully");

        } catch (IOException e) {
            android.util.Log.e("CustomMediaRecorder", "CANNOT_RECORD - Failed to generate MediaRecorder: " + e.getMessage());
            throw e;
        }
    }

    private void setRecorderOutputFile() throws IOException {
        File outputDir = context.getCacheDir();
        String directory = options.getDirectory();
        String subDirectory = options.getSubDirectory();

        if (directory != null) {
            outputDir = this.getDirectory(directory);
            if (subDirectory != null) {
                Pattern pattern = Pattern.compile("^/?(.+[^/])/?$");
                Matcher matcher = pattern.matcher(subDirectory);
                if (matcher.matches()) {
                    options.setSubDirectory(matcher.group(1));
                    outputDir = new File(outputDir, matcher.group(1));
                    if (!outputDir.exists()) {
                        outputDir.mkdirs();
                    }
                }
            }
        }

        outputFile = File.createTempFile(String.format("recording-%d", System.currentTimeMillis()), ".aac", outputDir);

        if (directory == null) {
            outputFile.deleteOnExit();
        }

        mediaRecorder.setOutputFile(outputFile.getAbsolutePath());
    }

    private File getDirectory(String directory) {
        return switch (directory) {
            case "DOCUMENTS" -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS);
            case "DATA", "LIBRARY" -> context.getFilesDir();
            case "CACHE" -> context.getCacheDir();
            case "EXTERNAL" -> context.getExternalFilesDir(null);
            case "EXTERNAL_STORAGE" -> Environment.getExternalStorageDirectory();
            default -> null;
        };
    }

    public void startRecording() throws IOException {
        android.util.Log.d("CustomMediaRecorder", "startRecording called");

        try {
            mediaRecorder.start();
            currentRecordingStatus = CurrentRecordingStatus.RECORDING;
            android.util.Log.d("CustomMediaRecorder", "Recording started successfully");
            startAmplitudeMonitor();
            startStreamingIfNeeded();
        } catch (Exception e) {
            android.util.Log.e("CustomMediaRecorder", "CANNOT_RECORD - MediaRecorder.start() failed: " + e.getMessage());
            throw e;
        }
    }

    public void stopRecording() {
        // Park the amplitude monitor first: it calls into mediaRecorder, which must not happen
        // once stop()/release() below has run.
        stopAmplitudeMonitor();
        // Capture the active input (mic) route BEFORE stop()/release() — getRoutedDevice()
        // returns null once the recorder is released. Best-effort: any failure leaves the
        // route unset rather than crashing the stop.
        try {
            if (mediaRecorder != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                android.media.AudioDeviceInfo device = mediaRecorder.getRoutedDevice();
                if (device != null) {
                    inputRoute = mapInputRoute(device.getType());
                }
            }
        } catch (Exception ignored) {}
        try {
            synchronized (recorderLock) {
                mediaRecorder.stop();
            }
        } catch (Exception e) {
            // MediaRecorder.stop() throws IllegalStateException for very short or paused/just-resumed
            // recordings (common in the promoter flow: rapid start/stop on form switches, and stop
            // after a focus-loss pause). Swallow it — release() below MUST still run. If it didn't,
            // the native AudioRecord would keep holding the microphone (orphaned recorder, the OS mic
            // indicator stays on), while currentRecordingStatus=NONE makes getCurrentStatus() report
            // NONE so neither JS nor native stopRecording() could ever reach and free it.
            android.util.Log.w("CustomMediaRecorder", "stop() failed, releasing anyway: " + e.getMessage());
        } finally {
            synchronized (recorderLock) {
                try {
                    mediaRecorder.release();
                } catch (Exception ignored) {}
                recorderReleased = true;
            }
            currentRecordingStatus = CurrentRecordingStatus.NONE;
            stopStreaming();
        }
    }

    public String getInputRoute() {
        return inputRoute;
    }

    // Normalizes Android AudioDeviceInfo input types to a vocabulary shared with iOS:
    // builtin_mic / bluetooth / wired_headset / usb / other.
    private static String mapInputRoute(int deviceType) {
        switch (deviceType) {
            case android.media.AudioDeviceInfo.TYPE_BUILTIN_MIC:
                return "builtin_mic";
            case android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO:
            case android.media.AudioDeviceInfo.TYPE_BLE_HEADSET:
                return "bluetooth";
            case android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET:
                return "wired_headset";
            case android.media.AudioDeviceInfo.TYPE_USB_DEVICE:
            case android.media.AudioDeviceInfo.TYPE_USB_HEADSET:
            case android.media.AudioDeviceInfo.TYPE_USB_ACCESSORY:
                return "usb";
            default:
                return "other";
        }
    }

    // ---------------------------------------------------------------------------------------
    // Audio source selection
    //
    // AMA-338 switched the source to UNPROCESSED unconditionally. UNPROCESSED is an OPTIONAL
    // source: when the device does not advertise support for it the audio HAL does not fall back
    // cleanly, it just hands over an ungained raw path. The recording then looks perfectly healthy
    // (right duration, right file size, right bitrate, no errors) and contains no speech. Every
    // Android recording in the fleet between 2026-06-24 and 2026-08-21 came out that way.
    // ---------------------------------------------------------------------------------------

    /** Default peak-amplitude floor (0..32767) under which a recording is flagged as silent. */
    public static final int DEFAULT_SILENCE_THRESHOLD = 200;

    /** How often the amplitude monitor samples the encoder input. */
    private static final long AMPLITUDE_SAMPLE_INTERVAL_MS = 250L;

    /**
     * Maps a requested source token to a MediaRecorder.AudioSource constant.
     *
     * Deliberately pure and free of any Android runtime dependency (the AudioSource constants are
     * compile-time ints, so javac inlines them) — this is the piece unit tests cover.
     *
     * - "auto" (default), "voice_recognition", unknown/null → VOICE_RECOGNITION. Mandatory-supported
     *   and specified to run without AGC/noise suppression, which is what AMA-338 wanted.
     * - "unprocessed" → UNPROCESSED only when the device advertises support, else VOICE_RECOGNITION.
     * - "unprocessed_force" → UNPROCESSED regardless. Escape hatch for on-device diagnosis only.
     * - "mic" → MIC (the pre-AMA-338 source; processed, with AGC).
     * - "voice_communication" → VOICE_COMMUNICATION (AEC-tuned; useful only for call-like capture).
     */
    static int resolveAudioSource(String requested, boolean unprocessedSupported) {
        String pref = requested == null ? "auto" : requested.trim().toLowerCase(Locale.US);
        switch (pref) {
            case "mic":
                return MediaRecorder.AudioSource.MIC;
            case "voice_communication":
                return MediaRecorder.AudioSource.VOICE_COMMUNICATION;
            case "unprocessed_force":
                return MediaRecorder.AudioSource.UNPROCESSED;
            case "unprocessed":
                return unprocessedSupported
                    ? MediaRecorder.AudioSource.UNPROCESSED
                    : MediaRecorder.AudioSource.VOICE_RECOGNITION;
            case "voice_recognition":
            case "auto":
            default:
                return MediaRecorder.AudioSource.VOICE_RECOGNITION;
        }
    }

    /** Diagnostics label for a MediaRecorder.AudioSource constant. */
    static String audioSourceName(int source) {
        switch (source) {
            case MediaRecorder.AudioSource.MIC:
                return "mic";
            case MediaRecorder.AudioSource.VOICE_RECOGNITION:
                return "voice_recognition";
            case MediaRecorder.AudioSource.VOICE_COMMUNICATION:
                return "voice_communication";
            case MediaRecorder.AudioSource.UNPROCESSED:
                return "unprocessed";
            default:
                return "other_" + source;
        }
    }

    /**
     * Whether the device really provides AudioSource.UNPROCESSED. Backed by the framework resource
     * config_supportAudioSourceUnprocessed, which is false on every device in this fleet.
     * Best-effort: an unreadable AudioManager reads as "not supported", the safe direction.
     */
    static boolean isUnprocessedSupported(Context context) {
        try {
            AudioManager audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
            if (audioManager == null) {
                return false;
            }
            return "true".equalsIgnoreCase(audioManager.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED));
        } catch (Exception e) {
            return false;
        }
    }

    public String getResolvedAudioSourceName() {
        return audioSourceName(resolvedAudioSource);
    }

    public String getRequestedAudioSource() {
        String requested = options.getAudioSource();
        return requested == null ? "auto" : requested;
    }

    public boolean isUnprocessedSupportedOnDevice() {
        return unprocessedSupported;
    }

    /** Peak PCM amplitude (0..32767) over the recording; -1 when it was never sampled. */
    public int getPeakAmplitude() {
        return peakAmplitude;
    }

    /**
     * True when the capture never rose above the silence floor. Null-ish state (never sampled)
     * reports false — an unsampled recording is "unknown", not "proven silent".
     */
    public boolean isSilent() {
        return peakAmplitude >= 0 && peakAmplitude < options.getSilenceThreshold();
    }

    // ---------------------------------------------------------------------------------------
    // Amplitude monitor
    //
    // Pure observability: samples MediaRecorder.getMaxAmplitude() (the PCM level going INTO the
    // encoder) and keeps the running peak. It never touches the recording itself, so a failure
    // here can only cost the diagnostic, never the audio. This is the check whose absence let a
    // silent-capture regression run for two months behind passing file-size validation.
    // ---------------------------------------------------------------------------------------

    private void startAmplitudeMonitor() {
        amplitudeMonitorRunning = true;
        amplitudeMonitorThread = new Thread(
            () -> {
                while (amplitudeMonitorRunning) {
                    try {
                        Thread.sleep(AMPLITUDE_SAMPLE_INTERVAL_MS);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                    synchronized (recorderLock) {
                        if (!amplitudeMonitorRunning || recorderReleased || mediaRecorder == null) {
                            return;
                        }
                        try {
                            // getMaxAmplitude() reports the max since the previous call, so this
                            // loop is the only permitted caller.
                            // Starts at -1 ("never sampled"), so the first sample always lands —
                            // including a legitimate 0, which is exactly the dead-mic signal.
                            int amplitude = mediaRecorder.getMaxAmplitude();
                            if (amplitude > peakAmplitude) {
                                peakAmplitude = amplitude;
                            }
                        } catch (Exception e) {
                            // Paused/stopped/released underneath us — stop sampling, keep the peak.
                            return;
                        }
                    }
                }
            },
            "voice-recorder-amplitude"
        );
        amplitudeMonitorThread.setDaemon(true);
        amplitudeMonitorThread.start();
    }

    private void stopAmplitudeMonitor() {
        amplitudeMonitorRunning = false;
        Thread thread = amplitudeMonitorThread;
        amplitudeMonitorThread = null;
        if (thread == null) {
            return;
        }
        try {
            thread.interrupt();
            // Short join so stop() never blocks on the sampler; it is a daemon thread and its loop
            // bails out on the first check, so this is a formality.
            thread.join(500);
        } catch (Exception ignored) {}
    }

    public void setStreamEventListener(AudioStreamSink.EventListener listener) {
        this.streamEventListener = listener;
    }

    public JSObject getStreamingDiagnostics() {
        return streamingDiagnostics;
    }

    private void startStreamingIfNeeded() {
        StreamingConfig sc = options.getStreaming();
        if (sc == null || streamEventListener == null) {
            return;
        }
        try {
            streamingDiagnostics = null;
            streamSink = new AudioStreamSink(context, sc, UUID.randomUUID().toString(), streamEventListener);
            streamReader = new AdtsStreamReader(
                outputFile,
                new AdtsStreamReader.FrameListener() {
                    @Override
                    public void onFrame(long seq, long timestampMs, byte[] adtsFrame) {
                        if (streamSink != null) streamSink.enqueue(seq, timestampMs, adtsFrame);
                    }

                    @Override
                    public void onFormat(int sampleRate, int channels) {
                        if (streamSink != null) streamSink.setFormat(sampleRate, channels);
                    }
                }
            );
            streamSink.start();
            streamReader.start();
        } catch (Exception e) {
            android.util.Log.e("CustomMediaRecorder", "Streaming disabled — failed to start: " + e.getMessage());
            streamSink = null;
            streamReader = null;
        }
    }

    private void stopStreaming() {
        if (streamReader != null) {
            long frames = 0;
            int sampleRate = 44100;
            try {
                streamReader.stopAndFlush();
            } finally {
                frames = streamReader.getFrameCount();
                sampleRate = streamReader.getSampleRate();
                streamReader = null;
            }
            if (streamSink != null) {
                long msDuration = sampleRate > 0 ? (frames * 1024L * 1000L) / sampleRate : 0;
                streamSink.finish(msDuration);
                streamingDiagnostics = streamSink.diagnosticsSnapshot();
                streamSink = null;
            }
        } else if (streamSink != null) {
            streamSink.cancel();
            streamingDiagnostics = streamSink.diagnosticsSnapshot();
            streamSink = null;
        }
    }

    public File getOutputFile() {
        return outputFile;
    }

    public RecordOptions getRecordOptions() {
        return options;
    }

    public boolean pauseRecording() throws NotSupportedOsVersion {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            throw new NotSupportedOsVersion();
        }

        if (currentRecordingStatus == CurrentRecordingStatus.RECORDING) {
            mediaRecorder.pause();
            currentRecordingStatus = CurrentRecordingStatus.PAUSED;
            return true;
        } else {
            return false;
        }
    }

    public boolean resumeRecording() throws NotSupportedOsVersion {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            throw new NotSupportedOsVersion();
        }

        if (currentRecordingStatus == CurrentRecordingStatus.PAUSED) {
            mediaRecorder.resume();
            currentRecordingStatus = CurrentRecordingStatus.RECORDING;
            return true;
        } else {
            return false;
        }
    }

    public CurrentRecordingStatus getCurrentStatus() {
        return currentRecordingStatus;
    }

    public boolean deleteOutputFile() {
        return outputFile.delete();
    }

    public static boolean canPhoneCreateMediaRecorder(Context context) {
        return true;
    }

    private static boolean canPhoneCreateMediaRecorderWhileHavingPermission(Context context) {
        CustomMediaRecorder tempMediaRecorder = null;
        try {
            tempMediaRecorder = new CustomMediaRecorder(context, new RecordOptions(null, null));
            tempMediaRecorder.startRecording();
            tempMediaRecorder.stopRecording();
            return true;
        } catch (Exception exp) {
            return exp.getMessage().startsWith("stop failed");
        } finally {
            if (tempMediaRecorder != null) tempMediaRecorder.deleteOutputFile();
        }
    }
}
