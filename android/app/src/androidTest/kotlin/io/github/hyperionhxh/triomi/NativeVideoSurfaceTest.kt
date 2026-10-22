package io.github.hyperionhxh.triomi

import android.graphics.SurfaceTexture
import android.view.Surface
import android.view.TextureView
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer

/** Exercises the production view's callbacks without opening a network stream. */
@UnstableApi
@RunWith(AndroidJUnit4::class)
class NativeVideoSurfaceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val messenger = object : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) = Unit
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            callback?.reply(null)
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) = Unit
    }

    private class Harness(val view: PlatformView) {
        val callbacks = view as TextureView.SurfaceTextureListener
        val lifecycle = view as NativeVideoLifecycleOwner
        // Keep the production implementation private; observe the actual player
        // rather than replacing the callback behavior with a test-only policy.
        val player = view.javaClass.getDeclaredField("player").apply {
            isAccessible = true
        }.get(view) as ExoPlayer
        private val textures = mutableListOf<SurfaceTexture>()

        fun attach(): SurfaceTexture = SurfaceTexture(false).also {
            textures.add(it)
            callbacks.onSurfaceTextureAvailable(it, 1280, 720)
        }

        fun surface(): Surface? = view.javaClass.getDeclaredField("surface").apply {
            isAccessible = true
        }.get(view) as Surface?

        fun close() {
            try {
                view.dispose()
            } finally {
                textures.forEach { it.release() }
            }
        }
    }

    private fun withView(block: Harness.() -> Unit) {
        instrumentation.runOnMainSync {
            val previousOwner = NativeVideoLifecycle.active
            val harness = Harness(NativeVideoViewFactory(messenger).create(instrumentation.targetContext, 166, null))
            try {
                harness.player.setMediaItem(MediaItem.fromUri("https://triomi-playback.invalid/unopened"), 12_345L)
                harness.block()
            } finally {
                try {
                    harness.close()
                } finally {
                    NativeVideoLifecycle.active = previousOwner
                }
            }
        }
    }

    @Test fun resizeAndSurfaceReplacementPreservePlaybackIntentAndMedia() = withView {
        val item = player.currentMediaItem
        player.play()
        val first = attach()
        val oldSurface = surface()!!
        callbacks.onSurfaceTextureSizeChanged(first, 720, 1280)
        assertTrue(player.playWhenReady)
        assertTrue(callbacks.onSurfaceTextureDestroyed(first))
        assertFalse("The detached Surface wrapper must be released", oldSurface.isValid)
        assertTrue("Surface loss alone must not pause playback", player.playWhenReady)
        attach()
        assertTrue(player.playWhenReady)
        assertSame(item, player.currentMediaItem)
        assertEquals(12_345L, player.currentPosition)
        assertEquals("Surface callbacks must not prepare media", Player.STATE_IDLE, player.playbackState)
    }

    @Test fun surfaceReturnCannotResumePlaybackWhileActivityIsBackgrounded() = withView {
        player.play()
        val first = attach()
        callbacks.onSurfaceTextureDestroyed(first)
        lifecycle.onBackground(false)
        attach()
        assertFalse("A new surface is not permission to resume in background", player.playWhenReady)
        lifecycle.onForeground()
        assertTrue("Foreground must restore the intent from before detachment", player.playWhenReady)
    }

    @Test fun pauseThenStopRetainsResumeIntentAcrossSurfaceReplacement() = withView {
        player.play()
        val first = attach()
        lifecycle.onBackground(false)
        lifecycle.onBackground(false)
        callbacks.onSurfaceTextureDestroyed(first)
        attach()
        assertFalse(player.playWhenReady)
        lifecycle.onForeground()
        assertTrue("onStop must not overwrite the resume intent saved by onPause", player.playWhenReady)
    }

    @Test fun explicitlyPausedPlaybackStaysPausedAcrossResizeAndReattachment() = withView {
        player.pause()
        val first = attach()
        callbacks.onSurfaceTextureSizeChanged(first, 720, 1280)
        callbacks.onSurfaceTextureDestroyed(first)
        lifecycle.onBackground(false)
        attach()
        lifecycle.onForeground()
        assertFalse(player.playWhenReady)
    }

    @Test fun visiblePipAndBackgroundAudioContinueButStoppedPipPauses() = withView {
        player.play()
        val first = attach()
        lifecycle.onBackground(true)
        lifecycle.onPipChanged(true)
        callbacks.onSurfaceTextureDestroyed(first)
        attach()
        assertTrue("Allowed background/PiP playback must survive surface loss", player.playWhenReady)
        // MainActivity.onStop passes only the explicit background-audio option,
        // even when the platform's in-PiP flag has not changed yet.
        lifecycle.onBackground(false)
        assertFalse("Dismissed/invisible PiP cannot keep audio alive by itself", player.playWhenReady)
        lifecycle.onPipChanged(false)
        lifecycle.onForeground()
        assertTrue(player.playWhenReady)
    }

    @Test fun disposalDetachesSurfaceListenerAndIgnoresLateSurfaceCallbacks() = withView {
        val first = attach()
        val oldSurface = surface()!!
        val textureView = (view.view as android.view.ViewGroup).getChildAt(0) as TextureView
        view.dispose()
        assertEquals(null, textureView.surfaceTextureListener)
        assertFalse(oldSurface.isValid)
        assertTrue(callbacks.onSurfaceTextureDestroyed(first))
        assertEquals(null, surface())
        attach()
        assertEquals("A disposed view must not create another Surface", null, surface())
    }

    @Test fun explicitHlsMimeSupportsExtensionlessMediaAndDoesNotLeakToNextItem() = withView {
        val methods = view as MethodChannel.MethodCallHandler
        var error: String? = null
        val reply = object : MethodChannel.Result {
            override fun success(result: Any?) = Unit
            override fun error(code: String, message: String?, details: Any?) { error = code }
            override fun notImplemented() { error = "not_implemented" }
        }
        methods.onMethodCall(MethodCall("setUrl", mapOf("url" to "file:///triomi-fixture/manifest", "mimeType" to "application/vnd.apple.mpegurl")), reply)
        assertEquals(null, error)
        assertEquals(MimeTypes.APPLICATION_M3U8, player.currentMediaItem!!.localConfiguration!!.mimeType)
        methods.onMethodCall(MethodCall("setUrl", mapOf("url" to "file:///triomi-fixture/video.mp4")), reply)
        assertEquals(null, error)
        assertEquals(null, player.currentMediaItem!!.localConfiguration!!.mimeType)
    }

    @Test fun arbitraryHtmlMimeIsRejectedBeforeReplacingCurrentItem() = withView {
        val item = player.currentMediaItem
        var error: String? = null
        val reply = object : MethodChannel.Result {
            override fun success(result: Any?) = Unit
            override fun error(code: String, message: String?, details: Any?) { error = code }
            override fun notImplemented() = Unit
        }
        (view as MethodChannel.MethodCallHandler).onMethodCall(MethodCall("setUrl", mapOf("url" to "file:///triomi-fixture/page", "mimeType" to "text/html")), reply)
        assertEquals("native_video_error", error)
        assertSame(item, player.currentMediaItem)
    }
}
