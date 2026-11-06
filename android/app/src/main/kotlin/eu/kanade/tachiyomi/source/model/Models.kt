@file:Suppress("PropertyName")
@file:JvmName("SMangaKt")
package eu.kanade.tachiyomi.source.model

import android.net.Uri
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.Serializable as KotlinSerializable
import kotlinx.serialization.Transient
import java.io.Serializable
import eu.kanade.tachiyomi.network.ProgressListener
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class UpdateStrategy { ALWAYS_UPDATE, ONLY_FETCH_ONCE }

interface SManga : Serializable {
    var url: String; var title: String; var thumbnail_url: String?; var artist: String?; var author: String?
    var status: Int; var description: String?; var genre: String?; var update_strategy: UpdateStrategy
    var memo: JsonObject; var initialized: Boolean
    val originalTitle: String get() = title
    val originalAuthor: String? get() = author
    val originalArtist: String? get() = artist
    val originalThumbnailUrl: String? get() = thumbnail_url
    val originalDescription: String? get() = description
    val originalGenre: String? get() = genre
    val originalStatus: Int get() = status
    fun getGenres(): List<String>? = if (genre.isNullOrBlank()) null else genre?.split(", ")?.map { it.trim() }?.filter { it.isNotEmpty() }?.distinct()
    fun copy(): SManga = create().also {
        it.url = url; it.title = originalTitle; it.artist = originalArtist; it.author = originalAuthor
        it.thumbnail_url = originalThumbnailUrl; it.description = originalDescription; it.genre = originalGenre
        it.status = originalStatus; it.update_strategy = update_strategy; it.initialized = initialized; it.memo = memo
    }
    companion object {
        const val UNKNOWN = 0; const val ONGOING = 1; const val COMPLETED = 2; const val LICENSED = 3
        const val PUBLISHING_FINISHED = 4; const val CANCELLED = 5; const val ON_HIATUS = 6
        @JvmStatic fun create(): SManga = SMangaImpl()
        operator fun invoke(url: String, title: String, artist: String? = null, author: String? = null,
            description: String? = null, genre: String? = null, status: Int = 0,
            thumbnail_url: String? = null, initialized: Boolean = false): SManga = create().also {
            it.url = url; it.title = title; it.artist = artist; it.author = author; it.description = description
            it.genre = genre; it.status = status; it.thumbnail_url = thumbnail_url; it.initialized = initialized
        }
    }
}

class SMangaImpl : SManga {
    override lateinit var url: String
    override var title = ""
    override var thumbnail_url: String? = null
    override var artist: String? = null
    override var author: String? = null
    override var status = 0
    override var description: String? = null
    override var genre: String? = null
    override var update_strategy = UpdateStrategy.ALWAYS_UPDATE
    override var memo: JsonObject = buildJsonObject {}
    override var initialized = false
}

interface SChapter : Serializable {
    var url: String; var name: String; var chapter_number: Float; var scanlator: String?; var date_upload: Long; var memo: JsonObject
    companion object {
        @JvmStatic fun create(): SChapter = SChapterImpl()
        operator fun invoke(name: String, url: String, date_upload: Long = 0,
            chapter_number: Float = -1f, scanlator: String? = null): SChapter = create().also {
            it.name = name; it.url = url; it.date_upload = date_upload
            it.chapter_number = chapter_number; it.scanlator = scanlator
        }
    }
    fun copyFrom(other: SChapter) { url = other.url; name = other.name; chapter_number = other.chapter_number; scanlator = other.scanlator; date_upload = other.date_upload; memo = other.memo }
}

class SChapterImpl : SChapter {
    override lateinit var url: String
    override lateinit var name: String
    override var chapter_number = -1f
    override var scanlator: String? = null
    override var date_upload = 0L
    override var memo: JsonObject = buildJsonObject {}
}

@KotlinSerializable
open class Page(val index: Int, var url: String = "", var imageUrl: String? = null,
    @Transient var uri: Uri? = null) : ProgressListener {
    val number: Int get() = index + 1
    @Transient
    private val _statusFlow = MutableStateFlow<State>(State.Queue)
    @Transient
    val statusFlow = _statusFlow.asStateFlow()
    var status: State
        get() = _statusFlow.value
        set(value) { _statusFlow.value = value }
    @Transient
    private val _progressFlow = MutableStateFlow(0)
    @Transient
    val progressFlow = _progressFlow.asStateFlow()
    var progress: Int
        get() = _progressFlow.value
        set(value) { _progressFlow.value = value }
    override fun update(bytesRead: Long, contentLength: Long, done: Boolean) {
        progress = if (contentLength > 0) (100 * bytesRead / contentLength).toInt() else -1
    }
    sealed interface State {
        data object Queue : State
        data object LoadPage : State
        data object DownloadImage : State
        data object Ready : State
        data class Error(val error: Throwable) : State
    }
}

open class MangasPage(open val mangas: List<SManga>, open val hasNextPage: Boolean) {
    operator fun component1(): List<SManga> = mangas
    operator fun component2(): Boolean = hasNextPage
    fun copy(mangas: List<SManga> = this.mangas, hasNextPage: Boolean = this.hasNextPage): MangasPage = MangasPage(mangas, hasNextPage)
    override fun equals(other: Any?): Boolean = this === other || other is MangasPage && mangas == other.mangas && hasNextPage == other.hasNextPage
    override fun hashCode(): Int = 31 * mangas.hashCode() + hasNextPage.hashCode()
    override fun toString(): String = "MangasPage(mangas=$mangas, hasNextPage=$hasNextPage)"
}
class SMangaUpdate(val manga: SManga, val chapters: List<SChapter>)

open class Filter<T>(val name: String, var state: T) {
    override fun equals(other: Any?): Boolean = this === other || other is Filter<*> && name == other.name && state == other.state
    override fun hashCode(): Int = 31 * name.hashCode() + (state?.hashCode() ?: 0)
    open class Header(name: String) : Filter<Any>(name, 0)
    open class Separator(name: String = "") : Filter<Any>(name, 0)
    abstract class Select<V>(name: String, val values: Array<V>, state: Int = 0) : Filter<Int>(name, state)
    abstract class Text(name: String, state: String = "") : Filter<String>(name, state)
    abstract class CheckBox(name: String, state: Boolean = false) : Filter<Boolean>(name, state)
    abstract class TriState(name: String, state: Int = 0) : Filter<Int>(name, state) {
        fun isIgnored() = state == 0
        fun isIncluded() = state == 1
        fun isExcluded() = state == 2
        companion object { const val STATE_IGNORE = 0; const val STATE_INCLUDE = 1; const val STATE_EXCLUDE = 2 }
    }
    abstract class Group<V>(name: String, state: List<V>) : Filter<List<V>>(name, state)
    abstract class Sort(name: String, val values: Array<String>, state: Selection? = null) : Filter<Sort.Selection?>(name, state) {
        data class Selection(val index: Int, val ascending: Boolean)
    }
    abstract class AutoComplete(name: String, val hint: String, val values: List<String>,
        val skipAutoFillTags: List<String> = emptyList(), val validPrefixes: List<String> = emptyList(),
        state: List<String>) : Filter<List<String>>(name, state)
}
// Pinned Komikku source-api 64aeb48: this is a delegated data class, not ArrayList.
data class FilterList(val list: List<Filter<*>>) : List<Filter<*>> by list {
    constructor() : this(emptyList())
    constructor(vararg fs: Filter<*>) : this(if (fs.isNotEmpty()) fs.asList() else emptyList())
    override fun equals(other: Any?): Boolean = false
    override fun hashCode(): Int = list.hashCode()
}

fun SManga.copy(url: String = this.url, title: String = originalTitle, artist: String? = originalArtist,
    author: String? = originalAuthor, description: String? = originalDescription, genre: String? = originalGenre,
    status: Int = this.status, thumbnail_url: String? = originalThumbnailUrl, initialized: Boolean = this.initialized,
    memo: JsonObject = this.memo): SManga = SManga.create().also {
    it.url = url; it.title = title; it.artist = artist; it.author = author; it.description = description
    it.genre = genre; it.status = status; it.thumbnail_url = thumbnail_url; it.initialized = initialized; it.memo = memo
}
