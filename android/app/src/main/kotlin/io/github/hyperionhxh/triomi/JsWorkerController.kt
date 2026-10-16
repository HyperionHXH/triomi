package io.github.hyperionhxh.triomi

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.ResultReceiver
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class JsWorkerController(
    private val context: Context,
    engine: FlutterEngine,
    background: Boolean = false,
) {
    private val serviceClass = if (background) BackgroundJsWorkerService::class.java else JsWorkerService::class.java
    private val processName = "${context.packageName}:${if (background) "js_worker_background" else "js_worker"}"
    private var token: String? = null
    private var pid: Int? = null
    init {
        MethodChannel(engine.dartExecutor.binaryMessenger, "triomi/js-worker")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val key = call.argument<String>("token")
                        val port = call.argument<Int>("port")
                        if (key == null || port == null || key.length < 40) {
                            result.error("invalid_worker", "Worker configuration invalid", null)
                        } else {
                            killOwnedWorker()
                            token = key
                            val receiver = object : ResultReceiver(Handler(Looper.getMainLooper())) {
                                override fun onReceiveResult(code: Int, data: Bundle?) {
                                    val reported = data?.getInt("pid")
                                    if (token != key) {
                                        if (reported != null) killVerified(reported)
                                        return
                                    }
                                    if (code == 0 && reported != null && reported != Process.myPid()) {
                                        pid = reported
                                        result.success(null)
                                    } else result.error("worker_start", "Worker could not start", null)
                                }
                            }
                            try {
                                context.startService(Intent(context, serviceClass)
                                    .putExtra("port", port).putExtra("token", key).putExtra("receiver", receiver))
                            } catch (_: Exception) {
                                token = null
                                result.error("worker_start", "Worker service unavailable", null)
                            }
                        }
                    }
                    "kill" -> {
                        if (call.argument<String>("token") == token) {
                            token = null
                            killOwnedWorker()
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
    fun close() {
        if(token != null || pid != null) {
            token = null
            killOwnedWorker()
        }
    }
    private fun killVerified(target: Int) {
        val processes = (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).runningAppProcesses
        if (processes?.any { it.pid == target && it.uid == Process.myUid() && it.processName == processName } == true) {
            Process.killProcess(target)
        }
    }
    private fun killOwnedWorker() {
        // Remove Android's started-service record before SIGKILL. Otherwise
        // AMS schedules crashed-service restarts with increasing backoff.
        context.stopService(Intent(context, serviceClass))
        pid?.let { killVerified(it) }
        pid = null
        // Also recover a worker orphaned by a host process restart.
        val processes = (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).runningAppProcesses
        processes?.filter { it.uid == Process.myUid() && it.processName == processName }
            ?.forEach { Process.killProcess(it.pid) }
    }
}
