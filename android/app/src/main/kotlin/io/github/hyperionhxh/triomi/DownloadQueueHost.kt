package io.github.hyperionhxh.triomi

import android.app.Activity
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** The existing UI engine stays alive on Home/lock; no headless or process-death restart. */
class DownloadQueueHost(
    private val activity: Activity,
    private val channel: MethodChannel,
    private val foreground: () -> Boolean,
    private val requestPermission: (MethodChannel.Result) -> Unit,
    private val cancelResolver: () -> Unit,
) {
    private val handler = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var session: DownloadQueueSession? = null
    private var permissionResolved = false
    private var closed = false
    private val deadline = Runnable { end() }

    val active: Boolean get() = session?.let { DownloadQueueRuntime.current === it && it.service != null } == true

    fun begin(result: MethodChannel.Result) {
        if (closed || pending != null || session != null || !canStart()) {
            result.success(false)
            return
        }
        pending = result
        handler.postDelayed(deadline, 90_000)
        if (Build.VERSION.SDK_INT >= 33 && !BackgroundUpdate.hasNotificationPermission(activity)) {
            requestPermission(object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (pending == null || closed) return
                    // Denial hides the drawer notification, but Android still allows
                    // a real FGS visible in the system's active-app/task manager.
                    permissionResolved = true
                    handler.post {
                        if (pending != null && session == null) {
                            if (canStart()) start() else handler.postDelayed({
                                if (pending != null && session == null) finishBegin(false)
                            }, 1000)
                        }
                    }
                }
                override fun error(code: String, message: String?, details: Any?) { finishBegin(false) }
                override fun notImplemented() { finishBegin(false) }
            })
        } else {
            permissionResolved = true
            start()
        }
    }

    fun onResume() {
        if (pending != null && permissionResolved && session == null && canStart()) start()
    }

    private fun canStart() = foreground() && !activity.isFinishing && !activity.isDestroyed

    private fun start() {
        if (pending == null || !canStart()) { finishBegin(false); return }
        val lease = DownloadQueueRuntime.reserve(
            ready = { started ->
                if (started) channel.invokeMethod("downloadQueueNotificationVisibility", mapOf(
                    "visible" to DownloadForegroundService.notificationsVisible(activity),
                ))
                if (!started) session = null
                finishBegin(started)
            },
            pause = { reason ->
                session = null
                cancelResolver()
                finishBegin(false)
                channel.invokeMethod("downloadQueuePauseRequested", mapOf("reason" to reason))
            },
            wake = { channel.invokeMethod("downloadQueueWakeRequested", mapOf("reason" to "connectivity")) },
        )
        if (lease == null) { finishBegin(false); return }
        session = lease
        handler.removeCallbacks(deadline)
        handler.postDelayed(deadline, 10_000)
        try {
            val intent = DownloadForegroundService.startIntent(activity, lease.token)
            if (Build.VERSION.SDK_INT >= 26) activity.startForegroundService(intent)
            else activity.startService(intent)
        } catch (_: RuntimeException) {
            DownloadQueueRuntime.end(lease)
            session = null
            finishBegin(false)
        }
    }

    private fun finishBegin(value: Boolean) {
        handler.removeCallbacks(deadline)
        val reply = pending
        pending = null
        permissionResolved = false
        reply?.success(value)
    }

    fun update(call: MethodCall): Boolean {
        val service = session?.takeIf { DownloadQueueRuntime.current === it }?.service ?: return false
        return service.update(
            call.argument<String>("title").orEmpty(),
            call.argument<String>("chapter").orEmpty(),
            call.argument<String>("status").orEmpty(),
            call.argument<Number>("progress")?.toDouble(),
            call.argument<Number>("speed")?.toDouble() ?: 0.0,
        )
    }

    fun setActive(active: Boolean): Boolean {
        val lease = session?.takeIf { DownloadQueueRuntime.current === it } ?: return false
        return lease.service?.setQueueActive(lease.token, active) ?: false
    }

    fun end() {
        val lease = session
        session = null
        if (lease != null) DownloadQueueRuntime.end(lease)
        cancelResolver()
        finishBegin(false)
    }

    fun close() {
        if (closed) return
        closed = true
        session?.let { DownloadQueueRuntime.pause(it, "activity_destroyed") }
        end()
        handler.removeCallbacksAndMessages(null)
    }
}

internal class DownloadQueueSession(
    val token: Long,
    val ready: (Boolean) -> Unit,
    val pause: (String) -> Unit,
    val wake: () -> Unit,
) {
    var service: DownloadForegroundService? = null
}

/** Main-thread only. Identity checks reject delayed start/action intents from old queues. */
internal object DownloadQueueRuntime {
    var current: DownloadQueueSession? = null
        private set
    private var nextToken = 0L
    private var stoppingService: DownloadForegroundService? = null
    val idle: Boolean get() = current == null && stoppingService == null

    fun reserve(ready: (Boolean) -> Unit, pause: (String) -> Unit, wake: () -> Unit = {}): DownloadQueueSession? {
        if (current != null || stoppingService != null) return null
        return DownloadQueueSession(++nextToken, ready, pause, wake).also { current = it }
    }

    fun end(session: DownloadQueueSession) {
        if (current !== session) return
        current = null
        session.service?.let { stoppingService = it; it.finish() }
    }

    fun pause(session: DownloadQueueSession, reason: String) {
        if (current !== session) return
        end(session)
        session.pause(reason)
    }

    fun destroyed(service: DownloadForegroundService) {
        if (stoppingService === service) stoppingService = null
        current?.takeIf { it.service === service }?.let {
            current = null
            it.pause("service_stopped")
        }
    }
}
