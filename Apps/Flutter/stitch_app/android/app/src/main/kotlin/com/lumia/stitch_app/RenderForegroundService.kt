package com.lumia.stitch_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/** Keeps an actively requested local render foreground-visible and CPU-awake. */
class RenderForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var activeJobIds: ArrayList<String> = arrayListOf()
    private val renewWakeLock = object : Runnable {
        override fun run() {
            if (activeJobIds.isNotEmpty()) {
                acquireWakeLock()
                handler.postDelayed(this, WAKELOCK_RENEW_MS)
            }
        }
    }
    private val handler by lazy { android.os.Handler(mainLooper) }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                activeJobIds = intent.getStringArrayListExtra(EXTRA_JOB_IDS) ?: arrayListOf()
                startForeground(NOTIFICATION_ID, buildNotification())
                acquireWakeLock()
                handler.removeCallbacks(renewWakeLock)
                handler.postDelayed(renewWakeLock, WAKELOCK_RENEW_MS)
                sendBroadcast(
                    Intent(ACTION_READY)
                        .setPackage(packageName)
                        .putExtra(EXTRA_REQUEST_ID, intent.getStringExtra(EXTRA_REQUEST_ID)),
                )
            }
            else -> {
                stopSelf(startId)
                return START_NOT_STICKY
            }
        }
        return START_NOT_STICKY
    }

    private fun buildNotification() = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_render_notification)
        .setContentTitle(getString(R.string.render_notification_title))
        .setContentText(getString(R.string.render_notification_text))
        .setContentIntent(
            PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        )
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setCategory(NotificationCompat.CATEGORY_PROGRESS)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .build()

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.render_notification_channel),
            NotificationManager.IMPORTANCE_LOW,
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun acquireWakeLock() {
        releaseWakeLock()
        val lock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:render")
        lock.setReferenceCounted(false)
        lock.acquire(WAKELOCK_TIMEOUT_MS)
        wakeLock = lock
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        notifyTimeoutAndStop(startId)
    }

    @Suppress("OVERRIDE_DEPRECATION")
    override fun onTimeout(startId: Int) {
        notifyTimeoutAndStop(startId)
    }

    private fun notifyTimeoutAndStop(startId: Int) {
        val preferences = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
        val existing = preferences.getStringSet(PENDING_TIMEOUT_JOBS_KEY, emptySet()).orEmpty()
        val pending = MobilePlatformPolicy.mergePendingTimeoutJobs(existing, activeJobIds)
        // Persist before signaling Dart or ending foreground protection so the intent
        // remains discoverable if the Activity is detached or the process is recreated.
        preferences.edit().putStringSet(PENDING_TIMEOUT_JOBS_KEY, pending).commit()
        sendBroadcast(
            Intent(ACTION_TIMEOUT)
                .setPackage(packageName)
                .putStringArrayListExtra(EXTRA_JOB_IDS, activeJobIds),
        )
        preferences.edit().remove(ACTIVE_JOBS_KEY).apply()
        activeJobIds.clear()
        handler.removeCallbacks(renewWakeLock)
        stopForeground(STOP_FOREGROUND_REMOVE)
        releaseWakeLock()
        stopSelf(startId)
    }

    override fun onDestroy() {
        handler.removeCallbacks(renewWakeLock)
        releaseWakeLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val ACTION_TIMEOUT = "com.lumia.stitch_app.PROCESSING_TIMEOUT"
        const val ACTION_READY = "com.lumia.stitch_app.PROCESSING_READY"
        const val EXTRA_JOB_IDS = "jobIds"
        const val EXTRA_REQUEST_ID = "requestId"
        const val PREFERENCES = "render_service"
        const val ACTIVE_JOBS_KEY = "active_job_ids"
        const val PENDING_TIMEOUT_JOBS_KEY = "pending_timeout_job_ids"
        const val PROCESS_ID_KEY = "process_id"
        private const val ACTION_START = "com.lumia.stitch_app.START_RENDER"
        private const val CHANNEL_ID = "local_render"
        private const val NOTIFICATION_ID = 1001
        private const val WAKELOCK_TIMEOUT_MS = 10L * 60L * 1000L
        private const val WAKELOCK_RENEW_MS = 9L * 60L * 1000L

        fun start(context: android.content.Context, requestId: String, jobIds: ArrayList<String>) {
            val intent = Intent(context, RenderForegroundService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_REQUEST_ID, requestId)
                .putStringArrayListExtra(EXTRA_JOB_IDS, jobIds)
            ContextCompat.startForegroundService(context, intent)
        }
    }
}
