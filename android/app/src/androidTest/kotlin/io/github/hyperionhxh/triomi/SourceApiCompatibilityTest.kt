package io.github.hyperionhxh.triomi

import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.PagePreviewInfo
import eu.kanade.tachiyomi.source.PagePreviewPage
import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.UpdateStrategy
import eu.kanade.tachiyomi.source.model.copy
import eu.kanade.tachiyomi.source.online.ParsedHttpSource
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.put
import okhttp3.Headers
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import rx.Observable

@RunWith(AndroidJUnit4::class)
class SourceApiCompatibilityTest {
    @Test fun filterListHasUpstreamJvmConstructorsAndDataClassMethods() {
        val filter = object : Filter.Text("Search", "before") {}
        val type = FilterList::class.java
        // JM 1.6.64 links directly to this constructor before sending a request.
        val filters = type.getConstructor(List::class.java).newInstance(listOf(filter))
        assertSame(filter, filters.single())
        assertEquals(listOf(filter), type.getMethod("getList").invoke(filters))
        assertEquals(listOf(filter), type.getMethod("component1").invoke(filters))
        assertEquals(0, type.getConstructor().newInstance().size)
        assertEquals(1, type.getConstructor(emptyArray<Filter<*>>().javaClass)
            .newInstance(arrayOf<Filter<*>>(filter) as Any).size)
        val copied = type.getMethod("copy", List::class.java)
            .invoke(filters, listOf(filter)) as FilterList
        filter.state = "after"
        assertEquals("after", copied.single().state)
        // Upstream forces filter updates even when comparing the same instance.
        assertFalse(filters.equals(filters))
        assertEquals(filters.hashCode(), copied.hashCode())
    }

    @Test fun modelsPreserveOriginalFieldsMemoAndLegacyCopyAbi() {
        val manga = object : SManga by SManga.create() {
            override val originalTitle = "Original title"
            override val originalStatus = SManga.COMPLETED
            override fun copy(): SManga = super<SManga>.copy()
        }.apply {
            url = "/book/1"
            title = "User title"
            status = SManga.ONGOING
            memo = buildJsonObject { put("source.id", "1") }
            update_strategy = UpdateStrategy.ONLY_FETCH_ONCE
            initialized = true
        }
        val copy = manga.copy()
        assertEquals("Original title", copy.title)
        assertEquals(SManga.COMPLETED, copy.status)
        assertEquals(manga.memo, copy.memo)
        assertEquals(UpdateStrategy.ONLY_FETCH_ONCE, copy.update_strategy)
        assertTrue(copy.initialized)
        val explicitCopy = manga.copy(title = "Explicit title")
        assertEquals("Explicit title", explicitCopy.title)
        assertEquals(manga.memo, explicitCopy.memo)
        assertNotNull(Class.forName("eu.kanade.tachiyomi.source.model.SMangaKt")
            .declaredMethods.single { it.name == "copy\$default" })
        val page = MangasPage(listOf(manga), true)
        assertEquals(page, page.copy())
        assertSame(manga, page.component1().single())
        assertFalse(page.copy(hasNextPage = false).component2())
        assertEquals(listOf("one", "two"), SManga.create().apply { genre = "one, two, one" }.getGenres())
        assertNull(SManga.create().apply { genre = " " }.getGenres())
    }

    @Test fun pageReportsProgressAndStatusThroughUpstreamFlows() {
        val page = Page(2)
        assertEquals(3, page.number)
        assertSame(Page.State.Queue, page.statusFlow.value)
        page.status = Page.State.DownloadImage
        assertSame(Page.State.DownloadImage, page.statusFlow.value)
        page.update(25, 100, false)
        assertEquals(25, page.progressFlow.value)
        page.update(100, -1, true)
        assertEquals(-1, page.progress)
        val error = IllegalStateException("fixture")
        page.status = Page.State.Error(error)
        assertSame(error, (page.statusFlow.value as Page.State.Error).error)
    }

    @Test fun pageSerializationPersistsSourceFieldsAndResetsTransientRuntimeState() {
        val original = Page(4, "/page", "https://fixture.invalid/image", Uri.parse("content://fixture/page"))
        original.status = Page.State.Ready
        original.progress = 72
        val serializer = Page.serializer()
        val encoded = Json.encodeToString(serializer, original)
        assertEquals(setOf("index", "url", "imageUrl"), Json.parseToJsonElement(encoded).let {
            it as kotlinx.serialization.json.JsonObject
        }.keys)
        val restored = Json.decodeFromString(serializer, encoded)
        assertEquals(4, restored.index)
        assertEquals("/page", restored.url)
        assertEquals("https://fixture.invalid/image", restored.imageUrl)
        assertNull(restored.uri)
        assertSame(Page.State.Queue, restored.statusFlow.value)
        assertEquals(0, restored.progressFlow.value)
        val defaults = Json.decodeFromString(serializer, "{\"index\":0}")
        assertEquals("", defaults.url)
        assertNull(defaults.imageUrl)
        assertEquals("eu.kanade.tachiyomi.source.model.Page", serializer.descriptor.serialName)
        assertNotNull(Class.forName("eu.kanade.tachiyomi.source.model.Page\$\$serializer")
            .getField("INSTANCE").get(null))
    }

    @Test fun pagePreviewSerializationPreservesPaginationWithoutProgressFlow() {
        val preview = PagePreviewInfo(3, "https://fixture.invalid/preview")
        preview.update(1, 4, false)
        assertEquals(25, preview.progress.value)
        val original = PagePreviewPage(2, listOf(preview), true, 7)
        val encoded = Json.encodeToString(PagePreviewPage.serializer(), original)
        assertFalse(encoded.contains("progress"))
        val restored = Json.decodeFromString(PagePreviewPage.serializer(), encoded)
        assertEquals(2, restored.page)
        assertEquals(7, restored.pagePreviewPages)
        assertTrue(restored.hasNextPage)
        assertEquals(3, restored.pagePreviews.single().index)
        assertEquals(preview.imageUrl, restored.pagePreviews.single().imageUrl)
        assertEquals(-1, restored.pagePreviews.single().progress.value)
        restored.pagePreviews.single().update(1, -1, false)
        assertEquals(-1, restored.pagePreviews.single().progress.value)
        val optionalPages = Json.decodeFromString(PagePreviewPage.serializer(),
            "{\"page\":1,\"pagePreviews\":[],\"hasNextPage\":false,\"pagePreviewPages\":null}")
        assertNull(optionalPages.pagePreviewPages)
        assertNotNull(Class.forName("eu.kanade.tachiyomi.source.PagePreviewInfo\$\$serializer")
            .getField("INSTANCE").get(null))
    }

    @Test fun rxCatalogueUsesSuspendBridgeAndOriginalMangaForBothUpdateRequests() = runBlocking {
        val original = SManga("/original", "Original")
        val detailed = SManga("/details", "Details")
        val chapter = SChapter("Chapter", "/chapter")
        var detailsCalls = 0
        var chapterCalls = 0
        val source = object : CatalogueSource {
            override val id = 1L
            override val name = "Rx fixture"
            override val lang = "en"
            override val supportsLatest = true
            override fun fetchSearchManga(page: Int, query: String, filters: FilterList) =
                Observable.just(MangasPage(listOf(original), false))
            override fun fetchMangaDetails(manga: SManga): Observable<SManga> {
                assertSame(original, manga)
                detailsCalls++
                return Observable.just(detailed)
            }
            override fun fetchChapterList(manga: SManga): Observable<List<SChapter>> {
                assertSame(original, manga)
                chapterCalls++
                return Observable.just(listOf(chapter))
            }
        }
        assertSame(original, source.getSearchManga(1, "fixture", FilterList()).mangas.single())
        val update = source.getMangaUpdate(original, emptyList(), true, true)
        assertSame(detailed, update.manga)
        assertSame(chapter, update.chapters.single())
        val unchanged = source.getMangaUpdate(original, listOf(chapter), false, false)
        assertSame(original, unchanged.manga)
        assertSame(chapter, unchanged.chapters.single())
        assertEquals(1, detailsCalls)
        assertEquals(1, chapterCalls)
    }

    @Test fun parsedSourceUsesResponseBaseUriAndDefaultRequestsKeepQueryAndFragment() {
        val source = HtmlSource()
        val response = Response.Builder()
            .request(Request.Builder().url("https://fixture.invalid/catalog/").build())
            .protocol(Protocol.HTTP_1_1).code(200).message("OK")
            .body("<a class='book' href='first'>First</a><a class='next'>Next</a>".toResponseBody())
            .build()
        response.use {
            val page = source.popularMangaParse(it)
            assertEquals("https://fixture.invalid/catalog/first", page.mangas.single().url)
            assertEquals("First", page.mangas.single().title)
            assertTrue(page.hasNextPage)
        }
        val manga = SManga("/original", "Original")
        source.setUrlWithoutDomain(manga, "https://other.invalid/book/1?q=two#page")
        assertEquals("/book/1?q=two#page", manga.url)
        assertEquals("https://fixture.invalid/book/1?q=two#page", source.getMangaUrl(manga))
        val chapter = SChapter("Chapter", "/chapter")
        source.setUrlWithoutDomain(chapter, "https://other.invalid/chapter/2?q=one#image")
        assertEquals("https://fixture.invalid/chapter/2?q=one#image", source.getChapterUrl(chapter))
    }

    private class HtmlSource : ParsedHttpSource() {
        override val name = "HTML fixture"
        override val lang = "en"
        override val supportsLatest = true
        override val baseUrl = "https://fixture.invalid"
        override val headers = Headers.Builder().build()
        override fun popularMangaSelector() = ".book"
        override fun popularMangaFromElement(element: Element) =
            SManga(element.absUrl("href"), element.text())
        override fun popularMangaNextPageSelector() = ".next"
        override fun searchMangaSelector() = popularMangaSelector()
        override fun searchMangaFromElement(element: Element) = popularMangaFromElement(element)
        override fun searchMangaNextPageSelector() = popularMangaNextPageSelector()
        override fun latestUpdatesSelector() = popularMangaSelector()
        override fun latestUpdatesFromElement(element: Element) = popularMangaFromElement(element)
        override fun latestUpdatesNextPageSelector() = popularMangaNextPageSelector()
        override fun mangaDetailsParse(document: Document) = SManga("/details", document.title())
        override fun chapterListSelector() = ".chapter"
        override fun chapterFromElement(element: Element) = SChapter(element.text(), element.attr("href"))
        override fun pageListParse(document: Document) = emptyList<Page>()
        override fun imageUrlParse(document: Document) = document.selectFirst("img")!!.absUrl("src")
        public override fun popularMangaParse(response: Response) = super.popularMangaParse(response)
    }
}
