@file:Suppress("FunctionName")

package eu.kanade.tachiyomi.network

import okhttp3.CacheControl
import okhttp3.Headers
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import java.util.concurrent.TimeUnit

private val DEFAULT_CACHE_CONTROL = CacheControl.Builder().maxAge(10, TimeUnit.MINUTES).build()
private val DEFAULT_HEADERS = Headers.Builder().build()
private val DEFAULT_BODY: RequestBody = FormBody.Builder().build()

// Kept in its own file because extensions compiled against source-api resolve
// these top-level functions as eu.kanade.tachiyomi.network.RequestsKt.
fun GET(url: String, headers: Headers = DEFAULT_HEADERS, cacheControl: CacheControl? = DEFAULT_CACHE_CONTROL): Request {
    val builder = Request.Builder().url(url).headers(headers)
    if (cacheControl != null) builder.cacheControl(cacheControl)
    return builder.get().build()
}

fun GET(url: HttpUrl, headers: Headers = DEFAULT_HEADERS, cacheControl: CacheControl? = DEFAULT_CACHE_CONTROL): Request = GET(url.toString(), headers, cacheControl)
fun POST(url: String, headers: Headers = DEFAULT_HEADERS, body: RequestBody = DEFAULT_BODY, cacheControl: CacheControl? = DEFAULT_CACHE_CONTROL): Request {
    val builder = Request.Builder().url(url).headers(headers).post(body)
    if (cacheControl != null) builder.cacheControl(cacheControl)
    return builder.build()
}

fun PUT(url: String, headers: Headers = DEFAULT_HEADERS, body: RequestBody = DEFAULT_BODY, cacheControl: CacheControl? = DEFAULT_CACHE_CONTROL): Request =
    requestWithBody("PUT", url, headers, body, cacheControl)

fun PATCH(url: String, headers: Headers = DEFAULT_HEADERS, body: RequestBody = DEFAULT_BODY, cacheControl: CacheControl? = DEFAULT_CACHE_CONTROL): Request =
    requestWithBody("PATCH", url, headers, body, cacheControl)

fun DELETE(url: String, headers: Headers = DEFAULT_HEADERS, body: RequestBody = DEFAULT_BODY, cacheControl: CacheControl? = DEFAULT_CACHE_CONTROL): Request =
    requestWithBody("DELETE", url, headers, body, cacheControl)

private fun requestWithBody(method: String, url: String, headers: Headers, body: RequestBody, cacheControl: CacheControl?): Request {
    val builder = Request.Builder().url(url).headers(headers).method(method, body)
    if (cacheControl != null) builder.cacheControl(cacheControl)
    return builder.build()
}

fun Response.awaitSuccess(): Response {
    if (!isSuccessful) {
        val failure = HttpResponseException(this)
        close()
        throw failure
    }
    return this
}
