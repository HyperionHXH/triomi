package eu.kanade.tachiyomi.source

import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.network.MihonRequestScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import rx.Observable

interface Source {
    val id: Long
    val name: String
    val lang: String get() = ""
    val supportsLatest: Boolean
    fun getFilterList(): FilterList = FilterList()
    suspend fun getPopularManga(page: Int): MangasPage
    suspend fun getLatestUpdates(page: Int): MangasPage
    suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage
    suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean): SMangaUpdate
    suspend fun getPageList(chapter: SChapter): List<Page>
    val supportsRelatedMangas: Boolean get() = false
    val disableRelatedMangasBySearch: Boolean get() = false
    val disableRelatedMangas: Boolean get() = false
    suspend fun fetchRelatedMangaList(manga: SManga): List<SManga> = throw UnsupportedOperationException("Unsupported")
    suspend fun getRelatedMangaList(manga: SManga, exceptionHandler: (Throwable) -> Unit,
        pushResults: suspend (Pair<String, List<SManga>>, Boolean) -> Unit) {
        if (disableRelatedMangas) return
        val handler = CoroutineExceptionHandler { _, error -> exceptionHandler(error) }
        supervisorScope {
            if (supportsRelatedMangas) launch(handler) { getRelatedMangaListByExtension(manga, pushResults) }
            if (!disableRelatedMangasBySearch) launch(handler) { getRelatedMangaListBySearch(manga, pushResults) }
        }
    }
    suspend fun getRelatedMangaListByExtension(manga: SManga,
        pushResults: suspend (Pair<String, List<SManga>>, Boolean) -> Unit) {
        try {
            val mangas = fetchRelatedMangaList(manga)
            if (mangas.isNotEmpty()) pushResults("" to mangas, false)
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) { android.util.Log.w("MihonSource", "Related extension request failed", error) }
    }
    fun String.stripKeywordForRelatedMangas(): List<String> {
        val regexWhitespace = Regex("\\s+")
        val regexSpecialCharacters =
            Regex("([!~#$%^&*+_|/\\\\,?:;'“”‘’\"<>(){}\\[\\]。・～：—！？、―«»《》〘〙【】「」｜]|\\s-|-\\s|\\s\\.|\\.\\s)")
        val regexNumberOnly = Regex("^\\d+$")

        return replace(regexSpecialCharacters, " ")
            .split(regexWhitespace)
            .map {
                // remove number only
                it.replace(regexNumberOnly, "")
                    .lowercase()
            }
            // exclude single character
            .filter { it.length > 1 }
    }

    suspend fun getRelatedMangaListBySearch(manga: SManga,
        pushResults: suspend (Pair<String, List<SManga>>, Boolean) -> Unit) {
        val words = linkedSetOf(manga.title)
        if (!manga.title.equals(manga.originalTitle, true)) words.add(manga.originalTitle)
        for (word in manga.title.stripKeywordForRelatedMangas() + manga.originalTitle.stripKeywordForRelatedMangas()) {
            if (words.none { it.equals(word, true) }) words.add(word)
        }
        coroutineScope {
            val filters = getFilterList()
            words.filter(String::isNotBlank).forEach { keyword ->
                launch {
                    try {
                        val mangas = getSearchManga(1, keyword.sanitizeRelatedQuery(), filters).mangas
                        if (mangas.isNotEmpty()) pushResults(keyword to mangas, false)
                    } catch (error: CancellationException) { throw error }
                    catch (error: Exception) { android.util.Log.w("MihonSource", "Related search failed", error) }
                }
            }
        }
    }
    fun fetchMangaDetails(manga: SManga): Observable<SManga> = throw UnsupportedOperationException()
    fun fetchChapterList(manga: SManga): Observable<List<SChapter>> = throw UnsupportedOperationException()
    fun fetchPageList(chapter: SChapter): Observable<List<Page>> = throw UnsupportedOperationException()
}

interface CatalogueSource : Source {
    override val lang: String
    override suspend fun getPopularManga(page: Int): MangasPage = MihonRequestScope.awaitSingle(fetchPopularManga(page))
    override suspend fun getLatestUpdates(page: Int): MangasPage = MihonRequestScope.awaitSingle(fetchLatestUpdates(page))
    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage =
        MihonRequestScope.awaitSingle(fetchSearchManga(page, query, filters))
    override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean,
        fetchChapters: Boolean): SMangaUpdate = supervisorScope {
        val details = if (fetchDetails) async { MihonRequestScope.awaitSingle(fetchMangaDetails(manga)) } else null
        val updated = if (fetchChapters) async { MihonRequestScope.awaitSingle(fetchChapterList(manga)) } else null
        SMangaUpdate(details?.await() ?: manga, updated?.await() ?: chapters)
    }
    override suspend fun getPageList(chapter: SChapter): List<Page> = MihonRequestScope.awaitSingle(fetchPageList(chapter))
    fun fetchPopularManga(page: Int): Observable<MangasPage> = throw UnsupportedOperationException()
    fun fetchLatestUpdates(page: Int): Observable<MangasPage> = throw UnsupportedOperationException()
    fun fetchSearchManga(page: Int, query: String, filters: FilterList): Observable<MangasPage> = throw UnsupportedOperationException()
}

interface SourceFactory { fun createSources(): List<Source> }

// QuerySanitizer from the pinned host, kept private to avoid another public ABI.
private fun String.sanitizeRelatedQuery(): String = trim()
    .trim(' ', '\u0009', '\u000a', '\u000b', '\u000c', '\u000d', '\u0020', '\u0085',
        '\u00a0', '\u1680', '\u2000', '\u2001', '\u2002', '\u2003', '\u2004', '\u2005',
        '\u2006', '\u2007', '\u2008', '\u2009', '\u200a', '\u2028', '\u2029', '\u202f',
        '\u205f', '\u3000', '-', '_', ',', ':')
    .replace("\u2019", "'").replace("\u2018", "'")
    .replace("\u201c", "\"").replace("\u201d", "\"")
    .replace("\u2013", "-").replace("\u2014", "-").replace("\u2026", "...")
