package io.github.hyperionhxh.triomi

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import eu.kanade.tachiyomi.network.awaitSuccess
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.online.HttpSource
import okhttp3.Request
import okhttp3.Response
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import rx.Observable
import rx.schedulers.Schedulers
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

@RunWith(AndroidJUnit4::class)
class MihonRequestCancellationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    @Test fun imageFileCancellationStopsSocketAndRemovesOnlyItsStagingFile() {
        SlowHttpSourceServer().use { server ->
            withSource(server) { host, source, args ->
                val executor = Executors.newFixedThreadPool(2)
                val request = source.imageRequest(Page(0, imageUrl = "${server.url}/slow-image"))
                val key = MessageDigest.getInstance("SHA-256")
                    .digest(("${source.id}\n${request.url}\n${request.headers}").toByteArray())
                    .joinToString("") { "%02x".format(it) }
                val cache = File(context.cacheDir, "mihon-images")
                val id = UUID.randomUUID().toString()
                val admitted = host.prepareRequest(args + mapOf("requestId" to id,
                    "operation" to "imageFile", "pageData" to mapOf("url" to "${server.url}/resolve")))
                try {
                    val transfer = executor.submit<Map<String, Any?>> { admitted() }
                    assertTrue(server.state("/slow-image").started.await(10, TimeUnit.SECONDS))
                    val independent = executor.submit<Map<String, Any?>> {
                        host.request(args + mapOf("requestId" to UUID.randomUUID().toString(),
                            "operation" to "image", "pageData" to mapOf("imageUrl" to "${server.url}/quick-image")))
                    }
                    assertEquals(true, host.cancelRequest(id)["cancelled"])
                    val canceled = transfer.get(10, TimeUnit.SECONDS)
                    assertEquals(false, canceled["ok"])
                    assertEquals(true, canceled["cancelled"])
                    assertEquals("request_cancelled", canceled["errorCode"])
                    assertEquals(id, canceled["requestId"])
                    assertTrue("cancel must close the actual HTTP stream", server.state("/slow-image").closed.await(10, TimeUnit.SECONDS))
                    assertTrue(server.state("/slow-image").bytes.get() < server.totalBytes)
                    assertEquals(true, independent.get(10, TimeUnit.SECONDS)["ok"])
                    assertFalse("partial image must never be published", File(cache, "$key.image").exists())
                    assertFalse(File(cache, "$key.mime").exists())
                    assertTrue("canceled staging file must be removed", cache.listFiles().orEmpty()
                        .none { it.name.startsWith(key) && it.name.endsWith(".tmp") })
                    assertEquals(false, host.cancelRequest(id)["cancelled"])
                    assertEquals("duplicate_request_id", host.request(args + mapOf("requestId" to id, "operation" to "filters"))["errorCode"])
                    assertEquals(true, host.request(args + mapOf("requestId" to UUID.randomUUID().toString(), "operation" to "filters"))["ok"])
                } finally {
                    host.cancelRequest(id)
                    executor.shutdownNow()
                    cache.listFiles().orEmpty().filter { it.name.startsWith(key) }.forEach { it.delete() }
                }
            }
        }
    }

    @Test fun cancelingOneImageFileSubscriberDoesNotDeleteAnotherSubscribersStaging() {
        SlowHttpSourceServer().use { server ->
            withSource(server) { host, _, args ->
                val executor = Executors.newFixedThreadPool(2)
                val canceledId = UUID.randomUUID().toString()
                val otherId = UUID.randomUUID().toString()
                val imageArgs = args + mapOf("operation" to "imageFile",
                    "pageData" to mapOf("imageUrl" to "${server.url}/same-image"))
                var published: File? = null
                try {
                    val first = executor.submit<Map<String, Any?>> { host.request(imageArgs + ("requestId" to canceledId)) }
                    val second = executor.submit<Map<String, Any?>> { host.request(imageArgs + ("requestId" to otherId)) }
                    assertTrue(server.state("/same-image").bothStarted.await(10, TimeUnit.SECONDS))
                    assertTrue(server.state("/same-image").started.await(10, TimeUnit.SECONDS))
                    host.cancelRequest(canceledId)
                    assertEquals(true, first.get(10, TimeUnit.SECONDS)["cancelled"])
                    assertFalse("the other subscriber must remain active", second.isDone)
                    server.state("/same-image").release.countDown()
                    val successful = second.get(10, TimeUnit.SECONDS)
                    assertEquals(true, successful["ok"])
                    published = File(successful["filePath"] as String)
                    assertTrue(published!!.length() > 0)
                    assertTrue(File(published!!.parentFile, published!!.nameWithoutExtension + ".mime").isFile)
                    assertTrue(published!!.parentFile!!.listFiles().orEmpty()
                        .none { it.name.startsWith(published!!.nameWithoutExtension) && it.name.endsWith(".tmp") })
                    assertEquals(false, host.cancelRequest(canceledId)["cancelled"])
                    assertEquals(true, host.request(imageArgs + ("requestId" to UUID.randomUUID().toString()))["ok"])
                } finally {
                    host.cancelRequest(canceledId)
                    host.cancelRequest(otherId)
                    executor.shutdownNow()
                    published?.let { image ->
                        File(image.parentFile, image.nameWithoutExtension + ".mime").delete()
                        image.delete()
                    }
                }
            }
        }
    }

    @Test fun actualHttpFailuresKeepRetryAfterWithoutLeakingEarlierFailureMetadata() {
        SlowHttpSourceServer().use { server ->
            withSource(server) { host, _, args ->
                for ((path, retryAfter) in listOf("/throttled" to "7",
                    "/throttled-date" to "Wed, 21 Oct 2037 07:28:00 GMT")) {
                    val response = host.request(args + mapOf("requestId" to UUID.randomUUID().toString(),
                        "operation" to "pages", "chapter" to mapOf("url" to path)))
                    assertEquals(false, response["ok"])
                    assertEquals(429, response["statusCode"])
                    assertEquals(retryAfter, response["retryAfter"])
                }
                val image = host.request(args + mapOf("requestId" to UUID.randomUUID().toString(),
                    "operation" to "imageFile", "pageData" to mapOf("imageUrl" to "${server.url}/throttled")))
                assertEquals(429, image["statusCode"])
                assertEquals("7", image["retryAfter"])
                val unrelated = host.request(args + mapOf("requestId" to UUID.randomUUID().toString(),
                    "operation" to "pages", "chapter" to mapOf("url" to "/caught-then-error")))
                assertEquals(false, unrelated["ok"])
                assertTrue(unrelated["error"].toString().contains("unrelated source failure"))
                assertFalse(unrelated.containsKey("statusCode"))
                assertFalse(unrelated.containsKey("retryAfter"))
            }
        }
    }

    @Test fun rxScheduledHttpCompletesWithoutCancellationAfterSubscriptionReturns() {
        SlowHttpSourceServer().use { server ->
            withSource(server) { host, _, args ->
                val executor = Executors.newSingleThreadExecutor()
                val id = UUID.randomUUID().toString()
                try {
                    val pages = executor.submit<Map<String, Any?>> {
                        host.request(args + mapOf("requestId" to id,
                            "operation" to "pages", "chapter" to mapOf("url" to "/async-pages")))
                    }
                    assertTrue("Rx scheduled source must start its actual HTTP call",
                        server.state("/async-pages").started.await(10, TimeUnit.SECONDS))
                    assertFalse("request must await the held asynchronous HTTP body", pages.isDone)
                    server.state("/async-pages").release.countDown()
                    val response = pages.get(10, TimeUnit.SECONDS)
                    assertEquals(true, response["ok"])
                    val resultPages = response["pages"] as List<*>
                    assertEquals(1, resultPages.size)
                    assertEquals("${server.url}/quick-image", (resultPages.single() as Map<*, *>)["imageUrl"])
                    assertEquals(false, host.cancelRequest(id)["cancelled"])
                } finally {
                    host.cancelRequest(id)
                    executor.shutdownNow()
                }
            }
        }
    }

    @Test fun rxScheduledNetworkHelperCallIsOwnedWithoutCancelingAnotherRequest() {
        SlowHttpSourceServer().use { server ->
            withSource(server) { host, _, args ->
                val executor = Executors.newFixedThreadPool(2)
                val id = UUID.randomUUID().toString()
                val independentId = UUID.randomUUID().toString()
                try {
                    val pages = executor.submit<Map<String, Any?>> { host.request(args + mapOf("requestId" to id,
                        "operation" to "pages", "chapter" to mapOf("url" to "/slow-pages"))) }
                    val other = executor.submit<Map<String, Any?>> { host.request(args + mapOf("requestId" to independentId,
                        "operation" to "pages", "chapter" to mapOf("url" to "/other-pages"))) }
                    assertTrue(server.state("/slow-pages").started.await(10, TimeUnit.SECONDS))
                    assertTrue(server.state("/other-pages").started.await(10, TimeUnit.SECONDS))
                    host.cancelRequest(id)
                    assertEquals(true, pages.get(10, TimeUnit.SECONDS)["cancelled"])
                    assertTrue(server.state("/slow-pages").closed.await(10, TimeUnit.SECONDS))
                    assertFalse("another owner must keep its socket", server.state("/other-pages").closed.await(150, TimeUnit.MILLISECONDS))
                    server.state("/other-pages").release.countDown()
                    assertEquals(true, other.get(10, TimeUnit.SECONDS)["ok"])
                    assertEquals(false, host.cancelRequest(id)["cancelled"])
                    assertEquals(true, host.request(args + mapOf("requestId" to UUID.randomUUID().toString(), "operation" to "filters"))["ok"])
                } finally {
                    host.cancelRequest(id)
                    host.cancelRequest(independentId)
                    executor.shutdownNow()
                }
            }
        }
    }

    @Test fun imageUrlResolutionAndDefaultPageListUseTheSameCancelableOwner() {
        SlowHttpSourceServer().use { server ->
            withSource(server) { host, _, args ->
                val executor = Executors.newSingleThreadExecutor()
                try {
                    for ((operation, path) in listOf("imageFile" to "/slow-resolution", "pages" to "/default-pages")) {
                        val id = UUID.randomUUID().toString()
                        val payload = if (operation == "pages") mapOf("chapter" to mapOf("url" to path))
                            else mapOf("pageData" to mapOf("url" to "${server.url}$path"))
                        val transfer = executor.submit<Map<String, Any?>> {
                            host.request(args + payload + mapOf("requestId" to id, "operation" to operation))
                        }
                        assertTrue(server.state(path).started.await(10, TimeUnit.SECONDS))
                        host.cancelRequest(id)
                        assertEquals(true, transfer.get(10, TimeUnit.SECONDS)["cancelled"])
                        assertTrue(server.state(path).closed.await(10, TimeUnit.SECONDS))
                    }
                } finally {
                    executor.shutdownNow()
                }
            }
        }
    }

    @Test fun admissionClosesEarlyCancelRaceAndRejectsRepeatedInvocation() {
        SlowHttpSourceServer().use { server ->
            withSource(server) { host, _, args ->
                val id = UUID.randomUUID().toString()
                val requestArgs = args + mapOf("requestId" to id, "operation" to "imageFile",
                    "pageData" to mapOf("imageUrl" to "${server.url}/slow-image"))
                val request = host.prepareRequest(requestArgs)
                assertEquals("duplicate_request_id", host.prepareRequest(requestArgs)()["errorCode"])
                assertEquals(true, host.cancelRequest(id)["cancelled"])
                assertEquals(true, request()["cancelled"])
                assertEquals("duplicate_request_id", request()["errorCode"])
                assertEquals("duplicate_request_id", host.request(requestArgs)["errorCode"])
                assertEquals(0L, server.state("/slow-image").bytes.get())
                val nextId = UUID.randomUUID().toString()
                val next = host.prepareRequest(args + mapOf("requestId" to nextId, "operation" to "filters"))
                assertEquals(false, host.cancelRequest(id)["cancelled"])
                assertEquals(true, next()["ok"])
                assertEquals("duplicate_request_id", host.request(args + mapOf("requestId" to nextId, "operation" to "filters"))["errorCode"])
                assertEquals(true, host.request(args + ("operation" to "filters"))["ok"])
                assertEquals("invalid_request_id", host.request(args + mapOf("requestId" to "", "operation" to "filters"))["errorCode"])
                val unknownId = UUID.randomUUID().toString()
                assertEquals(false, host.cancelRequest(unknownId)["cancelled"])
                assertEquals(true, host.request(args + mapOf("requestId" to unknownId, "operation" to "filters"))["ok"])
            }
        }
    }

    private fun withSource(server: SlowHttpSourceServer, block: (MihonHost, HttpSource, Map<String, Any?>) -> Unit) {
        lateinit var host: MihonHost
        instrumentation.runOnMainSync { host = MihonHost(context) }
        val packageName = "org.triomi.cancel.fixture${UUID.randomUUID().toString().replace("-", "") }"
        val source = object : HttpSource() {
            override val name = packageName
            override val lang = "en"
            override val supportsLatest = false
            override val baseUrl = server.url
            override fun pageListRequest(chapter: SChapter): Request = Request.Builder().url("$baseUrl${chapter.url}").build()
            override fun pageListParse(response: Response): List<Page> {
                response.body.string()
                return listOf(Page(0, imageUrl = "$baseUrl/quick-image"))
            }
            override fun fetchPageList(chapter: SChapter): Observable<List<Page>> {
                when (chapter.url) {
                    "/default-pages", "/throttled", "/throttled-date" -> return super.fetchPageList(chapter)
                }
                // This mirrors extension-owned HTTP outside HttpSource's default fetch methods.
                return Observable.fromCallable {
                    if (chapter.url == "/caught-then-error") {
                        try {
                            network.client.newCall(Request.Builder().url("$baseUrl/denied").build())
                                .execute().awaitSuccess().close()
                        } catch (_: IOException) { }
                        error("unrelated source failure")
                    }
                    network.client.newBuilder().build().newCall(pageListRequest(chapter)).execute().use(::pageListParse)
                }.subscribeOn(Schedulers.io())
            }
            override fun imageUrlParse(response: Response): String {
                response.body.string()
                return "$baseUrl/slow-image"
            }
        }
        val pins = context.getSharedPreferences("mihon.host", Context.MODE_PRIVATE)
        val type = Class.forName("io.github.hyperionhxh.triomi.MihonHost\$LoadedExtension")
        val constructor = type.declaredConstructors.single().also { it.isAccessible = true }
        val loaded = MihonHost::class.java.getDeclaredField("loaded").also { it.isAccessible = true }
            .get(host) as MutableMap<String, Any>
        loaded[packageName] = constructor.newInstance(File(context.cacheDir, "$packageName.apk"),
            packageName, "fixture", source.javaClass.classLoader, null, listOf<Source>(source))
        pins.edit().putBoolean("enabled.$packageName", true).commit()
        try {
            block(host, source, mapOf("packageName" to packageName, "sourceId" to source.id.toString()))
        } finally {
            loaded.remove(packageName)
            pins.edit().remove("enabled.$packageName").commit()
        }
    }

    private class SlowHttpSourceServer : Closeable {
        class Transfer {
            val started = CountDownLatch(1)
            val bothStarted = CountDownLatch(2)
            val closed = CountDownLatch(1)
            val release = CountDownLatch(1)
            val bytes = AtomicLong()
        }
        private val listener = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
        private val executor = Executors.newCachedThreadPool()
        private val transfers = ConcurrentHashMap<String, Transfer>()
        private val sockets = ConcurrentHashMap.newKeySet<Socket>()
        val url = "http://127.0.0.1:${listener.localPort}"
        val totalBytes = 128L * 1024 * 1024
        fun state(path: String): Transfer = transfers.getOrPut(path) { Transfer() }

        init {
            executor.execute {
                try {
                    while (!listener.isClosed) {
                        val socket = listener.accept()
                        sockets.add(socket)
                        executor.execute { respond(socket) }
                    }
                } catch (_: IOException) { }
            }
        }

        private fun respond(socket: Socket) {
            var transfer: Transfer? = null
            try {
                socket.use {
                    socket.sendBufferSize = 8192
                    val input = socket.getInputStream().bufferedReader()
                    val path = input.readLine().split(' ')[1]
                    while (!input.readLine().isNullOrEmpty()) { }
                    val output = socket.getOutputStream()
                    if (path == "/throttled" || path == "/throttled-date" || path == "/denied") {
                        val code = if (path == "/denied") 401 else 429
                        val retryAfter = if (path == "/throttled-date") "Wed, 21 Oct 2037 07:28:00 GMT" else "7"
                        output.write("HTTP/1.1 $code Rejected\r\nRetry-After: $retryAfter\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                        output.flush()
                    } else if (path == "/resolve" || path == "/quick-image") {
                        val body = if (path == "/resolve") "resolved".toByteArray() else byteArrayOf(1, 2, 3, 4)
                        output.write("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
                        output.write(body)
                        output.flush()
                    } else {
                        transfer = state(path)
                        output.write("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".toByteArray())
                        val chunk = ByteArray(16 * 1024) { 42 }
                        var firstChunk = true
                        while (transfer!!.bytes.get() < totalBytes && transfer!!.release.count > 0) {
                            output.write("${chunk.size.toString(16)}\r\n".toByteArray())
                            output.write(chunk)
                            output.write("\r\n".toByteArray())
                            output.flush()
                            transfer!!.bytes.addAndGet(chunk.size.toLong())
                            transfer!!.started.countDown()
                            if (firstChunk) {
                                transfer!!.bothStarted.countDown()
                                firstChunk = false
                            }
                            Thread.sleep(10)
                        }
                        output.write("0\r\n\r\n".toByteArray())
                        output.flush()
                    }
                }
            } catch (_: IOException) {
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            } finally {
                transfer?.closed?.countDown()
                sockets.remove(socket)
                socket.close()
            }
        }

        override fun close() {
            listener.close()
            sockets.forEach { it.close() }
            executor.shutdownNow()
            executor.awaitTermination(5, TimeUnit.SECONDS)
        }
    }
}
