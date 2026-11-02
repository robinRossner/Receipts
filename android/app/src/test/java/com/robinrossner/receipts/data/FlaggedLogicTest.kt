package com.robinrossner.receipts.data

import com.robinrossner.receipts.data.db.ReceiptSummary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The pure parts of "items without a category": the draft of a new category, the wording, the grouping. */
class FlaggedLogicTest {
    private val taxonomy = bundledTaxonomy()

    @Test
    fun theDraftStartsFromTheSuggestionAndTrims() {
        val draft = FlagPathDraft(TaxonomyPath("Household", "Pets", "Pet Food"))
        assertEquals(TaxonomyPath("Household", "Pets", "Pet Food"), draft.path)
        assertEquals("Dog Food", draft.copy(itemGroup = "  Dog Food\t").path.itemGroup)
        assertTrue(FlagPathDraft(null as TaxonomyPath?).isEmpty)
        assertTrue(FlagPathDraft(" ", "\t", "").isEmpty)
        assertFalse(draft.isEmpty)
    }

    @Test
    fun theDraftStatusSaysNewExistingOrInvalid() {
        assertEquals(FlagPathDraft.Status.New, FlagPathDraft(TaxonomyPath("Household", "Pets", "Pet Food")).status(taxonomy))
        assertEquals("case does not matter", FlagPathDraft.Status.Existing, FlagPathDraft(TaxonomyPath("food", "dairy & eggs", "MILK")).status(taxonomy))
        assertTrue("a > is refused", FlagPathDraft(TaxonomyPath("Household", "Pets", "Pet > Food")).status(taxonomy) is FlagPathDraft.Status.Invalid)
        assertTrue("empty is refused", FlagPathDraft(null as TaxonomyPath?).status(taxonomy) is FlagPathDraft.Status.Invalid)
    }

    @Test
    fun theTextsRead() {
        assertEquals("1 purchase · €2.50", FlaggedText.usage(1, 2.5))
        assertEquals("3 purchases · €12.00", FlaggedText.usage(3, 12.0))
        val path = TaxonomyPath("A", "B", "C")
        assertEquals("Filed 1 item under A > B > C.", FlaggedText.filed(1, path))
        assertEquals("Filed 2 items under A > B > C.", FlaggedText.filed(2, path))
        assertEquals("No good category. Suggested: Pet Food", FlaggedText.mark("Pet Food"))
        assertEquals("No good category", FlaggedText.mark(null))
        assertEquals("No good category", FlaggedText.mark(""))
        val receipts = listOf(ReceiptSummary("7aaaaaaa-1111", "ALDI", "2026-03-01", null, null, false, null, null, null, null, null))
        assertEquals("ALDI · 2026-03-01", FlaggedText.receiptLabel("7aaaaaaa-1111", receipts))
        assertEquals("Receipt #8bbbbbbb", FlaggedText.receiptLabel("8bbbbbbb-2222", receipts))
        val blankStore = listOf(ReceiptSummary("r", "", "2026-03-01", null, null, false, null, null, null, null, null))
        assertEquals("blank parts are dropped", "2026-03-01", FlaggedText.receiptLabel("r", blankStore))
    }

    @Test
    fun suggestionsBecomePaths() {
        assertEquals(TaxonomyPath("Household", "Pet Food", "General"), FlaggedItems.path("Pet Food", "Household"))
        assertEquals(TaxonomyPath("Household", "Pets", "Pet Food"), FlaggedItems.path("Pet Food", "Household > Pets"))
        assertNull(FlaggedItems.path("Pet Food", "A > B > C"))
        assertNull(FlaggedItems.path("", "Household"))
        assertNull(FlaggedItems.path(null, "Household"))
        assertNull(FlaggedItems.path("Pet Food", null))
    }

    private fun item(id: String, sc: String?, sp: String?, count: Int = 1) = FlaggedItem(id, id, null, sc, sp, count, count.toDouble(), emptyList())

    @Test
    fun groupingIsCaseInsensitiveBiggestFirstAndTheGroupWithoutASuggestionLast() {
        val groups = FlaggedItems.group(
            listOf(
                item("none", null, null, count = 9), item("a", "Pet Food", "Household"), item("b", "pet food", "household"),
                item("c", "Toys", "Other", count = 3), item("d", "Dog Toys", "Household > Pets"),
            ),
        )
        assertEquals("by item count, then key", listOf("other|toys|general", "household|pet food|general", "household|pets|dog toys", ""), groups.map { it.id })
        assertEquals("", groups.last().id)
        assertEquals(9, groups.last().itemCount)
        val pet = groups.first { it.id == "household|pet food|general" }
        assertEquals(listOf("a", "b"), pet.dictionaryIds)
        assertEquals("Pet Food", pet.suggestedCategory)
        assertEquals(TaxonomyPath("Household", "Pet Food", "General"), pet.suggestedPath)
        assertEquals(2, pet.itemCount); assertEquals(2.0, pet.totalSpend, 0.0001)
    }
}
