package com.soronet.pi_droid

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Keeps the process alive while the app is backgrounded so the main isolate's
 * WebSocket to the hub stays connected and settles keep arriving.
 *
 * A native service rather than a Dart-isolate plugin: the hub client lives in
 * the Flutter main isolate, so a service running Dart in a separate isolate
 * could not share its socket. The service does no work itself — it only holds
 * the process in the foreground.
 */
class HubConnectionService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // The 2-arg overload is the one every supported API accepts. On API 34+
        // a typed `startForeground(int, Notification, int)` overload also
        // exists; the manifest declares `specialUse`, and the runtime binding is
        // covered only by an on-device run, never by the manifest test.
        startForeground(FOREGROUND_NOTIFICATION_ID, persistentNotification())
        // START_NOT_STICKY: a restart cannot reconstruct the Dart socket, so it
        // would only leave a zombie notification. Backgrounding with Home keeps
        // the activity and the socket alive; a swipe-away does not (documented
        // accepted limitation).
        return START_NOT_STICKY
    }

    @Suppress("DEPRECATION")
    private fun persistentNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "Connection",
                        NotificationManager.IMPORTANCE_LOW,
                    ),
                )
            }
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("pi")
            .setContentText("Keeping the hub connection open")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .build()
    }

    companion object {
        /** The persistent notification's id; settle notifications start at 1000. */
        const val FOREGROUND_NOTIFICATION_ID = 1
        const val CHANNEL_ID = "pi_connection"
    }
}
