package io.github.hyperionhxh.triomi

import android.app.job.JobParameters
import android.app.job.JobService
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * 后台更新检查作业：拉起一个 headless FlutterEngine 执行 Dart 入口
 * `backgroundUpdateCheck`。
 *
 * 与 Dart 侧的约定（通道 `triomi/background`）：
 * - Dart 判定有更新 → 回调 `notify`（title / body），这里发本地通知；
 * - Dart 收尾 → 回调 `done`，这里结束作业并销毁引擎；
 * - 超时兜底：Dart 侧异常未回调时也要收回引擎。
 */
class BackgroundUpdateCheckJobService : JobService() {
    private var engine: FlutterEngine? = null
    private val timeout = Handler(Looper.getMainLooper())

    override fun onStartJob(params: JobParameters?): Boolean {
        val flutterEngine = FlutterEngine(applicationContext)
        engine = flutterEngine
        var finished = false

        fun finish() {
            if (finished) return
            finished = true
            timeout.removeCallbacksAndMessages(null)
            jobFinished(params, false)
            engine?.destroy()
            engine = null
        }

        // FlutterEngine 默认会自动登记插件（path_provider 等），无需手动注册。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "notify" -> {
                        BackgroundUpdate.show(
                            this,
                            call.argument<String>("title") ?: "追番更新提醒",
                            call.argument<String>("body") ?: "",
                        )
                        result.success(true)
                    }
                    "done" -> {
                        result.success(true)
                        finish()
                    }
                    else -> result.notImplemented()
                }
            }

        try {
            flutterEngine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                    ENTRY_POINT,
                ),
            )
        } catch (error: Exception) {
            finish()
            return false
        }

        timeout.postDelayed({ finish() }, TIMEOUT_MS)
        return true
    }

    override fun onStopJob(params: JobParameters?): Boolean {
        timeout.removeCallbacksAndMessages(null)
        engine?.destroy()
        engine = null
        return true
    }

    companion object {
        private const val CHANNEL = "triomi/background"
        private const val ENTRY_POINT = "backgroundUpdateCheck"
        private const val TIMEOUT_MS = 60_000L
    }
}
