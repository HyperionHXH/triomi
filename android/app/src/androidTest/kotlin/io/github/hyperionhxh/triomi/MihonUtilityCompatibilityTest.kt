package io.github.hyperionhxh.triomi

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import eu.kanade.tachiyomi.network.MihonRequestOwner
import eu.kanade.tachiyomi.network.MihonRequestScope
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.source.online.HttpSource
import eu.kanade.tachiyomi.source.online.MihonRuntime
import eu.kanade.tachiyomi.util.asJsoup
import eu.kanade.tachiyomi.util.attrOrText
import eu.kanade.tachiyomi.util.awaitSingle
import eu.kanade.tachiyomi.util.selectInt
import eu.kanade.tachiyomi.util.selectText
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.ForwardingSource
import okio.buffer
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import rx.Observable
import rx.subscriptions.Subscriptions
import java.io.IOException
import java.nio.charset.Charset
import java.lang.reflect.InvocationTargetException
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get

@RunWith(AndroidJUnit4::class)
class MihonUtilityCompatibilityTest {
    @Test fun pluginCoroutineEntrypointsRunSuspendingWorkPropagateErrorsAndCancelRealJobs() {
        val builders = Class.forName("kotlinx.coroutines.BuildersKt")
        val run = builders.getMethod("runBlockingK", CoroutineContext::class.java, Function2::class.java)
        val defaults = builders.getMethod("runBlockingK\$default", CoroutineContext::class.java,
            Function2::class.java, Int::class.javaPrimitiveType, Any::class.java)
        val block: suspend CoroutineScope.() -> String = {
            delay(1)
            "suspended fixture result"
        }
        assertEquals("suspended fixture result", run.invoke(null, EmptyCoroutineContext, block))
        assertEquals("suspended fixture result", defaults.invoke(null, null, block, 1, null))
        val failure = IllegalStateException("coroutine fixture failure")
        val failing: suspend CoroutineScope.() -> String = { delay(1); throw failure }
        assertSame(failure, assertThrows(InvocationTargetException::class.java) {
            defaults.invoke(null, null, failing, 1, null)
        }.cause)
        val parent = Job()
        val child = Job(parent)
        try {
            Job::class.java.getMethod("cancel\$default", Job::class.java, CancellationException::class.java,
                Int::class.javaPrimitiveType, Any::class.java).invoke(null, parent, null, 1, null)
            assertTrue(parent.isCancelled)
            assertTrue(child.isCancelled)
        } finally {
            parent.cancel()
        }
    }

    @Test fun pluginInjektUsesTheRuntimeNetworkWithoutDuplicatingClientsOrCancellationPolicy() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync { MihonHost(instrumentation.targetContext) }
        // randomua resolves NetworkHelper through this external Kotlin API.
        val injected = Injekt.get<NetworkHelper>()
        val source = object : HttpSource() {
            override val name = "Injekt fixture"
            override val lang = "en"
            override val supportsLatest = false
            override val baseUrl = "https://fixture.invalid"
        }
        assertSame(MihonRuntime.network(), injected)
        assertSame(injected, source.network)
        assertSame(injected.client, source.client)
        assertSame(injected.client, injected.cloudflareClient)
        assertSame(injected.cookieJar, injected.client.cookieJar)
        assertSame(MihonRequestScope.eventListenerFactory, injected.client.eventListenerFactory)
        val independent = source.client.newCall(Request.Builder().url("http://127.0.0.1:1/independent").build())
        val owner = MihonRequestOwner("injekt-network-cancellation-fixture")
        try {
            runBlocking(MihonRequestScope.context(owner)) {
                val owned = injected.client.newCall(Request.Builder().url("http://127.0.0.1:1/owned").build())
                assertTrue(owner.cancel())
                // callStart must see the canceled captured owner before doing I/O.
                assertThrows(IOException::class.java) { owned.execute().close() }
                assertTrue(owned.isCanceled())
            }
            assertFalse(independent.isCanceled())
        } finally {
            owner.close()
            independent.cancel()
        }
    }

    @Test fun pluginDefaultBridgeDecodesHttpCharsetResolvesLinksAndClosesBody() {
        val body = TrackingBody("<a href='chapter/1'>caf\u00e9</a>".toByteArray(Charset.forName("windows-1252")),
            "text/html; charset=windows-1252".toMediaType())
        val response = response(body)
        val helper = Class.forName("eu.kanade.tachiyomi.util.JsoupExtensionsKt")
        // BaoziManhuaPlus 1.4.4 invokes this generated default bridge from APK DEX.
        val parse = helper.getMethod("asJsoup\$default", Response::class.java, String::class.java,
            Int::class.javaPrimitiveType, Any::class.java)
        val document = parse.invoke(null, response, null, 1, null) as org.jsoup.nodes.Document
        assertEquals("caf\u00e9", document.selectFirst("a")!!.text())
        assertEquals("https://fixture.invalid/catalog/chapter/1", document.selectFirst("a")!!.absUrl("href"))
        assertTrue(body.closed)
        assertTrue(body.reads > 0)
    }

    @Test fun bomOverridesDeclaredCharsetAndSuppliedHtmlLeavesBodyUnread() {
        val html = "<title>\u96ea</title>"
        val body = TrackingBody(byteArrayOf(0xef.toByte(), 0xbb.toByte(), 0xbf.toByte()) + html.toByteArray(),
            "text/html; charset=windows-1252".toMediaType())
        assertEquals("\u96ea", response(body).asJsoup().title())
        assertTrue(body.closed)
        val untouched = TrackingBody(byteArrayOf(), "text/html".toMediaType(), failOnRead = true)
        val response = response(untouched)
        try {
            val document = response.asJsoup("<a href='../book'>Supplied</a>")
            assertEquals("https://fixture.invalid/book", document.selectFirst("a")!!.absUrl("href"))
            assertEquals(0, untouched.reads)
            assertFalse(untouched.closed)
        } finally {
            response.close()
        }
        assertTrue(untouched.closed)
    }

    @Test fun bodyReadFailurePropagatesAndClosesSource() {
        val body = TrackingBody(byteArrayOf(), "text/html".toMediaType(), failOnRead = true)
        assertThrows(IOException::class.java) { response(body).asJsoup() }
        assertTrue(body.closed)
    }

    @Test fun selectorsKeepUpstreamMissingEmptyAndInvalidNumberBehavior() {
        val document = Jsoup.parse("<p class='empty'></p><p class='number'>42</p>" +
            "<p class='bad'>NaN</p><a href='/book'>Label</a>")
        assertNull(document.selectText(".missing"))
        assertEquals("fallback", document.selectText(".missing", "fallback"))
        assertEquals("", document.selectText(".empty", "fallback"))
        assertEquals(0, document.selectInt(".missing"))
        assertEquals(9, document.selectInt(".missing", 9))
        assertEquals(42, document.selectInt(".number"))
        assertThrows(NumberFormatException::class.java) { document.selectInt(".bad", 9) }
        assertThrows(NumberFormatException::class.java) { document.selectInt(".empty", 9) }
        val link = document.selectFirst("a")!!
        assertEquals("/book", link.attrOrText("href"))
        assertEquals("Label", link.attrOrText("text"))
        assertEquals("", link.attrOrText("missing"))
        val helper = Class.forName("eu.kanade.tachiyomi.util.JsoupExtensionsKt")
        assertNull(helper.getMethod("selectText\$default", Element::class.java, String::class.java,
            String::class.java, Int::class.javaPrimitiveType, Any::class.java)
            .invoke(null, document, ".missing", null, 2, null))
    }

    @Test fun rxBridgePreservesSingleResultAndUnsubscribesOnCoroutineAndOwnerCancellation() = runBlocking {
        assertEquals("result", Observable.just("result").awaitSingle())
        assertTrue(runCatching { Observable.empty<String>().awaitSingle() }.exceptionOrNull() is NoSuchElementException)
        assertTrue(runCatching { Observable.just("one", "two").awaitSingle() }.exceptionOrNull() is IllegalArgumentException)
        val unsubscribed = AtomicBoolean()
        val pending = async(start = CoroutineStart.UNDISPATCHED) {
            never(unsubscribed).awaitSingle()
        }
        pending.cancelAndJoin()
        assertTrue(unsubscribed.get())
        val owner = MihonRequestOwner("utility-cancellation-fixture")
        val ownerUnsubscribed = AtomicBoolean()
        try {
            val owned = async(owner.job + MihonRequestScope.context(owner), start = CoroutineStart.UNDISPATCHED) {
                never(ownerUnsubscribed).awaitSingle()
            }
            assertTrue(owner.cancel())
            withTimeout(1000) { owned.join() }
            assertTrue(owned.isCancelled)
            assertTrue(ownerUnsubscribed.get())
        } finally {
            owner.close()
        }
    }

    private fun never(unsubscribed: AtomicBoolean): Observable<String> = Observable.create { subscriber ->
        subscriber.add(Subscriptions.create { unsubscribed.set(true) })
    }

    private fun response(body: ResponseBody) = Response.Builder()
        .request(Request.Builder().url("https://fixture.invalid/catalog/").build())
        .protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body).build()

    private class TrackingBody(bytes: ByteArray, private val type: MediaType, failOnRead: Boolean = false) : ResponseBody() {
        var closed = false
        var reads = 0
        private val content = object : ForwardingSource(Buffer().write(bytes)) {
            override fun read(sink: Buffer, byteCount: Long): Long {
                reads++
                if (failOnRead) throw IOException("fixture read failed")
                return super.read(sink, byteCount)
            }
            override fun close() { closed = true; super.close() }
        }.buffer()
        override fun contentType(): MediaType = type
        override fun contentLength(): Long = -1
        override fun source(): BufferedSource = content
    }
}
