package eu.kanade.tachiyomi.network

import okhttp3.CacheControl
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response

// Kept in its own file because extensions compiled against source-api resolve
// these top-level functions as eu.kanade.tachiyomi.network.RequestsKt.
fun GET(url: String, headers: Headers = Headers.headersOf(), cacheControl: CacheControl? = null): Request {
    val builder = Request.Builder().url(url).headers(headers)
    if (cacheControl != null) builder.cacheControl(cacheControl)
    return builder.get().build()
}

fun GET(url: HttpUrl, headers: Headers = Headers.headersOf(), cacheControl: CacheControl? = null): Request = GET(url.toString(), headers, cacheControl)
fun POST(url: String, headers: Headers = Headers.headersOf(), body: RequestBody, cacheControl: CacheControl? = null): Request {
    val builder = Request.Builder().url(url).headers(headers).post(body)
    if (cacheControl != null) builder.cacheControl(cacheControl)
    return builder.build()
}

fun Response.awaitSuccess(): Response {
    if (!isSuccessful) { close(); throw HttpException(code, message) }
    return this
}

class HttpException(val statusCode: Int, message: String) : java.io.IOException("HTTP $statusCode: $message")
