package com.robinrossner.receipts.ui.detail

import com.robinrossner.receipts.data.Taxonomy
import com.robinrossner.receipts.data.db.ItemRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DetailLogicTest {
    private fun item(uuid: String, dict: String) = ItemRow(
        uuid, dict, 0, null, uuid, 1.0, 1.0, 1.0, null, null, null, null,
        dictNeedsReview = false, categoryFlagged = false, suggestedCategory = null, suggestedParent = null,
    )

    private val taxonomy = Taxonomy(
        listOf(
            Taxonomy.Category("Food", listOf(Taxonomy.Subcategory("Dairy", listOf("Milk", "Cheese")), Taxonomy.Subcategory("Bakery", listOf("Bread", "Milk")))),
            Taxonomy.Category("Household", listOf(Taxonomy.Subcategory("Cleaning", listOf("Soap")))),
        ),
    )

    @Test
    fun theSameProductStaysTogetherInOrderOfFirstAppearance() {
        val groups = DetailLogic.groupItems(listOf(item("1", "a"), item("2", "b"), item("3", "a")))
        assertEquals(listOf(listOf("1", "3"), listOf("2")), groups.map { g -> g.map { it.uuid } })
    }

    @Test
    fun storeSuggestionsSkipTheTypedNameAndStopAtFive() {
        val known = listOf("ALDI", "ALDI SÜD", "Lidl", "REWE", "Edeka", "Penny", "Netto", "Real")
        assertEquals(listOf("ALDI SÜD"), DetailLogic.storeSuggestions(known, "aldi"))
        assertEquals(known.take(5), DetailLogic.storeSuggestions(known, ""))
        assertEquals(listOf("Lidl"), DetailLogic.storeSuggestions(known, " idl "))
        assertTrue(DetailLogic.storeSuggestions(known, "xyz").isEmpty())
    }

    @Test
    fun storeEditsCommitTrimmedAndEmptyReverts() {
        assertEquals(StoreCommit.Revert, DetailLogic.commitStore("   ", "ALDI"))
        assertEquals(StoreCommit.NoChange, DetailLogic.commitStore(" ALDI ", "ALDI"))
        assertEquals(StoreCommit.Update("Lidl"), DetailLogic.commitStore(" Lidl", "ALDI"))
        assertEquals(StoreCommit.Update("Lidl"), DetailLogic.commitStore("Lidl", null))
    }

    @Test
    fun printedTotalCommitRules() {
        assertEquals(TotalCommit.Update(null), DetailLogic.commitTotal("  ", 12.5))
        assertEquals(TotalCommit.NoChange, DetailLogic.commitTotal("", null))
        assertEquals(TotalCommit.Revert, DetailLogic.commitTotal("abc", 12.5))
        assertEquals(TotalCommit.NoChange, DetailLogic.commitTotal("12.50", 12.5))
        assertEquals(TotalCommit.Update(3.49), DetailLogic.commitTotal("3,49", 12.5))
        assertEquals("12.50", DetailLogic.totalString(12.5))
        assertEquals("", DetailLogic.totalString(null))
    }

    @Test
    fun differenceShowsOnlyForARealGap() {
        assertNull(DetailLogic.difference(null, "10"))
        assertNull(DetailLogic.difference(10.0, ""))
        assertNull(DetailLogic.difference(10.0, "x"))
        assertNull(DetailLogic.difference(10.0, "10.00"))
        assertNull("a rounding sliver is no difference", DetailLogic.difference(10.0, "10.004"))
        assertEquals(0.5, DetailLogic.difference(10.0, "9,50")!!, 1e-9)
        assertEquals(2.0, DetailLogic.difference(10.0, "12")!!, 1e-9)
    }

    @Test
    fun theAddFormNeedsANameAndAPrice() {
        assertNull(DetailLogic.parseNewItem("", "1", "2.00"))
        assertNull(DetailLogic.parseNewItem("Milk", "1", ""))
        assertNull(DetailLogic.parseNewItem("Milk", "1", "abc"))
        assertEquals(NewItem("Milk", 1.0, 1.29), DetailLogic.parseNewItem(" Milk ", "x", "1,29"))
        assertEquals(NewItem("Milk", 2.5, 1.0), DetailLogic.parseNewItem("Milk", "2,5", "1"))
    }

    @Test
    fun previewTotalMultipliesAndAcceptsAComma() {
        assertEquals("€10.47", DetailLogic.previewTotal("3", "3,49"))
        assertEquals("€1.25", DetailLogic.previewTotal("0.5", "2.50"))
        assertEquals("—", DetailLogic.previewTotal("", "2.50"))
        assertEquals("—", DetailLogic.previewTotal("2", "abc"))
    }

    @Test
    fun theSummaryLineJoinsWhatIsKnown() {
        assertEquals("1 × €2.49 · Dairy › Milk", DetailLogic.summaryLine(1.0, 2.49, "Dairy", "Milk"))
        assertEquals("2 × €1.00 · Dairy", DetailLogic.summaryLine(2.0, 1.0, "Dairy", ""))
        assertEquals("0.5 × €4.00", DetailLogic.summaryLine(0.5, 4.0, null, null))
        assertEquals("Dairy › Milk", DetailLogic.categoryPath("Dairy", "Milk"))
    }

    @Test
    fun theUsageNoteCountsLineItemsAndReceipts() {
        assertEquals("This changes the shared dictionary entry for this item.", DetailLogic.usageNote(null, null))
        assertEquals("Saving updates the dictionary entry, so it applies to 1 line item across 1 receipt.", DetailLogic.usageNote(1, 1))
        assertEquals("Saving updates the dictionary entry, so it applies to 4 line items across 2 receipts.", DetailLogic.usageNote(4, 2))
    }

    @Test
    fun choosingACategoryResetsTheLevelsBelow() {
        assertEquals(CategoryChoice("Household", "Cleaning", "Soap"), DetailLogic.chooseCategory(taxonomy, "Household"))
        assertEquals(CategoryChoice("Food", "Dairy", "Milk"), DetailLogic.chooseCategory(taxonomy, "Food"))
    }

    @Test
    fun choosingASubcategoryKeepsTheGroupWhenItStillExists() {
        assertEquals(CategoryChoice("Food", "Bakery", "Milk"), DetailLogic.chooseSubcategory(taxonomy, "Food", "Bakery", "Milk"))
        assertEquals(CategoryChoice("Food", "Bakery", "Bread"), DetailLogic.chooseSubcategory(taxonomy, "Food", "Bakery", "Cheese"))
    }

    @Test
    fun looksGoodWaitsForBusyAndReadingReceipts() {
        assertTrue(DetailLogic.looksGoodEnabled(busy = false, stillReading = false))
        assertFalse(DetailLogic.looksGoodEnabled(busy = true, stillReading = false))
        assertFalse(DetailLogic.looksGoodEnabled(busy = false, stillReading = true))
    }

    @Test
    fun photoZoomIsClampedAndStepsByOneAndAHalf() {
        assertEquals(1.5f, PhotoZoom.zoomIn(1f), 1e-6f)
        assertEquals(8f, PhotoZoom.zoomIn(7f), 1e-6f)
        assertEquals(1f, PhotoZoom.zoomOut(1.2f), 1e-6f)
        assertEquals(1f, PhotoZoom.zoomOut(1.5f), 1e-6f)
        assertEquals(2.5f, PhotoZoom.doubleTap(1f), 1e-6f)
        assertEquals(1f, PhotoZoom.doubleTap(2.5f), 1e-6f)
        assertEquals(8f, PhotoZoom.clamp(20f), 1e-6f)
    }

    @Test
    fun actualSizeIsOneImagePixelPerDp() {
        assertEquals(4f, PhotoZoom.actualSize(1600f, 400f), 1e-6f)
        assertEquals(8f, PhotoZoom.actualSize(4000f, 400f), 1e-6f)
        assertEquals(1f, PhotoZoom.actualSize(300f, 400f), 1e-6f)
        assertEquals(1f, PhotoZoom.actualSize(0f, 400f), 1e-6f)
        assertTrue(PhotoZoom.isFit(1f))
        assertFalse(PhotoZoom.isFit(2f))
        assertTrue(PhotoZoom.isActualSize(4f, 4f))
        assertFalse("at zoom 1 the Fit chip is lit, not 100%", PhotoZoom.isActualSize(1f, 1f))
    }

    @Test
    fun panStaysInsideWhatOverhangsThePane() {
        assertEquals(0f, PhotoZoom.maxPan(300f, 1f, 400f), 1e-6f)
        assertEquals(0f, PhotoZoom.maxPan(300f, 1.3f, 400f), 1e-6f)
        assertEquals(100f, PhotoZoom.maxPan(300f, 2f, 400f), 1e-6f)
    }
}
