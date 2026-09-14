package com.tchvu3.capacitorvoicerecorder;

import android.app.ActivityManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import androidx.core.app.NotificationCompat;
import androidx.core.app.ServiceCompat;
import androidx.core.content.ContextCompat;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Keeps the microphone alive while the app is not the visible app on screen.
 *
 * RECORD_AUDIO is a *while-in-use* permission. From Android 11 the platform grants the microphone
 * capability to a process only while it has a visible activity, or while it runs a foreground
 * service declared with `foregroundServiceType="microphone"`. Without such a service the app does
 * not get an error when it leaves the screen — MediaRecorder keeps running and the audio HAL hands
 * it digital zeros. The result is a file with the right duration, the right size, the right
 * bitrate and no sound in it, which is exactly what AMA-393 was: 4h28m of which 99.7% was silence,
 * matching the app's own off-screen window to the second.
 *
 * This service is therefore not observability and not an optimisation — it is the only mechanism
 * the platform offers for the thing the recording feature exists to do. It carries no logic of its
 * own: it starts, shows the mandatory notification, and lives exactly as long as the recording.
 *
 * Fail-open: {@link #start(Context)} returns a reason string instead of throwing, and the caller
 * records anyway. A recording that captures only while the app is on screen is bad; refusing to
 * record at all because a notification channel could not be created is worse.
 */
public class RecordingForegroundService extends Service {

    private static final String TAG = "RecordingFgService";
    private static final String CHANNEL_ID = "voice_recorder_capture";
    private static final int NOTIFICATION_ID = 8213;

    /**
     * How long {@link #start(Context)} waits for the service to reach startForeground(). The call
     * itself is asynchronous, and the capability is only granted once the service is actually in
     * the foreground, so the caller must not open the microphone before that.
     */
    private static final long START_TIMEOUT_MS = 3000L;

    private static volatile CountDownLatch startLatch;
    private static volatile boolean foregroundActive;
    private static volatile String lastError;

    /**
     * Starts the service and blocks until it is in the foreground.
     *
     * @return null when the service is up, otherwise a short reason token for the diagnostics.
     */
    static String start(Context context) {
        if (foregroundActive) {
            return null;
        }
        CountDownLatch latch = new CountDownLatch(1);
        startLatch = latch;
        lastError = null;
        try {
            ContextCompat.startForegroundService(context, new Intent(context, RecordingForegroundService.class));
        } catch (Exception e) {
            // The start refused outright. API 31+ can throw
            // ForegroundServiceStartNotAllowedException here for a start from the background.
            // Manual and promoter recordings start on screen and do not get here; an AUTOMATIC
            // start (proximity, presentation) off screen can. From Android 14 (API 34) a
            // `microphone` service started from the background is refused with SecurityException
            // (measured on Android 16). Service#startForeground is where that one is documented,
            // so it may reach start() through onStartCommand's catch and lastError instead; either
            // way start() returns the class name and it is reported as
            // mic_foreground_service_error. It must not cost the recording.
            startLatch = null;
            lastError = e.getClass().getSimpleName();
            android.util.Log.w(TAG, "startForegroundService refused: " + e.getMessage());
            return lastError;
        }
        try {
            if (!latch.await(START_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                android.util.Log.w(TAG, "service did not reach startForeground within " + START_TIMEOUT_MS + "ms");
                return "start_timeout";
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return "interrupted";
        }
        if (foregroundActive) {
            return null;
        }
        return lastError != null ? lastError : "not_foreground";
    }

    /**
     * Whether the app is visible right now — which decides whether the service will get the
     * microphone at all.
     *
     * A foreground service of type `microphone` inherits the while-in-use capability only when it
     * is started while the app is in the foreground. Up to Android 13, started from the background
     * it comes up perfectly happily, logs nothing, and the process capability mask stays without
     * `M`: measured on Android 12L (API 32), `L--N` before and after. So `started == true` is not
     * the same claim as "this recording can hear anything", and reporting only the former would put
     * a reassuring `true` in the log for precisely the recordings that come back silent.
     *
     * From Android 14 (API 34) the start from the background is refused outright with
     * SecurityException — measured on Android 16 — so there `started` is false as well, and the
     * class name is reported as `mic_foreground_service_error`.
     *
     * Either way that is the state of an AUTOMATIC start — proximity or presentation — that fires
     * while the rep has the tablet in a bag. The manual and promoter starts this ticket is about all
     * happen on screen, and those do get the capability.
     */
    static boolean isAppVisible(Context context) {
        try {
            ActivityManager.RunningAppProcessInfo info = new ActivityManager.RunningAppProcessInfo();
            ActivityManager.getMyMemoryState(info);
            return info.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND;
        } catch (Exception e) {
            // Unknown reads as "visible": the alternative is crying wolf on every recording.
            return true;
        }
    }

    static void stop(Context context) {
        try {
            context.stopService(new Intent(context, RecordingForegroundService.class));
        } catch (Exception e) {
            android.util.Log.w(TAG, "stopService failed: " + e.getMessage());
        }
        foregroundActive = false;
    }

    /** Whether the microphone capability is currently held by this service. */
    static boolean isRunning() {
        return foregroundActive;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        try {
            createChannel();
            int type = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
                ? ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                : 0;
            ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(), type);
            foregroundActive = true;
            android.util.Log.d(TAG, "microphone foreground service active");
        } catch (Exception e) {
            // Missing FOREGROUND_SERVICE_MICROPHONE, a revoked RECORD_AUDIO at this instant, an OEM
            // notification restriction, or — from Android 14 — a `microphone` service started from
            // the background, which this call is documented to refuse with SecurityException (the
            // refusal was measured on Android 16). Report it and get out of the way — the caller
            // keeps recording and the reason travels to person_app_logs in the stop diagnostics.
            foregroundActive = false;
            lastError = e.getClass().getSimpleName();
            android.util.Log.e(TAG, "startForeground failed: " + e.getMessage());
            stopSelf();
        } finally {
            CountDownLatch latch = startLatch;
            startLatch = null;
            if (latch != null) {
                latch.countDown();
            }
        }
        // Never resurrect on our own: a recording without the plugin instance that owns it has no
        // way to be stopped or saved, and would hold the microphone indefinitely.
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        foregroundActive = false;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }
        NotificationManager manager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager == null || manager.getNotificationChannel(CHANNEL_ID) != null) {
            return;
        }
        NotificationChannel channel = new NotificationChannel(
            CHANNEL_ID,
            "Audio recording",
            NotificationManager.IMPORTANCE_LOW
        );
        channel.setDescription("Shown while the app is recording audio.");
        channel.setShowBadge(false);
        channel.setSound(null, null);
        channel.enableVibration(false);
        manager.createNotificationChannel(channel);
    }

    private Notification buildNotification() {
        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Recording in progress")
            .setContentText("Audio is being recorded.")
            // A framework drawable: the plugin ships no resources, and a missing icon makes
            // startForeground throw.
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE);

        PendingIntent launch = launchIntent();
        if (launch != null) {
            builder.setContentIntent(launch);
        }
        return builder.build();
    }

    /** Tapping the notification returns to the app. Best-effort: no launcher intent, no tap. */
    private PendingIntent launchIntent() {
        try {
            Intent intent = getPackageManager().getLaunchIntentForPackage(getPackageName());
            if (intent == null) {
                return null;
            }
            intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                flags |= PendingIntent.FLAG_IMMUTABLE;
            }
            return PendingIntent.getActivity(this, 0, intent, flags);
        } catch (Exception e) {
            return null;
        }
    }
}
