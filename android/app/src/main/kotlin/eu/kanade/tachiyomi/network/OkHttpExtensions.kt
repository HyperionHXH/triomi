package eu.kanade.tachiyomi.network

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.json.Json
import kotlinx.serialization.serializer
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import rx.Observable
import rx.Producer
import rx.Subscription
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resumeWithException

val jsonMime = "application/json; charset=utf-8".toMediaType()

@Deprecated("Use suspend APIs instead")
fun Call.asObservable(): Observable<Response> = Observable.unsafeCreate { subscriber ->
    val call = clone()
    val owner = MihonRequestScope.currentOwner()
    val arbiter = object : Producer, Subscription {
        private val requested = AtomicBoolean(false)

        override fun request(n: Long) {
            if (n <= 0L || !requested.compareAndSet(false, true)) return
            try {
                owner?.ensureActive()
                owner?.track(call)
                val response = call.execute()
                if (subscriber.isUnsubscribed) {
                    response.close()
                } else {
                    subscriber.onNext(response)
                    subscriber.onCompleted()
                }
            } catch (error: Exception) {
                if (!subscriber.isUnsubscribed) subscriber.onError(error)
            } finally {
                owner?.untrack(call)
            }
        }

        override fun unsubscribe() = call.cancel()
        override fun isUnsubscribed(): Boolean = call.isCanceled()
    }
    subscriber.add(arbiter)
    subscriber.setProducer(arbiter)
}

@Deprecated("Use suspend APIs instead")
fun Call.asObservableSuccess(): Observable<Response> {
    @Suppress("DEPRECATION")
    return asObservable().doOnNext { response -> response.awaitSuccess() }
}

/** Keep extension await asynchronous and tied to the caller's request owner. */
@OptIn(ExperimentalCoroutinesApi::class)
suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
    val owner = MihonRequestScope.currentOwner()
    owner?.ensureActive()
    owner?.track(this)
    continuation.invokeOnCancellation {
        cancel()
        owner?.untrack(this)
    }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            owner?.untrack(call)
            if (continuation.isActive) continuation.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            // The owner retains the call until the response body is closed.
            // Its normal EventListener releases it on callEnd/callFailed.
            continuation.resume(response) { response.close() }
        }
    })
}

suspend fun Call.awaitSuccess(): Response {
    return await().awaitSuccess()
}

fun OkHttpClient.newCachelessCallWithProgress(request: Request, listener: ProgressListener): Call =
    newBuilder().cache(null).addNetworkInterceptor { chain ->
        val response = chain.proceed(chain.request())
        response.newBuilder().body(ProgressResponseBody(response.body, listener)).build()
    }.build().newCall(request)

// Context parameters in the pinned upstream compile to leading Json arguments.
// Spell those arguments explicitly so this ABI does not depend on a compiler flag.
inline fun <reified T> parseAs(json: Json, response: Response): T =
    decodeFromJsonResponse(json, serializer(), response)

fun <T> decodeFromJsonResponse(
    json: Json,
    deserializer: DeserializationStrategy<T>,
    response: Response,
): T = response.body.use { json.decodeFromString(deserializer, it.string()) }
