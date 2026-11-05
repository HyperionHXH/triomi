package eu.kanade.tachiyomi.network

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Response
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** ABI-compatible coroutine helpers used by Mihon extensions. */
suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    try {
        continuation.resume(execute())
    } catch (error: Throwable) {
        continuation.resumeWithException(error)
    }
}

suspend fun Call.awaitSuccess(): Response {
    val response = await()
    if (!response.isSuccessful) {
        val failure = HttpException(response.code, response.message, response.header("Retry-After"))
        response.close()
        throw failure
    }
    return response
}
