package eu.kanade.tachiyomi.util

import eu.kanade.tachiyomi.network.MihonRequestScope
import rx.Observable

suspend fun <T> Observable<T>.awaitSingle(): T = MihonRequestScope.awaitSingle(this)
