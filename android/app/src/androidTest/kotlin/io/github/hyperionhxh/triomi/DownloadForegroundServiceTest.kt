package io.github.hyperionhxh.triomi

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleCallback
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeFalse
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Disposable emulator only; permission cases require POST_NOTIFICATIONS denied before instrumentation starts. */
@RunWith(AndroidJUnit4::class)
class DownloadForegroundServiceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private var activityFixture: ActivityFixture? = null
    private var host: DownloadQueueHost? = null

    private class Reply : MethodChannel.Result {
        val done = CountDownLatch(1)
        var value: Any? = null
        var calls = 0
        override fun success(result: Any?) { value = result; calls++; done.countDown() }
        override fun error(code: String, message: String?, details: Any?) { value = code; calls++; done.countDown() }
        override fun notImplemented() { value = "not_implemented"; calls++; done.countDown() }
    }

    private class Messenger : BinaryMessenger {
        val events = mutableListOf<Pair<String, Any?>>()
        override fun send(channel: String, message: ByteBuffer?) { send(channel, message, null) }
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            if (message != null) {
                // Flutter encoders leave the write position at the end.
                val input = message.duplicate().apply { flip() }
                val call = StandardMethodCodec.INSTANCE.decodeMethodCall(input)
                events.add(call.method to call.arguments)
            }
            callback?.reply(null)
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) = Unit
    }

    private inner class ActivityFixture(val owner: MainActivity) {
        fun onActivity(action: (MainActivity) -> Unit) {
            instrumentation.runOnMainSync { action(owner) }
        }
    }

    private fun launch(): ActivityFixture {
        val resumed = CountDownLatch(1)
        var owner: MainActivity? = null
        val monitor = ActivityLifecycleMonitorRegistry.getInstance()
        val callback = ActivityLifecycleCallback { activity, stage ->
            if (activity is MainActivity && stage == Stage.RESUMED) {
                owner = activity
                resumed.countDown()
            }
        }
        instrumentation.runOnMainSync { monitor.addLifecycleCallback(callback) }
        try {
            context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            assertTrue("Queue activity must resume", resumed.await(10, TimeUnit.SECONDS))
            return ActivityFixture(requireNotNull(owner)).also { activityFixture = it }
        } finally {
            instrumentation.runOnMainSync { monitor.removeLifecycleCallback(callback) }
        }
    }

    private fun sendHomeAndAwaitStop() {
        val owner = requireNotNull(activityFixture).owner
        val stopped = CountDownLatch(1)
        val monitor = ActivityLifecycleMonitorRegistry.getInstance()
        val callback = ActivityLifecycleCallback { activity, stage ->
            if (activity === owner && stage == Stage.STOPPED) stopped.countDown()
        }
        instrumentation.runOnMainSync { monitor.addLifecycleCallback(callback) }
        try {
            // Exercise the actual Home transition, not synthetic lifecycle state
            // control or global UI-idle synchronization of a live Flutter engine.
            context.startActivity(Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_HOME)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
            assertTrue("Home must stop, not destroy, the queue's activity",
                stopped.await(10, TimeUnit.SECONDS))
            instrumentation.runOnMainSync { assertFalse(owner.isDestroyed) }
        } finally {
            instrumentation.runOnMainSync { monitor.removeLifecycleCallback(callback) }
        }
    }

    private fun waitUntil(message: String, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 10_000
        while (SystemClock.elapsedRealtime() < deadline) {
            var success = false
            instrumentation.runOnMainSync { success = predicate() }
            if (success) return
            SystemClock.sleep(20)
        }
        fail(message)
    }

    @After fun cleanup() {
        instrumentation.runOnMainSync {
            host?.close()
            host = null
            DownloadQueueRuntime.current?.let { DownloadQueueRuntime.end(it) }
        }
        val owner = activityFixture?.owner
        activityFixture = null
        if (owner != null) {
            val destroyed = CountDownLatch(1)
            val monitor = ActivityLifecycleMonitorRegistry.getInstance()
            val callback = ActivityLifecycleCallback { activity, stage ->
                if (activity === owner && stage == Stage.DESTROYED) destroyed.countDown()
            }
            instrumentation.runOnMainSync {
                monitor.addLifecycleCallback(callback)
                if (owner.isDestroyed) destroyed.countDown() else owner.finish()
            }
            try {
                assertTrue("Queue activity must finish", destroyed.await(10, TimeUnit.SECONDS))
            } finally {
                instrumentation.runOnMainSync { monitor.removeLifecycleCallback(callback) }
            }
        }
        waitUntil("Service must fully stop between tests") { DownloadQueueRuntime.idle }
    }

    @Test fun manifestDeclaresPrivateDataSyncServiceAndPermissions() {
        val info = context.packageManager.getServiceInfo(
            ComponentName(context, DownloadForegroundService::class.java), 0,
        )
        assertFalse(info.exported)
        if (Build.VERSION.SDK_INT >= 29) {
            assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC, info.foregroundServiceType)
        }
        val permissions = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
            .requestedPermissions.orEmpty().toSet()
        assertTrue(permissions.contains(Manifest.permission.WAKE_LOCK))
        assertTrue(permissions.contains(Manifest.permission.FOREGROUND_SERVICE))
        assertTrue(permissions.contains("android.permission.FOREGROUND_SERVICE_DATA_SYNC"))
        assertTrue(permissions.contains("android.permission.POST_NOTIFICATIONS"))
    }

    @Test fun backgroundBeginRepliesExactlyOnceWithoutRequestingPermission() {
        val reply = Reply()
        launch().onActivity { owner ->
            val backgroundHost = DownloadQueueHost(owner, MethodChannel(Messenger(), "test"),
                { false }, { fail("Background start must not request permission") }, {})
            backgroundHost.begin(reply)
            backgroundHost.close()
            assertEquals(false, reply.value)
            assertEquals(1, reply.calls)
            assertTrue(DownloadQueueRuntime.idle)
        }
    }

    @Test @SdkSuppress(minSdkVersion = 33)
    fun destroyDuringPermissionRequestCompletesReplyOnceAndIgnoresLateGrant() {
        assumeFalse("Set POST_NOTIFICATIONS denied before starting instrumentation",
            BackgroundUpdate.hasNotificationPermission(context))
        val reply = Reply()
        var permissionReply: MethodChannel.Result? = null
        launch().onActivity { owner ->
            host = DownloadQueueHost(owner, MethodChannel(Messenger(), "test"), { true },
                { permissionReply = it }, {})
            host!!.begin(reply)
            assertNotNull(permissionReply)
            host!!.close()
            permissionReply!!.success(true)
            assertEquals(false, reply.value)
            assertEquals(1, reply.calls)
            assertTrue(DownloadQueueRuntime.idle)
        }
    }

    private fun startQueue(wake: () -> Unit = {}, pause: (String) -> Unit = {}): DownloadQueueSession {
        lateinit var lease: DownloadQueueSession
        val ready = CountDownLatch(1)
        var started = false
        launch().onActivity { owner ->
            lease = requireNotNull(DownloadQueueRuntime.reserve({ value -> started = value; ready.countDown() }, pause, wake))
            val intent = DownloadForegroundService.startIntent(owner, lease.token)
            if (Build.VERSION.SDK_INT >= 26) owner.startForegroundService(intent) else owner.startService(intent)
        }
        assertTrue("startForeground acknowledgement", ready.await(10, TimeUnit.SECONDS))
        assertTrue(started)
        return lease
    }

    @Test fun serviceRetainsWakeLockOnHomeAndReleasesOnExplicitEnd() {
        val lease = startQueue()
        val service = requireNotNull(lease.service)
        sendHomeAndAwaitStop()
        instrumentation.runOnMainSync {
            assertSame(lease, DownloadQueueRuntime.current)
            assertTrue(service.wakeLockHeld)
            assertTrue(service.update("作品", "第2章", "下载中", 0.5, 4096.0))
            DownloadQueueRuntime.end(lease)
            assertFalse(service.wakeLockHeld)
            assertFalse(service.update("旧队列", "", "", null, 0.0))
            assertFalse(service.setQueueActive(lease.token, true))
            assertFalse(service.wakeLockHeld)
        }
        waitUntil("Explicit end removes the service") { DownloadQueueRuntime.idle }
    }

    @Test fun idleReleasesCpuButRetainsServiceAndOnlyCurrentLeaseCanResume() {
        val paused = CountDownLatch(1)
        var wakes = 0
        val lease = startQueue(wake = { wakes++ }) { paused.countDown() }
        val service = requireNotNull(lease.service)
        instrumentation.runOnMainSync {
            assertTrue(service.wakeLockHeld)
            assertTrue(service.connectivityWatching)
            service.dispatchConnectivityWake(lease.token)
            assertEquals("Active transfers need no idle wake event", 0, wakes)
            assertTrue(service.setQueueActive(lease.token, false))
            assertFalse(service.wakeLockHeld)
            assertSame(lease, DownloadQueueRuntime.current)
            assertSame(service, lease.service)
        }
        // Waiting while the Activity is stopped must not require a new
        // background startForegroundService when the next transfer is ready.
        sendHomeAndAwaitStop()
        instrumentation.runOnMainSync {
            val previousWakes = wakes
            service.dispatchConnectivityWake(lease.token - 1)
            assertEquals(previousWakes, wakes)
            service.dispatchConnectivityWake(lease.token)
            assertEquals(previousWakes + 1, wakes)
            assertFalse(service.setQueueActive(lease.token - 1, true))
            assertFalse(service.wakeLockHeld)
            assertTrue(service.setQueueActive(lease.token, true))
            assertTrue(service.wakeLockHeld)
            service.dispatchConnectivityWake(lease.token)
            assertEquals("Reacquiring CPU disables idle wake events", previousWakes + 1, wakes)
            assertFalse(service.setQueueActive(lease.token - 1, false))
            assertTrue(service.wakeLockHeld)
            DownloadQueueRuntime.pause(lease, "notification")
            assertFalse(service.wakeLockHeld)
            assertFalse(service.setQueueActive(lease.token, true))
            assertFalse(service.wakeLockHeld)
            assertFalse(service.connectivityWatching)
            service.dispatchConnectivityWake(lease.token)
            assertEquals("Stopped leases cannot wake or reacquire", previousWakes + 1, wakes)
        }
        assertTrue("Pause still requests physical cancellation", paused.await(10, TimeUnit.SECONDS))
        waitUntil("Paused idle/active session fully stops") { DownloadQueueRuntime.idle }
    }

    @Test fun unexpectedServiceStopSignalsPauseAndReleasesWakeLock() {
        val paused = CountDownLatch(1)
        var reason: String? = null
        val lease = startQueue { reason = it; paused.countDown() }
        val service = requireNotNull(lease.service)
        instrumentation.runOnMainSync {
            assertTrue(context.stopService(Intent(context, DownloadForegroundService::class.java)))
        }
        assertTrue("Unexpected native stop must request Dart cancellation", paused.await(10, TimeUnit.SECONDS))
        assertEquals("service_stopped", reason)
        assertFalse(service.wakeLockHeld)
        waitUntil("Unexpected stop clears session ownership") { DownloadQueueRuntime.idle }
    }

    @Test fun grantedPermissionPublishesProgressAndWorkingNotificationPauseAction() {
        assumeFalse("Run this case with notifications granted and enabled",
            !DownloadForegroundService.notificationsVisible(context))
        val paused = CountDownLatch(1)
        val lease = startQueue { paused.countDown() }
        val manager = context.getSystemService(NotificationManager::class.java)
        instrumentation.runOnMainSync {
            assertTrue(requireNotNull(lease.service).update("通知作品", "第3章", "下载中", 0.25, 8192.0))
        }
        waitUntil("Updated queue notification appears") {
            manager.activeNotifications.any {
                it.id == DownloadForegroundService.NOTIFICATION_ID &&
                    it.notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() == "通知作品"
            }
        }
        val notification = manager.activeNotifications.single { it.id == DownloadForegroundService.NOTIFICATION_ID }.notification
        assertTrue(notification.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertEquals(1000, notification.extras.getInt(Notification.EXTRA_PROGRESS_MAX))
        assertEquals(250, notification.extras.getInt(Notification.EXTRA_PROGRESS))
        assertTrue(notification.extras.getCharSequence(Notification.EXTRA_TEXT).toString().contains("8 KiB/s"))
        assertEquals(1, notification.actions.size)
        notification.actions.single().actionIntent.send()
        assertTrue("The actual notification action requests pause", paused.await(10, TimeUnit.SECONDS))
        waitUntil("Action removes notification and service") {
            DownloadQueueRuntime.idle && manager.activeNotifications.none { it.id == DownloadForegroundService.NOTIFICATION_ID }
        }
    }

    @Test fun notificationPauseRequestsPhysicalDartPauseAndStopsService() {
        val paused = CountDownLatch(1)
        var reason: String? = null
        val lease = startQueue { reason = it; paused.countDown() }
        val service = requireNotNull(lease.service)
        instrumentation.runOnMainSync {
            service.onStartCommand(Intent(context, DownloadForegroundService::class.java)
                .setAction(DownloadForegroundService.ACTION_PAUSE)
                .putExtra(DownloadForegroundService.EXTRA_TOKEN, lease.token - 1), 0, 1)
            assertSame(lease, DownloadQueueRuntime.current)
            context.startService(Intent(context, DownloadForegroundService::class.java)
                .setAction(DownloadForegroundService.ACTION_PAUSE)
                .putExtra(DownloadForegroundService.EXTRA_TOKEN, lease.token))
        }
        assertTrue(paused.await(10, TimeUnit.SECONDS))
        assertEquals("notification", reason)
        assertFalse(service.wakeLockHeld)
        waitUntil("Pause action stops native service") { DownloadQueueRuntime.idle }
    }

    @Test @SdkSuppress(minSdkVersion = 35)
    fun dataSyncTimeoutRequestsPhysicalPauseAndReleasesImmediately() {
        val paused = CountDownLatch(1)
        var reason: String? = null
        val lease = startQueue { reason = it; paused.countDown() }
        val service = requireNotNull(lease.service)
        instrumentation.runOnMainSync {
            service.onTimeout(1, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            assertFalse(service.wakeLockHeld)
            assertNull(DownloadQueueRuntime.current)
        }
        assertTrue(paused.await(10, TimeUnit.SECONDS))
        assertEquals("timeout", reason)
        waitUntil("Timeout stops native service") { DownloadQueueRuntime.idle }
    }

    @Test @SdkSuppress(minSdkVersion = 33)
    fun deniedNotificationPermissionStillRunsRealForegroundService() {
        // Revoking our own permission during instrumentation can kill the test
        // process. Establish denial using adb before launching this suite.
        assumeFalse("Set POST_NOTIFICATIONS denied before starting instrumentation",
            BackgroundUpdate.hasNotificationPermission(context))
        val reply = Reply()
        val messenger = Messenger()
        var requested = false
        var cancelledResolver = false
        launch().onActivity { owner ->
            host = DownloadQueueHost(owner, MethodChannel(messenger, "test"), { true },
                { callback -> requested = true; callback.success(false) }, { cancelledResolver = true })
            host!!.begin(reply)
        }
        assertTrue(reply.done.await(10, TimeUnit.SECONDS))
        assertTrue(requested)
        assertEquals(true, reply.value)
        instrumentation.runOnMainSync {
            assertTrue(host!!.active)
            val service = requireNotNull(DownloadQueueRuntime.current?.service)
            assertTrue(service.wakeLockHeld)
            assertTrue(messenger.events.any {
                it.first == "downloadQueueNotificationVisibility" && (it.second as? Map<*, *>)?.get("visible") == false
            })
            val lease = requireNotNull(DownloadQueueRuntime.current)
            assertTrue(host!!.setActive(false))
            assertTrue(host!!.setActive(false))
            assertTrue(host!!.active)
            assertFalse(service.wakeLockHeld)
            service.dispatchConnectivityWake(lease.token)
            assertTrue(messenger.events.any {
                it.first == "downloadQueueWakeRequested" && (it.second as? Map<*, *>)?.get("reason") == "connectivity"
            })
            assertTrue(host!!.setActive(true))
            assertTrue(service.wakeLockHeld)
            DownloadQueueRuntime.pause(lease, "notification")
            assertTrue(cancelledResolver)
            assertFalse(service.wakeLockHeld)
            assertFalse(host!!.setActive(true))
            assertFalse(service.wakeLockHeld)
            assertTrue(messenger.events.any {
                it.first == "downloadQueuePauseRequested" && (it.second as? Map<*, *>)?.get("reason") == "notification"
            })
            host!!.end()
            assertEquals(1, reply.calls)
        }
        waitUntil("Denied-notification queue stops cleanly") { DownloadQueueRuntime.idle }
    }
}
