package io.github.hyperionhxh.triomi

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class LocalBackupJobService : JobService() {
    private var engine: FlutterEngine? = null
    private val handler = Handler(Looper.getMainLooper())
    private var worker: java.util.concurrent.ExecutorService? = null

    override fun onStartJob(params: JobParameters?): Boolean {
        if (engine != null) return false
        val e = FlutterEngine(applicationContext)
        engine = e
        BackupArtifactGuard.register(applicationContext, e.dartExecutor.binaryMessenger)
        val executor = Executors.newSingleThreadExecutor()
        worker = executor
        var finished = false
        fun finish(retry: Boolean = false) {
            if (finished || engine !== e) return
            finished = true
            handler.removeCallbacksAndMessages(null)
            jobFinished(params, retry)
            executor.shutdownNow()
            worker = null
            e.destroy()
            engine = null
        }
        MethodChannel(e.dartExecutor.binaryMessenger, "triomi/platform").setMethodCallHandler { call, result ->
            if (call.method != "writeToTree") { result.notImplemented(); return@setMethodCallHandler }
            val uri = call.argument<String>("treeUri")
            val name = call.argument<String>("fileName")
            val path = call.argument<String>("sourcePath")
            if (uri == null || name == null || path == null) {
                result.error("invalid_args", "Backup destination is required", null)
                return@setMethodCallHandler
            }
            executor.execute {
                try {
                    val created = SafDocumentWriter.write(applicationContext, uri, name, "application/zip", null, path)
                    handler.post { if (!finished) result.success(created) }
                } catch (_: Exception) {
                    handler.post { if (!finished) result.error("backup_write_failed", "Backup directory is unavailable", null) }
                }
            }
        }
        MethodChannel(e.dartExecutor.binaryMessenger, "triomi/backups").setMethodCallHandler { call, result ->
            if (call.method == "done") { result.success(null); finish() } else result.notImplemented()
        }
        try {
            e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(), "scheduledLocalBackup"))
        } catch (_: Exception) { finish(true); return false }
        handler.postDelayed({ finish(true) }, 9 * 60_000)
        return true
    }

    override fun onStopJob(params: JobParameters?): Boolean {
        handler.removeCallbacksAndMessages(null)
        worker?.shutdownNow(); worker = null
        engine?.destroy(); engine = null
        return true
    }

    companion object {
        const val JOB_ID = 7501
        fun schedule(context: Context, enabled: Boolean): Boolean {
            val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
            if (!enabled) { scheduler.cancel(JOB_ID); return true }
            return scheduler.schedule(JobInfo.Builder(JOB_ID, ComponentName(context, LocalBackupJobService::class.java))
                .setPersisted(true).setRequiresBatteryNotLow(true)
                .setPeriodic(24 * 60 * 60_000L).build()) == JobScheduler.RESULT_SUCCESS
        }
    }
}
