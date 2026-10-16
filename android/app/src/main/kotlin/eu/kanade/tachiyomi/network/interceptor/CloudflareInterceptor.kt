package eu.kanade.tachiyomi.network.interceptor

import android.content.Context
import eu.kanade.tachiyomi.network.AndroidCookieJar
import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException

/** Detect challenges so callers can offer the visible source browser. */
class CloudflareInterceptor(
    @Suppress("UNUSED_PARAMETER") context: Context,
    @Suppress("UNUSED_PARAMETER") cookieJar: AndroidCookieJar,
    @Suppress("UNUSED_PARAMETER") userAgentProvider: () -> String,
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val response = chain.proceed(chain.request())
        if (!looksLikeChallenge(response)) return response
        response.close()
        throw IOException("Cloudflare challenge required; open the source in a browser to establish a session")
    }

    internal fun looksLikeChallenge(response: Response): Boolean {
        if (response.code !in setOf(403, 503)) return false
        val mitigated = response.header("cf-mitigated").orEmpty().lowercase()
        if (mitigated == "challenge") return true
        val body = response.peekBody(64 * 1024).string().lowercase()
        return body.contains("challenge-platform") ||
            body.contains("cf-chl-") ||
            body.contains("just a moment") ||
            body.contains("/cdn-cgi/challenge-platform/")
    }
}
