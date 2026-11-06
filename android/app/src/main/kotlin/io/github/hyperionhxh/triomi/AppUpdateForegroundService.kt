package io.github.hyperionhxh.triomi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/** User-started update transfer only; no sticky restart or force-stop guarantee. */
class AppUpdateForegroundService : Service() {
    private var session: AppUpdateTransferSession? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var started = false
    internal val wakeLockHeld: Boolean get() = wakeLock?.isHeld == true
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val lease = AppUpdateTransferRuntime.current
        if (lease == null || intent?.getLongExtra("token", -1) != lease.token) {
            if (session == null && lease == null) stopSelf(startId)
            return START_NOT_STICKY
        }
        if (intent?.action == CANCEL) {
            AppUpdateTransferRuntime.cancel(lease)
            if (session == null) stopSelf(startId)
            return START_NOT_STICKY
        }
        if (intent?.action != START || started) return START_NOT_STICKY
        session = lease
        lease.service = this
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                getSystemService(NotificationManager::class.java).createNotificationChannel(
                    NotificationChannel(CHANNEL, "应用更新下载", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "更新包下载、核验与取消；不会自动安装"
                        setShowBadge(false)
                    })
            }
            val notification = notification("准备下载并核验", 0, null)
            if (Build.VERSION.SDK_INT >= 29) startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else startForeground(ID, notification)
            started = true
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:app-update").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            lease.ready(true)
        } catch (_: RuntimeException) {
            AppUpdateTransferRuntime.end(lease)
            lease.ready(false)
        }
        return START_NOT_STICKY
    }

    fun update(phase: String, bytes: Long, total: Long?): Boolean {
        if (!started || session !== AppUpdateTransferRuntime.current) return false
        return try {
            val label = when (phase) {
                "metadata" -> "读取发布信息"
                "download" -> "下载更新包"
                else -> "核验更新包"
            }
            getSystemService(NotificationManager::class.java).notify(ID, notification(label, bytes, total))
            true
        } catch (_: RuntimeException) {
            session?.let { AppUpdateTransferRuntime.cancel(it) }
            false
        }
    }

    private fun notification(status: String, bytes: Long, total: Long?): Notification {
        val cancel = PendingIntent.getService(this, ID,
            Intent(this, AppUpdateForegroundService::class.java).setAction(CANCEL)
                .setData(Uri.parse("triomi-update://transfer/${session?.token}"))
                .putExtra("token", session?.token ?: -1),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        builder.setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Triomi 应用更新")
            .setContentText("$status · 可离开页面，完成后需手动确认安装")
            .setCategory(Notification.CATEGORY_PROGRESS).setOngoing(true).setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(null, "取消更新下载", cancel).build())
        packageManager.getLaunchIntentForPackage(packageName)?.let {
            builder.setContentIntent(PendingIntent.getActivity(this, ID, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        }
        val fraction = total?.takeIf { it > 0 }?.let { (bytes.toDouble() / it).coerceIn(0.0, 1.0) }
        builder.setProgress(1000, fraction?.let { (it * 1000).toInt() } ?: 0, fraction == null)
        return builder.build()
    }

    internal fun finish() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        if (started) {
            started = false
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
        stopSelf()
    }
    override fun onTimeout(startId: Int, fgsType: Int) {
        session?.let { AppUpdateTransferRuntime.cancel(it) }
        finish()
    }
    override fun onDestroy() {
        finish()
        AppUpdateTransferRuntime.destroyed(this)
        session = null
        super.onDestroy()
    }
    companion object {
        private const val CHANNEL = "triomi.app-update"
        private const val ID = 7404
        private const val START = "io.github.hyperionhxh.triomi.update.START"
        private const val CANCEL = "io.github.hyperionhxh.triomi.update.CANCEL"
        internal fun startIntent(context: Context, token: Long) =
            Intent(context, AppUpdateForegroundService::class.java).setAction(START).putExtra("token", token)
    }
}

internal class AppUpdateTransferSession(val token: Long, val ready: (Boolean) -> Unit, val cancelled: () -> Unit) {
    var service: AppUpdateForegroundService? = null
}

/** Main-thread generation leases isolate update downloads from the content queue. */
internal object AppUpdateTransferRuntime {
    var current: AppUpdateTransferSession? = null
        private set
    private var generation = 0L
    private var stopping: AppUpdateForegroundService? = null
    val idle: Boolean get() = current == null && stopping == null
    fun reserve(ready: (Boolean) -> Unit, cancelled: () -> Unit): AppUpdateTransferSession? {
        if (current != null || stopping != null) return null
        return AppUpdateTransferSession(++generation, ready, cancelled).also { current = it }
    }
    fun end(lease: AppUpdateTransferSession) {
        if (current !== lease) return
        current = null
        lease.service?.let { stopping = it; it.finish() }
    }
    fun cancel(lease: AppUpdateTransferSession) {
        if (current !== lease) return
        end(lease)
        lease.ready(false)
        lease.cancelled()
    }
    fun destroyed(service: AppUpdateForegroundService) {
        if (stopping === service) stopping = null
        current?.takeIf { it.service === service }?.let {
            current = null
            it.ready(false)
            it.cancelled()
        }
    }
}
