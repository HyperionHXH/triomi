package io.github.hyperionhxh.triomi

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import eu.kanade.tachiyomi.network.DELETE
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.HttpException
import eu.kanade.tachiyomi.network.MihonRequestScope
import eu.kanade.tachiyomi.network.PATCH
import eu.kanade.tachiyomi.network.POST
import eu.kanade.tachiyomi.network.PUT
import eu.kanade.tachiyomi.network.ProgressListener
import eu.kanade.tachiyomi.network.ProgressResponseBody
import eu.kanade.tachiyomi.network.asObservableSuccess
import eu.kanade.tachiyomi.network.await
import eu.kanade.tachiyomi.network.awaitSuccess
import eu.kanade.tachiyomi.network.decodeFromJsonResponse
import eu.kanade.tachiyomi.network.interceptor.rateLimit
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Authenticator
import okhttp3.ConnectionPool
import okhttp3.CookieJar
import okhttp3.Dns
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.Proxy
import java.net.ServerSocket
import java.net.SocketException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

@Suppress("DEPRECATION")
@RunWith(AndroidJUnit4::class)
class MihonHttpCompatibilityTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    @Test fun exceptionMatchesPluginConstructorAndGetterDescriptors() {
        val type = HttpException::class.java
        val failure = type.getConstructor(Int::class.javaPrimitiveType).newInstance(401)
        assertTrue(failure is IllegalStateException)
        assertEquals("HTTP error 401", failure.message)
        assertEquals(401, type.getMethod("getCode").invoke(failure))
        assertEquals(401, type.getMethod("getStatusCode").invoke(failure))
        assertNull(type.getMethod("getRetryAfter").invoke(failure))
        assertNotNull(type.getConstructor(Int::class.javaPrimitiveType, String::class.java, String::class.java))
    }

    @Test fun businessErrorsDoNotMasqueradeAsHttpFailures() = withSource { host, args ->
        for (path in listOf("/business", "/constructed")) {
            val result = pages(host, args, path)
            assertEquals(false, result["ok"])
            assertTrue(result["error"].toString().contains(if (path == "/business") "401" else "429"))
            assertFalse("plugin-created exceptions cannot prove an HTTP status", result.containsKey("statusCode"))
            assertFalse(result.containsKey("retryAfter"))
        }
    }

    @Test fun allHttpHelpersKeepRealStatusAndRetryAfterWithoutLeakingEarlierErrors() = withSource { host, args ->
        for (path in listOf("/sync", "/rx", "/suspend")) {
            val result = pages(host, args, path)
            assertEquals(false, result["ok"])
            assertEquals("missing response metadata for $path", 429, result["statusCode"])
            assertEquals("7", result["retryAfter"])
        }
        val unrelated = pages(host, args, "/caught-then-error")
        assertEquals(false, unrelated["ok"])
        assertTrue(unrelated["error"].toString().contains("unrelated source failure"))
        assertFalse(unrelated.containsKey("statusCode"))
        assertFalse(unrelated.containsKey("retryAfter"))
    }

    @Test fun requestsUseUpstreamDefaultsAndSupportAllBodyMethods() {
        val url = "https://fixture.invalid/api"
        assertEquals(600, GET(url).cacheControl.maxAgeSeconds)
        for (request in listOf(POST(url), PUT(url), PATCH(url), DELETE(url))) {
            assertEquals(600, request.cacheControl.maxAgeSeconds)
            assertEquals(0L, request.body!!.contentLength())
        }
        assertEquals(listOf("POST", "PUT", "PATCH", "DELETE"),
            listOf(POST(url), PUT(url), PATCH(url), DELETE(url)).map { it.method })
    }

    @Test fun rxCanSubscribeTwiceAndProgressAndJsonHelpersConsumeTheirBodies() {
        val client = fixtureClient()
        val observable = client.newCall(GET("https://fixture.invalid/ok")).asObservableSuccess()
        repeat(2) { assertEquals("ok", observable.toBlocking().single().use { it.body.string() }) }
        val updates = mutableListOf<Triple<Long, Long, Boolean>>()
        ProgressResponseBody("payload".toResponseBody(), object : ProgressListener {
            override fun update(bytesRead: Long, contentLength: Long, done: Boolean) {
                updates += Triple(bytesRead, contentLength, done)
            }
        }).use { assertEquals("payload", it.string()) }
        assertEquals(Triple(7L, 7L, true), updates.last())
        val jsonResponse = Response.Builder().request(GET("https://fixture.invalid/json"))
            .protocol(Protocol.HTTP_1_1).code(200).message("OK").body("\"value\"".toResponseBody()).build()
        assertEquals("value", decodeFromJsonResponse(Json, String.serializer(), jsonResponse))
    }

    @Test fun coroutineCancellationCancelsTheActualCustomClientCall() = runBlocking {
        val started = CountDownLatch(1)
        val stopped = CountDownLatch(1)
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            started.countDown()
            try {
                while (!chain.call().isCanceled()) Thread.sleep(5)
                throw IOException("Canceled")
            } finally {
                stopped.countDown()
            }
        }.build()
        val call = client.newCall(GET("https://fixture.invalid/held"))
        val job = async(Dispatchers.IO) { call.await().close() }
        try {
            assertTrue(started.await(5, TimeUnit.SECONDS))
            job.cancelAndJoin()
            assertTrue(call.isCanceled())
            assertTrue(stopped.await(5, TimeUnit.SECONDS))
        } finally {
            call.cancel()
            job.cancelAndJoin()
        }
    }

    @Test fun okhttp54ChainOverridesRetainCallIdentityAndExposeRealSettings() {
        val dns = Dns { listOf(InetAddress.getLoopbackAddress()) }
        val authenticator = Authenticator { _, _ -> null }
        val pool = ConnectionPool()
        var inspected = false
        lateinit var client: OkHttpClient
        client = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
            .addInterceptor { chain ->
                assertSame(client.authenticator, chain.authenticator)
                assertSame(client.cache, chain.cache)
                assertSame(client.cookieJar, chain.cookieJar)
                assertSame(client.certificatePinner, chain.certificatePinner)
                assertSame(client.connectionPool, chain.connectionPool)
                assertSame(client.dns, chain.dns)
                assertSame(client.hostnameVerifier, chain.hostnameVerifier)
                assertSame(client.proxy, chain.proxy)
                assertSame(client.proxyAuthenticator, chain.proxyAuthenticator)
                assertSame(client.proxySelector, chain.proxySelector)
                assertSame(client.socketFactory, chain.socketFactory)
                assertSame(client.sslSocketFactory, chain.sslSocketFactoryOrNull)
                assertNotNull(chain.x509TrustManagerOrNull)
                assertNotNull(chain.eventListener)
                assertFalse(chain.followRedirects)
                assertFalse(chain.followSslRedirects)
                val overridden = chain.withDns(dns).withAuthenticator(authenticator)
                    .withCache(null).withCookieJar(CookieJar.NO_COOKIES)
                    .withConnectionPool(pool).withProxy(Proxy.NO_PROXY)
                    .withProxySelector(client.proxySelector)
                    .withProxyAuthenticator(authenticator)
                    .withRetryOnConnectionFailure(false)
                    .withSocketFactory(client.socketFactory)
                    .withSslSocketFactory(chain.sslSocketFactoryOrNull, chain.x509TrustManagerOrNull)
                    .withHostnameVerifier(client.hostnameVerifier)
                    .withCertificatePinner(client.certificatePinner)
                assertSame(chain.call(), overridden.call())
                assertSame(dns, overridden.dns)
                assertSame(authenticator, overridden.authenticator)
                assertSame(authenticator, overridden.proxyAuthenticator)
                assertSame(CookieJar.NO_COOKIES, overridden.cookieJar)
                assertSame(pool, overridden.connectionPool)
                assertSame(Proxy.NO_PROXY, overridden.proxy)
                assertNull(overridden.cache)
                assertFalse(overridden.retryOnConnectionFailure)
                overridden.proceed(chain.request())
            }.addInterceptor { chain ->
                assertSame(dns, chain.dns)
                assertSame(authenticator, chain.authenticator)
                assertSame(pool, chain.connectionPool)
                assertSame(CookieJar.NO_COOKIES, chain.cookieJar)
                assertFalse(chain.retryOnConnectionFailure)
                inspected = true
                Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                    .code(200).message("OK").body("real-chain".toResponseBody()).build()
            }.build()
        client.newCall(GET("https://fixture.invalid/chain54")).execute().use {
            assertEquals("real-chain", it.body.string())
        }
        assertTrue(inspected)
        pool.evictAll()
    }

    @Test fun cancelingCallAfterChainOverridesClosesItsActualLoopbackSocket() {
        val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val started = CountDownLatch(1)
        val disconnected = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        val peer = executor.submit<Unit> {
            server.accept().use { socket ->
                socket.soTimeout = 5000
                val input = socket.getInputStream().bufferedReader()
                while (!input.readLine().isNullOrEmpty()) { }
                started.countDown()
                try {
                    assertEquals("cancellation must close the physical connection", -1, input.read())
                } catch (_: SocketException) {
                    // A peer reset also proves physical closure; a read timeout must fail.
                }
                disconnected.countDown()
            }
        }
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            val overridden = chain.withProxy(Proxy.NO_PROXY)
                .withRetryOnConnectionFailure(false).withCookieJar(CookieJar.NO_COOKIES)
            assertSame(chain.call(), overridden.call())
            overridden.proceed(chain.request())
        }.build()
        val call = client.newCall(GET("http://127.0.0.1:${server.localPort}/held"))
        val request = executor.submit<Unit> { call.execute().close() }
        try {
            assertTrue(started.await(5, TimeUnit.SECONDS))
            call.cancel()
            try {
                request.get(5, TimeUnit.SECONDS)
                fail("canceled socket request must fail")
            } catch (error: ExecutionException) {
                assertTrue(error.cause is IOException)
            }
            assertTrue(disconnected.await(5, TimeUnit.SECONDS))
            peer.get(5, TimeUnit.SECONDS)
        } finally {
            call.cancel()
            server.close()
            executor.shutdownNow()
            client.connectionPool.evictAll()
        }
    }

    @Test fun cancelingAThrottledCallDoesNotWaitForItsEntireRateLimitPeriod() {
        val client = OkHttpClient.Builder().rateLimit(1, 10L, TimeUnit.SECONDS).addInterceptor { chain ->
            val metadata = Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(200).message("OK").build()
            metadata.newBuilder().networkResponse(metadata).body("ok".toResponseBody()).build()
        }.build()
        client.newCall(GET("https://fixture.invalid/first")).execute().close()
        val call = client.newCall(GET("https://fixture.invalid/second"))
        val executor = Executors.newSingleThreadExecutor()
        try {
            val request = executor.submit<Unit> { call.execute().close() }
            try {
                request.get(200, TimeUnit.MILLISECONDS)
                fail("second network request must wait for the rate limit")
            } catch (_: TimeoutException) { }
            call.cancel()
            try {
                request.get(2, TimeUnit.SECONDS)
                fail("canceled rate-limited call must fail")
            } catch (error: ExecutionException) {
                assertTrue(error.cause is IOException)
            }
        } finally {
            call.cancel()
            executor.shutdownNow()
        }
    }

    private fun pages(host: MihonHost, args: Map<String, Any?>, path: String): Map<String, Any?> =
        host.request(args + mapOf("requestId" to UUID.randomUUID().toString(), "operation" to "pages",
            "chapter" to mapOf("url" to path)))

    private fun fixtureClient(): OkHttpClient = OkHttpClient.Builder().addInterceptor { chain ->
        val business = chain.request().url.encodedPath == "/business"
        val successful = business || chain.request().url.encodedPath == "/ok"
        Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
            .code(if (successful) 200 else 429).message(if (successful) "OK" else "Throttled")
            .header("Retry-After", "7")
            .body((if (business) "{\"code\":401}" else "ok").toResponseBody()).build()
    }.build()

    private fun withSource(block: (MihonHost, Map<String, Any?>) -> Unit) {
        lateinit var host: MihonHost
        instrumentation.runOnMainSync { host = MihonHost(context) }
        val packageName = "org.triomi.http.fixture${UUID.randomUUID().toString().replace("-", "") }"
        val source = object : HttpSource() {
            override val name = packageName
            override val lang = "en"
            override val supportsLatest = false
            override val baseUrl = "https://fixture.invalid"
            init { client = fixtureClient() }
            override fun pageListRequest(chapter: SChapter): Request = GET(baseUrl + chapter.url)
            override fun pageListParse(response: Response): List<Page> {
                if (response.body.string().contains("401")) throw HttpException(401)
                return emptyList()
            }
            override suspend fun getPageList(chapter: SChapter): List<Page> = when (chapter.url) {
                "/constructed" -> throw HttpException(429, "plugin business error", "99")
                "/rx" -> MihonRequestScope.awaitSingle(client.newCall(pageListRequest(chapter))
                    .asObservableSuccess().map { it.use(::pageListParse) })
                "/suspend" -> client.newCall(pageListRequest(chapter)).awaitSuccess().use(::pageListParse)
                "/caught-then-error" -> {
                    try {
                        client.newCall(pageListRequest(chapter)).execute().awaitSuccess().close()
                    } catch (_: HttpException) { }
                    error("unrelated source failure")
                }
                else -> super.getPageList(chapter)
            }
        }
        val pins = context.getSharedPreferences("mihon.host", Context.MODE_PRIVATE)
        val type = Class.forName("io.github.hyperionhxh.triomi.MihonHost\$LoadedExtension")
        val constructor = type.declaredConstructors.single().also { it.isAccessible = true }
        @Suppress("UNCHECKED_CAST")
        val loaded = MihonHost::class.java.getDeclaredField("loaded").also { it.isAccessible = true }
            .get(host) as MutableMap<String, Any>
        loaded[packageName] = constructor.newInstance(File(context.cacheDir, "$packageName.apk"),
            packageName, "fixture", source.javaClass.classLoader, null, listOf<Source>(source))
        pins.edit().putBoolean("enabled.$packageName", true).commit()
        try {
            block(host, mapOf("packageName" to packageName, "sourceId" to source.id.toString()))
        } finally {
            loaded.remove(packageName)
            pins.edit().remove("enabled.$packageName").commit()
        }
    }
}
