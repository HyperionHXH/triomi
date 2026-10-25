package io.github.hyperionhxh.triomi

import android.content.Context
import android.database.ContentObserver
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.provider.Settings
import kotlin.math.roundToInt

internal data class MediaVolumeReading(
    val index: Int,
    val minimum: Int,
    val maximum: Int,
    val fixed: Boolean,
    val muted: Boolean,
)

/** The only boundary allowed to write device volume; construction and observation are read-only. */
internal interface MediaVolumeDevice {
    fun read(): MediaVolumeReading
    fun setIndex(index: Int)
    fun startObserving(onChange: () -> Unit)
    fun stopObserving()
}

internal data class MediaVolumeState(
    val volume: Double? = null,
    val index: Int? = null,
    val minimum: Int? = null,
    val maximum: Int? = null,
    val canSet: Boolean = false,
    val muted: Boolean = false,
    val error: String? = null,
) {
    fun asMap(): Map<String, Any?> = mapOf(
        "mediaVolume" to volume,
        "mediaVolumeIndex" to index,
        "mediaVolumeMin" to minimum,
        "mediaVolumeMax" to maximum,
        "mediaVolumeCanSet" to canSet,
        "mediaVolumeMuted" to muted,
        "mediaVolumeError" to error,
    )
}

internal class MediaVolumeController(
    private val device: MediaVolumeDevice,
    private val handler: Handler,
    private val onChanged: (MediaVolumeState) -> Unit,
) {
    private var active = false
    private var disposed = false
    var state = MediaVolumeState()
        private set
    private val poll = object : Runnable {
        override fun run() {
            if (!active || disposed) return
            refresh()
            handler.postDelayed(this, 500)
        }
    }

    fun start() {
        if (disposed || active) return
        active = true
        try {
            device.startObserving { if (active && !disposed) refresh() }
        } catch (_: RuntimeException) {
            // Public device callbacks/settings notifications are only hints.
            // The bounded foreground poll also handles OEM/OS volume changes.
            device.stopObserving()
        }
        refresh()
        handler.postDelayed(poll, 500)
    }

    fun stop() {
        active = false
        handler.removeCallbacks(poll)
        device.stopObserving()
    }

    fun refresh(): MediaVolumeState {
        if (disposed) return state
        return publish(readState())
    }

    fun setVolume(volume: Double): MediaVolumeState {
        if (disposed) return state
        val before = readState()
        if (!volume.isFinite()) return publish(before.copy(error = "media_volume_invalid"))
        if (!before.canSet) return publish(before)
        val minimum = before.minimum!!
        val maximum = before.maximum!!
        val target = (volume.coerceIn(0.0, 1.0) * maximum).roundToInt().coerceIn(minimum, maximum)
        if (target == before.index && (!before.muted || target == 0)) return publish(before)
        try {
            device.setIndex(target)
        } catch (_: SecurityException) {
            return publish(readState().copy(canSet = false, error = "media_volume_permission_denied"))
        } catch (_: RuntimeException) {
            return publish(readState().copy(error = "media_volume_unavailable"))
        }
        val after = readState()
        return publish(if (after.index != target || after.muted && target > 0) {
            after.copy(error = after.error ?: "media_volume_not_applied")
        } else after)
    }

    private fun readState(): MediaVolumeState = try {
        val reading = device.read()
        require(reading.minimum >= 0 && reading.maximum >= reading.minimum)
        val index = reading.index.coerceIn(reading.minimum, reading.maximum)
        MediaVolumeState(
            // A nonzero platform minimum can still be audible: never label it mute.
            volume = if (reading.muted || reading.maximum == 0) 0.0 else index.toDouble() / reading.maximum,
            index = index,
            minimum = reading.minimum,
            maximum = reading.maximum,
            canSet = !reading.fixed && reading.maximum > reading.minimum,
            muted = reading.muted,
            error = if (reading.fixed || reading.maximum == reading.minimum) "media_volume_fixed" else null,
        )
    } catch (_: SecurityException) {
        MediaVolumeState(error = "media_volume_permission_denied")
    } catch (_: RuntimeException) {
        MediaVolumeState(error = "media_volume_unavailable")
    }

    private fun publish(next: MediaVolumeState): MediaVolumeState {
        if (state != next) {
            state = next
            if (active && !disposed) onChanged(next)
        }
        return next
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        stop()
    }
}

/** Uses only public Android APIs; no hidden VOLUME_CHANGED_ACTION contract. */
internal class AndroidMediaVolumeDevice(context: Context, private val handler: Handler) : MediaVolumeDevice {
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val resolver = context.contentResolver
    private var changed: (() -> Unit)? = null
    private var settingsRegistered = false
    private var devicesRegistered = false
    private val settings = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) { changed?.invoke() }
    }
    private val devices = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) { changed?.invoke() }
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) { changed?.invoke() }
    }

    override fun read() = MediaVolumeReading(
        index = audio.getStreamVolume(AudioManager.STREAM_MUSIC),
        minimum = if (Build.VERSION.SDK_INT >= 28) audio.getStreamMinVolume(AudioManager.STREAM_MUSIC) else 0,
        maximum = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
        fixed = audio.isVolumeFixed,
        muted = audio.isStreamMute(AudioManager.STREAM_MUSIC),
    )

    override fun setIndex(index: Int) {
        // Flags 0 avoids OS sound/vibration or ringer/DND policy changes.
        // Readback, not the requested value, is authoritative (safe-volume caps, routes).
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, index, 0)
    }

    override fun startObserving(onChange: () -> Unit) {
        stopObserving()
        changed = onChange
        try {
            resolver.registerContentObserver(Settings.System.CONTENT_URI, true, settings)
            settingsRegistered = true
        } catch (_: RuntimeException) { /* Polling still observes volume if settings are restricted. */ }
        try {
            audio.registerAudioDeviceCallback(devices, handler)
            devicesRegistered = true
        } catch (_: RuntimeException) { /* Polling also detects route-specific ranges. */ }
    }

    override fun stopObserving() {
        changed = null
        if (settingsRegistered) {
            settingsRegistered = false
            try { resolver.unregisterContentObserver(settings) } catch (_: RuntimeException) { }
        }
        if (devicesRegistered) {
            devicesRegistered = false
            try { audio.unregisterAudioDeviceCallback(devices) } catch (_: RuntimeException) { }
        }
    }
}
