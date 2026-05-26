package com.tchvu3.capacitorvoicerecorder;

import android.content.Context;
import android.media.MediaRecorder;
import android.os.Build;
import android.os.Environment;
import com.getcapacitor.JSObject;
import java.io.File;
import java.io.IOException;
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
            // UNPROCESSED (API 24+) provides raw mic input without any processing:
            // no echo cancellation, no noise suppression, no automatic gain control.
            // This prevents Android from distorting/filtering speaker audio (video playback)
            // and eliminates metallic artifacts from AGC adjustments.
            // Falls back to VOICE_RECOGNITION on older devices.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                mediaRecorder.setAudioSource(MediaRecorder.AudioSource.UNPROCESSED);
            } else {
                mediaRecorder.setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION);
            }
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
            startStreamingIfNeeded();
        } catch (Exception e) {
            android.util.Log.e("CustomMediaRecorder", "CANNOT_RECORD - MediaRecorder.start() failed: " + e.getMessage());
            throw e;
        }
    }

    public void stopRecording() {
        try {
            mediaRecorder.stop();
            mediaRecorder.release();
        } finally {
            currentRecordingStatus = CurrentRecordingStatus.NONE;
            stopStreaming();
        }
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
