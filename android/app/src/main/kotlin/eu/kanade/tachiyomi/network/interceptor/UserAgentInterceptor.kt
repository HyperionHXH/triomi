package eu.kanade.tachiyomi.network.interceptor

import okhttp3.Interceptor
import okhttp3.Response

/** Supplies the host default User-Agent when an extension did not set one. */
class UserAgentInterceptor(
    private val defaultUserAgentProvider: () -> String,
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val original = chain.request()
        if (!original.header("User-Agent").isNullOrEmpty()) return chain.proceed(original)
        return chain.proceed(
            original.newBuilder()
                .removeHeader("User-Agent")
                .addHeader("User-Agent", defaultUserAgentProvider())
                .build(),
        )
    }
}
