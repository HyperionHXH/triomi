package io.github.hyperionhxh.triomi

import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer

/** Uses the production channel consumer with a controllable device, never the emulator's volume. */
@UnstableApi
@RunWith(AndroidJUnit4::class)
class MediaVolumeTest {
    private class Device : MediaVolumeDevice {
        var current = MediaVolumeReading(index = 5, minimum = 2, maximum = 12, fixed = false, muted = false)
        val writes = mutableListOf<Int>()
        var listener: (() -> Unit)? = null
        var denied = false
        var unreadable = false
        override fun read(): MediaVolumeReading {
            if (unreadable) throw SecurityException()
            return current
        }
        override fun setIndex(index: Int) {
            if (denied) throw SecurityException()
            writes.add(index)
            current = current.copy(index = index, muted = false)
        }
        override fun startObserving(onChange: () -> Unit) { listener = onChange }
        override fun stopObserving() { listener = null }
        fun external(index: Int, minimum: Int = current.minimum, maximum: Int = current.maximum) {
            current = current.copy(index = index, minimum = minimum, maximum = maximum)
            listener?.invoke()
        }
    }

    private class Messenger : BinaryMessenger {
        val events = mutableListOf<MethodCall>()
        override fun send(channel: String, message: ByteBuffer?) {
            if (message != null) events.add(StandardMethodCodec.INSTANCE.decodeMethodCall(message.duplicate().apply { rewind() }))
        }
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            send(channel, message)
            callback?.reply(null)
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) = Unit
    }

    private fun withPlayer(block: (Device, Messenger, io.flutter.plugin.platform.PlatformView) -> Unit) {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val previousOwner = NativeVideoLifecycle.active
            val device = Device()
            val messenger = Messenger()
            val view = NativeVideoViewFactory(messenger) { _, handler, changed ->
                MediaVolumeController(device, handler, changed)
            }.create(InstrumentationRegistry.getInstrumentation().targetContext, 184, null)
            try {
                block(device, messenger, view)
            } finally {
                view.dispose()
                NativeVideoLifecycle.active = previousOwner
            }
        }
    }

    private fun call(view: io.flutter.plugin.platform.PlatformView, method: String, args: Map<String, Any?>? = null): Any? {
        var value: Any? = null
        (view as MethodChannel.MethodCallHandler).onMethodCall(MethodCall(method, args), object : MethodChannel.Result {
            override fun success(result: Any?) { value = result }
            override fun error(code: String, message: String?, details: Any?) { throw AssertionError("$code: $message") }
            override fun notImplemented() { throw AssertionError("Unimplemented $method") }
        })
        return value
    }
    @Test fun androidAdapterReadsActualMusicStreamWithoutChangingIt() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val context = instrumentation.targetContext
            val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val before = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
            val device = AndroidMediaVolumeDevice(context, Handler(Looper.getMainLooper()))
            val reading = device.read()
            assertEquals(before, reading.index)
            assertEquals(audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC), reading.maximum)
            assertEquals(if (Build.VERSION.SDK_INT >= 28) audio.getStreamMinVolume(AudioManager.STREAM_MUSIC) else 0, reading.minimum)
            assertEquals(audio.isStreamMute(AudioManager.STREAM_MUSIC), reading.muted)
            assertEquals(audio.isVolumeFixed, reading.fixed)
            assertEquals(before, audio.getStreamVolume(AudioManager.STREAM_MUSIC))
        }
    }


    @Test fun openingChangingSpeedAndEpisodesNeverWriteDeviceVolume() = withPlayer { device, _, view ->
        val initial = call(view, "getState") as Map<*, *>
        assertEquals(5.0 / 12, initial["mediaVolume"] as Double, .00001)
        assertEquals(2, initial["mediaVolumeMin"])
        assertEquals(12, initial["mediaVolumeMax"])
        call(view, "setUrl", mapOf("url" to "file:///triomi-fixture/one.mp4"))
        call(view, "setRate", mapOf("rate" to 1.5))
        call(view, "setUrl", mapOf("url" to "file:///triomi-fixture/two.mp4"))
        call(view, "setRate", mapOf("rate" to 2.0))
        assertTrue(device.writes.isEmpty())
    }

    @Test fun settingVolumeSnapsToCurrentDeviceBoundsAndReturnsReadback() = withPlayer { device, _, view ->
        val result = call(view, "setMediaVolume", mapOf("volume" to .46)) as Map<*, *>
        assertEquals(listOf(6), device.writes)
        assertEquals(.5, result["mediaVolume"] as Double, .00001)
        assertEquals(6, result["mediaVolumeIndex"])
        call(view, "setMediaVolume", mapOf("volume" to .48))
        assertEquals("The same snapped step must not be written repeatedly", listOf(6), device.writes)
        call(view, "setMediaVolume", mapOf("volume" to -1.0))
        call(view, "setMediaVolume", mapOf("volume" to 2.0))
        assertEquals(listOf(6, 2, 12), device.writes)
        val atMinimum = call(view, "setMediaVolume", mapOf("volume" to 0.0)) as Map<*, *>
        assertEquals(2.0 / 12, atMinimum["mediaVolume"] as Double, .00001)
        assertEquals(false, atMinimum["mediaVolumeMuted"])
    }

    @Test fun physicalKeysAndRouteChangesUpdateConsumerWithoutWritingBack() = withPlayer { device, messenger, view ->
        device.external(9)
        var state = messenger.events.last { it.method == "state" }.arguments as Map<*, *>
        assertEquals(.75, state["mediaVolume"] as Double, .00001)
        device.external(3, minimum = 0, maximum = 6)
        state = messenger.events.last { it.method == "state" }.arguments as Map<*, *>
        assertEquals(.5, state["mediaVolume"] as Double, .00001)
        assertEquals(6, state["mediaVolumeMax"])
        assertTrue(device.writes.isEmpty())
        call(view, "setMediaVolume", mapOf("volume" to 1.0))
        assertEquals(listOf(6), device.writes)
    }

    @Test fun fixedMutedAndPermissionFailuresReturnHonestDeviceState() = withPlayer { device, _, view ->
        device.current = device.current.copy(fixed = true)
        var state = call(view, "setMediaVolume", mapOf("volume" to 1.0)) as Map<*, *>
        assertEquals(false, state["mediaVolumeCanSet"])
        assertEquals("media_volume_fixed", state["mediaVolumeError"])
        assertTrue(device.writes.isEmpty())
        device.current = device.current.copy(fixed = false, index = 2, muted = true)
        state = call(view, "getMediaVolume") as Map<*, *>
        assertEquals(0.0, state["mediaVolume"])
        assertTrue(device.writes.isEmpty())
        device.denied = true
        state = call(view, "setMediaVolume", mapOf("volume" to .8)) as Map<*, *>
        assertEquals("media_volume_permission_denied", state["mediaVolumeError"])
        assertEquals(0.0, state["mediaVolume"])
        assertTrue(device.writes.isEmpty())
        device.unreadable = true
        state = call(view, "getMediaVolume") as Map<*, *>
        assertEquals(null, state["mediaVolume"])
        assertEquals(false, state["mediaVolumeCanSet"])
    }

    @Test fun observerStopsInBackgroundAndDisposalAndResumesReadOnlyInForegroundOrPip() = withPlayer { device, messenger, view ->
        val lifecycle = view as NativeVideoLifecycleOwner
        assertTrue(device.listener != null)
        lifecycle.onBackground(false)
        assertEquals(null, device.listener)
        device.external(8)
        lifecycle.onForeground()
        assertTrue(device.listener != null)
        assertEquals(8.0 / 12, (call(view, "getState") as Map<*, *>)["mediaVolume"] as Double, .00001)
        lifecycle.onBackground(true)
        assertEquals(null, device.listener)
        lifecycle.onPipChanged(true)
        assertTrue(device.listener != null)
        lifecycle.onBackground(true, visiblePip = true)
        assertTrue("PiP remains observed even if onPause follows the PiP callback", device.listener != null)
        val lateCallback = device.listener!!
        view.dispose()
        assertEquals(null, device.listener)
        val count = messenger.events.size
        lateCallback()
        lifecycle.onForeground()
        lifecycle.onPipChanged(true)
        assertEquals(count, messenger.events.size)
        assertFalse(device.listener != null)
        assertTrue(device.writes.isEmpty())
    }

    @Test fun periodicReadCatchesUnannouncedOsChangesAndStopCancelsIt() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val device = Device()
        val observed = mutableListOf<MediaVolumeState>()
        lateinit var controller: MediaVolumeController
        instrumentation.runOnMainSync {
            controller = MediaVolumeController(device, Handler(Looper.getMainLooper())) { observed.add(it) }
            controller.start()
            device.current = device.current.copy(index = 10)
        }
        // Instrumentation only; production uses the main-loop timer, never a hidden volume broadcast.
        Thread.sleep(650)
        instrumentation.runOnMainSync {
            assertEquals(10.0 / 12, observed.last().volume!!, .00001)
            controller.stop()
            assertEquals(null, device.listener)
            assertTrue(device.writes.isEmpty())
            controller.dispose()
        }
    }
}
