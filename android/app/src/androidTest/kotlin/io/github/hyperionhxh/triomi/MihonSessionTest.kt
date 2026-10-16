package io.github.hyperionhxh.triomi

import android.webkit.CookieManager
import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import eu.kanade.tachiyomi.network.AndroidCookieJar
import eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Cookie
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.io.File

@RunWith(AndroidJUnit4::class)
class MihonSessionTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    private fun setCookie(url: String, cookie: String) {
        val done = CountDownLatch(1)
        instrumentation.runOnMainSync {
            CookieManager.getInstance().setCookie(url, cookie) { done.countDown() }
        }
        assertTrue("WebView cookie write completed", done.await(10, TimeUnit.SECONDS))
    }

    @Test fun browserCookieScopeLogoutAndRecreation() {
        val url = "https://triomi-session.invalid/".toHttpUrl()
        val jar = AndroidCookieJar(context)
        setCookie(url.toString(), "triomi_root=ok; Path=/; Secure; Max-Age=600; HttpOnly")
        setCookie(url.toString(), "triomi_private=only; Path=/private; Secure; Max-Age=600")
        instrumentation.runOnMainSync { jar.useBrowserSession(setOf(url.host)) }
        assertEquals(listOf("triomi_root"), jar.loadForRequest(url).map { it.name })
        assertEquals(2, jar.loadForRequest(url.resolve("/private/chapter")!!).size)
        assertTrue(jar.loadForRequest("https://another-session.invalid/".toHttpUrl()).isEmpty())
        assertTrue(jar.loadForRequest("http://triomi-session.invalid/".toHttpUrl()).isEmpty())
        val recreated = AndroidCookieJar(context)
        assertEquals("ok", recreated.loadForRequest(url).single().value)
        setCookie(url.toString(), "triomi_root=; Path=/; Secure; Max-Age=0")
        assertTrue("logout must not resurrect native cookies", recreated.loadForRequest(url).isEmpty())
        setCookie(url.toString(), "triomi_private=; Path=/private; Secure; Max-Age=0")
    }

    @Test fun cloudflareDenialIsNotAlwaysAChallenge() {
        val detector = CloudflareInterceptor(context, AndroidCookieJar(context)) { "test" }
        fun response(body: String, challenge: Boolean = false): Response = Response.Builder()
            .request(Request.Builder().url("https://triomi-session.invalid/").build())
            .protocol(Protocol.HTTP_1_1).code(403).message("Forbidden")
            .header("Server", "cloudflare")
            .apply { if (challenge) header("cf-mitigated", "challenge") }
            .body(body.toResponseBody()).build()
        response("Access denied: account permission required").use {
            assertFalse(detector.looksLikeChallenge(it))
        }
        response("<html>cf-chl-challenge-platform</html>").use {
            assertTrue(detector.looksLikeChallenge(it))
        }
        response("", challenge = true).use { assertTrue(detector.looksLikeChallenge(it)) }
    }

    @Test fun nativeHostOnlyCookieCannotLeakToAnotherSite() {
        val url = "https://triomi-native.invalid/".toHttpUrl()
        val jar = AndroidCookieJar(context)
        jar.saveFromResponse(url, listOf(Cookie.parse(url, "native_private=ok; Path=/; Secure; Max-Age=600")!!))
        assertTrue(jar.loadForRequest(url).any { it.name == "native_private" })
        assertFalse(jar.loadForRequest("https://unrelated-native.invalid/".toHttpUrl()).any { it.name == "native_private" })
        assertFalse(jar.loadForRequest("https://sub.triomi-native.invalid/".toHttpUrl()).any { it.name == "native_private" })
        assertFalse(jar.loadForRequest("http://triomi-native.invalid/".toHttpUrl()).any { it.name == "native_private" })
        jar.saveFromResponse(url, listOf(Cookie.parse(url, "native_private=; Path=/; Secure; Max-Age=0")!!))
        assertFalse(AndroidCookieJar(context).loadForRequest(url).any { it.name == "native_private" })
    }

    @Test fun openingHomepageImportsNativeLoginPathCookies() {
        val url = "https://triomi-import.invalid/".toHttpUrl()
        val jar = AndroidCookieJar(context)
        jar.saveFromResponse(url, listOf(
            Cookie.parse(url, "native_login=present; Path=/account; Secure; Max-Age=600")!!,
        ))
        val ready = CountDownLatch(1)
        instrumentation.runOnMainSync { jar.prepareBrowser(url) { ready.countDown() } }
        assertTrue("native cookies imported before navigation", ready.await(10, TimeUnit.SECONDS))
        val manager = CookieManager.getInstance()
        assertFalse(manager.getCookie(url.toString()).orEmpty().contains("native_login"))
        assertTrue(manager.getCookie(url.resolve("/account/profile")!!.toString()).orEmpty()
            .contains("native_login=present"))
        setCookie(url.toString(), "native_login=; Path=/account; Secure; Max-Age=0")
        jar.saveFromResponse(url, listOf(Cookie.parse(url, "native_login=; Path=/account; Secure; Max-Age=0")!!))
    }

    @Test fun cookieAcrossProcesses() {
        val phase = InstrumentationRegistry.getArguments().getString("sessionPhase", "save")
        val url = "https://triomi-restart.invalid/".toHttpUrl()
        val jar = AndroidCookieJar(context)
        if (phase == "save") {
            setCookie(url.toString(), "triomi_restart=persisted; Path=/; Secure; Max-Age=600")
            instrumentation.runOnMainSync { jar.useBrowserSession(setOf(url.host)) }
        } else {
            assertEquals("resume", phase)
        }
        assertEquals("persisted", jar.loadForRequest(url).single { it.name == "triomi_restart" }.value)
        if (phase == "resume") {
            setCookie(url.toString(), "triomi_restart=; Path=/; Secure; Max-Age=0")
        }
    }

    @Test fun persistedRealApkAbiAndFailureBoundaries() {
        lateinit var host: MihonHost
        instrumentation.runOnMainSync { host = MihonHost(context) }
        val prefs = context.getSharedPreferences("mihon.host", Context.MODE_PRIVATE)
        val packages = mapOf(
            "eu.kanade.tachiyomi.extension.all.mangadex" to "1.6",
            "eu.kanade.tachiyomi.extension.zh.eighteenmanhua" to "1.6",
            "eu.kanade.tachiyomi.extension.zh.copymanga" to "1.4",
        )
        for ((pkg, abi) in packages) {
            val path = prefs.getString("apk.$pkg", null)
                ?: File(context.filesDir, "mihon-regression/$pkg.apk").absolutePath
            val signer = prefs.getString("signer.$pkg", null) ?: if (abi == "1.4")
                "896d1ca35175c42baf61b1a157e4354df9568beed4ccc82a03762d1167005e79"
                else "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"
            val version = prefs.getLong("version.$pkg", if (abi == "1.4") 85 else if (pkg.contains("eighteen")) 106003 else 106000)
            val wasEnabled = prefs.getBoolean("enabled.$pkg", false)
            val pinsBefore = prefs.all.toMap()
            val stagingBefore = File(context.filesDir, "mihon-staging").listFiles()?.map { it.name }?.toSet().orEmpty()
            val metadata = host.metadata(path, pkg, version)
            assertEquals(true, metadata["signatureVerified"])
            assertEquals(pkg, metadata["packageName"])
            assertEquals(version, metadata["versionCode"])
            assertEquals("metadata must not publish an executable runtime", null, metadata["executable"])
            assertEquals("metadata must not import trust or enable preferences", pinsBefore, prefs.all.toMap())
            assertEquals("metadata must not stage extra APK bytes", stagingBefore,
                File(context.filesDir, "mihon-staging").listFiles()?.map { it.name }?.toSet().orEmpty())
            val inspected = host.inspect(path, pkg, version, signer)
            assertEquals(true, inspected["signatureVerified"])
            assertEquals(false, host.inspect(path, pkg, version, signer, "0".repeat(64))["executable"])
            assertEquals(inspected["sha256"], metadata["sha256"])
            assertEquals(inspected.toString(), true, inspected["executable"])
            assertEquals(abi, inspected["abi"])
            val sources = inspected["sources"] as List<*>
            assertTrue(sources.isNotEmpty())
            val sourceId = (sources.first() as Map<*, *>)["id"].toString()
            val args = mapOf("packageName" to pkg, "sourceId" to sourceId, "operation" to "browserInfo")
            try {
                host.setEnabled(pkg, true)
                assertEquals(true, host.request(args)["ok"])
                assertEquals(false, host.inspect(path, pkg, version + 1, signer)["executable"])
                assertEquals(false, host.inspect(path, pkg, version, "0".repeat(64))["executable"])
                assertEquals("failed candidate must keep old runtime", true, host.request(args)["ok"])
                host.setEnabled(pkg, false)
                try {
                    host.request(args)
                    fail("disabled extension must reject browser and content requests")
                } catch (expected: IllegalStateException) {
                    assertTrue(expected.message.orEmpty().contains("disabled"))
                }
            } finally {
                host.setEnabled(pkg, wasEnabled)
            }
        }
    }
}
