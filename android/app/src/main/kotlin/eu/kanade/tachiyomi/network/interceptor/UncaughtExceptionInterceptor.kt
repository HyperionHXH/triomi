package eu.kanade.tachiyomi.network.interceptor

import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException

/**
 * Mihon source-api requires this first interceptor on the default client.
 * It also keeps extension exceptions inside the request boundary.
 */
class UncaughtExceptionInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        return try {
            chain.proceed(chain.request())
        } catch (error: Exception) {
            if (error is IOException) throw error
            throw IOException(error)
        }
    }
}
