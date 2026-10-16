package io.github.hyperionhxh.triomi

import android.app.Instrumentation
import android.app.Activity
import android.os.Bundle

/** Build with -Ptriomi.releaseAbiRunner=true. Install the test APK alone over
 * the production release, without replacing
 * the target app. Reflection must use its class loader so debug dependencies
 * cannot hide R8 trimming in the installed host. */
class ReleaseAbiInstrumentation : Instrumentation() {
    private val loader get() = targetContext.classLoader

    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val result = Bundle()
        try {
            externalPreferenceAbiSurvivesMinification()
            result.putString("preferenceAbi", "passed")
            nativeZstdResponseDecodesInInstalledHost()
            result.putString("nativeZstd", "passed")
            extensionJsonDependencySurvivesMinification()
            result.putString("extensionJson", "passed")
            result.putString("stream", "OK (3 release ABI checks)\n")
            finish(Activity.RESULT_OK, result)
        } catch (error: Throwable) {
            // Types only: never expose request/session data from target process.
            result.putString("failureType", error.javaClass.simpleName)
            result.putString("stream", "FAILED release ABI: ${error.javaClass.simpleName}\n")
            finish(Activity.RESULT_CANCELED, result)
        }
    }

    private fun externalPreferenceAbiSurvivesMinification() {
        val preference = loader.loadClass("androidx.preference.Preference")
        preference.getConstructor(android.content.Context::class.java)
        preference.getMethod("setKey", String::class.java)
        preference.getMethod("setTitle", CharSequence::class.java)
        val listener = loader.loadClass("androidx.preference.Preference\$OnPreferenceChangeListener")
        preference.getMethod("setOnPreferenceChangeListener", listener)
        loader.loadClass("androidx.preference.ListPreference")
            .getMethod("setEntryValues", Array<CharSequence>::class.java)
    }

    private fun extensionJsonDependencySurvivesMinification() {
        // Webtoons common-utils asks Injekt for Json in its static initializer,
        // then calls this exact Okio ABI from its external, unminified DEX.
        loader.loadClass("io.github.hyperionhxh.triomi.MihonHost")
            .getConstructor(android.content.Context::class.java).newInstance(targetContext)
        val jsonClass = loader.loadClass("kotlinx.serialization.json.Json")
        val injekt = loader.loadClass("uy.kohesive.injekt.InjektKt")
            .getMethod("getInjekt").invoke(null)
        val json = loader.loadClass("uy.kohesive.injekt.api.InjektFactory")
            .getMethod("getInstance", java.lang.reflect.Type::class.java).invoke(injekt, jsonClass)
        check(jsonClass.isInstance(json))
        val config = jsonClass.getMethod("getConfiguration").invoke(json)
        check(config.javaClass.getMethod("getIgnoreUnknownKeys").invoke(config) == true)
        check(config.javaClass.getMethod("getExplicitNulls").invoke(config) == false)
        val decode = loader.loadClass("kotlinx.serialization.json.okio.OkioStreamsKt")
            .getMethod("decodeFromBufferedSource", jsonClass,
                loader.loadClass("kotlinx.serialization.DeserializationStrategy"),
                loader.loadClass("okio.BufferedSource"))
        val bufferClass = loader.loadClass("okio.Buffer")
        val buffer = bufferClass.getConstructor().newInstance()
        bufferClass.getMethod("writeUtf8", String::class.java).invoke(buffer, "\"Triomi Json ABI\"")
        val serializer = loader.loadClass("kotlinx.serialization.internal.StringSerializer")
            .getField("INSTANCE").get(null)
        check(decode.invoke(null, json, serializer, buffer) == "Triomi Json ABI")
    }

    private fun nativeZstdResponseDecodesInInstalledHost() {
        // JNI looks up both compressor and decompressor classes even when the
        // application only decompresses. Assert before JNI to avoid process abort.
        loader.loadClass("com.squareup.zstd.ZstdCompressor")
        loader.loadClass("com.squareup.zstd.ZstdDecompressor")
        val text = "Triomi release zstd response"
        val payload = text.toByteArray(Charsets.UTF_8)
        // Single-segment Zstandard frame containing one last, uncompressed block.
        val blockHeader = (payload.size shl 3) or 1
        val frame = byteArrayOf(0x28, 0xb5.toByte(), 0x2f, 0xfd.toByte(), 0x20,
            payload.size.toByte(), blockHeader.toByte(), (blockHeader shr 8).toByte(),
            (blockHeader shr 16).toByte()) + payload
        val bufferClass = loader.loadClass("okio.Buffer")
        val buffer = bufferClass.getConstructor().newInstance()
        bufferClass.getMethod("write", ByteArray::class.java).invoke(buffer, frame)
        val zstd = loader.loadClass("okhttp3.zstd.Zstd")
        val source = zstd.getMethod("decompress", loader.loadClass("okio.BufferedSource"))
            .invoke(zstd.getField("INSTANCE").get(null), buffer)
        val okio = loader.loadClass("okio.Okio")
        val decoded = okio.getMethod("buffer", loader.loadClass("okio.Source")).invoke(null, source)
        try {
            check(text == loader.loadClass("okio.BufferedSource").getMethod("readUtf8").invoke(decoded))
        } finally {
            loader.loadClass("okio.Source").getMethod("close").invoke(decoded)
        }
    }
}
