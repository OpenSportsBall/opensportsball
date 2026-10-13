// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

package dev.opensportsball.opensportsball

import android.Manifest
import android.app.Activity
import android.app.ForegroundServiceStartNotAllowedException
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

private const val TAG = "BackgroundUpload"

/** What the notification shows; mirrors `BackgroundStatus` in Dart. */
data class UploadStatus(val title: String, val text: String, val permille: Int, val busy: Boolean) {
    companion object {
        fun from(call: MethodCall) = UploadStatus(
            title = call.argument<String>("title") ?: "Uploading",
            text = call.argument<String>("text") ?: "",
            permille = (call.argument<Number>("permille")?.toInt() ?: 0).coerceIn(0, 1000),
            busy = call.argument<Boolean>("busy") == true,
        )
    }
}

/**
 * `opensportsball/background_upload`: Dart starts, updates and stops
 * [UploadKeepAliveService] (lib/src/upload/background.dart).
 */
class BackgroundUploadChannel(private val context: Context) {
    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "opensportsball/background_upload")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> result.success(start(UploadStatus.from(call)))
                    "update" -> result.success(UploadKeepAliveService.update(UploadStatus.from(call)))
                    "stop" -> {
                        UploadKeepAliveService.stop()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun start(status: UploadStatus): Boolean {
        askForNotifications()
        UploadKeepAliveService.status = status
        if (UploadKeepAliveService.running != null) {
            UploadKeepAliveService.wanted = true
            return UploadKeepAliveService.update(status)
        }
        return try {
            context.startForegroundService(Intent(context, UploadKeepAliveService::class.java))
            UploadKeepAliveService.wanted = true
            true
        } catch (e: Exception) {
            // Android 12+ refuses to start one from the background.
            if (Build.VERSION.SDK_INT >= 31 && e is ForegroundServiceStartNotAllowedException) {
                Log.i(TAG, "not allowed to start from the background")
            } else {
                Log.w(TAG, "start failed", e)
            }
            false
        }
    }

    /** Android 13+: the progress notification is hidden without this. */
    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT < 33 || asked) return
        val a = activity ?: return
        if (a.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        asked = true
        a.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7301)
    }

    companion object {
        /** The activity on screen, for the permission prompt. */
        var activity: Activity? = null
        private var asked = false
    }
}

/**
 * Keeps the process (and the Flutter engine in it) alive while the upload
 * queue has work, with a progress notification. Holds a partial wake lock
 * and a Wi-Fi lock only while bytes are moving.
 */
class UploadKeepAliveService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = this
        val nm = getSystemService(NotificationManager::class.java)
        // Default importance for the status-bar icon (low hides it in the
        // Silent section), but without sound or vibration. A channel's
        // importance can't change, hence the new id.
        nm.deleteNotificationChannel("uploads")
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Uploads", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Progress while recordings upload"
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            }
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val s = status
        val n = notification(s)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
        // Stopped before it got here: startForeground had to be called anyway.
        if (!wanted) {
            shutdown()
            return START_NOT_STICKY
        }
        holdLocks(s.busy)
        // If the system kills the process, the engine (and queue) is gone
        // too; don't restart an empty service. Opening the app resumes.
        return START_NOT_STICKY
    }

    /** Android 15: dataSync services get 6 hours a day. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.i(TAG, "dataSync time limit reached")
        wanted = false
        shutdown()
    }

    override fun onDestroy() {
        holdLocks(false)
        if (running === this) {
            running = null
            wanted = false // stopped by the system, not by Dart
        }
        super.onDestroy()
    }

    private fun shutdown() {
        holdLocks(false)
        stopForeground(STOP_FOREGROUND_REMOVE)
        // A progress update posted just before can land after the removal
        // above (it goes another way); a cancel here is queued behind it.
        getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
        stopSelf()
        if (running === this) running = null
    }

    private fun show(s: UploadStatus) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(s))
        holdLocks(s.busy)
    }

    private fun notification(s: UploadStatus): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(s.title)
            .setContentText(s.text)
            .setProgress(1000, s.permille, false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setContentIntent(open)
            .apply { if (Build.VERSION.SDK_INT >= 31) setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE) }
            .build()
    }

    private fun holdLocks(on: Boolean) {
        if (on) {
            if (wakeLock == null) {
                wakeLock = getSystemService(PowerManager::class.java)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "opensportsball:upload")
                    .apply { setReferenceCounted(false); acquire() }
            }
            if (wifiLock == null) {
                @Suppress("DEPRECATION") // still keeps Wi-Fi out of power save with the screen off
                wifiLock = applicationContext.getSystemService(WifiManager::class.java)
                    .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "opensportsball:upload")
                    .apply { setReferenceCounted(false); acquire() }
            }
        } else {
            wakeLock?.let { if (it.isHeld) it.release() }
            wakeLock = null
            wifiLock?.let { if (it.isHeld) it.release() }
            wifiLock = null
        }
    }

    companion object {
        private const val CHANNEL_ID = "upload_progress"
        private const val NOTIFICATION_ID = 7300

        @Volatile var status = UploadStatus("Uploading", "", 0, true)
        @Volatile var running: UploadKeepAliveService? = null

        /** Started by Dart and not stopped since (it may still be starting). */
        @Volatile var wanted = false

        /** False if the service is no longer wanted (the OS stopped it). */
        fun update(s: UploadStatus): Boolean {
            status = s
            running?.show(s)
            return wanted
        }

        /** A service still starting stops itself in [onStartCommand]. */
        fun stop() {
            wanted = false
            running?.shutdown()
        }
    }
}
