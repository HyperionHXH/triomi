package io.github.hyperionhxh.triomi

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/**
 * 后台更新提醒的排程与通知。
 *
 * 设计约束（T7-7 / 规格 D5）：不引入 workmanager 插件，用原生 JobScheduler
 * 周期拉起 [BackgroundUpdateCheckJobService]，由 Dart 侧判断是否有追番更新。
 * 默认关闭，开启前需通知权限（Android 13+）。
 */
object BackgroundUpdate {
    /** 周期任务的作业 id（强制触发用 `cmd jobscheduler run -f <包名> 7301`）。 */
    const val JOB_ID = 7301

    const val CHANNEL_ID = "triomi.updates"

    private const val NOTIFICATION_ID = 7302
    private const val INTERVAL_MS = 12 * 60 * 60 * 1000L

    /** 注册周期任务：12 小时一次，仅在非计费网络（WiFi）上执行。 */
    fun schedule(context: Context): Boolean {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return false
        val job = JobInfo.Builder(
            JOB_ID,
            ComponentName(context, BackgroundUpdateCheckJobService::class.java),
        )
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_UNMETERED)
            .setPeriodic(INTERVAL_MS)
            .setPersisted(true)
            .build()
        return try {
            scheduler.schedule(job) == JobScheduler.RESULT_SUCCESS
        } catch (_: Exception) {
            // 约束/权限不满足时系统抛 SecurityException：回给 Dart false，界面据此提示。
            false
        }
    }

    fun cancel(context: Context) {
        try {
            context.getSystemService(JobScheduler::class.java)?.cancel(JOB_ID)
        } catch (_: Exception) {
        }
    }

    fun isScheduled(context: Context): Boolean {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return false
        return try {
            scheduler.getPendingJob(JOB_ID) != null
        } catch (_: Exception) {
            false
        }
    }

    /** 通知权限是否可用（13 以下默认允许，无需运行时申请）。 */
    fun hasNotificationPermission(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    /** 发一条更新提醒；没有通知权限时静默跳过（不报错、不影响任务收尾）。 */
    fun show(context: Context, title: String, body: String) {
        if (!hasNotificationPermission(context)) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        ensureChannel(manager)

        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        val pending = launch?.let {
            PendingIntent.getActivity(
                context,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context)
        }
        builder.setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
        if (pending != null) builder.setContentIntent(pending)

        manager.notify(NOTIFICATION_ID, builder.build())
    }

    private fun ensureChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "追番更新",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply { description = "追番有新一集放送时提醒" },
        )
    }
}
