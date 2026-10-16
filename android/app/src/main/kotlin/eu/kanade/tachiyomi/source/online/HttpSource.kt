package eu.kanade.tachiyomi.source.online

import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import okhttp3.Headers
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import rx.Observable
import java.security.MessageDigest

abstract class HttpSource : CatalogueSource {
    // Public getter is part of the extension ABI (plugins call getNetwork()).
    open val network: NetworkHelper by lazy { MihonRuntime.network() }
    abstract val baseUrl: String
    open fun getHomeUrl(): String = baseUrl
    open val versionId: Int = 1
    override val id: Long by lazy {
        val digest = MessageDigest.getInstance("MD5").digest("${name.lowercase()}/$lang/$versionId".toByteArray())
        digest.take(8).fold(0L) { value, byte -> (value shl 8) or (byte.toLong() and 0xff) } and Long.MAX_VALUE
    }
    open val headers: Headers by lazy { headersBuilder().build() }
    private var clientOverride: OkHttpClient? = null
    open var client: OkHttpClient
        get() = clientOverride ?: network.client
        set(value) { clientOverride = value }
    protected open fun headersBuilder(): Headers.Builder = Headers.Builder().add("User-Agent", network.defaultUserAgentProvider())
    override fun toString(): String = "$name (${lang.uppercase()})"

    open fun fetchPopularManga(page: Int): Observable<MangasPage> = Observable.fromCallable {
        client.newCall(popularMangaRequest(page)).execute().use { popularMangaParse(it) }
    }
    protected open fun popularMangaRequest(page: Int): Request = unsupported()
    protected open fun popularMangaParse(response: Response): MangasPage = unsupported()
    open fun fetchSearchManga(page: Int, query: String, filters: FilterList): Observable<MangasPage> = Observable.fromCallable {
        client.newCall(searchMangaRequest(page, query, filters)).execute().use { searchMangaParse(it) }
    }
    protected open fun searchMangaRequest(page: Int, query: String, filters: FilterList): Request = unsupported()
    protected open fun searchMangaParse(response: Response): MangasPage = unsupported()
    open fun fetchLatestUpdates(page: Int): Observable<MangasPage> = Observable.fromCallable {
        client.newCall(latestUpdatesRequest(page)).execute().use { latestUpdatesParse(it) }
    }
    protected open fun latestUpdatesRequest(page: Int): Request = unsupported()
    protected open fun latestUpdatesParse(response: Response): MangasPage = unsupported()
    open fun fetchMangaDetails(manga: SManga): Observable<SManga> = Observable.fromCallable {
        client.newCall(mangaDetailsRequest(manga)).execute().use { mangaDetailsParse(it) }
    }
    open fun mangaDetailsRequest(manga: SManga): Request = unsupported()
    protected open fun mangaDetailsParse(response: Response): SManga = unsupported()
    open fun fetchChapterList(manga: SManga): Observable<List<SChapter>> = Observable.fromCallable {
        client.newCall(chapterListRequest(manga)).execute().use { chapterListParse(it) }
    }
    protected open fun chapterListRequest(manga: SManga): Request = unsupported()
    protected open fun chapterListParse(response: Response): List<SChapter> = unsupported()
    open fun fetchPageList(chapter: SChapter): Observable<List<Page>> = Observable.fromCallable {
        client.newCall(pageListRequest(chapter)).execute().use { pageListParse(it) }
    }
    protected open fun pageListRequest(chapter: SChapter): Request = unsupported()
    protected open fun pageListParse(response: Response): List<Page> = unsupported()
    open fun fetchImageUrl(page: Page): Observable<String> = Observable.fromCallable {
        client.newCall(imageUrlRequest(page)).execute().use { imageUrlParse(it) }
    }
    open suspend fun getImageUrl(page: Page): String =
        fetchImageUrl(page).toBlocking().single()
    protected open fun imageUrlRequest(page: Page): Request = Request.Builder().url(page.imageUrl ?: page.url).build()
    protected open fun imageUrlParse(response: Response): String = response.request.url.toString()
    open fun imageRequest(page: Page): Request = Request.Builder().url(page.imageUrl ?: page.url).headers(headers).build()
    override suspend fun getPopularManga(page: Int): MangasPage =
        fetchPopularManga(page).toBlocking().single()
    override suspend fun getLatestUpdates(page: Int): MangasPage =
        fetchLatestUpdates(page).toBlocking().single()
    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage =
        fetchSearchManga(page, query, filters).toBlocking().single()
    override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean): SMangaUpdate {
        val details = if (fetchDetails) fetchMangaDetails(manga).toBlocking().single() else manga
        val loadedChapters = if (fetchChapters) fetchChapterList(details).toBlocking().single() else chapters
        return SMangaUpdate(details, loadedChapters)
    }
    override suspend fun getPageList(chapter: SChapter): List<Page> =
        fetchPageList(chapter).toBlocking().single()
    open fun getMangaUrl(manga: SManga): String = "$baseUrl${manga.url}"
    open fun getChapterUrl(chapter: SChapter): String = "$baseUrl${chapter.url}"
    fun setUrlWithoutDomain(chapter: SChapter, url: String) { chapter.url = url.removePrefix(baseUrl) }
    fun setUrlWithoutDomain(manga: SManga, url: String) { manga.url = url.removePrefix(baseUrl) }
    protected fun <T> unsupported(): T = throw UnsupportedOperationException("Unsupported source operation")
}

object MihonRuntime {
    @Volatile private var helper: NetworkHelper? = null
    fun install(networkHelper: NetworkHelper) { helper = networkHelper }
    fun network(): NetworkHelper = helper ?: error("Mihon runtime is not initialized")
}
