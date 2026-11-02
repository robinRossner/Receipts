package com.robinrossner.receipts.data

import com.robinrossner.receipts.data.db.SyncState
import com.robinrossner.receipts.data.sync.SyncDate
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** "No good category": listing, resolving, adding categories (ReceiptStore+Flagged.swift) on a real (in-memory) Room database. */
@RunWith(RobolectricTestRunner::class)
class FlaggedRepositoryTest {
    private lateinit var env: TestEnv
    private val pets = TaxonomyPath("Household", "Pets", "Pet Food")

    @Before fun setUp() { env = TestEnv() }
    @After fun tearDown() { env.close() }

    /** The shape of the Swift test data: receipts with items, some of them flagged (suggestion = category, parent). */
    private suspend fun seedShop() {
        env.receipt("r1", store = "Fressnapf", date = "2026-03-01", createdAt = "2026-03-01T10:00:00.000Z")
        env.dict("pedigree", "pedigree hundefutter", "Other", "Miscellaneous", "General", flagged = true, suggestedCategory = "Pet Food", suggestedParent = "Household")
        env.dict("butter", "kerrygold butter", "Food", "Dairy & Eggs", "Butter")
        env.dict("zfelix", "felix katzennahrung", "Other", "Miscellaneous", "General", flagged = true, suggestedCategory = "pet food", suggestedParent = "household")
        env.item("i1", "r1", "pedigree", 2.5, 0); env.item("i2", "r1", "butter", 1.5, 1); env.item("i3", "r1", "zfelix", 1.0, 2)

        env.receipt("r2", store = "Fressnapf", date = "2026-03-05", createdAt = "2026-03-05T10:00:00.000Z")
        env.dict("trixie", "trixie kauknochen", "Other", "Miscellaneous", "General", flagged = true, suggestedCategory = "Dog Toys", suggestedParent = "Household > Pets")
        env.item("i4", "r2", "trixie", 4.0)

        env.receipt("r3", store = "Fressnapf", date = "2026-03-06", deletedAt = "2026-04-01T00:00:00.000Z")
        env.dict("schleich", "schleich pferd", "Other", "Miscellaneous", "General", flagged = true, suggestedCategory = "Toys", suggestedParent = "Other")
        env.item("i5", "r3", "schleich", 9.0)

        env.receipt("r4", store = "Fressnapf", date = "2026-03-07", createdAt = "2026-03-07T10:00:00.000Z")
        env.dict("ratgeber", "ratgeber heft", "Other", "Miscellaneous", "General", flagged = true, suggestedCategory = "", suggestedParent = "")
        env.item("i6", "r4", "ratgeber", 3.0)
    }

    @Test
    fun listGroupsAndCountOnlyLiveFlaggedItems() = runBlocking {
        seedShop()
        assertEquals("the item only on a deleted receipt does not count", 4, env.repo.observeFlaggedCount().first())
        val items = env.repo.flaggedItems()
        assertEquals(4, items.size)
        val pedigree = items.first { it.name == "pedigree hundefutter" }
        assertEquals(2.5, pedigree.totalSpend, 0.0001)
        assertEquals(1, pedigree.itemCount)
        assertEquals(listOf("r1"), pedigree.receiptIds)
        assertEquals(items, env.repo.observeFlaggedItems().first())

        val groups = env.repo.flaggedGroups()
        assertEquals("Pet Food / pet food are one group; no suggestion is its own", 3, groups.size)
        val petGroup = groups.first { it.suggestedPath == TaxonomyPath("Household", "Pet Food", "General") }
        assertEquals(2, petGroup.items.size); assertEquals(2, petGroup.itemCount); assertEquals(3.5, petGroup.totalSpend, 0.0001)
        assertEquals("items without a suggestion come last", "", groups.last().id)
        assertEquals("ratgeber heft", groups.last().items.first().name)
    }

    @Test
    fun deletedPurgedAndTombstonedUsesDoNotCount() = runBlocking {
        env.dict("d", "thing", "Other", "Miscellaneous", "General", flagged = true, suggestedCategory = "X", suggestedParent = "Household")
        env.receipt("gone", purged = true); env.item("a", "gone", "d")
        env.receipt("live"); env.item("b", "live", "d", deletedAt = "2026-03-02T00:00:00.000Z")
        assertEquals(0, env.repo.observeFlaggedCount().first())
        assertTrue(env.repo.flaggedItems().isEmpty())
        env.item("c", "live", "d", 2.0)
        assertEquals(1, env.repo.observeFlaggedCount().first())
        // a deleted dictionary entry is out, too
        env.dict("d", "thing", "Other", "Miscellaneous", "General", flagged = true, suggestedCategory = "X", suggestedParent = "Household", deletedAt = "2026-03-03T00:00:00.000Z")
        assertEquals(0, env.repo.observeFlaggedCount().first())
    }

    @Test
    fun receiptIdsAreNewestFirstAndUsesAreCounted() = runBlocking {
        env.dict("d", "thing", "Other", "Miscellaneous", "General", flagged = true, suggestedCategory = "X", suggestedParent = "Household")
        env.receipt("old", createdAt = "2026-01-01T10:00:00.000Z"); env.receipt("new", createdAt = "2026-03-01T10:00:00.000Z")
        env.item("a", "old", "d", 1.0); env.item("b", "new", "d", 2.0); env.item("c", "new", "d", 3.0, position = 1)
        val item = env.repo.flaggedItems().single()
        assertEquals(listOf("new", "old"), item.receiptIds)
        assertEquals(3, item.itemCount)
        assertEquals(6.0, item.totalSpend, 0.0001)
    }

    @Test
    fun resolveWithAnExistingCategoryClearsTheFlagAndFilesTheItem() = runBlocking {
        seedShop()
        val before = env.changes
        val item = env.repo.flaggedItems().first { it.dictionaryId == "pedigree" }
        val result = env.repo.resolveFlaggedItemsTo(listOf(item.dictionaryId), TaxonomyPath("household", "household goods", "HOUSEHOLD GOODS & BATTERIES"))
        assertEquals(FlagResolution.Resolved(1), result)
        val row = env.db.dictionary().get("pedigree")!!
        assertEquals("the taxonomy's spelling", "Household", row.category)
        assertEquals("Household Goods & Batteries", row.itemGroup)
        assertFalse(row.categoryFlagged); assertNull(row.suggestedCategory); assertNull(row.suggestedParent)
        assertTrue("manual override: extraction never changes it again", row.isManualOverride)
        assertFalse(row.needsReview)
        assertEquals("the resolution syncs", SyncState.DIRTY, row.syncState)
        assertTrue(SyncDate.parse(row.updatedAt)!!.isAfter(SyncDate.parse("2026-03-01T10:00:00.000Z")))
        assertTrue("the debounced sync was asked for", env.changes > before)
        assertEquals(3, env.repo.observeFlaggedCount().first())
        // again: not flagged any more, nothing changes
        assertEquals(FlagResolution.Resolved(0), env.repo.resolveFlaggedItemsTo(listOf("pedigree"), Taxonomy.FALLBACK))
    }

    @Test
    fun resolvingToTheFallbackJustClearsTheFlagAndSendsFalseOnPush() = runBlocking {
        seedShop()
        assertEquals(FlagResolution.Resolved(1), env.repo.resolveFlaggedItemsTo(listOf("ratgeber"), Taxonomy.FALLBACK))
        val row = env.db.dictionary().get("ratgeber")!!
        assertFalse(row.categoryFlagged)
        assertEquals(listOf("Other", "Miscellaneous", "General"), listOf(row.category, row.subcategory, row.itemGroup))
        assertEquals(SyncState.DIRTY, row.syncState)
        assertEquals(false, env.store.collectPush(com.robinrossner.receipts.data.api.PushEntity.DICTIONARY).dictionary.first { it.id == "ratgeber" }.categoryFlagged)
    }

    @Test
    fun resolvingToAPathThatIsNotInTheTaxonomyIsRefused() = runBlocking {
        seedShop()
        val result = env.repo.resolveFlaggedItemsTo(listOf("pedigree"), pets)
        assertEquals(FlagResolution.Invalid("Household > Pets > Pet Food is not in the category list. Add it first."), result)
        assertTrue(env.db.dictionary().get("pedigree")!!.categoryFlagged)
        assertEquals(SyncState.SYNCED, env.db.dictionary().get("pedigree")!!.syncState)
    }

    @Test
    fun resolvingTakesOnlyFlaggedEntries() = runBlocking {
        seedShop()
        val result = env.repo.resolveFlaggedItemsTo(listOf("butter", "pedigree", "does-not-exist"), TaxonomyPath("Household", "Household Goods", "Household Goods & Batteries"))
        assertEquals(FlagResolution.Resolved(1), result)
        assertEquals("an unflagged entry is left alone", "Butter", env.db.dictionary().get("butter")!!.itemGroup)
        assertEquals(SyncState.SYNCED, env.db.dictionary().get("butter")!!.syncState)
    }

    @Test
    fun resolveByAddingTheSuggestedCategoryExtendsTheTaxonomyAndResolvesTheGroup() = runBlocking {
        env.receipt("r1", store = "Fressnapf")
        env.dict("pedigree", "pedigree hundefutter", "Other", "Miscellaneous", "General", flagged = true, suggestedCategory = "Pet Food", suggestedParent = "Household > Pets")
        env.dict("zfelix", "felix katzennahrung", "Other", "Miscellaneous", "General", flagged = true, suggestedCategory = "Pet Food", suggestedParent = "household > pets")
        env.item("i1", "r1", "pedigree", 2.5); env.item("i2", "r1", "zfelix", 1.0, 1)
        val group = env.repo.flaggedGroups().first()
        assertEquals(pets, group.suggestedPath)
        assertFalse(env.repo.taxonomy.value.contains(pets))

        val result = env.repo.resolveFlaggedItemsAdding(group.dictionaryIds, group.suggestedPath!!)
        assertEquals(FlagResolution.Resolved(2), result)
        val merged = env.awaitTaxonomy { it.contains(pets) }
        assertEquals(listOf("Pet Food"), merged.itemGroups("Household", "Pets"))
        assertFalse("the bundled taxonomy stays as it is", env.base.contains(pets))
        val added = env.db.taxonomy().all()
        assertEquals(1, added.size)
        assertEquals(SyncState.DIRTY, added[0].syncState)
        assertEquals("household > pets > pet food", added[0].pathKey)
        assertEquals(2, env.db.dictionary().live().count { it.itemGroup == "Pet Food" && !it.categoryFlagged })
        assertEquals("a dirty addition is an unsent change", 3, env.store.unsentChangeCount())  // 2 entries + the path

        // the same path in another case is a no-op; an existing category keeps its spelling
        assertEquals(FlagResolution.Resolved(0), env.repo.addTaxonomyPath(TaxonomyPath("household", "pets", "pet food")))
        assertEquals(FlagResolution.Resolved(1), env.repo.addTaxonomyPath(TaxonomyPath("household", "PETS", "Cat Litter")))
        assertEquals(listOf("Pet Food", "Cat Litter"), env.awaitTaxonomy { it.itemGroups("Household", "Pets").size == 2 }.itemGroups("Household", "Pets"))
        assertEquals(TaxonomyPath("Household", "Pets", "Cat Litter"), env.db.taxonomy().all().last().let { TaxonomyPath(it.category, it.subcategory, it.itemGroup) })
        assertEquals(2, env.db.taxonomy().all().size)
    }

    @Test
    fun theAdditionsSurviveReopeningTheDatabase() = runBlocking {
        val name = "reopen-test.db"
        val first = TestEnv(name = name)
        assertEquals(FlagResolution.Resolved(1), first.repo.addTaxonomyPath(pets))
        first.close()
        val second = TestEnv(name = name)
        try {
            assertTrue(second.awaitTaxonomy { it.contains(pets) }.contains(pets))
        } finally {
            second.close()
            second.context.deleteDatabase(name)
        }
    }

    @Test
    fun invalidCategoryNamesAreRefused() = runBlocking {
        for (bad in listOf(TaxonomyPath("", "Pets", "Pet Food"), TaxonomyPath("Household", "A > B", "x"), TaxonomyPath("Household", "Pets", "x".repeat(61)))) {
            assertTrue(bad.label, env.repo.addTaxonomyPath(bad) is FlagResolution.Invalid)
        }
        assertTrue(env.repo.resolveFlaggedItemsAdding(listOf("1"), TaxonomyPath("Household", "Pets", "  ")) is FlagResolution.Invalid)
        assertTrue(env.db.taxonomy().all().isEmpty())
        // spaces and tabs around a name are trimmed, not refused
        assertEquals(FlagResolution.Resolved(1), env.repo.addTaxonomyPath(TaxonomyPath(" Household ", "\tPets", "Pet Food ")))
        assertEquals("household > pets > pet food", env.db.taxonomy().all().single().pathKey)
    }

    @Test
    fun editingTheCategoryThroughTheNormalPathClearsTheFlag() = runBlocking {
        seedShop()
        env.repo.correctItem("pedigree", "Household", "Cleaning", "Laundry", null)
        assertEquals(3, env.repo.observeFlaggedCount().first())
        val row = env.db.dictionary().get("pedigree")!!
        assertFalse(row.categoryFlagged); assertNull(row.suggestedCategory); assertNull(row.suggestedParent)
        assertEquals("Laundry", row.itemGroup)
        assertTrue(row.isManualOverride)
    }

    @Test
    fun overviewTotalsStayCorrectWhileFlaggedAndAfterResolving() = runBlocking {
        env.receipt("r1", store = "Fressnapf", date = "2026-03-01")
        env.dict("pedigree", "pedigree hundefutter", "Other", "Miscellaneous", "General", flagged = true, suggestedCategory = "Pet Food", suggestedParent = "Household > Pets")
        env.dict("butter", "kerrygold butter", "Food", "Dairy & Eggs", "Butter")
        env.item("i1", "r1", "pedigree", 2.5); env.item("i2", "r1", "butter", 1.5, 1)
        val before = env.repo.statsSummary(null, null)
        assertEquals(4.0, before.total, 0.001)
        val other = before.categories.first { it.category == "Other" }
        assertEquals("a flagged item counts under Other > Miscellaneous > General", 2.5, other.total, 0.001)
        assertEquals("General", other.subcategories.first().itemGroups.first().itemGroup)

        env.repo.resolveFlaggedItemsAdding(listOf("pedigree"), pets)
        val after = env.repo.statsSummary(null, null)
        assertEquals("same money, filed elsewhere", 4.0, after.total, 0.001)
        assertNull(after.categories.firstOrNull { it.category == "Other" })
        assertEquals("Pets", after.categories.first { it.category == "Household" }.subcategories.first().subcategory)
    }

}
