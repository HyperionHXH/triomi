package io.github.hyperionhxh.triomi

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.UpdateStrategy
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import rx.Observable
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class MihonMemoCompatibilityTest {
    @Test fun sourceMemoSurvivesSearchDetailChapterAndPageHostInvocations() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        lateinit var host: MihonHost
        instrumentation.runOnMainSync { host = MihonHost(context) }
        val packageName = "org.triomi.memo.fixture${UUID.randomUUID().toString().replace("-", "") }"
        val mangaMemo = Json.parseToJsonElement("""{"id":9223372036854775000,"nested":{"values":[true,null,"request-state"]}}""") as JsonObject
        val chapterMemo = Json.parseToJsonElement("""{"imageKey":"opaque-value","episodeId":6286738698187452081}""") as JsonObject
        val source = object : HttpSource() {
            override val name = packageName
            override val lang = "en"
            override val supportsLatest = false
            override val baseUrl = "https://fixture.invalid"
            override fun fetchSearchManga(page: Int, query: String, filters: FilterList) = Observable.just(
                MangasPage(listOf(SManga.create().apply {
                    url = "/work"; title = "Source title"; author = null; artist = "Source artist"
                    status = SManga.ON_HIATUS; initialized = true
                    update_strategy = UpdateStrategy.ONLY_FETCH_ONCE; memo = mangaMemo
                }), false))
            override fun fetchMangaDetails(manga: SManga): Observable<SManga> {
                assertEquals(mangaMemo, manga.memo)
                assertEquals("Source artist", manga.artist)
                assertNull(manga.author)
                assertEquals(SManga.ON_HIATUS, manga.status)
                assertTrue(manga.initialized)
                assertEquals(UpdateStrategy.ONLY_FETCH_ONCE, manga.update_strategy)
                return Observable.just(manga.copy().apply { title = "Detailed source title" })
            }
            override fun fetchChapterList(manga: SManga): Observable<List<SChapter>> {
                assertEquals(mangaMemo, manga.memo)
                assertEquals("Detailed source title", manga.title)
                return Observable.just(listOf(SChapter.create().apply {
                    url = "/chapter"; name = "Source chapter"; memo = chapterMemo
                    scanlator = "Original group"; date_upload = 1727000700000; chapter_number = 3.5f
                }))
            }
            override fun fetchPageList(chapter: SChapter): Observable<List<Page>> {
                assertEquals(chapterMemo, chapter.memo)
                assertEquals("Original group", chapter.scanlator)
                assertEquals(1727000700000, chapter.date_upload)
                return Observable.just(listOf(Page(0, imageUrl = "$baseUrl/image")))
            }
        }
        val type = Class.forName("io.github.hyperionhxh.triomi.MihonHost\$LoadedExtension")
        val constructor = type.declaredConstructors.single().also { it.isAccessible = true }
        @Suppress("UNCHECKED_CAST")
        val loaded = MihonHost::class.java.getDeclaredField("loaded").also { it.isAccessible = true }
            .get(host) as MutableMap<String, Any>
        loaded[packageName] = constructor.newInstance(File(context.cacheDir, "$packageName.apk"), packageName,
            "fixture", source.javaClass.classLoader, null, listOf<Source>(source))
        val pins = context.getSharedPreferences("mihon.host", Context.MODE_PRIVATE)
        pins.edit().putBoolean("enabled.$packageName", true).commit()
        val args = mapOf("packageName" to packageName, "sourceId" to source.id.toString())
        try {
            val searched = host.request(args + mapOf("operation" to "search", "query" to "fixture", "page" to 1))
            assertEquals(true, searched["ok"])
            val manga = (searched["mangas"] as List<*>).single() as Map<*, *>
            assertEquals(mangaMemo.toString(), manga["extensionMemo"])
            val detailed = host.request(args + mapOf("operation" to "detail", "manga" to manga))
            assertEquals(true, detailed["ok"])
            val chapters = host.request(args + mapOf("operation" to "chapters", "manga" to detailed))
            assertEquals(true, chapters["ok"])
            val chapter = (chapters["chapters"] as List<*>).single() as Map<*, *>
            assertEquals(chapterMemo.toString(), chapter["extensionMemo"])
            val pages = host.request(args + mapOf("operation" to "pages", "chapter" to chapter))
            assertEquals(true, pages["ok"])
            assertEquals(1, (pages["pages"] as List<*>).size)
        } finally {
            loaded.remove(packageName)
            pins.edit().remove("enabled.$packageName").commit()
        }
    }
}
