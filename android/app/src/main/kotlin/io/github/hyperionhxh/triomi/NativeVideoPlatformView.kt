package io.github.hyperionhxh.triomi

import android.content.Context
import android.content.pm.ApplicationInfo
import android.graphics.Color
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.graphics.SurfaceTexture
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.widget.FrameLayout
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * TextureView + MediaPlayer playback path for Android.
 *
 * API35 x86_64 testing showed that a VideoView/SurfaceView embedded in Flutter
 * can lose its buffers, and VideoView's Context+Uri overload can reject the
 * HTTP fixture with "No content provider". MediaPlayer.setDataSource(String)
 * plus a TextureView avoids both issues while keeping the player in Flutter.
 */
class NativeVideoViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(io.flutter.plugin.common.StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        NativeVideoPlatformView(context, viewId, messenger, args)
}

private class NativeVideoPlatformView(
    context: Context,
    viewId: Int,
    messenger: BinaryMessenger,
    args: Any?,
) : PlatformView, MethodChannel.MethodCallHandler, TextureView.SurfaceTextureListener {
    private val tag = "TriomiNativeVideo"
    private val debugLogging =
        (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    private val root = FrameLayout(context).apply { setBackgroundColor(Color.BLACK) }
    private val texture = TextureView(context).apply {
        surfaceTextureListener = this@NativeVideoPlatformView
        layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT,
        )
    }
    private val channel = MethodChannel(messenger, "triomi/native-video/$viewId")
    private val handler = Handler(Looper.getMainLooper())
    private var disposed = false
    private var currentUrl: String? = null
    private var player: MediaPlayer? = null
    private var outputSurface: Surface? = null
    private var prepared = false
    private var shouldPlay = true
    private var playbackRate = 1f
    // TextureView can be destroyed/recreated during rotation, backgrounding,
    // or hybrid-composition relayout. Keep the last position independently of
    // MediaPlayer so the replacement instance can resume deterministically.
    private var resumePositionMs = 0L
    private var lastDurationMs = 0L
    private var lastLoggedPositionMs = -1000L

    private val progressRunnable = object : Runnable {
        override fun run() {
            if (disposed) return
            emitState()
            val position = player?.let { lastPositionFrom(it) } ?: resumePositionMs
            if (position - lastLoggedPositionMs >= 1000L || position < lastLoggedPositionMs) {
                lastLoggedPositionMs = position
                debug("state url=${safeUrl(currentUrl)} prepared=$prepared playing=${stateMap()["playing"]} position=$position duration=$lastDurationMs")
            }
            handler.postDelayed(this, 250L)
        }
    }

    init {
        root.addView(texture)
        channel.setMethodCallHandler(this)
        handler.post(progressRunnable)
        val initialUrl = (args as? Map<*, *>)?.get("url")?.toString()
        if (!initialUrl.isNullOrBlank()) { currentUrl = initialUrl }
    }

    override fun getView(): View = root
    override fun onFlutterViewAttached(flutterView: android.view.View) = Unit
    override fun onFlutterViewDetached() = Unit

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "setUrl" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) result.error("invalid_url", "url is required", null)
                    else { setUrl(url); result.success(null) }
                }
                "play" -> {
                    shouldPlay = true
                    if (prepared) player?.start()
                    emitState(); result.success(null)
                }
                "pause" -> {
                    shouldPlay = false
                    if (prepared && player?.isPlaying == true) player?.pause()
                    emitState(); result.success(null)
                }
                "seek" -> {
                    val ms = call.argument<Number>("milliseconds")?.toInt() ?: 0
                    if (prepared) player?.seekTo(ms.coerceAtLeast(0))
                    result.success(null)
                }
                "setRate" -> {
                    playbackRate = (call.argument<Number>("rate")?.toFloat() ?: 1f).coerceIn(0.25f, 4f)
                    applyPlaybackRate(); result.success(null)
                }
                "getState" -> result.success(stateMap())
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            result.error("native_video_error", error.message, null)
        }
    }

    private fun setUrl(url: String) {
        debug("setUrl url=${safeUrl(url)} surface=${outputSurface != null}")
        currentUrl = url
        shouldPlay = true
        resumePositionMs = 0L
        lastDurationMs = 0L
        releasePlayer()
        prepareIfPossible()
    }

    private fun prepareIfPossible() {
        val url = currentUrl ?: return
        val surface = outputSurface ?: return
        if (disposed || player != null) return
        val mediaPlayer = MediaPlayer()
        player = mediaPlayer
        try {
            // `setDataSource(String)` expects a filesystem path for local media.
            // Dart's offline-first path passes `file:///...`; normalize that URI
            // here while leaving HTTP(S) URLs untouched.
            mediaPlayer.setDataSource(normalizeDataSource(url))
            mediaPlayer.setSurface(surface)
            mediaPlayer.setOnPreparedListener { p ->
                if (disposed || p !== player) {
                    try { p.release() } catch (_: Throwable) {}
                    return@setOnPreparedListener
                }
                prepared = true
                lastDurationMs = p.duration.toLong().coerceAtLeast(0L)
                debug("prepared duration=$lastDurationMs url=${safeUrl(url)} shouldPlay=$shouldPlay")
                val resume = if (lastDurationMs > 0L) {
                    resumePositionMs.coerceIn(0L, lastDurationMs)
                } else {
                    resumePositionMs.coerceIn(0L, Int.MAX_VALUE.toLong())
                }
                if (resume > 0L) {
                    try { p.seekTo(resume.toInt()) } catch (_: Throwable) {}
                }
                applyPlaybackRate()
                if (shouldPlay) p.start()
                emit(
                    "prepared",
                    mapOf("duration" to lastDurationMs, "position" to resume),
                )
                emitState()
            }
            mediaPlayer.setOnCompletionListener { p ->
                if (p !== player) return@setOnCompletionListener
                lastPositionFrom(p)?.let { resumePositionMs = it }
                debug("completed position=$resumePositionMs duration=$lastDurationMs url=${safeUrl(url)}")
                shouldPlay = false; emit("completed", null); emitState()
            }
            mediaPlayer.setOnErrorListener { p, what, extra ->
                if (p !== player) return@setOnErrorListener true
                lastPositionFrom(p)?.let { resumePositionMs = it }
                prepared = false; shouldPlay = false
                Log.e(tag, "error what=$what extra=$extra position=$resumePositionMs duration=$lastDurationMs")
                emit(
                    "error",
                    mapOf(
                        "what" to what,
                        "extra" to extra,
                        "message" to "MediaPlayer error $what/$extra",
                    ),
                )
                emitState(); true
            }
            mediaPlayer.prepareAsync()
        } catch (error: Throwable) {
            prepared = false
            if (debugLogging) Log.e(tag, "prepare exception url=${safeUrl(url)}", error)
            emit("error", mapOf("message" to (error.message ?: "prepare failed")))
            try { mediaPlayer.release() } catch (_: Throwable) {}
            if (player === mediaPlayer) player = null
        }
    }

    private fun applyPlaybackRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || !prepared) return
        val p = player ?: return
        try {
            // Nonzero playbackParams can start MediaPlayer, including after
            // a paused Surface rebuild. Restore the explicit pause intent.
            p.playbackParams = p.playbackParams.setSpeed(playbackRate)
            if (!shouldPlay && p.isPlaying) p.pause()
        } catch (_: Throwable) {}
    }

    private fun normalizeDataSource(url: String): String =
        if (url.startsWith("file://", ignoreCase = true)) {
            Uri.parse(url).path ?: url
        } else {
            url
        }

    private fun stateMap(): Map<String, Any> {
        val p = player
        val pos = if (prepared && p != null) lastPositionFrom(p) ?: resumePositionMs else resumePositionMs
        val dur = if (prepared && p != null) {
            try { p.duration.toLong().coerceAtLeast(0L) } catch (_: Throwable) { lastDurationMs }
        } else {
            lastDurationMs
        }
        val playing = if (prepared && p != null) try { p.isPlaying } catch (_: Throwable) { false } else false
        return mapOf("position" to pos, "duration" to dur, "playing" to playing, "url" to (currentUrl ?: ""))
    }

    private fun emitState() = emit("state", stateMap())
    private fun emit(method: String, args: Any?) { if (!disposed) channel.invokeMethod(method, args) }

    private fun lastPositionFrom(mediaPlayer: MediaPlayer): Long? =
        try { mediaPlayer.currentPosition.toLong().coerceAtLeast(0L) } catch (_: Throwable) { null }

    private fun releasePlayer(preservePosition: Boolean = false) {
        val old = player; player = null; prepared = false
        if (preservePosition && old != null) {
            lastPositionFrom(old)?.let { resumePositionMs = it }
            try {
                lastDurationMs = old.duration.toLong().coerceAtLeast(0L)
            } catch (_: Throwable) {
            }
        }
        if (old != null) { try { old.reset() } catch (_: Throwable) {}; try { old.release() } catch (_: Throwable) {} }
    }

    override fun onSurfaceTextureAvailable(surfaceTexture: SurfaceTexture, width: Int, height: Int) {
        debug("surface available ${width}x$height")
        outputSurface?.release()
        outputSurface = Surface(surfaceTexture)
        prepareIfPossible()
    }
    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) = Unit
    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        debug("surface destroyed prepared=$prepared position=${stateMap()["position"]}")
        if (!disposed) {
            // Capture both the current position and whether playback was active
            // before releasing the old player. A new SurfaceTexture will create
            // a fresh MediaPlayer and seek back to this point.
            player?.let { mediaPlayer ->
                if (prepared) {
                    lastPositionFrom(mediaPlayer)?.let { resumePositionMs = it }
                    shouldPlay = try { mediaPlayer.isPlaying } catch (_: Throwable) { shouldPlay }
                }
            }
            releasePlayer(preservePosition = true)
        } else {
            releasePlayer()
        }
        outputSurface?.release()
        outputSurface = null
        return true
    }
    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit

    private fun debug(message: String) {
        if (debugLogging) Log.d(tag, message)
    }

    private fun safeUrl(url: String?): String {
        if (url.isNullOrBlank()) return "<none>"
        return try {
            val parsed = Uri.parse(url)
            buildString {
                if (!parsed.scheme.isNullOrBlank()) append(parsed.scheme).append("://")
                if (!parsed.host.isNullOrBlank()) append(parsed.host)
                append(parsed.path ?: "")
            }
        } catch (_: Throwable) {
            "<invalid-url>"
        }
    }

    override fun dispose() {
        if (disposed) return
        disposed = true; handler.removeCallbacks(progressRunnable); channel.setMethodCallHandler(null)
        releasePlayer(); outputSurface?.release(); outputSurface = null; root.removeAllViews()
    }
}
