package eu.kanade.tachiyomi.network

import kotlinx.coroutines.CompletableJob
import kotlinx.coroutines.Job
import kotlinx.coroutines.asContextElement
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import rx.Observable
import rx.Subscriber
import rx.Subscription
import rx.functions.Action0
import rx.plugins.RxJavaHooks
import rx.subscriptions.SerialSubscription
import java.io.IOException
import java.util.concurrent.CancellationException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** One host invocation, never a source/client/dispatcher-wide cancellation token. */
class MihonRequestOwner(val requestId: String?) {
    val job: CompletableJob = Job()
    private val lock = Any()
    private val calls = mutableSetOf<Call>()
    private val subscriptions = mutableSetOf<Subscription>()
    private var canceled = false
    private var completed = false

    val isCancelled: Boolean get() = synchronized(lock) { canceled }
    val isActive: Boolean get() = synchronized(lock) { !canceled && !completed }

    fun ensureActive() = synchronized(lock) {
        if (canceled || completed) throw CancellationException("Mihon request is no longer active")
    }

    fun track(call: Call) {
        val cancel = synchronized(lock) {
            if (canceled || completed) true else { calls.add(call); false }
        }
        if (cancel) call.cancel()
    }

    fun untrack(call: Call) { synchronized(lock) { calls.remove(call) } }

    fun track(subscription: Subscription) {
        val cancel = synchronized(lock) {
            if (canceled || completed) true else { subscriptions.add(subscription); false }
        }
        if (cancel) subscription.unsubscribe()
    }

    fun untrack(subscription: Subscription) { synchronized(lock) { subscriptions.remove(subscription) } }

    /** Signals physical I/O first; it never waits for the worker on the channel thread. */
    fun cancel(): Boolean {
        val resources = synchronized(lock) {
            if (canceled || completed) return false
            canceled = true
            calls.toList() to subscriptions.toList()
        }
        resources.first.forEach { it.cancel() }
        resources.second.forEach { runCatching { it.unsubscribe() } }
        job.cancel(CancellationException("Mihon request canceled"))
        return true
    }

    /** Cancellation and cache/result publication have a single linearization point. */
    fun <T> publish(block: () -> T): T = synchronized(lock) {
        ensureActive()
        block()
    }

    fun <T> complete(block: () -> T): T = synchronized(lock) {
        ensureActive()
        block().also { completed = true }
    }

    fun close() {
        val resources = synchronized(lock) {
            completed = true
            (calls.toList() to subscriptions.toList()).also {
                calls.clear()
                subscriptions.clear()
            }
        }
        resources.first.forEach { it.cancel() }
        resources.second.forEach { runCatching { it.unsubscribe() } }
        job.cancel()
    }
}

/**
 * Admission belongs on the channel thread, before worker submission. Unknown/late
 * cancellation never creates tombstones. IDs are unique per invocation; retaining
 * only the last 4096 completed IDs rejects accidental recent replay without an
 * ever-growing registry. No caller may intentionally recycle a retired ID.
 */
class MihonRequestRegistry {
    private val active = mutableMapOf<String, MihonRequestOwner>()
    private val retired = LinkedHashSet<String>()

    @Synchronized fun reserve(requestId: String?): MihonRequestOwner? {
        if (requestId == null) return MihonRequestOwner(null)
        if (active.containsKey(requestId) || retired.contains(requestId)) return null
        return MihonRequestOwner(requestId).also { active[requestId] = it }
    }

    fun cancel(requestId: String): Boolean {
        val owner = synchronized(this) { active[requestId] } ?: return false
        val canceled = owner.cancel()
        release(owner)
        return canceled
    }

    @Synchronized fun release(owner: MihonRequestOwner) {
        val id = owner.requestId ?: return
        if (active[id] !== owner) return
        active.remove(id)
        retired.add(id)
        if (retired.size > 4096) retired.remove(retired.first())
    }
}

/** Carries ownership across coroutine dispatch, Rx schedulers and newCall(). */
object MihonRequestScope {
    private val current = ThreadLocal<MihonRequestOwner?>()
    private var installed = false

    @Synchronized fun install() {
        if (installed) return
        val previous = RxJavaHooks.getOnScheduleAction()
        RxJavaHooks.setOnScheduleAction { action ->
            val decorated = previous?.call(action) ?: action
            val owner = current.get()
            if (owner == null) decorated else Action0 {
                val old = current.get()
                current.set(owner)
                try {
                    // Retired scheduled work must not start another HTTP call.
                    if (owner.isActive) decorated.call()
                } finally {
                    current.set(old)
                }
            }
        }
        installed = true
    }

    fun context(owner: MihonRequestOwner) = current.asContextElement(owner)

    internal fun currentOwner(): MihonRequestOwner? = current.get()

    /** Factory.create runs in newCall's caller, before OkHttp changes threads. */
    val eventListenerFactory = EventListener.Factory {
        val owner = current.get()
        if (owner == null) EventListener.NONE else object : EventListener() {
            override fun callStart(call: Call) { owner.track(call) }
            override fun callEnd(call: Call) { owner.untrack(call) }
            override fun callFailed(call: Call, ioe: IOException) { owner.untrack(call) }
        }
    }

    /** Also covers source-owned custom clients, without changing their TLS/auth. */
    fun <T> execute(client: OkHttpClient, request: Request, consume: (Response) -> T): T {
        val owner = current.get()
        owner?.ensureActive()
        val call = client.newCall(request)
        owner?.track(call)
        return try {
            call.execute().use { response ->
                if (!response.isSuccessful) throw HttpResponseException(response)
                consume(response)
            }
        } finally {
            owner?.untrack(call)
        }
    }

    fun <T> publish(block: () -> T): T {
        val owner = current.get()
        return if (owner == null) block() else owner.publish(block)
    }

    suspend fun <T> awaitSingle(observable: Observable<T>): T = suspendCancellableCoroutine { continuation ->
        val owner = current.get()
        val subscription = SerialSubscription()
        owner?.track(subscription)
        continuation.invokeOnCancellation {
            subscription.unsubscribe()
            owner?.untrack(subscription)
        }
        val subscriber = object : Subscriber<T>() {
            override fun onNext(value: T) {
                owner?.untrack(subscription)
                continuation.resume(value)
            }
            override fun onError(error: Throwable) {
                owner?.untrack(subscription)
                if (continuation.isActive) continuation.resumeWithException(error)
            }
            override fun onCompleted() { }
        }
        subscription.set(subscriber)
        if (continuation.isActive && !subscriber.isUnsubscribed) {
            // RxJava 1's SafeSubscriber shares this subscriber's subscription
            // state. Replacing the SerialSubscription with subscribe()'s return
            // value would unsubscribe both before asynchronous work can emit.
            observable.single().subscribe(subscriber)
        }
    }
}
