package eu.kanade.tachiyomi.network

import android.content.Context
import android.webkit.CookieManager
import android.webkit.WebSettings
import okhttp3.Cache
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor
import eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor
import eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
import java.io.File
import java.util.concurrent.TimeUnit

class AndroidCookieJar(context: Context) : CookieJar {
    private val prefs = context.getSharedPreferences("mihon.cookies", Context.MODE_PRIVATE)
    private val browserHosts get() = prefs.getStringSet("browserHosts", emptySet()).orEmpty()

    /** Called on the UI thread before showing a source's browser. */
    @Synchronized
    fun prepareBrowser(url: HttpUrl, onReady: () -> Unit) {
        if (url.host in browserHosts) {
            onReady()
            return
        }
        val manager = CookieManager.getInstance()
        val stored = storedCookies(url).filter {
            // Import every path on this origin, including login endpoints that
            // do not match the homepage used to open the browser.
            it.expiresAt > System.currentTimeMillis() &&
                it.matches(url.newBuilder().encodedPath(it.path).build())
        }.distinctBy { "${it.domain}\n${it.path}\n${it.name}" }
        if (stored.isEmpty()) {
            onReady()
            return
        }
        var remaining = stored.size
        stored.forEach {
            val origin = url.newBuilder().encodedPath(it.path).build()
            manager.setCookie(origin.toString(), it.toString()) {
                remaining--
                if (remaining == 0) {
                    manager.flush()
                    onReady()
                }
            }
        }
    }

    @Synchronized
    fun useBrowserSession(hosts: Set<String>) {
        CookieManager.getInstance().flush()
        prefs.edit().putStringSet("browserHosts", browserHosts + hosts).commit()
    }

    @Synchronized
    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        val stored = prefs.getString(url.host, null)?.lines()?.mapNotNull { Cookie.parse(url, it) }.orEmpty()
        val combined = (stored + cookies).associateBy { "${it.domain}\n${it.path}\n${it.name}" }.values
            .filter { it.expiresAt > System.currentTimeMillis() }
        prefs.edit().putString(url.host, combined.joinToString("\n") { it.toString() }).apply()
        if (url.host in browserHosts) {
            val manager = CookieManager.getInstance()
            cookies.forEach { manager.setCookie(url.toString(), it.toString()) }
            manager.flush()
        }
    }
    @Synchronized
    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        if (url.host in browserHosts) {
            // CookieManager has already applied domain/path/expiry rules. Never
            // persist guessed attributes or resurrect cookies removed at logout.
            return CookieManager.getInstance().getCookie(url.toString()).orEmpty()
                .split(';').mapNotNull { Cookie.parse(url, it.trim()) }
        }
        return storedCookies(url)
            .filter { it.expiresAt > System.currentTimeMillis() && it.matches(url) }
            .distinctBy { "${it.domain}\n${it.path}\n${it.name}" }
    }

    private fun storedCookies(url: HttpUrl): List<Cookie> = prefs.all.entries.flatMap { (host, value) ->
        if (value !is String) return@flatMap emptyList()
        // Host-only cookies omit Domain in Set-Cookie. Rebuild them against
        // their original host, never the host of an unrelated outgoing request.
        val origin = runCatching { url.newBuilder().host(host).encodedPath("/").build() }.getOrNull()
            ?: return@flatMap emptyList()
        value.lines().mapNotNull { Cookie.parse(origin, it) }
    }
}

class NetworkHelper(context: Context) {
    private val cookies = AndroidCookieJar(context)
    private val userAgent = WebSettings.getDefaultUserAgent(context)
    val client: OkHttpClient = OkHttpClient.Builder()
        .cookieJar(cookies)
        .addInterceptor(UncaughtExceptionInterceptor())
        .addInterceptor(UserAgentInterceptor(::defaultUserAgentProvider))
        .addInterceptor(CloudflareInterceptor(context, cookies, ::defaultUserAgentProvider))
        .cache(Cache(File(context.cacheDir, "mihon-http"), 8L * 1024L * 1024L))
        .connectTimeout(30, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS)
        .callTimeout(120, TimeUnit.SECONDS).build()
    val cookieJar: AndroidCookieJar get() = cookies

    // Legacy 1.4 ABI entry. Challenge solving still requires a browser session;
    // sharing this client preserves headers, HTTP cache and persisted cookies.
    fun getCloudflareClient(): OkHttpClient = client

    fun defaultUserAgentProvider(): String = userAgent
}
