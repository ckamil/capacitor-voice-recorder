package com.tchvu3.capacitorvoicerecorder;

import java.io.File;
import java.io.RandomAccessFile;
import java.util.Arrays;

/**
 * Tails the ADTS file that MediaRecorder writes and emits complete ADTS frames. The recorder and its
 * file are left completely untouched (the file is the source of truth); this is an additive reader.
 *
 * MediaRecorder gives no access to PCM or encoded frames, so the live stream is produced by reading
 * the bytes it appends to disk and splitting them on ADTS frame boundaries (self-framing format).
 * Live latency therefore depends on how often MediaRecorder flushes to the file — best-effort.
 */
public class AdtsStreamReader {

    public interface FrameListener {
        void onFrame(long seq, long timestampMs, byte[] adtsFrame);
        void onFormat(int sampleRate, int channels);
    }

    private static final int[] SAMPLE_RATES = {
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350
    };
    private static final int POLL_INTERVAL_MS = 120;
    private static final int MAX_READ_PER_POLL = 1 << 20; // 1 MB

    private final File file;
    private final FrameListener listener;

    private volatile boolean running = false;
    private Thread thread;

    private long readOffset = 0;
    private byte[] carry = new byte[0];
    private long seq = 0;
    private long frameCount = 0;
    private int sampleRate = 44100;
    private boolean formatReported = false;

    public AdtsStreamReader(File file, FrameListener listener) {
        this.file = file;
        this.listener = listener;
    }

    public void start() {
        running = true;
        thread = new Thread(this::loop, "vr-adts-reader");
        thread.setDaemon(true);
        thread.start();
    }

    /** Stop polling and read any final bytes (call after MediaRecorder.stop() has flushed the file). */
    public void stopAndFlush() {
        running = false;
        if (thread != null) {
            thread.interrupt();
            try {
                thread.join(500);
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
            thread = null;
        }
        try {
            readNewBytes();
        } catch (Exception ignored) {}
    }

    public long getFrameCount() {
        return frameCount;
    }

    public int getSampleRate() {
        return sampleRate;
    }

    private void loop() {
        while (running) {
            try {
                readNewBytes();
                Thread.sleep(POLL_INTERVAL_MS);
            } catch (InterruptedException e) {
                break;
            } catch (Exception e) {
                // Best-effort: swallow and keep going. Streaming must never disrupt recording.
            }
        }
    }

    private synchronized void readNewBytes() throws Exception {
        if (!file.exists()) {
            return;
        }
        long length = file.length();
        if (length <= readOffset) {
            return;
        }

        int toRead = (int) Math.min(length - readOffset, MAX_READ_PER_POLL);
        byte[] buf = new byte[toRead];
        RandomAccessFile raf = new RandomAccessFile(file, "r");
        try {
            raf.seek(readOffset);
            raf.readFully(buf);
        } finally {
            raf.close();
        }
        readOffset += toRead;

        byte[] data = concat(carry, buf);
        int consumed = parseFrames(data);
        carry = Arrays.copyOfRange(data, consumed, data.length);
    }

    private int parseFrames(byte[] data) {
        int pos = 0;
        int n = data.length;
        while (pos + 7 <= n) {
            // ADTS syncword (12 bits) + layer == 00.
            if ((data[pos] & 0xFF) != 0xFF || (data[pos + 1] & 0xF6) != 0xF0) {
                pos++; // resync
                continue;
            }
            int frameLen =
                ((data[pos + 3] & 0x03) << 11) | ((data[pos + 4] & 0xFF) << 3) | ((data[pos + 5] & 0xE0) >> 5);
            if (frameLen < 7) {
                pos++;
                continue;
            }
            if (pos + frameLen > n) {
                break; // incomplete frame — wait for more bytes
            }

            if (!formatReported) {
                int srIndex = (data[pos + 2] & 0x3C) >> 2;
                int chCfg = ((data[pos + 2] & 0x01) << 2) | ((data[pos + 3] & 0xC0) >> 6);
                if (srIndex >= 0 && srIndex < SAMPLE_RATES.length) {
                    sampleRate = SAMPLE_RATES[srIndex];
                }
                formatReported = true;
                listener.onFormat(sampleRate, chCfg > 0 ? chCfg : 1);
            }

            byte[] frame = Arrays.copyOfRange(data, pos, pos + frameLen);
            long timestampMs = sampleRate > 0 ? (frameCount * 1024L * 1000L) / sampleRate : 0;
            listener.onFrame(seq, timestampMs, frame);
            seq++;
            frameCount++;
            pos += frameLen;
        }
        return pos;
    }

    private static byte[] concat(byte[] a, byte[] b) {
        if (a.length == 0) {
            return b;
        }
        if (b.length == 0) {
            return a;
        }
        byte[] out = new byte[a.length + b.length];
        System.arraycopy(a, 0, out, 0, a.length);
        System.arraycopy(b, 0, out, a.length, b.length);
        return out;
    }
}
