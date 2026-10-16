package io.github.hyperionhxh.triomi

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.IBinder
import android.os.Process
import android.os.ResultReceiver
import android.os.Debug
import kotlin.concurrent.thread
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** Private same-UID OS process. The host kills its PID without asking a
 * potentially blocked Dart/QuickJS thread to cooperate. Never sticky. */
open class JsWorkerService : Service() {
    private var engine: FlutterEngine? = null
    @Volatile private var watching = false
    override fun onBind(intent: Intent?): IBinder? = null
    @Suppress("DEPRECATION")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) { stopSelf(); return START_NOT_STICKY }
        val receiver = intent.getParcelableExtra<ResultReceiver>("receiver")
        val port = intent.getIntExtra("port", 0)
        val token = intent.getStringExtra("token") ?: ""
        if (port !in 1..65535 || token.length < 40 || engine != null) {
            receiver?.send(1, Bundle())
            return START_NOT_STICKY
        }
        receiver?.send(0, Bundle().apply { putInt("pid", Process.myPid()) })
        // A native allocation loop can block Dart. Sample from an independent
        // JVM thread; only this private worker PID may be terminated here.
        watching = true
        thread(name = "triomi-js-memory", isDaemon = true) {
            while (watching) {
                if (Debug.getNativeHeapAllocatedSize() > 384L * 1024 * 1024) {
                    Process.killProcess(Process.myPid())
                }
                Thread.sleep(100)
            }
        }
        try {
            // Automatic registration is disabled: the worker needs only FFI,
            // not account, filesystem, media or platform plugins.
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
            val worker = FlutterEngine(applicationContext, null, false)
            engine = worker
            MethodChannel(worker.dartExecutor.binaryMessenger, "triomi/js-worker-config")
                .setMethodCallHandler { call, result ->
                    if (call.method == "config") result.success(mapOf("port" to port, "token" to token))
                    else result.notImplemented()
                }
            worker.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "package:triomi/main.dart", "jsWorker"),
            )
        } catch (_: Throwable) {
            Process.killProcess(Process.myPid())
        }
        return START_NOT_STICKY
    }
    override fun onDestroy() {
        watching = false
        engine?.destroy()
        engine = null
        super.onDestroy()
    }
}

/** Background catalogue engine owns a distinct OS worker process. */
class BackgroundJsWorkerService : JsWorkerService()
