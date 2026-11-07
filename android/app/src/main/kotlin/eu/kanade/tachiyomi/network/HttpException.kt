package eu.kanade.tachiyomi.network

import okhttp3.Response

/** Public extension ABI, pinned to Komikku 64aeb48 / source-api 1.6. */
open class HttpException @JvmOverloads constructor(
    val code: Int,
    message: String? = null,
    val retryAfter: String? = null,
) : IllegalStateException(if (message == null) "HTTP error $code" else "HTTP $code: $message") {
    // Preserve the previous Triomi getter without treating plugin business codes
    // as proof that a response actually used that HTTP status.
    val statusCode: Int get() = code
}

/** Only response-backed failures may supply transport metadata to Dart. */
internal class HttpResponseException(response: Response) :
    HttpException(response.code, response.message, response.header("Retry-After"))
