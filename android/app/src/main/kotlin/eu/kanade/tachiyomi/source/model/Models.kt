@file:Suppress("PropertyName")
package eu.kanade.tachiyomi.source.model

import android.net.Uri
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.buildJsonObject
import java.io.Serializable

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
    fun getGenres(): List<String>? = genre?.split(", ")?.map { it.trim() }?.filter { it.isNotEmpty() }?.distinct()
    companion object {
        const val UNKNOWN = 0; const val ONGOING = 1; const val COMPLETED = 2; const val LICENSED = 3
        const val PUBLISHING_FINISHED = 4; const val CANCELLED = 5; const val ON_HIATUS = 6
        @JvmStatic fun create(): SManga = SMangaImpl()
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
    companion object { @JvmStatic fun create(): SChapter = SChapterImpl() }
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

class Page(val index: Int, var url: String = "", var imageUrl: String? = null, var uri: Uri? = null) {
    val number: Int get() = index + 1
}

open class MangasPage(open val mangas: List<SManga>, open val hasNextPage: Boolean)
class SMangaUpdate(val manga: SManga, val chapters: List<SChapter>)

open class Filter<T>(val name: String, var state: T) {
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
class FilterList : ArrayList<Filter<*>> {
    constructor() : super()
    constructor(vararg filters: Filter<*>) : super(filters.toList())
}
