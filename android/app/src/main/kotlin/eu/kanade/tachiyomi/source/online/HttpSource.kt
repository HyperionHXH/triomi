package eu.kanade.tachiyomi.source.online

import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.MihonRequestScope
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
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.awaitSuccess
import eu.kanade.tachiyomi.network.newCachelessCallWithProgress
import rx.Observable
import java.security.MessageDigest
import java.net.URI
import java.net.URISyntaxException

abstract class HttpSource : CatalogueSource {
    // Public getter is part of the extension ABI (plugins call getNetwork()).
    open val network: NetworkHelper by lazy { MihonRuntime.network() }
    abstract val baseUrl: String
    open fun getHomeUrl(): String = baseUrl
    open val versionId: Int = 1
    override val id: Long by lazy {
        generateId(name, lang, versionId)
    }
    protected fun generateId(name: String, lang: String, versionId: Int): Long {
        val digest = MessageDigest.getInstance("MD5").digest("${name.lowercase()}/$lang/$versionId".toByteArray())
        return digest.take(8).fold(0L) { value, byte -> (value shl 8) or (byte.toLong() and 0xff) } and Long.MAX_VALUE
    }
    open val headers: Headers by lazy { headersBuilder().build() }
    private var clientOverride: OkHttpClient? = null
    open var client: OkHttpClient
        get() = clientOverride ?: network.client
        set(value) { clientOverride = value }
    protected open fun headersBuilder(): Headers.Builder = Headers.Builder().add("User-Agent", network.defaultUserAgentProvider())
    override fun toString(): String = "$name (${lang.uppercase()})"

    override fun fetchPopularManga(page: Int): Observable<MangasPage> = Observable.fromCallable {
        MihonRequestScope.execute(client, popularMangaRequest(page), ::popularMangaParse)
    }
    protected open fun popularMangaRequest(page: Int): Request = unsupported()
    protected open fun popularMangaParse(response: Response): MangasPage = unsupported()
    override fun fetchSearchManga(page: Int, query: String, filters: FilterList): Observable<MangasPage> = Observable.fromCallable {
        MihonRequestScope.execute(client, searchMangaRequest(page, query, filters), ::searchMangaParse)
    }
    protected open fun searchMangaRequest(page: Int, query: String, filters: FilterList): Request = unsupported()
    protected open fun searchMangaParse(response: Response): MangasPage = unsupported()
    override fun fetchLatestUpdates(page: Int): Observable<MangasPage> = Observable.fromCallable {
        MihonRequestScope.execute(client, latestUpdatesRequest(page), ::latestUpdatesParse)
    }
    open fun latestUpdatesRequest(page: Int): Request = unsupported()
    open fun latestUpdatesParse(response: Response): MangasPage = unsupported()
    override fun fetchMangaDetails(manga: SManga): Observable<SManga> = Observable.fromCallable {
        MihonRequestScope.execute(client, mangaDetailsRequest(manga)) { response -> mangaDetailsParse(response).apply { initialized = true } }
    }
    open fun mangaDetailsRequest(manga: SManga): Request = GET(baseUrl + manga.url, headers)
    protected open fun mangaDetailsParse(response: Response): SManga = unsupported()
    override fun fetchChapterList(manga: SManga): Observable<List<SChapter>> = Observable.fromCallable {
        MihonRequestScope.execute(client, chapterListRequest(manga), ::chapterListParse)
    }
    protected open fun chapterListRequest(manga: SManga): Request = GET(baseUrl + manga.url, headers)
    protected open fun chapterListParse(response: Response): List<SChapter> = unsupported()
    override fun fetchPageList(chapter: SChapter): Observable<List<Page>> = Observable.fromCallable {
        MihonRequestScope.execute(client, pageListRequest(chapter), ::pageListParse)
    }
    protected open fun pageListRequest(chapter: SChapter): Request = GET(baseUrl + chapter.url, headers)
    protected open fun pageListParse(response: Response): List<Page> = unsupported()
    open fun fetchImageUrl(page: Page): Observable<String> = Observable.fromCallable {
        MihonRequestScope.execute(client, imageUrlRequest(page), ::imageUrlParse)
    }
    open suspend fun getImageUrl(page: Page): String =
        MihonRequestScope.awaitSingle(fetchImageUrl(page))
    protected open fun imageUrlRequest(page: Page): Request = GET(page.url, headers)
    protected open fun imageUrlParse(response: Response): String = unsupported()
    open fun imageRequest(page: Page): Request = Request.Builder().url(page.imageUrl ?: page.url).headers(headers).build()
    open suspend fun getImage(page: Page): Response = client.newCachelessCallWithProgress(imageRequest(page), page).awaitSuccess()
    open fun prepareNewChapter(chapter: SChapter, manga: SManga) { }
    override suspend fun getPopularManga(page: Int): MangasPage =
        MihonRequestScope.awaitSingle(fetchPopularManga(page))
    override suspend fun getLatestUpdates(page: Int): MangasPage =
        MihonRequestScope.awaitSingle(fetchLatestUpdates(page))
    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage =
        MihonRequestScope.awaitSingle(fetchSearchManga(page, query, filters))
    override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean): SMangaUpdate =
        super.getMangaUpdate(manga, chapters, fetchDetails, fetchChapters)
    override suspend fun getPageList(chapter: SChapter): List<Page> =
        MihonRequestScope.awaitSingle(fetchPageList(chapter))
    open fun getMangaUrl(manga: SManga): String = mangaDetailsRequest(manga).url.toString()
    open fun getChapterUrl(chapter: SChapter): String = pageListRequest(chapter).url.toString()
    fun setUrlWithoutDomain(chapter: SChapter, url: String) { chapter.url = getUrlWithoutDomain(url) }
    fun setUrlWithoutDomain(manga: SManga, url: String) { manga.url = getUrlWithoutDomain(url) }
    private fun getUrlWithoutDomain(url: String): String = try {
        val uri = URI(url.replace(" ", "%20"))
        uri.path + (uri.query?.let { "?$it" } ?: "") + (uri.fragment?.let { "#$it" } ?: "")
    } catch (_: URISyntaxException) { url }
    override val supportsRelatedMangas: Boolean get() = true
    override suspend fun fetchRelatedMangaList(manga: SManga): List<SManga> {
        var type: Class<*>? = javaClass
        var available = false
        while (type != null && type != HttpSource::class.java) {
            if (type.declaredMethods.any { it.name == "relatedMangaListParse" || it.name == "popularMangaParse" }) {
                available = true
                break
            }
            type = type.superclass
        }
        if (!available) return emptyList()
        return MihonRequestScope.execute(client, relatedMangaListRequest(manga), ::relatedMangaListParse)
    }
    protected open fun relatedMangaListRequest(manga: SManga): Request = mangaDetailsRequest(manga)
    protected open fun relatedMangaListParse(response: Response): List<SManga> = popularMangaParse(response).mangas
    protected fun <T> unsupported(): T = throw UnsupportedOperationException("Unsupported source operation")
}

object MihonRuntime {
    @Volatile private var helper: NetworkHelper? = null
    fun install(networkHelper: NetworkHelper) { helper = networkHelper }
    fun network(): NetworkHelper = helper ?: error("Mihon runtime is not initialized")
}
