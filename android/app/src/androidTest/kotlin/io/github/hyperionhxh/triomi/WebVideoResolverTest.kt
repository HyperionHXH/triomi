package io.github.hyperionhxh.triomi

import android.annotation.SuppressLint
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Synthetic responses exercise production JavaScript without contacting a site. */
@RunWith(AndroidJUnit4::class)
class WebVideoResolverTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val hls = "application/vnd.apple.mpegurl"

    private class Reply : MethodChannel.Result {
        var value: Any? = null
        var error: String? = null
        var calls = 0
        override fun success(result: Any?) { value = result; calls++ }
        override fun error(code: String, message: String?, details: Any?) { error = code; calls++ }
        override fun notImplemented() { error = "not_implemented"; calls++ }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun scriptResult(fixture: String, legacy: Boolean = false, action: String): JSONObject {
        val ready = CountDownLatch(1)
        val done = CountDownLatch(1)
        var output = ""
        lateinit var web: WebView
        instrumentation.runOnMainSync {
            web = WebView(instrumentation.targetContext)
            web.settings.javaScriptEnabled = true
            web.addJavascriptInterface(object {
                @JavascriptInterface fun finished(value: String) { output = value; done.countDown() }
            }, "TestBridge")
            web.webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, url: String) { ready.countDown() }
            }
            web.loadDataWithBaseURL("https://triomi-resolver.invalid/player", fixture, "text/html", "UTF-8", null)
        }
        try {
            assertTrue("Fixture loaded", ready.await(10, TimeUnit.SECONDS))
            instrumentation.runOnMainSync {
                web.evaluateJavascript(
                    "window.reports=[];window.TriomiMedia={found:(url,mimeType,omitCookies)=>reports.push({url,mimeType,omitCookies})};" +
                        WebVideoResolver.detectionScript(legacy) + action,
                    null,
                )
            }
            assertTrue("Script completed", done.await(10, TimeUnit.SECONDS))
            return JSONObject(output)
        } finally {
            instrumentation.runOnMainSync { web.removeJavascriptInterface("TestBridge"); web.destroy() }
        }
    }

    @Test fun fetchManifestPrefixIsDetectedWithoutPlayerCallingText() {
        val fixture = """
            <script>
            window.fetch = () => Promise.resolve(new Response('  #EXTM3U\n#EXT-X-VERSION:3', {headers:{'Content-Type':'application/octet-stream'}}));
            </script>
            <video src="blob:https://triomi-resolver.invalid/not-a-network-url"></video>
        """.trimIndent()
        val result = scriptResult(fixture, action = """
            fetch('https://triomi-resolver.invalid/manifest?id=1').then(r=>r.arrayBuffer()).then(body=>
              setTimeout(()=>TestBridge.finished(JSON.stringify({reports,body:new TextDecoder().decode(body)})),100));
        """.trimIndent())
        val report = result.getJSONArray("reports").getJSONObject(0)
        assertEquals("https://triomi-resolver.invalid/manifest?id=1", report.getString("url"))
        assertEquals(hls, report.getString("mimeType"))
        assertTrue("The player's body remains readable", result.getString("body").contains("#EXTM3U"))
        assertEquals(1, result.getJSONArray("reports").length())
    }

    @Test fun fetchHlsMimeAndNoCredentialsArePreservedWithoutReadingBody() {
        val fixture = """
            <script>
            window.fetch = () => Promise.resolve(new Response('not-read', {headers:{'Content-Type':'application/x-mpegURL; charset=utf-8'}}));
            </script>
        """.trimIndent()
        val result = scriptResult(fixture, action = """
            fetch('https://cdn-resolver.invalid/opaque-path', {credentials:'omit'}).then(()=>
              TestBridge.finished(JSON.stringify({reports})));
        """.trimIndent())
        val report = result.getJSONArray("reports").getJSONObject(0)
        assertEquals(hls, report.getString("mimeType"))
        assertTrue(report.getBoolean("omitCookies"))
    }

    @Test fun clonedResponseRetainsCredentialOmissionInTextFallback() {
        val fixture = """
            <script>
            window.fetch=()=>{
              const response=new Response('#EXTM3U\n');
              Object.defineProperty(response,'url',{value:'https://cdn-resolver.invalid/cloned-manifest'});
              Object.defineProperty(response,'body',{value:null});
              return Promise.resolve(response);
            };
            </script>
        """.trimIndent()
        val result = scriptResult(fixture, action = """
            fetch('https://cdn-resolver.invalid/cloned-manifest',{credentials:'omit'}).then(r=>{
              const copy=r.clone();
              Object.defineProperty(copy,'url',{value:r.url});
              return copy.text();
            }).then(()=>TestBridge.finished(JSON.stringify({reports})));
        """.trimIndent())
        val report = result.getJSONArray("reports").getJSONObject(0)
        assertEquals(hls, report.getString("mimeType"))
        assertTrue(report.getBoolean("omitCookies"))
    }

    @Test fun responseTextAndXhrArrayBufferMimeReportExtensionlessHls() {
        val fixture = """
            <script>
            class FixtureXHR extends EventTarget {
              open(method,url) {this.responseURL=url;this.responseType='arraybuffer';this.withCredentials=false;}
              getResponseHeader(name) {return 'application/vnd.apple.mpegurl';}
              send() {this.dispatchEvent(new Event('load'));}
            }
            window.XMLHttpRequest=FixtureXHR;
            </script>
        """.trimIndent()
        val result = scriptResult(fixture, action = """
            const response=new Response('#EXTM3U\n');
            Object.defineProperty(response,'url',{value:'https://triomi-resolver.invalid/text-manifest'});
            response.text().then(()=>{
              const xhr=new XMLHttpRequest();xhr.open('GET','https://cdn-resolver.invalid/manifest');xhr.send();
              TestBridge.finished(JSON.stringify({reports}));
            });
        """.trimIndent())
        val reports = result.getJSONArray("reports")
        assertEquals(2, reports.length())
        assertEquals(hls, reports.getJSONObject(0).getString("mimeType"))
        assertEquals(hls, reports.getJSONObject(1).getString("mimeType"))
        assertTrue(reports.getJSONObject(1).getBoolean("omitCookies"))
    }

    @Test fun xhrArrayBufferBodyWithGenericMimeIsDetected() {
        val fixture = """
            <script>
            class FixtureXHR extends EventTarget {
              open(method,url) {
                this.responseURL=url;this.responseType='arraybuffer';this.withCredentials=false;
                this.response=new TextEncoder().encode('  #EXTM3U\n').buffer;
              }
              getResponseHeader(name) {return 'application/octet-stream';}
              send() {this.dispatchEvent(new Event('load'));}
            }
            window.XMLHttpRequest=FixtureXHR;
            </script>
        """.trimIndent()
        val result = scriptResult(fixture, action = """
            const xhr=new XMLHttpRequest();xhr.open('GET','https://triomi-resolver.invalid/binary-manifest');xhr.send();
            TestBridge.finished(JSON.stringify({reports}));
        """.trimIndent())
        val report = result.getJSONArray("reports").getJSONObject(0)
        assertEquals("https://triomi-resolver.invalid/binary-manifest", report.getString("url"))
        assertEquals(hls, report.getString("mimeType"))
        assertFalse(report.getBoolean("omitCookies"))
    }

    @Test fun ordinaryHtmlIsNotPromotedToHls() {
        val fixture = "<script>window.fetch=()=>Promise.resolve(new Response('<html>not media</html>'));</script>"
        val result = scriptResult(fixture, action = """
            fetch('/page').then(r=>r.text()).then(()=>setTimeout(()=>TestBridge.finished(JSON.stringify({reports})),100));
        """.trimIndent())
        assertEquals(0, result.getJSONArray("reports").length())
    }

    @Test fun legacyIframeQueryRequiresOptInAndKeepsWholeSignedMediaUrl() {
        val media = "https://cdn-resolver.invalid/video.m3u8?token=fixture&part=1"
        val fixture = "<iframe src=\"about:blank?url=${android.net.Uri.encode(media)}\"></iframe><iframe src=\"about:blank?url=https%3A%2F%2Fexample.invalid%2Fplayer.html\"></iframe>"
        val action = "TestBridge.finished(JSON.stringify({reports}));"
        assertEquals(0, scriptResult(fixture, action = action).getJSONArray("reports").length())
        val reports = scriptResult(fixture, legacy = true, action = action).getJSONArray("reports")
        assertEquals(1, reports.length())
        assertEquals(media, reports.getJSONObject(0).getString("url"))
        assertEquals(hls, reports.getJSONObject(0).getString("mimeType"))
    }

    @Test fun productionBridgeReturnsExtensionlessHlsMetadata() {
        val done = CountDownLatch(1)
        var response: Map<*, *>? = null
        var error: String? = null
        val reply = object : MethodChannel.Result {
            override fun success(result: Any?) { response = result as Map<*, *>; done.countDown() }
            override fun error(code: String, message: String?, details: Any?) { error = code; done.countDown() }
            override fun notImplemented() { error = "not_implemented"; done.countDown() }
        }
        lateinit var resolver: WebVideoResolver
        instrumentation.runOnMainSync {
            resolver = WebVideoResolver(instrumentation.targetContext)
            resolver.resolve(MethodCall("resolveVideo", mapOf("url" to "https://triomi-resolver.invalid/player")), reply)
            val web = resolver.javaClass.getDeclaredField("view").apply { isAccessible = true }.get(resolver) as WebView
            web.stopLoading()
            val script = WebVideoResolver.detectionScript(false)
            web.loadDataWithBaseURL("https://triomi-resolver.invalid/player", """
                <script>
                window.fetch=()=>Promise.resolve(new Response('#EXTM3U\n',{headers:{'Content-Type':'application/vnd.apple.mpegurl'}}));
                // Use the production script after the deterministic transport is installed.
                window.__triomiMedia=false;
                $script
                window.addEventListener('load',()=>fetch('https://triomi-resolver.invalid/extensionless',{credentials:'omit'}));
                </script>
            """.trimIndent(), "text/html", "UTF-8", null)
        }
        try {
            assertTrue("Production bridge completed", done.await(10, TimeUnit.SECONDS))
            assertNull(error)
            assertEquals("https://triomi-resolver.invalid/extensionless", response!!["url"])
            assertEquals(hls, response!!["mimeType"])
            val headers = response!!["headers"] as Map<*, *>
            assertFalse(headers.keys.any { it.toString().equals("Referer", true) || it.toString().equals("Cookie", true) })
        } finally {
            instrumentation.runOnMainSync { resolver.cancel() }
        }
    }

    @Test fun staleTimeoutAndWebCallbacksCannotFinishReplacementRequest() {
        instrumentation.runOnMainSync {
            val resolver = WebVideoResolver(instrumentation.targetContext)
            val first = Reply()
            val second = Reply()
            val viewField = resolver.javaClass.getDeclaredField("view").apply { isAccessible = true }
            val timeoutField = resolver.javaClass.getDeclaredField("timeout").apply { isAccessible = true }
            try {
                resolver.resolve(MethodCall("resolveVideo", mapOf("url" to "https://triomi-resolver.invalid/one", "requestId" to "one")), first)
                val oldWeb = viewField.get(resolver) as WebView
                val oldClient = oldWeb.webViewClient
                val oldTimeout = timeoutField.get(resolver) as Runnable
                resolver.resolve(MethodCall("resolveVideo", mapOf("url" to "https://triomi-resolver.invalid/two", "requestId" to "two")), second)
                val newWeb = viewField.get(resolver)
                oldTimeout.run()
                oldClient.onPageFinished(oldWeb, "https://triomi-resolver.invalid/one")
                resolver.cancel("one")
                assertEquals("resolve_cancelled", first.error)
                assertEquals(1, first.calls)
                assertEquals(0, second.calls)
                assertSame(newWeb, viewField.get(resolver))
            } finally {
                resolver.cancel()
            }
            assertEquals("resolve_cancelled", second.error)
            assertEquals(1, second.calls)
        }
    }

    @Test fun cancellationReplyCannotOrphanAReentrantReplacement() {
        instrumentation.runOnMainSync {
            val resolver = WebVideoResolver(instrumentation.targetContext)
            val nested = Reply()
            val outer = Reply()
            val first = object : MethodChannel.Result {
                override fun success(result: Any?) = Unit
                override fun error(code: String, message: String?, details: Any?) {
                    resolver.resolve(MethodCall("resolveVideo", mapOf("url" to "https://triomi-resolver.invalid/nested", "requestId" to "nested")), nested)
                }
                override fun notImplemented() = Unit
            }
            try {
                resolver.resolve(MethodCall("resolveVideo", mapOf("url" to "https://triomi-resolver.invalid/first")), first)
                resolver.resolve(MethodCall("resolveVideo", mapOf("url" to "https://triomi-resolver.invalid/outer", "requestId" to "outer")), outer)
                assertEquals("resolve_cancelled", outer.error)
                assertEquals(0, nested.calls)
                val requestId = resolver.javaClass.getDeclaredField("requestId").apply { isAccessible = true }.get(resolver)
                assertEquals("nested", requestId)
            } finally {
                resolver.cancel()
            }
            assertEquals("resolve_cancelled", nested.error)
            assertEquals(1, nested.calls)
        }
    }

    @Test fun nativeRequestHeadersKeepNoReferrerAndObservedCookie() {
        val done = CountDownLatch(1)
        val reply = object : MethodChannel.Result {
            var response: Map<*, *>? = null
            override fun success(result: Any?) { response = result as Map<*, *>; done.countDown() }
            override fun error(code: String, message: String?, details: Any?) { done.countDown() }
            override fun notImplemented() { done.countDown() }
        }
        lateinit var resolver: WebVideoResolver
        instrumentation.runOnMainSync {
            resolver = WebVideoResolver(instrumentation.targetContext)
            resolver.resolve(MethodCall("resolveVideo", mapOf("url" to "https://triomi-resolver.invalid/player", "headers" to mapOf("Referer" to "https://must-not-be-inherited.invalid/"))), reply)
            val web = resolver.javaClass.getDeclaredField("view").apply { isAccessible = true }.get(resolver) as WebView
            web.stopLoading()
            val request = object : WebResourceRequest {
                override fun getUrl() = android.net.Uri.parse("https://triomi-resolver.invalid/media.mp4")
                override fun isForMainFrame() = false
                override fun isRedirect() = false
                override fun hasGesture() = false
                override fun getMethod() = "GET"
                override fun getRequestHeaders() = mapOf("Origin" to "https://frame.invalid", "Cookie" to "exact=fixture", "User-Agent" to "FixtureUA")
            }
            web.webViewClient.shouldInterceptRequest(web, request)
        }
        try {
            assertTrue(done.await(10, TimeUnit.SECONDS))
            val headers = reply.response!!["headers"] as Map<*, *>
            assertFalse(headers.keys.any { it.toString().equals("Referer", true) })
            assertEquals("https://frame.invalid", headers["Origin"])
            assertEquals("exact=fixture", headers["Cookie"])
            assertEquals("FixtureUA", headers["User-Agent"])
        } finally {
            instrumentation.runOnMainSync { resolver.cancel() }
        }
    }
}
