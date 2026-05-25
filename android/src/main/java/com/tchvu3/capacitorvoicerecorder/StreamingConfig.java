package com.tchvu3.capacitorvoicerecorder;

import com.getcapacitor.JSObject;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;

/**
 * Configuration for the optional live audio stream. Parsed from the JS `streaming` option on each
 * startRecording call (so multi-profile apps simply pass a different server per call).
 */
public class StreamingConfig {

    public final String url;
    public final String token;
    public final Map<String, String> headers;
    public final JSObject config;
    public final int reconnectInitialDelayMs;
    public final int reconnectMaxDelayMs;
    public final int reconnectMaxAttempts; // 0 = unlimited
    public final double maxBufferSeconds;
    public final int pingIntervalMs; // 0 = disabled
    public final boolean requireReachability;

    public StreamingConfig(
        String url,
        String token,
        Map<String, String> headers,
        JSObject config,
        int reconnectInitialDelayMs,
        int reconnectMaxDelayMs,
        int reconnectMaxAttempts,
        double maxBufferSeconds,
        int pingIntervalMs,
        boolean requireReachability
    ) {
        this.url = url;
        this.token = token;
        this.headers = headers;
        this.config = config;
        this.reconnectInitialDelayMs = reconnectInitialDelayMs;
        this.reconnectMaxDelayMs = reconnectMaxDelayMs;
        this.reconnectMaxAttempts = reconnectMaxAttempts;
        this.maxBufferSeconds = maxBufferSeconds;
        this.pingIntervalMs = pingIntervalMs;
        this.requireReachability = requireReachability;
    }

    /** Returns null (streaming disabled) when the object is absent or the URL is missing/invalid. */
    public static StreamingConfig fromJSObject(JSObject obj) {
        if (obj == null) {
            return null;
        }
        String url = obj.getString("url");
        if (url == null || url.isEmpty()) {
            return null;
        }

        String token = obj.getString("token");

        Map<String, String> headers = new HashMap<>();
        JSObject rawHeaders = obj.getJSObject("headers");
        if (rawHeaders != null) {
            Iterator<String> keys = rawHeaders.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                String value = rawHeaders.optString(key, null);
                if (value != null) {
                    headers.put(key, value);
                }
            }
        }

        JSObject config = obj.getJSObject("config");

        JSObject reconnect = obj.getJSObject("reconnect");
        // Floor the initial delay at 50ms and keep maxDelay >= initial (parity with iOS), so a tiny
        // misconfigured value cannot turn reconnect into a busy-retry storm.
        int initialDelayMs = Math.max(50, reconnect != null ? reconnect.optInt("initialDelayMs", 1000) : 1000);
        int maxDelayMs = reconnect != null ? reconnect.optInt("maxDelayMs", 8000) : 8000;
        maxDelayMs = Math.max(initialDelayMs, maxDelayMs);
        int maxAttempts = reconnect != null ? reconnect.optInt("maxAttempts", 0) : 0;

        double maxBufferSeconds = obj.optDouble("maxBufferSeconds", 10);
        int pingIntervalMs = obj.optInt("pingIntervalMs", 20000);
        boolean requireReachability = obj.optBoolean("requireReachability", true);

        return new StreamingConfig(
            url,
            token,
            headers,
            config,
            initialDelayMs,
            maxDelayMs,
            maxAttempts,
            maxBufferSeconds,
            pingIntervalMs,
            requireReachability
        );
    }
}
