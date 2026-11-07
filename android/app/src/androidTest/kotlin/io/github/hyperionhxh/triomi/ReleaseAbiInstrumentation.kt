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
            externalSourceModelAbiSurvivesMinification()
            result.putString("sourceModelAbi", "passed")
            serializedSourceModelsSurviveMinification()
            result.putString("sourceSerializationAbi", "passed")
            externalUtilityAbiSurvivesMinification()
            result.putString("utilityAbi", "passed")
            externalCoroutineAbiSurvivesMinification()
            result.putString("coroutineAbi", "passed")
            externalDependencyAbiSurvivesMinification()
            result.putString("dependencyAbi", "passed")
            result.putString("stream", "OK (8 release ABI checks)\n")
            finish(Activity.RESULT_OK, result)
        } catch (error: Throwable) {
            // Types only: never expose request/session data from target process.
            result.putString("failureType", error.javaClass.simpleName)
            result.putString("stream", "FAILED release ABI: ${error.javaClass.simpleName}\n")
            finish(Activity.RESULT_CANCELED, result)
        }
    }

    private fun externalDependencyAbiSurvivesMinification() {
        val quickJs = loader.loadClass("app.cash.quickjs.QuickJs")
        quickJs.getMethod("create")
        quickJs.getMethod("evaluate", String::class.java)
        quickJs.getMethod("compile", String::class.java, String::class.java)
        quickJs.getMethod("execute", ByteArray::class.java)
        quickJs.getMethod("close")
        check(quickJs.classLoader === loader)
        val engine = quickJs.getMethod("create").invoke(null)
        try {
            check((quickJs.getMethod("evaluate", String::class.java).invoke(engine, "6 * 7") as Number).toInt() == 42)
            val bytecode = quickJs.getMethod("compile", String::class.java, String::class.java)
                .invoke(engine, "JSON.stringify({value: 6 * 7})", "release-extension.js") as ByteArray
            check(bytecode.isNotEmpty())
            check(quickJs.getMethod("execute", ByteArray::class.java).invoke(engine, bytecode) == "{\"value\":42}")
        } finally {
            quickJs.getMethod("close").invoke(engine)
        }
        loader.loadClass("kotlinx.serialization.protobuf.ProtoBuf")
        loader.loadClass("kotlinx.serialization.protobuf.ProtoNumber").getMethod("number")
        loader.loadClass("kotlinx.serialization.protobuf.ProtoType").getMethod("type")
        loader.loadClass("kotlinx.serialization.protobuf.ProtoOneOf")
        loader.loadClass("kotlinx.serialization.protobuf.ProtoPacked")
        val integers = loader.loadClass("kotlinx.serialization.protobuf.ProtoIntegerType")
        for (name in listOf("DEFAULT", "FIXED", "SIGNED")) check(integers.getField(name).get(null) != null)
        val decoder = loader.loadClass("tachiyomi.decoder.ImageDecoder")
        val companion = loader.loadClass("tachiyomi.decoder.ImageDecoder\$Companion")
        val newDecoder = companion.getMethod("newInstance\$default", companion, java.io.InputStream::class.java,
            Boolean::class.javaPrimitiveType, ByteArray::class.java, Int::class.javaPrimitiveType, Any::class.java)
        val decode = decoder.getMethod("decode\$default", decoder, android.graphics.Rect::class.java,
            Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, Any::class.java)
        decoder.getMethod("getWidth")
        decoder.getMethod("getHeight")
        decoder.getMethod("recycle")
        check(decoder.classLoader === loader && companion.classLoader === loader)
        val bitmap = android.graphics.Bitmap.createBitmap(2, 3, android.graphics.Bitmap.Config.ARGB_8888)
        val png = java.io.ByteArrayOutputStream().use { output ->
            try {
                bitmap.eraseColor(android.graphics.Color.RED)
                bitmap.setPixel(1, 2, android.graphics.Color.BLUE)
                check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output))
                output.toByteArray()
            } finally {
                bitmap.recycle()
            }
        }
        java.io.ByteArrayInputStream(png).use { input ->
            val instance = newDecoder.invoke(null, decoder.getField("Companion").get(null), input,
                false, null, 6, null) ?: error("Release PNG decoder was not created")
            try {
                check(decoder.getMethod("getWidth").invoke(instance) == 2)
                check(decoder.getMethod("getHeight").invoke(instance) == 3)
                val decoded = decode.invoke(null, instance, android.graphics.Rect(0, 0, 2, 3),
                    0, 2, null) as? android.graphics.Bitmap ?: error("Release PNG decode failed")
                try {
                    check(decoded.width == 2 && decoded.height == 3)
                    check(decoded.getPixel(0, 0) == android.graphics.Color.RED)
                    check(decoded.getPixel(1, 2) == android.graphics.Color.BLUE)
                } finally {
                    decoded.recycle()
                }
            } finally {
                decoder.getMethod("recycle").invoke(instance)
            }
        }
        val chain = loader.loadClass("okhttp3.Interceptor\$Chain")
        chain.getMethod("getCookieJar")
        chain.getMethod("withCookieJar", loader.loadClass("okhttp3.CookieJar"))
        chain.getMethod("getEventListener")
        chain.getMethod("withDns", loader.loadClass("okhttp3.Dns"))
    }

    private fun externalCoroutineAbiSurvivesMinification() {
        val builders = loader.loadClass("kotlinx.coroutines.BuildersKt")
        val context = loader.loadClass("kotlin.coroutines.CoroutineContext")
        val function = loader.loadClass("kotlin.jvm.functions.Function2")
        builders.getMethod("runBlockingK", context, function)
        builders.getMethod("runBlockingK\$default", context, function,
            Int::class.javaPrimitiveType, Any::class.java)
        val jobClass = loader.loadClass("kotlinx.coroutines.Job")
        jobClass.getMethod("cancel\$default", jobClass, java.util.concurrent.CancellationException::class.java,
            Int::class.javaPrimitiveType, Any::class.java)
    }

    private fun externalUtilityAbiSurvivesMinification() {
        val helpers = loader.loadClass("eu.kanade.tachiyomi.util.JsoupExtensionsKt")
        val response = loader.loadClass("okhttp3.Response")
        val element = loader.loadClass("org.jsoup.nodes.Element")
        helpers.getMethod("asJsoup", response, String::class.java)
        helpers.getMethod("asJsoup\$default", response, String::class.java,
            Int::class.javaPrimitiveType, Any::class.java)
        helpers.getMethod("selectText\$default", element, String::class.java, String::class.java,
            Int::class.javaPrimitiveType, Any::class.java)
        helpers.getMethod("selectInt\$default", element, String::class.java, Int::class.javaPrimitiveType,
            Int::class.javaPrimitiveType, Any::class.java)
        helpers.getMethod("attrOrText", element, String::class.java)
        loader.loadClass("eu.kanade.tachiyomi.util.RxExtensionKt")
            .getMethod("awaitSingle", loader.loadClass("rx.Observable"),
                loader.loadClass("kotlin.coroutines.Continuation"))
    }

    private fun serializedSourceModelsSurviveMinification() {
        val jsonClass = loader.loadClass("kotlinx.serialization.json.Json")
        val json = jsonClass.getField("Default").get(null)
        val serializationStrategy = loader.loadClass("kotlinx.serialization.SerializationStrategy")
        val deserializationStrategy = loader.loadClass("kotlinx.serialization.DeserializationStrategy")
        val encode = jsonClass.getMethod("encodeToString", serializationStrategy, Any::class.java)
        val decode = jsonClass.getMethod("decodeFromString", deserializationStrategy, String::class.java)

        fun roundTrip(name: String, payload: String): Any {
            val type = loader.loadClass(name)
            val companion = type.getField("Companion").get(null)
            val serializer = companion.javaClass.getMethod("serializer").invoke(companion)
            check(loader.loadClass("kotlinx.serialization.KSerializer").isInstance(serializer))
            check(loader.loadClass("$name\$\$serializer").getField("INSTANCE").get(null) === serializer)
            val descriptor = loader.loadClass("kotlinx.serialization.KSerializer")
                .getMethod("getDescriptor").invoke(serializer)
            check(loader.loadClass("kotlinx.serialization.descriptors.SerialDescriptor")
                .getMethod("getSerialName").invoke(descriptor) == name)
            val model = decode.invoke(json, serializer, payload)
            check(type.isInstance(model))
            val encoded = encode.invoke(json, serializer, model) as String
            check(!encoded.contains("progress") && !encoded.contains("status") && !encoded.contains("uri"))
            return decode.invoke(json, serializer, encoded)
        }

        val page = roundTrip("eu.kanade.tachiyomi.source.model.Page",
            "{\"index\":6,\"url\":\"/fixture\",\"imageUrl\":\"https://fixture.invalid/image\"}")
        check(page.javaClass.getMethod("getIndex").invoke(page) == 6)
        check(page.javaClass.getMethod("getUrl").invoke(page) == "/fixture")
        check(page.javaClass.getMethod("getImageUrl").invoke(page) == "https://fixture.invalid/image")
        check(page.javaClass.getMethod("getUri").invoke(page) == null)
        check(page.javaClass.getMethod("getProgress").invoke(page) == 0)
        check(page.javaClass.getMethod("getStatus").invoke(page).javaClass.name ==
            "eu.kanade.tachiyomi.source.model.Page\$State\$Queue")
        val preview = roundTrip("eu.kanade.tachiyomi.source.PagePreviewInfo",
            "{\"index\":2,\"imageUrl\":\"https://fixture.invalid/preview\"}")
        check(preview.javaClass.getMethod("getIndex").invoke(preview) == 2)
        val progress = preview.javaClass.getMethod("getProgress").invoke(preview)
        check(loader.loadClass("kotlinx.coroutines.flow.StateFlow").getMethod("getValue").invoke(progress) == -1)
        val previewPage = roundTrip("eu.kanade.tachiyomi.source.PagePreviewPage",
            "{\"page\":1,\"pagePreviews\":[{\"index\":2,\"imageUrl\":\"https://fixture.invalid/preview\"}]," +
                "\"hasNextPage\":true,\"pagePreviewPages\":4}")
        check(previewPage.javaClass.getMethod("getPagePreviewPages").invoke(previewPage) == 4)
        check(previewPage.javaClass.getMethod("getHasNextPage").invoke(previewPage) == true)
        check((previewPage.javaClass.getMethod("getPagePreviews").invoke(previewPage) as List<*>).size == 1)
    }

    private fun externalSourceModelAbiSurvivesMinification() {
        val filterList = loader.loadClass("eu.kanade.tachiyomi.source.model.FilterList")
        val filters = filterList.getConstructor(List::class.java).newInstance(emptyList<Any>())
        check((filters as List<*>).isEmpty())
        check(filterList.getMethod("getList").invoke(filters) == emptyList<Any>())
        check(filterList.getMethod("component1").invoke(filters) == emptyList<Any>())
        val copy = filterList.getMethod("copy", List::class.java).invoke(filters, emptyList<Any>())
        check(copy is List<*> && copy.isEmpty())
        val exception = loader.loadClass("eu.kanade.tachiyomi.network.HttpException")
        val failure = exception.getConstructor(Int::class.javaPrimitiveType).newInstance(401)
        check(exception.getMethod("getCode").invoke(failure) == 401)
        check(failure is IllegalStateException)
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
