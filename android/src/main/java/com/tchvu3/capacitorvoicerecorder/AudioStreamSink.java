package com.tchvu3.capacitorvoicerecorder;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.Uri;

import com.getcapacitor.JSObject;

import java.util.ArrayDeque;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;

import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;
import okio.ByteString;

/**
 * Best-effort live audio sink over a WebSocket (OkHttp). It NEVER blocks recording and NEVER throws
 * into the recorder: every failure is swallowed, surfaced as an event, and (for transient failures)
 * retried with exponential backoff. The on-disk recording is the source of truth; this is additive.
 *
 * All mutable state is confined to a single-thread executor (mirrors the iOS serial queue). OkHttp
 * listener callbacks and the network callback hop onto it before touching state. OkHttp's built-in
 * pingInterval provides the keepalive / dead-connection detection.
 */
public class AudioStreamSink {

    public interface EventListener {
        void onStreamEvent(JSObject event);
    }

    private final StreamingConfig config;
    private final String recordingId;
    private final EventListener events;
    private final Context appContext;

    private final ScheduledExecutorService exec;
    private final OkHttpClient client;

    private WebSocket webSocket;
    private final ArrayDeque<byte[]> pending = new ArrayDeque<>();
    private int maxBufferedFrames;
    private long maxOutgoingQueueBytes;
    private int sampleRate = 44100;
    private int channels = 1;
    private boolean formatKnown = false;

    private boolean connected = false;
    private boolean finishing = false;
    private boolean closed = false;
    private boolean fatal = false;
    private boolean hasNetwork = true;
    private boolean reportedFinished = false;
    private boolean startSent = false;
    private int reconnectAttempt = 0;
    private long endMsDuration = 0;
    private long lastDropEventAt = 0;
    private ScheduledFuture<?> reconnectFuture;

    private ConnectivityManager connectivityManager;
    private ConnectivityManager.NetworkCallback networkCallback;

    // Diagnostics — volatile so diagnosticsSnapshot() can read them off-thread.
    private volatile long framesSent = 0;
    private volatile long bytesSent = 0;
    private volatile long framesDropped = 0;
    private volatile int reconnects = 0;
    private volatile String lastError = null;
    private volatile String finalState = "init";

    public AudioStreamSink(Context context, StreamingConfig config, String recordingId, EventListener events) {
        this.appContext = context.getApplicationContext();
        this.config = config;
        this.recordingId = recordingId;
        this.events = events;
        this.maxBufferedFrames = clampFrames((int) Math.round(Math.max(1, config.maxBufferSeconds) * 47));
        this.maxOutgoingQueueBytes = outgoingQueueBytes(this.maxBufferedFrames);

        ThreadFactory factory = r -> {
            Thread t = new Thread(r, "vr-stream-sink");
            t.setDaemon(true);
            return t;
        };
        this.exec = Executors.newSingleThreadScheduledExecutor(factory);

        OkHttpClient.Builder builder = new OkHttpClient.Builder();
        if (config.pingIntervalMs > 0) {
            builder.pingInterval(config.pingIntervalMs, TimeUnit.MILLISECONDS);
        }
        this.client = builder.build();
    }

    // ----- Public API (called from the recorder) -----

    public void start() {
        post(() -> {
            if (closed) return;
            registerNetworkCallback();
            emit("connecting", null);
            connect();
        });
    }

    /** Called by the reader once it knows the real format from the first ADTS frame. */
    public void setFormat(int sampleRate, int channels) {
        post(() -> {
            if (formatKnown) return;
            this.sampleRate = sampleRate > 0 ? sampleRate : 44100;
            this.channels = channels > 0 ? channels : 1;
            this.formatKnown = true;
            this.maxBufferedFrames = clampFrames((int) Math.round(Math.max(1, config.maxBufferSeconds) * (this.sampleRate / 1024.0)));
            this.maxOutgoingQueueBytes = outgoingQueueBytes(this.maxBufferedFrames);
            if (connected && webSocket != null && !startSent) {
                sendStart();
                pump();
            }
        });
    }

    public void enqueue(long seq, long timestampMs, byte[] adtsFrame) {
        final byte[] payload = frame(seq, timestampMs, adtsFrame);
        post(() -> {
            if (closed || finishing || fatal) return;
            if (pending.size() >= maxBufferedFrames) {
                pending.pollFirst();
                framesDropped++;
                noteDropThrottled();
            }
            pending.offerLast(payload);
            pump();
        });
    }

    public void finish(long msDuration) {
        post(() -> {
            if (closed) return;
            finishing = true;
            endMsDuration = msDuration;
            finalState = "finished";
            drainThenEnd(System.currentTimeMillis() + 3000);
        });
    }

    public void cancel() {
        post(() -> {
            if (closed) return;
            finalState = "cancelled";
            teardown(false, 1001, "going away");
        });
    }

    public JSObject diagnosticsSnapshot() {
        JSObject d = new JSObject();
        d.put("enabled", true);
        d.put("finalState", finalState);
        d.put("framesSent", framesSent);
        d.put("framesDropped", framesDropped);
        d.put("bytesSent", bytesSent);
        d.put("reconnects", reconnects);
        if (lastError != null) {
            d.put("lastError", lastError);
        }
        return d;
    }

    // ----- Connection (all on exec) -----

    private void connect() {
        if (closed || finishing || fatal) return;

        if (config.requireReachability && !hasNetwork) {
            finalState = "waiting_network";
            return;
        }

        Request.Builder rb = new Request.Builder().url(config.url);
        if (config.token != null) {
            rb.addHeader("Authorization", "Bearer " + config.token);
        }
        if (config.headers != null) {
            for (Map.Entry<String, String> e : config.headers.entrySet()) {
                rb.addHeader(e.getKey(), e.getValue());
            }
        }
        webSocket = client.newWebSocket(rb.build(), new Listener(this));
    }

    private void markConnected(WebSocket ws) {
        if (ws != webSocket || closed || finishing || fatal) return;
        connected = true;
        if (reconnectAttempt > 0) {
            reconnects++;
        }
        reconnectAttempt = 0;
        finalState = "connected";
        emit("connected", null);
        // Only declare `start` once the real ADTS format is known (parsed from the first frame),
        // so the server never gets a wrong-then-duplicate format. setFormat() sends it otherwise.
        if (formatKnown) {
            sendStart();
            pump();
        }
    }

    private void sendStart() {
        if (webSocket == null) return;
        JSObject start = new JSObject();
        start.put("type", "start");
        start.put("recordingId", recordingId);
        start.put("codec", "aac_adts");
        start.put("profile", "aac_lc");
        start.put("sampleRate", sampleRate);
        start.put("channels", channels);
        start.put("framesPerPacket", 1024);
        JSObject frameHeader = new JSObject();
        frameHeader.put("seqBytes", 4);
        frameHeader.put("timestampMsBytes", 4);
        frameHeader.put("endian", "big");
        start.put("frameHeader", frameHeader);
        start.put("startedAt", java.time.Instant.now().toString());
        // Android always streams by tailing the on-disk ADTS file; the iOS-only encodeMode option
        // does not apply, so report the effective mode for parity in the server-side meta.
        start.put("encodeMode", "file_tail");
        if (config.config != null) {
            start.put("config", config.config);
        }
        webSocket.send(start.toString());
        startSent = true;
    }

    private void handleInbound(String text) {
        try {
            org.json.JSONObject obj = new org.json.JSONObject(text);
            String type = obj.optString("type", null);
            if ("error".equals(type) || "close".equals(type)) {
                String reason = obj.optString("reason", type);
                handleFatal("server_" + reason, null);
            }
        } catch (Exception ignored) {}
    }

    private void pump() {
        if (!connected || finishing || closed || fatal || webSocket == null || !startSent) return;
        while (!pending.isEmpty()) {
            // OkHttp.send() returns true once a message is queued in its OWN (large) outgoing
            // buffer, not when it hits the wire. On a slow-but-alive link that buffer could grow
            // past our maxBufferSeconds bound, so stop handing it frames once its queue is full —
            // frames then stay in our bounded deque (drop-oldest), preserving the memory bound.
            if (webSocket.queueSize() > maxOutgoingQueueBytes) {
                break;
            }
            byte[] payload = pending.peekFirst();
            if (!webSocket.send(ByteString.of(payload))) {
                break; // socket closing — will reconnect
            }
            pending.pollFirst();
            framesSent++;
            bytesSent += payload.length;
        }
    }

    // ----- Failure handling (on exec) -----

    private void handleDisconnect(WebSocket ws, String reason, boolean isFatal, Integer httpCode, Throwable t) {
        if (ws != webSocket || closed || finishing) return;

        boolean wasConnected = connected;
        connected = false;
        startSent = false; // a fresh connection must re-send `start`
        if (webSocket != null) {
            webSocket.cancel();
            webSocket = null;
        }
        lastError = t != null && t.getMessage() != null ? reason + ": " + t.getMessage() : reason;

        JSObject e = new JSObject();
        e.put("type", wasConnected ? "disconnected" : "error");
        if (reason != null) e.put("reason", reason);
        if (httpCode != null) e.put("code", httpCode);
        if (t != null && t.getMessage() != null) e.put("message", t.getMessage());
        emitRaw(e);

        if (isFatal) {
            fatal = true;
            finalState = "fatal";
            emit("error", "server_rejected");
            return;
        }
        scheduleReconnect();
    }

    private void handleFatal(String reason, Integer httpCode) {
        if (closed) return;
        lastError = reason;
        fatal = true;
        connected = false;
        finalState = "fatal";
        JSObject e = new JSObject();
        e.put("type", "error");
        e.put("reason", reason);
        if (httpCode != null) e.put("code", httpCode);
        emitRaw(e);
        teardown(true, 1000, "fatal");
    }

    private void scheduleReconnect() {
        if (closed || finishing || fatal) return;

        if (config.reconnectMaxAttempts > 0 && reconnectAttempt >= config.reconnectMaxAttempts) {
            fatal = true;
            finalState = "fatal";
            JSObject e = new JSObject();
            e.put("type", "error");
            e.put("reason", "max_attempts");
            e.put("attempt", reconnectAttempt);
            emitRaw(e);
            return;
        }
        if (config.requireReachability && !hasNetwork) {
            finalState = "waiting_network";
            return;
        }

        reconnectAttempt++;
        double backoff = Math.min(config.reconnectMaxDelayMs, config.reconnectInitialDelayMs * Math.pow(2, reconnectAttempt - 1));
        finalState = "reconnecting";
        JSObject e = new JSObject();
        e.put("type", "reconnecting");
        e.put("attempt", reconnectAttempt);
        e.put("backoffMs", (int) backoff);
        emitRaw(e);
        reconnectFuture = schedule(() -> {
            if (!closed && !finishing && !fatal) connect();
        }, (long) backoff);
    }

    private void onNetwork(boolean up) {
        boolean cameBack = up && !hasNetwork;
        hasNetwork = up;
        if (closed || finishing || fatal) return;

        if (cameBack) {
            reconnectAttempt = 0;
            if (!connected) {
                JSObject e = new JSObject();
                e.put("type", "reconnecting");
                e.put("attempt", 0);
                e.put("reason", "network_restored");
                e.put("backoffMs", 0);
                emitRaw(e);
                connect();
            }
        } else if (!up && (connected || webSocket != null)) {
            handleDisconnect(webSocket, "no_network", false, null, null);
        }
    }

    // ----- Finish / teardown (on exec) -----

    private void drainThenEnd(long deadlineMs) {
        while (connected && webSocket != null && startSent && !pending.isEmpty() && System.currentTimeMillis() <= deadlineMs) {
            byte[] payload = pending.peekFirst();
            if (!webSocket.send(ByteString.of(payload))) {
                break;
            }
            pending.pollFirst();
            framesSent++;
            bytesSent += payload.length;
        }
        sendEndAndClose();
    }

    private void sendEndAndClose() {
        if (closed) return;
        reportFinished();
        if (connected && webSocket != null) {
            JSObject end = new JSObject();
            end.put("type", "end");
            end.put("recordingId", recordingId);
            end.put("framesSent", framesSent);
            end.put("msDuration", endMsDuration);
            end.put("reason", "user_stop");
            webSocket.send(end.toString());
        }
        teardown(true, 1000, "done");
    }

    private void reportFinished() {
        if (reportedFinished) return;
        reportedFinished = true;
        finalState = "finished";
        JSObject e = new JSObject();
        e.put("type", "finished");
        e.put("framesSent", framesSent);
        e.put("bytesSent", bytesSent);
        e.put("reconnects", reconnects);
        emitRaw(e);
    }

    private void teardown(boolean graceful, int code, String reason) {
        if (closed) return;
        closed = true;
        connected = false;
        if (reconnectFuture != null) {
            reconnectFuture.cancel(false);
            reconnectFuture = null;
        }
        unregisterNetworkCallback();
        if (webSocket != null) {
            if (graceful) {
                webSocket.close(code, reason);
            } else {
                webSocket.cancel();
            }
            webSocket = null;
        }
        pending.clear();
        // Don't force-shutdown the OkHttp client here: a graceful close(1000) still needs to flush
        // the queued `end` + close frames. OkHttp's idle threads/connections self-terminate (~60 s).
        exec.shutdown();
    }

    // ----- Reachability -----

    private void registerNetworkCallback() {
        if (!config.requireReachability) return;
        try {
            connectivityManager = (ConnectivityManager) appContext.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (connectivityManager == null) return;
            networkCallback = new ConnectivityManager.NetworkCallback() {
                @Override
                public void onAvailable(Network network) {
                    post(() -> onNetwork(true));
                }

                @Override
                public void onLost(Network network) {
                    post(() -> onNetwork(false));
                }
            };
            connectivityManager.registerDefaultNetworkCallback(networkCallback);
        } catch (Exception e) {
            // Missing permission or unsupported — proceed without reachability gating.
            networkCallback = null;
            hasNetwork = true;
        }
    }

    private void unregisterNetworkCallback() {
        if (connectivityManager != null && networkCallback != null) {
            try {
                connectivityManager.unregisterNetworkCallback(networkCallback);
            } catch (Exception ignored) {}
        }
        networkCallback = null;
        connectivityManager = null;
    }

    // ----- Helpers -----

    private void post(Runnable r) {
        try {
            exec.execute(r);
        } catch (RejectedExecutionException ignored) {}
    }

    private ScheduledFuture<?> schedule(Runnable r, long delayMs) {
        try {
            return exec.schedule(r, delayMs, TimeUnit.MILLISECONDS);
        } catch (RejectedExecutionException ignored) {
            return null;
        }
    }

    private void noteDropThrottled() {
        long now = System.currentTimeMillis();
        if (now - lastDropEventAt < 1000) return;
        lastDropEventAt = now;
        JSObject e = new JSObject();
        e.put("type", "dropped");
        e.put("droppedFrames", framesDropped);
        emitRaw(e);
    }

    private void emit(String type, String reason) {
        JSObject e = new JSObject();
        e.put("type", type);
        if (reason != null) e.put("reason", reason);
        emitRaw(e);
    }

    private void emitRaw(JSObject e) {
        e.put("timestamp", java.time.Instant.now().toString());
        String host = hostOf(config.url);
        if (host != null) e.put("host", host);
        if (events != null) {
            events.onStreamEvent(e);
        }
    }

    private static String hostOf(String url) {
        try {
            return Uri.parse(url).getHost();
        } catch (Exception e) {
            return null;
        }
    }

    private static byte[] frame(long seq, long timestampMs, byte[] adts) {
        byte[] out = new byte[8 + adts.length];
        out[0] = (byte) (seq >>> 24);
        out[1] = (byte) (seq >>> 16);
        out[2] = (byte) (seq >>> 8);
        out[3] = (byte) seq;
        out[4] = (byte) (timestampMs >>> 24);
        out[5] = (byte) (timestampMs >>> 16);
        out[6] = (byte) (timestampMs >>> 8);
        out[7] = (byte) timestampMs;
        System.arraycopy(adts, 0, out, 8, adts.length);
        return out;
    }

    private static int clampFrames(int n) {
        return Math.min(Math.max(n, 8), 200000);
    }

    /** Cap for OkHttp's own outgoing queue, so a slow link cannot balloon memory past our bound. */
    private static long outgoingQueueBytes(int frames) {
        return Math.max(64L * 1024, (long) frames * 512);
    }

    private static boolean isFatalHttp(int status) {
        if (status == 408 || status == 429) return false;
        return status >= 400 && status <= 499;
    }

    private static boolean isFatalClose(int code) {
        switch (code) {
            case 1000: // normal — server intentionally closed
            case 1002: // protocol error
            case 1003: // unsupported data
            case 1007: // invalid payload
            case 1008: // policy violation
            case 1010: // mandatory extension
                return true;
            default:
                return false;
        }
    }

    // ----- OkHttp listener (callbacks arrive off-thread; hop onto exec) -----

    private static final class Listener extends WebSocketListener {

        private final AudioStreamSink sink;

        Listener(AudioStreamSink sink) {
            this.sink = sink;
        }

        @Override
        public void onOpen(WebSocket ws, Response response) {
            sink.post(() -> sink.markConnected(ws));
        }

        @Override
        public void onMessage(WebSocket ws, String text) {
            sink.post(() -> sink.handleInbound(text));
        }

        @Override
        public void onMessage(WebSocket ws, ByteString bytes) {
            // Binary server→client messages are ignored in v1.
        }

        @Override
        public void onClosing(WebSocket ws, int code, String reason) {
            boolean isFatal = isFatalClose(code);
            sink.post(() -> sink.handleDisconnect(ws, "close_" + code, isFatal, null, null));
        }

        @Override
        public void onClosed(WebSocket ws, int code, String reason) {
            // Handled in onClosing / handleDisconnect.
        }

        @Override
        public void onFailure(WebSocket ws, Throwable t, Response response) {
            final Integer code = response != null ? response.code() : null;
            final boolean isFatal = code != null && isFatalHttp(code);
            final String reason = code != null ? "http_" + code : "transport";
            sink.post(() -> sink.handleDisconnect(ws, reason, isFatal, code, t));
        }
    }
}
