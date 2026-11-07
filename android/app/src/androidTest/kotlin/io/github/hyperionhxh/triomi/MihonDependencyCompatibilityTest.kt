package io.github.hyperionhxh.triomi

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Rect
import androidx.test.ext.junit.runners.AndroidJUnit4
import app.cash.quickjs.QuickJs
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.protobuf.ProtoBuf
import kotlinx.serialization.protobuf.ProtoIntegerType
import kotlinx.serialization.protobuf.ProtoNumber
import kotlinx.serialization.protobuf.ProtoPacked
import kotlinx.serialization.protobuf.ProtoType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import tachiyomi.decoder.ImageDecoder

@OptIn(ExperimentalSerializationApi::class)
@RunWith(AndroidJUnit4::class)
class MihonDependencyCompatibilityTest {
    @Test fun quickJsExecutesScriptAndCompiledBytecode() {
        QuickJs.create().use { engine ->
            assertEquals("plugin-value", engine.evaluate("['plugin', 'value'].join('-')"))
            val bytecode = engine.compile("JSON.stringify({value: 6 * 7})", "extension.js")
            assertTrue(bytecode.isNotEmpty())
            assertEquals("{\"value\":42}", engine.execute(bytecode))
        }
    }

    @Test fun protobufPreservesPluginLongIdsAndPackedFields() {
        val original = PluginPayload(9223372036854775000L, -6286738698187452081L, listOf(1, 128, 65536))
        val bytes = ProtoBuf.encodeToByteArray(PluginPayload.serializer(), original)
        assertTrue(bytes.isNotEmpty())
        assertEquals(original, ProtoBuf.decodeFromByteArray(PluginPayload.serializer(), bytes))
    }

    @Test fun legacyImageDecoderDecodesActualPngPixels() {
        val original = Bitmap.createBitmap(2, 3, Bitmap.Config.ARGB_8888)
        val bytes = ByteArrayOutputStream().use { output ->
            try {
                original.eraseColor(Color.RED)
                original.setPixel(1, 2, Color.BLUE)
                assertTrue(original.compress(Bitmap.CompressFormat.PNG, 100, output))
                output.toByteArray()
            } finally {
                original.recycle()
            }
        }
        val decoder = ImageDecoder.newInstance(ByteArrayInputStream(bytes))
        assertNotNull(decoder)
        decoder!!
        try {
            assertEquals(2, decoder.width)
            assertEquals(3, decoder.height)
            val decoded = decoder.decode(Rect(0, 0, decoder.width, decoder.height))
            assertNotNull(decoded)
            decoded!!
            try {
                assertEquals(Color.RED, decoded.getPixel(0, 0))
                assertEquals(Color.BLUE, decoded.getPixel(1, 2))
            } finally {
                decoded.recycle()
            }
        } finally {
            decoder.recycle()
        }
    }

    @Serializable
    private data class PluginPayload(
        @ProtoNumber(1) val id: Long,
        @ProtoNumber(2) @ProtoType(ProtoIntegerType.SIGNED) val signedId: Long,
        @ProtoNumber(3) @ProtoPacked val pages: List<Int>,
    )
}
