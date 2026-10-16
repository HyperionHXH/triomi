package io.github.hyperionhxh.triomi

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.widget.FrameLayout
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.VideoSize
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.SubtitleView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

interface NativeVideoLifecycleOwner {
    fun onBackground(allowAudio: Boolean)
    fun onForeground()
    fun onPipChanged(inPip: Boolean)
}
object NativeVideoLifecycle {
    var active: NativeVideoLifecycleOwner? = null
    var inPip = false
}
class NativeVideoViewFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(io.flutter.plugin.common.StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        NativeVideoPlatformView(context, viewId, messenger)
}

/** Media3 with the already verified hybrid-composition TextureView surface. */
@UnstableApi
private class NativeVideoPlatformView(
    private val context: Context,
    viewId: Int,
    messenger: BinaryMessenger,
) : PlatformView, MethodChannel.MethodCallHandler, TextureView.SurfaceTextureListener, NativeVideoLifecycleOwner {
    private val root = FrameLayout(context).apply { setBackgroundColor(Color.BLACK) }
    private val texture = TextureView(context).apply {
        surfaceTextureListener = this@NativeVideoPlatformView
        layoutParams = FrameLayout.LayoutParams(-1, -1)
    }
    private val subtitles = SubtitleView(context).apply {
        layoutParams = FrameLayout.LayoutParams(-1, -1)
        setUserDefaultStyle()
        setUserDefaultTextSize()
    }
    private val channel = MethodChannel(messenger, "triomi/native-video/$viewId")
    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var currentUrl: String? = null
    @Volatile private var currentHeaders: Map<String, String> = emptyMap()
    private var surface: Surface? = null
    private var disposed = false
    private var announcedReady = false
    private var resumeAfterSurface = false
    private var backgroundAudio = false
    private var fit = "contain"
    private var videoWidth = 0
    private var videoHeight = 0
    private val dataSource = ResolvingDataSource.Factory(
        DefaultDataSource.Factory(context, DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(false)),
    ) { spec ->
        val origin = currentUrl?.let(Uri::parse)
        val sameOrigin = origin != null && origin.scheme == spec.uri.scheme && origin.authority == spec.uri.authority
        val headers = currentHeaders.filterKeys {
            sameOrigin || it.lowercase() !in listOf("cookie", "authorization")
        }
        spec.withRequestHeaders(headers)
    }
    private val player = ExoPlayer.Builder(context)
        .setMediaSourceFactory(DefaultMediaSourceFactory(dataSource))
        .setAudioAttributes(AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
        .setHandleAudioBecomingNoisy(true)
        .build()
    private val ticker = object : Runnable {
        override fun run() {
            if (disposed) return
            emitState()
            handler.postDelayed(this, 500)
        }
    }

    init {
        NativeVideoLifecycle.active = this
        root.addView(texture)
        root.addView(subtitles)
        channel.setMethodCallHandler(this)
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (disposed) return
                if (state == Player.STATE_READY && !announcedReady) {
                    announcedReady = true
                    emit("prepared", stateMap())
                    updateBackgroundService()
                }
                if (state == Player.STATE_ENDED) {
                    emit("completed", stateMap())
                }
                emitState()
            }
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                emitState()
            }
            override fun onPlayerError(error: PlaybackException) {
                // Never include media URLs, query tokens, headers or upstream bodies.
                emit("error", mapOf("message" to "Media3 ${error.errorCodeName}",
                    "what" to error.errorCode, "extra" to 0))
                stopBackgroundService()
            }
            override fun onVideoSizeChanged(size: VideoSize) {
                videoWidth = (size.width * size.pixelWidthHeightRatio).toInt()
                videoHeight = size.height
                fitVideo()
            }
            override fun onCues(cueGroup: CueGroup) {
                subtitles.setCues(cueGroup.cues)
            }
        })
        handler.post(ticker)
    }

    override fun getView(): View = root
    override fun onFlutterViewAttached(flutterView: View) = Unit
    override fun onFlutterViewDetached() = Unit

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "setUrl" -> {
                    val url = requireNotNull(call.argument<String>("url"))
                    val uri = Uri.parse(url)
                    require(uri.scheme in listOf("http", "https", "file", "content"))
                    require(uri.userInfo == null)
                    currentUrl = url
                    currentHeaders = call.argument<Map<String, String>>("headers") ?: emptyMap()
                    announcedReady = false
                    resumeOnForeground = false
                    resumeAfterSurface = false
                    val position = (call.argument<Number>("startMilliseconds")?.toLong() ?: 0L).coerceAtLeast(0)
                    player.setMediaItem(MediaItem.Builder().setUri(uri)
                        .setMediaMetadata(MediaMetadata.Builder()
                            .setTitle(call.argument<String>("title") ?: "Triomi").build())
                        .build(), position)
                    player.prepare()
                    player.playWhenReady = true
                    result.success(null)
                }
                "play" -> { player.play(); updateBackgroundService(); result.success(null) }
                "pause" -> { player.pause(); result.success(null) }
                "seek" -> {
                    val duration = player.duration
                    val target = (call.argument<Number>("milliseconds")?.toLong() ?: 0L).coerceAtLeast(0)
                    player.seekTo(if (duration > 0) target.coerceAtMost(duration) else target)
                    result.success(null)
                }
                "setRate" -> {
                    player.setPlaybackSpeed((call.argument<Number>("rate")?.toFloat() ?: 1f).coerceIn(.5f, 3f))
                    result.success(null)
                }
                "setVolume" -> {
                    player.volume = (call.argument<Number>("volume")?.toFloat() ?: 1f).coerceIn(0f, 1f)
                    result.success(null)
                }
                "setFit" -> {
                    val value = call.argument<String>("fit") ?: "contain"
                    require(value in listOf("contain", "cover", "fill"))
                    fit = value; fitVideo(); result.success(null)
                }
                "setBackgroundAudio" -> {
                    backgroundAudio = call.argument<Boolean>("enabled") == true
                    if (backgroundAudio) updateBackgroundService() else stopBackgroundService()
                    result.success(null)
                }
                "subtitleTracks" -> result.success(subtitleTracks())
                "selectSubtitle" -> {
                    val id = call.argument<String>("id")
                    val builder = player.trackSelectionParameters.buildUpon()
                        .clearOverridesOfType(C.TRACK_TYPE_TEXT)
                        .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, id == null)
                    if (id != null) {
                        val parts = id.split(':').map(String::toInt)
                        require(parts.size == 2)
                        val group = player.currentTracks.groups[parts[0]].mediaTrackGroup
                        require(group.type == C.TRACK_TYPE_TEXT)
                        builder.addOverride(TrackSelectionOverride(group, parts[1]))
                    }
                    player.trackSelectionParameters = builder.build()
                    result.success(null)
                }
                "getState" -> result.success(stateMap())
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            result.error("native_video_error", "Media3 operation failed", null)
        }
    }

    private fun subtitleTracks(): List<Map<String, Any>> = buildList {
        player.currentTracks.groups.forEachIndexed { groupIndex, group ->
            if (group.type == C.TRACK_TYPE_TEXT) {
                for (track in 0 until group.length) {
                    if (!group.isTrackSupported(track)) continue
                    val format = group.getTrackFormat(track)
                    add(mapOf("id" to "$groupIndex:$track",
                        "title" to (format.label ?: format.language ?: "字幕 ${track + 1}"),
                        "selected" to group.isTrackSelected(track)))
                }
            }
        }
    }

    private fun stateMap(): Map<String, Any> = mapOf(
        "position" to player.currentPosition.coerceAtLeast(0),
        "duration" to player.duration.coerceAtLeast(0),
        "playing" to player.isPlaying,
    )
    private fun emitState() = emit("state", stateMap())
    private fun emit(method: String, args: Any?) {
        if (!disposed) channel.invokeMethod(method, args)
    }

    private fun updateBackgroundService() {
        if (!backgroundAudio || !announcedReady || !player.playWhenReady) return
        BackgroundPlaybackService.player = player
        context.startService(Intent(context, BackgroundPlaybackService::class.java))
    }
    private fun stopBackgroundService() {
        if (BackgroundPlaybackService.player !== player) return
        context.stopService(Intent(context, BackgroundPlaybackService::class.java))
        BackgroundPlaybackService.detach(player)
    }

    private var resumeOnForeground = false
    override fun onBackground(allowAudio: Boolean) {
        if (allowAudio) return
        resumeOnForeground = player.playWhenReady
        player.pause()
    }
    override fun onForeground() {
        if (resumeOnForeground) {
            resumeOnForeground = false
            player.play()
        }
    }
    override fun onPipChanged(inPip: Boolean) {
        emit("pip", mapOf("enabled" to inPip))
        if (inPip && resumeOnForeground) {
            resumeOnForeground = false
            player.play()
        }
    }

    override fun onSurfaceTextureAvailable(value: SurfaceTexture, width: Int, height: Int) {
        surface?.release()
        surface = Surface(value)
        player.setVideoSurface(surface)
        if (resumeAfterSurface) {
            resumeAfterSurface = false
            player.play()
        }
        fitVideo()
    }
    override fun onSurfaceTextureSizeChanged(value: SurfaceTexture, width: Int, height: Int) = fitVideo()
    override fun onSurfaceTextureDestroyed(value: SurfaceTexture): Boolean {
        player.clearVideoSurface()
        if (!backgroundAudio && !NativeVideoLifecycle.inPip) {
            resumeAfterSurface = player.playWhenReady || resumeOnForeground
            player.pause()
        }
        surface?.release(); surface = null
        return true
    }
    override fun onSurfaceTextureUpdated(value: SurfaceTexture) = Unit
    private fun fitVideo() {
        val width = texture.width.toFloat(); val height = texture.height.toFloat()
        if (videoWidth <= 0 || videoHeight <= 0 || width <= 0 || height <= 0) return
        val scale = if (fit == "cover") maxOf(width / videoWidth, height / videoHeight)
            else minOf(width / videoWidth, height / videoHeight)
        texture.setTransform(Matrix().apply {
            if (fit != "fill") {
                setScale(videoWidth * scale / width, videoHeight * scale / height, width / 2, height / 2)
            }
        })
    }
    override fun dispose() {
        if (disposed) return
        disposed = true
        if (NativeVideoLifecycle.active === this) NativeVideoLifecycle.active = null
        handler.removeCallbacks(ticker)
        channel.setMethodCallHandler(null)
        stopBackgroundService()
        player.release()
        surface?.release(); surface = null
        root.removeAllViews()
    }
}
