package io.github.hyperionhxh.triomi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.IBinder
import android.os.PowerManager
import java.util.Locale

/** A user-started dataSync FGS, not an automatic restart or force-stop guarantee. */
class DownloadForegroundService : Service() {
    private var session: DownloadQueueSession? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var foregroundStarted = false
    internal val wakeLockHeld: Boolean get() = wakeLock?.isHeld == true
    private val connectivityHandler = Handler(Looper.getMainLooper())
    private var connectivityCallback: ConnectivityManager.NetworkCallback? = null
    private var connectivityToken: Long? = null
    private val connectivityWake = Runnable { connectivityToken?.let { dispatchConnectivityWake(it) } }
    internal val connectivityWatching: Boolean get() = connectivityCallback != null

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "下载队列", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "下载章节、进度与暂停操作"
                    setShowBadge(false)
                },
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val lease = DownloadQueueRuntime.current
        val token = intent?.getLongExtra(EXTRA_TOKEN, -1) ?: -1
        if (lease == null || token != lease.token) {
            // A late stop action must never stop a new generation's queue.
            if (session == null && lease == null) stopSelf(startId)
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_PAUSE) {
            DownloadQueueRuntime.pause(lease, "notification")
            if (session == null) stopSelf(startId)
            return START_NOT_STICKY
        }
        if (intent?.action != ACTION_START || (session != null && session !== lease)) {
            return START_NOT_STICKY
        }
        if (foregroundStarted) return START_NOT_STICKY
        session = lease
        lease.service = this
        try {
            ensureNotificationChannel()
            val notification = notification("Triomi 下载", "", "准备下载", null, 0.0)
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else startForeground(NOTIFICATION_ID, notification)
            foregroundStarted = true
            acquireWakeLock()
            watchConnectivity(lease.token)
            lease.ready(true)
        } catch (_: RuntimeException) {
            // Includes permission/type errors and FGS-start restrictions. Complete
            // the awaiting MethodChannel call while tearing down the service.
            DownloadQueueRuntime.end(lease)
            lease.ready(false)
        }
        return START_NOT_STICKY
    }

    fun update(title: String, chapter: String, status: String, progress: Double?, speed: Double): Boolean {
        if (!foregroundStarted || session !== DownloadQueueRuntime.current) return false
        return try {
            getSystemService(NotificationManager::class.java).notify(
                NOTIFICATION_ID, notification(title, chapter, status, progress, speed),
            )
            true
        } catch (_: RuntimeException) {
            session?.let { DownloadQueueRuntime.pause(it, "notification_failed") }
            false
        }
    }

    /** Idle/backoff retains the FGS, but only actual work holds the CPU awake. */
    internal fun setQueueActive(token: Long, active: Boolean): Boolean {
        val lease = session ?: return false
        if (!foregroundStarted || lease !== DownloadQueueRuntime.current || token != lease.token) return false
        return try {
            if (active) acquireWakeLock() else releaseWakeLock()
            true
        } catch (_: RuntimeException) {
            DownloadQueueRuntime.pause(lease, "wake_lock_failed")
            false
        }
    }

    private fun watchConnectivity(token: Long) {
        val manager = getSystemService(ConnectivityManager::class.java)
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = scheduleConnectivityWake()
            override fun onLost(network: Network) = scheduleConnectivityWake()
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = scheduleConnectivityWake()
            override fun onBlockedStatusChanged(network: Network, blocked: Boolean) = scheduleConnectivityWake()
        }
        connectivityCallback = callback
        connectivityToken = token
        if (Build.VERSION.SDK_INT >= 24) manager.registerDefaultNetworkCallback(callback)
        else manager.registerNetworkCallback(NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(), callback)
    }

    private fun scheduleConnectivityWake() {
        connectivityHandler.removeCallbacks(connectivityWake)
        connectivityHandler.post(connectivityWake)
    }

    /** Same main-thread gate serves real callbacks and the instrumentation seam. */
    internal fun dispatchConnectivityWake(token: Long) {
        val lease = session ?: return
        if (foregroundStarted && !wakeLockHeld && lease === DownloadQueueRuntime.current && token == lease.token) {
            lease.wake()
        }
    }

    private fun unwatchConnectivity() {
        connectivityToken = null
        connectivityHandler.removeCallbacks(connectivityWake)
        val callback = connectivityCallback
        connectivityCallback = null
        if (callback != null) {
            try {
                getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(callback)
            } catch (_: RuntimeException) {
                // Failed/previously removed registrations must not prevent stop.
            }
        }
    }

    private fun notification(title: String, chapter: String, status: String, progress: Double?, speed: Double): Notification {
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
            else Notification.Builder(this)
        val speedText = if (speed.isFinite() && speed > 0) {
            if (speed >= 1024 * 1024) String.format(Locale.ROOT, "%.1f MiB/s", speed / (1024 * 1024))
            else String.format(Locale.ROOT, "%.0f KiB/s", speed / 1024)
        } else ""
        val text = listOf(chapter.take(160), status.take(160), speedText).filter { it.isNotBlank() }.joinToString(" · ")
        val pause = PendingIntent.getService(this, NOTIFICATION_ID,
            Intent(this, DownloadForegroundService::class.java).setAction(ACTION_PAUSE)
                .setData(Uri.parse("triomi-download://queue/${session?.token}"))
                .putExtra(EXTRA_TOKEN, session?.token ?: -1),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        builder.setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title.take(160).ifBlank { "Triomi 下载" })
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(null, "暂停下载", pause).build())
        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            builder.setContentIntent(PendingIntent.getActivity(this, NOTIFICATION_ID, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        }
        val fraction = progress?.takeIf { it.isFinite() }?.coerceIn(0.0, 1.0)
        builder.setProgress(1000, fraction?.let { (it * 1000).toInt() } ?: 0, fraction == null)
        return builder.build()
    }

    internal fun finish() {
        unwatchConnectivity()
        releaseWakeLock()
        if (foregroundStarted) {
            foregroundStarted = false
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
        stopSelf()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val lock = wakeLock ?: getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:download-queue").apply {
                setReferenceCounted(false)
            }.also { wakeLock = it }
        lock.acquire()
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    // Android 15 dataSync time budget: stop native resources immediately and ask
    // Dart to cancel the physical transfer, not merely mark the row paused.
    override fun onTimeout(startId: Int, fgsType: Int) {
        session?.let { DownloadQueueRuntime.pause(it, "timeout") }
        finish()
    }

    override fun onDestroy() {
        unwatchConnectivity()
        releaseWakeLock()
        if (foregroundStarted) {
            foregroundStarted = false
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
        DownloadQueueRuntime.destroyed(this)
        session = null
        super.onDestroy()
    }

    companion object {
        internal const val CHANNEL = "triomi.download-queue"
        internal const val NOTIFICATION_ID = 7403
        internal const val ACTION_START = "io.github.hyperionhxh.triomi.download.START"
        internal const val ACTION_PAUSE = "io.github.hyperionhxh.triomi.download.PAUSE"
        internal const val EXTRA_TOKEN = "download_queue_token"

        internal fun notificationsVisible(context: Context): Boolean {
            if (!BackgroundUpdate.hasNotificationPermission(context)) return false
            val manager = context.getSystemService(NotificationManager::class.java) ?: return false
            if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) return false
            if (Build.VERSION.SDK_INT >= 26 &&
                manager.getNotificationChannel(CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE) return false
            return true
        }

        internal fun startIntent(context: Context, token: Long) =
            Intent(context, DownloadForegroundService::class.java).setAction(ACTION_START).putExtra(EXTRA_TOKEN, token)
    }
}
