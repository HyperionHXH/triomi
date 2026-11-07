package io.github.hyperionhxh.triomi

import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import java.util.IdentityHashMap

internal object MihonFilters {
    private const val MAX_DEPTH = 8
    private const val MAX_NODES = 65_536

    // Tag groups can contain thousands of ordinary filters. Bound total work
    // instead of rejecting a valid group solely because it has 257 siblings.
    private class TreeBudget {
        private var remaining = MAX_NODES
        private val ancestors = IdentityHashMap<Filter.Group<*>, Boolean>()

        fun validate(filters: List<Filter<*>>, depth: Int) {
            require(depth in 0 until MAX_DEPTH && filters.size <= remaining) { "Filter tree is too large" }
            remaining -= filters.size
            for (filter in filters) {
                if (filter !is Filter.Group<*>) continue
                require(ancestors.put(filter, true) == null) { "Filter tree contains a cycle" }
                try {
                    validate(children(filter), depth + 1)
                } finally {
                    ancestors.remove(filter)
                }
            }
        }
    }

    private fun typeOf(filter: Filter<*>): String = when (filter) {
        is Filter.Header -> "header"
        is Filter.Separator -> "separator"
        is Filter.Select<*> -> "select"
        is Filter.Text -> "text"
        is Filter.CheckBox -> "check"
        is Filter.TriState -> "tri"
        is Filter.Group<*> -> "group"
        is Filter.Sort -> "sort"
        is Filter.AutoComplete -> "multi"
        else -> error("Unsupported filter type")
    }
    @Suppress("UNCHECKED_CAST")
    private fun children(filter: Filter.Group<*>): List<Filter<*>> = filter.state as List<Filter<*>>

    fun describe(filters: List<Filter<*>>, depth: Int = 0): List<Map<String, Any?>> {
        TreeBudget().validate(filters, depth)
        return describeList(filters)
    }
    private fun describeList(filters: List<Filter<*>>): List<Map<String, Any?>> {
        return filters.mapIndexed { index, filter ->
            mapOf("index" to index, "name" to filter.name, "type" to typeOf(filter),
                "state" to when (filter) {
                    is Filter.Group<*> -> describeList(children(filter))
                    is Filter.Sort -> filter.state?.let { mapOf("index" to it.index, "ascending" to it.ascending) }
                    is Filter.Header, is Filter.Separator -> null
                    else -> filter.state
                },
                "values" to when (filter) {
                    is Filter.Select<*> -> filter.values.map { it.toString() }
                    is Filter.Sort -> filter.values.toList()
                    is Filter.AutoComplete -> filter.values
                    else -> null
                })
        }
    }
    private fun sameValues(filter: Filter<*>, raw: Any?): Boolean {
        val count = when (filter) {
            is Filter.Select<*> -> filter.values.size
            is Filter.Sort -> filter.values.size
            is Filter.AutoComplete -> filter.values.size
            else -> return raw == null
        }
        val rows = raw as? List<*> ?: return false
        if (count != rows.size) return false
        for (i in 0 until count) {
            val value = when (filter) {
                is Filter.Select<*> -> filter.values[i].toString()
                is Filter.Sort -> filter.values[i]
                is Filter.AutoComplete -> filter.values[i]
                else -> return false
            }
            if (value != rows[i]) return false
        }
        return true
    }
    fun apply(filters: FilterList, raw: Any?): FilterList {
        if (raw == null) return filters
        TreeBudget().validate(filters, 0)
        applyList(filters, raw as? List<*> ?: error("Invalid filters"))
        return filters
    }
    @Suppress("UNCHECKED_CAST")
    private fun applyList(filters: List<Filter<*>>, rows: List<*>) {
        require(rows.size == filters.size) { "Saved filters changed; edit the search filters" }
        rows.forEachIndexed { index, value ->
            val row = value as? Map<*, *> ?: error("Invalid filter state")
            val filter = filters[index]
            require(row["name"] == filter.name && row["type"] == typeOf(filter) && sameValues(filter, row["values"])) {
                "Saved filters changed; edit the search filters"
            }
            val state = row["state"]
            when (filter) {
                is Filter.Select<*> -> filter.state = (state as? Number)?.toInt()?.also {
                    require(it in filter.values.indices) { "Invalid selected filter" }
                } ?: error("Invalid selected filter")
                is Filter.Text -> filter.state = state as? String ?: error("Invalid text filter")
                is Filter.CheckBox -> filter.state = state as? Boolean ?: error("Invalid checkbox filter")
                is Filter.TriState -> filter.state = (state as? Number)?.toInt()?.also {
                    require(it in 0..2) { "Invalid tri-state filter" }
                } ?: error("Invalid tri-state filter")
                is Filter.Group<*> -> applyList(children(filter), state as? List<*> ?: error("Invalid filter group"))
                is Filter.AutoComplete -> {
                    require(state is List<*> && state.all { it is String }) { "Invalid tag filter" }
                    filter.state = state as List<String>
                }
                is Filter.Sort -> filter.state = if (state == null) null else {
                    val selection = state as? Map<*, *> ?: error("Invalid sorting filter")
                    val selected = (selection["index"] as? Number)?.toInt() ?: error("Invalid sorting index")
                    require(selected in filter.values.indices) { "Invalid sorting index" }
                    Filter.Sort.Selection(selected, selection["ascending"] as? Boolean ?: error("Invalid sort order"))
                }
            }
        }
    }
}
