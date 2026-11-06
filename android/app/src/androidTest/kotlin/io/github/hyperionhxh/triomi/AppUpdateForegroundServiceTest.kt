package io.github.hyperionhxh.triomi

import android.content.Intent
import android.os.Build
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleCallback
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class AppUpdateForegroundServiceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private var owner: MainActivity? = null

    private fun launch(): MainActivity {
        val ready = CountDownLatch(1)
        val monitor = ActivityLifecycleMonitorRegistry.getInstance()
        val callback = ActivityLifecycleCallback { activity, stage ->
            if (activity is MainActivity && stage == Stage.RESUMED) {
                owner = activity
                ready.countDown()
            }
        }
        instrumentation.runOnMainSync { monitor.addLifecycleCallback(callback) }
        try {
            context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            assertTrue(ready.await(10, TimeUnit.SECONDS))
            return requireNotNull(owner)
        } finally {
            instrumentation.runOnMainSync { monitor.removeLifecycleCallback(callback) }
        }
    }

    private fun awaitIdle() {
        val deadline = SystemClock.elapsedRealtime() + 10_000
        while (SystemClock.elapsedRealtime() < deadline) {
            var idle = false
            instrumentation.runOnMainSync { idle = AppUpdateTransferRuntime.idle }
            if (idle) return
            SystemClock.sleep(20)
        }
        fail("Updater foreground service must release its lease")
    }

    @After fun cleanup() {
        instrumentation.runOnMainSync {
            AppUpdateTransferRuntime.current?.let { AppUpdateTransferRuntime.end(it) }
            owner?.finish()
        }
        awaitIdle()
    }

    @Test fun singleFlightAndStaleCancellationDoNotAffectContentQueueOrNewGeneration() {
        instrumentation.runOnMainSync {
            var cancellations = 0
            val first = requireNotNull(AppUpdateTransferRuntime.reserve({}, { cancellations++ }))
            assertNull(AppUpdateTransferRuntime.reserve({}, {}))
            AppUpdateTransferRuntime.end(first)
            val second = requireNotNull(AppUpdateTransferRuntime.reserve({}, { cancellations++ }))
            AppUpdateTransferRuntime.cancel(first)
            assertSame(second, AppUpdateTransferRuntime.current)
            assertEquals(0, cancellations)
            val queue = requireNotNull(DownloadQueueRuntime.reserve({}, {}))
            AppUpdateTransferRuntime.cancel(second)
            assertSame(queue, DownloadQueueRuntime.current)
            assertEquals(1, cancellations)
            assertTrue(AppUpdateTransferRuntime.idle)
            DownloadQueueRuntime.end(queue)
        }
    }

    @Test fun realServiceHoldsCpuAcrossHomeAndReleasesOnCancel() {
        val activity = launch()
        val acknowledged = CountDownLatch(1)
        var started = false
        var cancelled = false
        lateinit var lease: AppUpdateTransferSession
        instrumentation.runOnMainSync {
            lease = requireNotNull(AppUpdateTransferRuntime.reserve({ value ->
                started = value
                acknowledged.countDown()
            }, { cancelled = true }))
            val intent = AppUpdateForegroundService.startIntent(activity, lease.token)
            if (Build.VERSION.SDK_INT >= 26) activity.startForegroundService(intent) else activity.startService(intent)
        }
        assertTrue(acknowledged.await(10, TimeUnit.SECONDS))
        assertTrue(started)
        val stopped = CountDownLatch(1)
        val monitor = ActivityLifecycleMonitorRegistry.getInstance()
        val callback = ActivityLifecycleCallback { candidate, stage ->
            if (candidate === activity && stage == Stage.STOPPED) stopped.countDown()
        }
        instrumentation.runOnMainSync { monitor.addLifecycleCallback(callback) }
        try {
            context.startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            assertTrue(stopped.await(10, TimeUnit.SECONDS))
        } finally {
            instrumentation.runOnMainSync { monitor.removeLifecycleCallback(callback) }
        }
        instrumentation.runOnMainSync {
            val service = requireNotNull(lease.service)
            assertFalse(activity.isDestroyed)
            assertSame(lease, AppUpdateTransferRuntime.current)
            assertTrue(service.wakeLockHeld)
            assertTrue(service.update("download", 512, 1024))
            AppUpdateTransferRuntime.cancel(lease)
            assertTrue(cancelled)
            assertFalse(service.wakeLockHeld)
            assertFalse(service.update("download", 1024, 1024))
        }
        awaitIdle()
    }
}
