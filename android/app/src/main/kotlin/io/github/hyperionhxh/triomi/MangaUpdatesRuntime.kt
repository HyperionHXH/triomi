package io.github.hyperionhxh.triomi

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.graphics.BitmapFactory
import java.io.File

object MangaUpdatesRuntime {
    const val JOB_ID = 7401
    private const val CHANNEL = "triomi.manga-updates"
    private var leaseOwner: Any? = null
    private var cancelAction: (() -> Unit)? = null
    @Synchronized fun setCancellation(owner: Any, cancel: () -> Unit) {
        if (leaseOwner === owner) cancelAction = cancel
    }
    @Synchronized fun cancel() { cancelAction?.invoke() }
    private var downloadOwner: Any? = null
    @Synchronized fun beginDownloads(owner: Any): Boolean {
        if(downloadOwner != null) return false
        downloadOwner = owner
        return true
    }
    @Synchronized fun endDownloads(owner: Any) {
        if(downloadOwner === owner) downloadOwner = null
    }
    @Synchronized fun begin(owner: Any): Boolean {
        if (leaseOwner != null) return false
        leaseOwner = owner
        return true
    }
    @Synchronized fun end(owner: Any) {
        if (leaseOwner === owner) { leaseOwner = null; cancelAction = null }
    }
    fun schedule(context: Context, enabled: Boolean, wifi: Boolean, battery: Boolean): Boolean {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return false
        if (!enabled) { scheduler.cancel(JOB_ID); return true }
        val job = JobInfo.Builder(JOB_ID, ComponentName(context, MangaUpdateJobService::class.java))
            .setRequiredNetworkType(if (wifi) JobInfo.NETWORK_TYPE_UNMETERED else JobInfo.NETWORK_TYPE_ANY)
            .setRequiresBatteryNotLow(battery).setPersisted(true).setPeriodic(12 * 60 * 60 * 1000L).build()
        return scheduler.schedule(job) == JobScheduler.RESULT_SUCCESS
    }
    fun allowed(context: Context, wifi: Boolean, battery: Boolean): Boolean {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return false
        val caps = manager.getNetworkCapabilities(manager.activeNetwork) ?: return false
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return false
        if (wifi && !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) return false
        if (battery) {
            val status = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val level = status?.getIntExtra(BatteryManager.EXTRA_LEVEL, 100) ?: 100
            val scale = status?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
            val plugged = status?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
            if (plugged == 0 && level * 100 / scale.coerceAtLeast(1) <= 15) return false
        }
        return true
    }
    fun notify(context: Context, id: String, title: String, body: String, coverPath: String?) {
        if (!BackgroundUpdate.hasNotificationPermission(context)) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "漫画更新", NotificationManager.IMPORTANCE_DEFAULT))
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        intent.putExtra("triomi_route", "/manga/updates")
        val pending = PendingIntent.getActivity(context, id.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = android.app.Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_dialog_info).setContentTitle(title).setContentText(body)
            .setStyle(android.app.Notification.BigTextStyle().bigText(body)).setContentIntent(pending).setAutoCancel(true)
        if (coverPath != null) {
            val file = File(coverPath).canonicalFile
            if (file.path.startsWith(context.cacheDir.canonicalPath + File.separator)) {
                BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = 2 })?.let { builder.setLargeIcon(it) }
            }
        }
        manager.notify(id.hashCode(), builder.build())
    }
}
