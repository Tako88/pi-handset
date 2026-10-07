package io.github.tako88.pihandset

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the single `pi_handset/notifications` channel the Dart
 * `AndroidNotificationPresenter` talks to: permission request, the foreground
 * service, and showing/cancelling settle notifications.
 *
 * A notification tap launches (or re-delivers to) this activity with the
 * session id in an extra; a cold start exposes it through `getLaunchSession`,
 * a warm one pushes `openSession` back to Dart.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingSessionId: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingSessionId = intent?.getStringExtra(EXTRA_SESSION_ID)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ensureChannels()
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        this.channel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestNotificationPermission" -> result.success(requestNotificationPermission())
                "getLaunchSession" -> {
                    val sessionId = pendingSessionId
                    pendingSessionId = null
                    result.success(sessionId)
                }
                "startForegroundService" -> {
                    val service = Intent(this, HubConnectionService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(service)
                    } else {
                        startService(service)
                    }
                    result.success(null)
                }
                "stopForegroundService" -> {
                    stopService(Intent(this, HubConnectionService::class.java))
                    result.success(null)
                }
                "showNotification" -> {
                    showNotification(
                        call.argument<Int>("id") ?: 0,
                        call.argument<String>("title") ?: "",
                        call.argument<String>("body") ?: "",
                        call.argument<String>("sessionId") ?: "",
                    )
                    result.success(null)
                }
                "cancelNotification" -> {
                    notificationManager().cancel(call.argument<Int>("id") ?: 0)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val sessionId = intent.getStringExtra(EXTRA_SESSION_ID) ?: return
        channel?.invokeMethod("openSession", sessionId)
    }

    /** True when notifications are already permitted (or the API ignores it). */
    private fun requestNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        if (
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        ) {
            return true
        }
        requestPermissions(
            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
        return false
    }

    private fun ensureChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = notificationManager()
        if (manager.getNotificationChannel(SETTLE_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    SETTLE_CHANNEL_ID,
                    "Session activity",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
        }
        if (manager.getNotificationChannel(CONNECTION_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CONNECTION_CHANNEL_ID,
                    "Connection",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun showNotification(id: Int, title: String, body: String, sessionId: String) {
        val tapIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_SESSION_ID, sessionId)
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            id,
            tapIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, SETTLE_CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()
        notificationManager().notify(id, notification)
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    companion object {
        private const val CHANNEL = "pi_handset/notifications"
        private const val SETTLE_CHANNEL_ID = "pi_sessions"
        private const val CONNECTION_CHANNEL_ID = "pi_connection"
        private const val EXTRA_SESSION_ID = "sessionId"
        private const val NOTIFICATION_PERMISSION_REQUEST = 1
    }
}
