package io.github.hyperionhxh.triomi

import androidx.test.ext.junit.runners.AndroidJUnit4
import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MihonFiltersCompatibilityTest {
    @Test fun largeTagGroupsDescribeAndRestoreEveryOptionIncludingTheLastSelection() {
        val tags = List(4096) { tag(it) }
        val languages = List(512) { check(it) }
        val filters = FilterList(group("Tags", tags), group("Languages", languages))
        tags.last().state = Filter.TriState.STATE_EXCLUDE
        languages.last().state = true
        val rows = MihonFilters.describe(filters)
        assertEquals(4096, (rows[0]["state"] as List<*>).size)
        assertEquals(512, (rows[1]["state"] as List<*>).size)
        val restoredTags = List(4096) { tag(it) }
        val restoredLanguages = List(512) { check(it) }
        val restored = FilterList(group("Tags", restoredTags), group("Languages", restoredLanguages))
        assertSame(restored, MihonFilters.apply(restored, rows))
        assertEquals(Filter.TriState.STATE_EXCLUDE, restoredTags.last().state)
        assertTrue(restoredLanguages.last().state)
        assertEquals(Filter.TriState.STATE_IGNORE, restoredTags.first().state)
        assertFalse(restoredLanguages.first().state)
        val changed = FilterList(group("Changed tags", restoredTags), group("Languages", restoredLanguages))
        assertThrows(IllegalArgumentException::class.java) { MihonFilters.apply(changed, rows) }
    }

    @Test fun wideRootAndSharedAcyclicGroupsRemainUsable() {
        val shared = group("Shared", listOf(tag(1), tag(2)))
        val filters = FilterList(List(1024) { check(it) } + listOf(shared, shared))
        val rows = MihonFilters.describe(filters)
        assertEquals(1026, rows.size)
        MihonFilters.apply(filters, rows)
        assertEquals(2, (rows.last()["state"] as List<*>).size)
    }

    @Test fun directAndIndirectCyclesFailBeforeApplyingAnySavedState() {
        val directChildren = mutableListOf<Filter<*>>()
        val direct = group("Direct", directChildren)
        directChildren.add(direct)
        assertCycle(FilterList(direct))
        val firstChildren = mutableListOf<Filter<*>>()
        val secondChildren = mutableListOf<Filter<*>>()
        val first = group("First", firstChildren)
        val second = group("Second", secondChildren)
        firstChildren.add(second)
        secondChildren.add(first)
        assertCycle(FilterList(first))
    }

    @Test fun totalNodeBudgetCountsAcrossGroupsAndRetainsDepthProtection() {
        // The cap is shared by the whole traversal, including group nodes.
        val nearLimit = FilterList(group("Tags", List(65_535) { tag(it) }))
        assertEquals(65_535, (MihonFilters.describe(nearLimit).single()["state"] as List<*>).size)
        val tooWide = FilterList(List(65_537) { tag(it) })
        assertTooLarge(tooWide)
        val tooManyAcrossGroups = FilterList(group("First", List(32_768) { tag(it) }),
            group("Second", List(32_768) { tag(it) }))
        assertTooLarge(tooManyAcrossGroups)
        var deep: Filter<*> = tag(0)
        repeat(8) { deep = group("Level $it", listOf(deep)) }
        assertTooLarge(FilterList(deep))
    }

    private fun assertCycle(filters: FilterList) {
        assertEquals("Filter tree contains a cycle", assertThrows(IllegalArgumentException::class.java) {
            MihonFilters.describe(filters)
        }.message)
        assertEquals("Filter tree contains a cycle", assertThrows(IllegalArgumentException::class.java) {
            MihonFilters.apply(filters, emptyList<Any>())
        }.message)
    }

    private fun assertTooLarge(filters: FilterList) {
        assertEquals("Filter tree is too large", assertThrows(IllegalArgumentException::class.java) {
            MihonFilters.describe(filters)
        }.message)
        assertEquals("Filter tree is too large", assertThrows(IllegalArgumentException::class.java) {
            MihonFilters.apply(filters, emptyList<Any>())
        }.message)
    }

    private fun tag(index: Int) = object : Filter.TriState("Tag $index") {}
    private fun check(index: Int) = object : Filter.CheckBox("Language $index") {}
    private fun group(name: String, children: List<Filter<*>>) = object : Filter.Group<Filter<*>>(name, children) {}
}
