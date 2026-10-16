package io.github.hyperionhxh.triomi

import android.app.job.JobParameters
import android.app.job.JobService
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MangaUpdateJobService : JobService() {
    private var engine: FlutterEngine? = null
    private var workers: java.util.concurrent.ExecutorService? = null
    private var jsWorker: JsWorkerController? = null
    private val timeout = Handler(Looper.getMainLooper())
    override fun onStartJob(params: JobParameters?): Boolean {
        if (!MangaUpdatesRuntime.begin(this)) { jobFinished(params, true); return false }
        val e = FlutterEngine(applicationContext)
        engine = e
        val executor = Executors.newFixedThreadPool(3)
        workers = executor
        val host = MihonHost(this)
        jsWorker = JsWorkerController(this, e, background = true)
        var finished = false
        fun finish(reschedule: Boolean = false) {
            if (finished || engine !== e) return
            finished = true
            timeout.removeCallbacksAndMessages(null)
            MangaUpdatesRuntime.end(this)
            MangaUpdatesRuntime.endDownloads(this)
            jobFinished(params,reschedule)
            executor.shutdownNow()
            jsWorker?.close(); jsWorker=null
            if (engine === e) { e.destroy(); engine=null }
        }
        MethodChannel(e.dartExecutor.binaryMessenger,"triomi/platform").setMethodCallHandler { call,result ->
            when (call.method) {
                "beginDownloadQueue" -> result.success(MangaUpdatesRuntime.beginDownloads(this))
                "endDownloadQueue" -> { MangaUpdatesRuntime.endDownloads(this); result.success(null) }
                "canNotifyMangaUpdates" -> result.success(BackgroundUpdate.hasNotificationPermission(this))
                "mangaUpdateConstraints" -> result.success(MangaUpdatesRuntime.allowed(this,call.argument<Boolean>("wifiOnly") != false,call.argument<Boolean>("batteryNotLow") != false))
                "notifyMangaUpdate" -> { MangaUpdatesRuntime.notify(this,call.argument<String>("id") ?: "manga",call.argument<String>("title") ?: "漫画更新",call.argument<String>("body") ?: "",call.argument<String>("coverPath")); result.success(true) }
                "mihonRequest" -> {
                    val args=call.arguments as? Map<*, *>
                    if(args==null) result.error("invalid_args","Mihon arguments required",null)
                    else executor.execute {
                        try { val value=host.request(args); timeout.post { if(!finished && engine === e) result.success(value) } }
                        catch(_: Throwable) { timeout.post { if(!finished && engine === e) result.error("source_failed","Mihon background request failed",null) } }
                    }
                }
                else -> result.notImplemented()
            }
        }
        MangaUpdatesRuntime.setCancellation(this) {
            MethodChannel(e.dartExecutor.binaryMessenger, "triomi/manga-updates").invokeMethod("cancel", null)
        }
        MethodChannel(e.dartExecutor.binaryMessenger,"triomi/manga-updates").setMethodCallHandler { call,result ->
            when (call.method) {
                "done" -> { result.success(true); finish() }
                else -> result.notImplemented()
            }
        }
        try { e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(FlutterInjector.instance().flutterLoader().findAppBundlePath(), "mangaUpdateCheck")) }
        catch (_: Exception) { finish(); return false }
        timeout.postDelayed({ finish(true) }, 9 * 60_000)
        return true
    }
    override fun onStopJob(params: JobParameters?): Boolean {
        timeout.removeCallbacksAndMessages(null)
        MangaUpdatesRuntime.end(this)
        MangaUpdatesRuntime.endDownloads(this)
        workers?.shutdownNow(); workers=null
        jsWorker?.close(); jsWorker=null
        engine?.destroy(); engine=null
        return true
    }
}
