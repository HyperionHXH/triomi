package eu.kanade.tachiyomi.network.interceptor

import android.os.SystemClock
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Response
import java.io.IOException
import java.util.ArrayDeque
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.toDuration
import kotlin.time.toDurationUnit

@Deprecated("Use the version with kotlin.time APIs instead.")
fun OkHttpClient.Builder.rateLimit(
    permits: Int,
    period: Long = 1,
    unit: TimeUnit = TimeUnit.SECONDS,
) = addInterceptor(RateLimitInterceptor(null, permits, period.toDuration(unit.toDurationUnit())))

fun OkHttpClient.Builder.rateLimit(permits: Int, period: Duration = 1.seconds) =
    addInterceptor(RateLimitInterceptor(null, permits, period))

@Suppress("PLATFORM_CLASS_MAPPED_TO_KOTLIN")
internal class RateLimitInterceptor(
    private val host: String?,
    private val permits: Int,
    period: Duration,
) : Interceptor {
    init {
        require(permits > 0) { "permits must be positive" }
        require(period.isPositive() && period.isFinite()) { "period must be finite and positive" }
    }

    private val requestQueue = ArrayDeque<Long>(permits)
    private val rateLimitMillis = period.inWholeMilliseconds
    private val fairLock = Semaphore(1, true)

    override fun intercept(chain: Interceptor.Chain): Response {
        val call = chain.call()
        if (call.isCanceled()) throw IOException("Canceled")
        val request = chain.request()
        if (host != null && host != request.url.host) return chain.proceed(request)

        val timestamp: Long
        try {
            // Poll cancellation while waiting; a long rate limit must not hold a retired request.
            while (!fairLock.tryAcquire(100, TimeUnit.MILLISECONDS)) {
                if (call.isCanceled()) throw IOException("Canceled")
            }
            try {
                synchronized(requestQueue) {
                    while (true) {
                        if (call.isCanceled()) throw IOException("Canceled")
                        val now = SystemClock.elapsedRealtime()
                        while (requestQueue.isNotEmpty() && requestQueue.first <= now - rateLimitMillis) {
                            requestQueue.removeFirst()
                        }
                        if (requestQueue.size < permits) {
                            timestamp = now
                            requestQueue.addLast(timestamp)
                            break
                        }
                        (requestQueue as Object).wait((requestQueue.first + rateLimitMillis - now).coerceIn(1L, 100L))
                    }
                }
            } finally {
                fairLock.release()
            }
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw IOException(error)
        }

        val response = chain.proceed(request)
        if (response.networkResponse == null) {
            synchronized(requestQueue) {
                requestQueue.removeFirstOccurrence(timestamp)
                (requestQueue as Object).notifyAll()
            }
        }
        return response
    }
}
