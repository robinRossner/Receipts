package com.robinrossner.receipts.ui.settings

import com.robinrossner.receipts.data.FlagPathDraft
import com.robinrossner.receipts.data.FlaggedItem
import com.robinrossner.receipts.data.Taxonomy
import com.robinrossner.receipts.data.TaxonomyPath
import com.robinrossner.receipts.data.db.ReceiptSummary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The pure rules behind the Settings screen and the "Without a category" screens. */
class SettingsAndFlaggedUiLogicTest {
    private val taxonomy = Taxonomy(
        listOf(
            Taxonomy.Category("Food", listOf(Taxonomy.Subcategory("Dairy", listOf("Milk", "Cheese")), Taxonomy.Subcategory("Bakery", listOf("Bread")))),
            Taxonomy.Category("Household", listOf(Taxonomy.Subcategory("Cleaning", emptyList()))),
        ),
    )

    private fun item(id: String, suggestedCategory: String?, parent: String?, count: Int = 1, receipts: List<String> = emptyList()) =
        FlaggedItem(id, "name-$id", null, suggestedCategory, parent, count, count * 1.0, receipts)

    private fun receipt(uuid: String, store: String?, date: String?) = ReceiptSummary(uuid, store, date, null, null, false, null, null, null, null, null)

    // ---- Settings

    @Test
    fun saveAndTestNeedAUsableAddressAndAToken() {
        assertTrue(SettingsLogic.canSave(urlValid = true, hasStoredToken = true, typedToken = ""))
        assertTrue(SettingsLogic.canSave(urlValid = true, hasStoredToken = false, typedToken = "abc"))
        assertFalse(SettingsLogic.canSave(urlValid = true, hasStoredToken = false, typedToken = "  "))
        assertFalse(SettingsLogic.canSave(urlValid = false, hasStoredToken = true, typedToken = "abc"))
    }

    @Test
    fun theAddressProblemShowsOnlyForANonEmptyInvalidAddress() {
        assertNull(SettingsLogic.urlProblem("", valid = false, debugBuild = false))
        assertNull(SettingsLogic.urlProblem("https://a.b", valid = true, debugBuild = false))
        assertEquals("Not a valid address. Use https://…", SettingsLogic.urlProblem("ftp://x", valid = false, debugBuild = false))
        assertTrue(SettingsLogic.urlProblem("ftp://x", valid = false, debugBuild = true)!!.contains("10.0.2.2"))
    }

    @Test
    fun theTokenPlaceholderNamesTheKeystore() {
        assertEquals("Saved in Keystore", SettingsLogic.tokenPlaceholder(true))
        assertEquals("Paste the token", SettingsLogic.tokenPlaceholder(false))
    }

    @Test
    fun onlyTheSavedNoteGoesAwayWhenASyncFinishes() {
        assertTrue(SettingsLogic.clearSavedNote(SettingsLogic.SAVED_NOTE, syncIdle = true))
        assertFalse(SettingsLogic.clearSavedNote(SettingsLogic.SAVED_NOTE, syncIdle = false))
        assertFalse(SettingsLogic.clearSavedNote("Connected. 3 photo(s) on the server, extraction provider: none.", syncIdle = true))
        assertFalse(SettingsLogic.clearSavedNote(null, syncIdle = true))
    }

    @Test
    fun theSyncAndPhotoTextsRead() {
        assertEquals("2 change(s)", SettingsLogic.changeCount(2))
        assertEquals("1 record(s)", SettingsLogic.recordCount(1))
        assertTrue(SettingsLogic.photosFooter("300 MB").startsWith("This phone keeps up to 300 MB of receipt photos"))
    }

    // ---- Flagged cards

    @Test
    fun theSheetShowsOnlyItsOwnEntryAndTheScreenShowsAll() {
        val all = listOf(item("a", "Pet Food", "Household"), item("b", "Pet Food", "Household"), item("c", null, null))
        assertEquals(2, FlaggedLogic.groups(all, null).size)
        val only = FlaggedLogic.groups(all, "b")
        assertEquals(1, only.size)
        assertEquals(listOf("b"), only.single().dictionaryIds)
        assertTrue(FlaggedLogic.groups(all, "zzz").isEmpty())
    }

    @Test
    fun theCardHeadingAndSuggestionLine() {
        val groups = FlaggedLogic.groups(listOf(item("a", "Pet Food", "Household > Pets"), item("c", null, null)), null)
        assertEquals("Pet Food", FlaggedLogic.heading(groups[0]))
        assertEquals("Suggested under Household > Pets", FlaggedLogic.suggestedUnder(groups[0]))
        assertEquals("No suggestion", FlaggedLogic.heading(groups[1]))
        assertNull(FlaggedLogic.suggestedUnder(groups[1]))
        assertEquals("Items without a category", FlaggedLogic.title(null))
        assertEquals("Item without a category", FlaggedLogic.title("a"))
    }

    @Test
    fun theAddButtonNamesThePathOrAsksForOne() {
        assertEquals("Add a category and file this", FlaggedLogic.addLabel(FlagPathDraft(null as TaxonomyPath?), "this"))
        assertEquals("Add “Household > Pets > Pet Food” and file these", FlaggedLogic.addLabel(FlagPathDraft(" Household ", "Pets", "Pet Food "), "these"))
        val oneItem = FlaggedLogic.groups(listOf(item("a", "x", "Food")), null).single()
        val twoItems = FlaggedLogic.groups(listOf(item("a", "x", "Food"), item("b", "x", "Food")), null).single()
        assertEquals("this", FlaggedLogic.these(oneItem))
        assertEquals("these", FlaggedLogic.these(twoItems))
    }

    @Test
    fun theEditorStatusLine() {
        assertEquals("New category: added to the list on all your devices.", FlaggedLogic.statusLine(FlagPathDraft("Household", "Pets", "Pet Food").status(taxonomy)))
        assertEquals("This category already exists; the items are filed there.", FlaggedLogic.statusLine(FlagPathDraft("food", "DAIRY", "milk").status(taxonomy)))
        assertNull(FlaggedLogic.statusLine(FlagPathDraft("", "", "").status(taxonomy)))
    }

    @Test
    fun receiptLinksShowFourAndCountTheRest() {
        val ids = (1..6).map { "uuid-0000000$it" }
        val receipts = listOf(receipt(ids[0], "ALDI", "2026-03-01"), receipt(ids[1], "", "2026-03-02"))
        val links = FlaggedLogic.links(item("a", null, null, receipts = ids), receipts)
        assertEquals(4, links.shown.size)
        assertEquals(2, links.more)
        assertEquals("ALDI · 2026-03-01", links.shown[0].label)
        assertEquals("2026-03-02", links.shown[1].label)
        assertEquals("Receipt #uuid-000", links.shown[2].label)
        assertEquals(0, FlaggedLogic.links(item("b", null, null, receipts = ids.take(4)), receipts).more)
    }

    @Test
    fun theSubcategoryMenuFollowsTheTypedCategoryIgnoringCase() {
        assertEquals(listOf("Dairy", "Bakery"), FlaggedLogic.subcategoryOptions(taxonomy, FlagPathDraft(" food ", "", "")))
        assertTrue(FlaggedLogic.subcategoryOptions(taxonomy, FlagPathDraft("Pets", "", "")).isEmpty())
        assertTrue(FlaggedLogic.subcategoryOptions(taxonomy, FlagPathDraft("", "", "")).isEmpty())
    }

    // ---- Category chooser

    @Test
    fun theChooserStartsAtTheSuggestionWhenItExistsElseAtTheTop() {
        val atSuggestion = ChooserSelection.start(taxonomy, TaxonomyPath("FOOD", "bakery", "Pets"))
        assertEquals(ChooserSelection("Food", "Bakery", "Bread"), atSuggestion)
        val unknownSub = ChooserSelection.start(taxonomy, TaxonomyPath("Household", "Pets", "Pet Food"))
        assertEquals(ChooserSelection("Household", "Cleaning", "General"), unknownSub)
        assertEquals(ChooserSelection("Food", "Dairy", "Milk"), ChooserSelection.start(taxonomy, null))
        assertEquals(ChooserSelection("Food", "Dairy", "Milk"), ChooserSelection.start(taxonomy, TaxonomyPath("Nope", "Dairy", "Cheese")))
    }

    @Test
    fun choosingACategoryOrSubcategoryResetsTheLevelsBelow() {
        val start = ChooserSelection("Food", "Dairy", "Cheese")
        assertEquals(ChooserSelection("Household", "Cleaning", "General"), start.withCategory(taxonomy, "Household"))
        // The old group is not kept, unlike the item editor.
        assertEquals(ChooserSelection("Food", "Bakery", "Bread"), start.withSubcategory(taxonomy, "Bakery"))
        assertEquals(ChooserSelection("Food", "Dairy", "Milk"), start.withItemGroup("Milk"))
    }

    @Test
    fun fileHereNeedsAllThreeValues() {
        assertTrue(ChooserSelection("Food", "Dairy", "Milk").complete)
        assertFalse(ChooserSelection("Food", "Dairy", "").complete)
        assertFalse(ChooserSelection("", "", "").complete)
        assertEquals(TaxonomyPath("Food", "Dairy", "Milk"), ChooserSelection("Food", "Dairy", "Milk").path)
    }
}
