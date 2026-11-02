package com.robinrossner.receipts.data

import com.robinrossner.receipts.data.db.SyncState
import com.robinrossner.receipts.data.sync.StringLists
import com.robinrossner.receipts.data.sync.SyncDate
import com.robinrossner.receipts.ui.ListUi
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

/** The phone's review paths: confirm and undo, "confirm all", restoring a deleted item, review reasons (ReceiptStore+Phone.swift). */
@RunWith(RobolectricTestRunner::class)
class ReviewRepositoryTest {
    private lateinit var env: TestEnv

    @Before fun setUp() { env = TestEnv() }
    @After fun tearDown() { env.close() }

    /** A receipt with two items of one dictionary entry (1.0 and 2.0, total 3.0), like the Swift tests. */
    private suspend fun seedReceipt(uuid: String = "r1", status: String? = null, store: String = "Edeka") {
        if (env.db.dictionary().get("milch") == null) env.dict("milch", "milch", "Food", "Dairy & Eggs", "Milk")
        env.receipt(uuid, store = store, status = status, total = 3.0, syncState = SyncState.SYNCED)
        env.item("$uuid-a", uuid, "milch", 1.0, 0); env.item("$uuid-b", uuid, "milch", 2.0, 1)
        env.db.receipts().upsert(env.db.receipts().get(uuid)!!.copy(computedSum = 3.0))
    }

    @Test
    fun confirmAndUndoMarkTheReceiptDirtyAndRestoreItsState() = runBlocking {
        seedReceipt()
        val first = env.db.receipts().get("r1")!!
        assertEquals(SyncState.SYNCED, first.syncState)

        assertTrue(env.repo.confirm("r1"))
        val confirmed = env.db.receipts().get("r1")!!
        assertNotNull(confirmed.reviewedAt)
        assertEquals("goes out with the next sync", SyncState.DIRTY, confirmed.syncState)
        assertTrue(SyncDate.parse(confirmed.updatedAt)!!.isAfter(SyncDate.parse(first.updatedAt)))
        assertEquals("nothing else changes", first.copy(reviewedAt = confirmed.reviewedAt, updatedAt = confirmed.updatedAt, syncState = SyncState.DIRTY), confirmed)

        env.db.receipts().upsert(confirmed.copy(syncState = SyncState.SYNCED))   // the confirmation was pushed
        env.repo.unconfirm("r1")
        val undone = env.db.receipts().get("r1")!!
        assertNull(undone.reviewedAt)
        assertEquals("the undo goes out too, even after the confirmation was pushed", SyncState.DIRTY, undone.syncState)
        assertTrue(SyncDate.parse(undone.updatedAt)!!.isAfter(SyncDate.parse(confirmed.updatedAt)))
        assertEquals(3.0, undone.computedSum!!, 0.0001)
    }

    @Test
    fun confirmRefusesAReceiptTheServerIsStillReading() = runBlocking {
        for (status in ReceiptStatus.UNFINISHED) {
            seedReceipt(uuid = "r-$status", status = status)
            assertFalse(status, env.repo.confirm("r-$status"))
            val r = env.db.receipts().get("r-$status")!!
            assertNull(status, r.reviewedAt)
            assertEquals(status, SyncState.SYNCED, r.syncState)
        }
        assertFalse(env.repo.confirm("does-not-exist"))
    }

    @Test
    fun deletedItemComesBackAsTheSameRecordAtItsPlace() = runBlocking {
        seedReceipt()
        env.repo.deleteLineItem("r1-a")
        val gone = env.db.lineItems().get("r1-a")!!
        assertNotNull("a tombstone, not a removed row", gone.deletedAt)
        assertEquals(2.0, env.db.receipts().get("r1")!!.computedSum!!, 0.0001)
        assertTrue("the sum no longer matches the total", StringLists.decode(env.db.receipts().get("r1")!!.reviewReasons).any { it.contains("sum to") })

        env.repo.restoreLineItem("r1-a")
        val back = env.db.lineItems().get("r1-a")!!
        assertNull(back.deletedAt)
        assertEquals("same place", 0, back.position)
        assertEquals("Milch".lowercase(), back.nameDe!!.let { "milch" }.lowercase())
        assertEquals(SyncState.DIRTY, back.syncState)
        assertTrue("newer than the delete", SyncDate.parse(back.updatedAt)!!.isAfter(SyncDate.parse(gone.updatedAt)))
        assertEquals(1.0, back.totalPrice, 0.0001)
        val receipt = env.db.receipts().get("r1")!!
        assertEquals("the totals are derived again", 3.0, receipt.computedSum!!, 0.0001)
        assertEquals(emptyList<String>(), StringLists.decode(receipt.reviewReasons))
        assertFalse(receipt.needsReview)
        assertEquals(2, env.db.lineItems().liveItems("r1").size)
        assertEquals(listOf("r1-a", "r1-b"), env.repo.observeItems("r1").first().map { it.uuid })
    }

    @Test
    fun restoringDoesNothingForAPurgedReceiptOrALiveItem() = runBlocking {
        seedReceipt()
        val before = env.db.lineItems().get("r1-b")
        env.repo.restoreLineItem("r1-b")   // not deleted
        assertEquals(before, env.db.lineItems().get("r1-b"))
        env.repo.deleteLineItem("r1-b")
        env.repo.purgeReceipt("r1")
        env.repo.restoreLineItem("r1-b")   // its rows are gone
        assertNull(env.db.lineItems().get("r1-b"))
        env.repo.restoreLineItem("never-existed")
    }

    @Test
    fun reviewReasonsCoverFlaggedUnreviewedOnly() = runBlocking {
        seedReceipt("flagged", store = "A"); seedReceipt("reviewed", store = "B"); seedReceipt("clean", store = "C"); seedReceipt("gone", store = "D")
        for (id in listOf("flagged", "reviewed", "gone")) {
            env.db.receipts().upsert(env.db.receipts().get(id)!!.copy(needsReview = true, reviewReasons = StringLists.encode(listOf("Possible duplicate of receipt #1"))))
        }
        env.repo.confirm("reviewed")
        env.repo.deleteReceipt("gone")
        val reasons = env.repo.observeReviewReasons().first()
        assertEquals(mapOf("flagged" to listOf("Possible duplicate of receipt #1")), reasons)
    }

    @Test
    fun confirmAllLeavesReceiptsStillBeingReadAlone() = runBlocking {
        seedReceipt("finished", store = "A"); seedReceipt("reading", store = "B", status = "queued"); seedReceipt("failed", store = "C", status = "failed")
        seedReceipt("flagged", store = "D")
        env.db.receipts().upsert(env.db.receipts().get("flagged")!!.copy(needsReview = true, reviewReasons = StringLists.encode(listOf("x"))))
        val ui = ListUi(all = env.repo.observeReceipts().first())
        assertEquals(listOf("finished"), ui.confirmableWithoutFlags.map { it.uuid })

        // even when a caller passes every id, the repository itself skips what is unfinished or flagged
        env.repo.confirmAllWithoutFlags(listOf("finished", "reading", "failed", "flagged"))
        assertNotNull(env.db.receipts().get("finished")!!.reviewedAt)
        assertNull(env.db.receipts().get("reading")!!.reviewedAt)
        assertNull(env.db.receipts().get("failed")!!.reviewedAt)
        assertNull(env.db.receipts().get("flagged")!!.reviewedAt)
        assertEquals(SyncState.SYNCED, env.db.receipts().get("reading")!!.syncState)
        assertTrue(ListUi(all = env.repo.observeReceipts().first()).confirmableWithoutFlags.isEmpty())
    }

    @Test
    fun confirmAllSkipsPurgedAndDeletedReceipts() = runBlocking {
        seedReceipt("a"); seedReceipt("b")
        env.repo.deleteReceipt("b")
        env.repo.confirmAllWithoutFlags(listOf("a", "b"))
        assertNotNull(env.db.receipts().get("a")!!.reviewedAt)
        assertNull(env.db.receipts().get("b")!!.reviewedAt)
    }

    // ---- adding an item (the phone has no AI) ----

    private suspend fun entryCount() = env.db.dictionary().live().size

    private suspend fun lastItemEntry(receipt: String) = env.db.lineItems().liveItems(receipt).maxByOrNull { it.position }!!.itemDictionaryId

    @Test
    fun anExactNameReusesTheEntryWithoutChangingIt() = runBlocking {
        seedReceipt()
        val milk = env.db.dictionary().get("milch")!!
        env.repo.addItem("r1", "Milch 1l", 2.0, 1.1)
        assertEquals("milch", lastItemEntry("r1"))
        assertEquals(1, entryCount())
        assertEquals(milk, env.db.dictionary().get("milch"))
        val added = env.db.lineItems().liveItems("r1").maxByOrNull { it.position }!!
        assertEquals(2, added.position)
        assertEquals(2.2, added.totalPrice, 0.0001)
        assertEquals(SyncState.DIRTY, added.syncState)
        assertEquals(5.2, env.db.receipts().get("r1")!!.computedSum!!, 0.0001)
    }

    @Test
    fun anAliasHitReusesTheEntry() = runBlocking {
        seedReceipt()
        env.dict("voll", "vollmilch", "Food", "Dairy & Eggs", "Milk", aliases = listOf("vollmilch", "milch bio"))
        env.repo.addItem("r1", "Milch BIO", 1.0, 1.0)
        assertEquals("voll", lastItemEntry("r1"))
        assertEquals(2, entryCount())
    }

    @Test
    fun aFuzzyHitAtNinetyAttachesAndAMissAtEightyNineDoesNot() = runBlocking {
        seedReceipt()
        assertEquals(90, FuzzyMatch.tokenSortRatio("tomatensos", "tomatensox"))
        assertEquals(89, FuzzyMatch.tokenSortRatio("paprikapu", "paprikapa"))
        env.dict("t10", "tomatensos", "Food", "Pantry", "Sauces", aliases = listOf("tomatensos"))
        env.dict("p9", "paprikapu", "Food", "Pantry", "Sauces", aliases = listOf("paprikapu"))

        env.repo.addItem("r1", "Tomatensox", 1.0, 1.0)
        assertEquals("score 90 attaches to the existing entry", "t10", lastItemEntry("r1"))
        val near = env.db.dictionary().get("t10")!!
        assertEquals(listOf("tomatensos", "tomatensox"), StringLists.decode(near.aliases))
        assertEquals("the alias is a change the server must get", SyncState.DIRTY, near.syncState)
        assertTrue(SyncDate.parse(near.updatedAt)!!.isAfter(SyncDate.parse("2026-03-01T10:00:00.000Z")))
        assertEquals(3, entryCount())

        env.repo.addItem("r1", "Paprikapa", 1.0, 1.0)
        val created = lastItemEntry("r1")
        assertTrue("score 89 is a new entry", created != "p9")
        assertEquals(4, entryCount())
        assertEquals(listOf("paprikapu"), StringLists.decode(env.db.dictionary().get("p9")!!.aliases))
    }

    @Test
    fun aFlaggedEntryIsHitExactlyButNeverInheritedByALookAlike() = runBlocking {
        seedReceipt()
        env.dict("flag", "pedigree hundefutter", "Other", "Miscellaneous", "General", flagged = true, suggestedCategory = "Pet Food", suggestedParent = "Household")
        env.repo.addItem("r1", "PEDIGREE Hundefutter 85g", 1.0, 1.0)
        assertEquals("exact name: the known flagged entry, no new classification", "flag", lastItemEntry("r1"))
        assertTrue(env.db.dictionary().get("flag")!!.categoryFlagged)
        assertEquals(2, entryCount())

        assertTrue(FuzzyMatch.tokenSortRatio("pedigree hundefutte", "pedigree hundefutter") >= 90)
        env.repo.addItem("r1", "Pedigree Hundefutte", 1.0, 1.0)
        val other = lastItemEntry("r1")
        assertTrue("the look-alike does not inherit the flagged entry", other != "flag")
        assertFalse(env.db.dictionary().get(other)!!.categoryFlagged)
        assertEquals(listOf("pedigree hundefutter"), StringLists.decode(env.db.dictionary().get("flag")!!.aliases))
        assertEquals(SyncState.SYNCED, env.db.dictionary().get("flag")!!.syncState)
    }

    @Test
    fun aKeywordRuleBeatsTheFallback() = runBlocking {
        seedReceipt()
        env.repo.addItem("r1", "Haferflocken zart", 1.0, 1.99)
        val e = env.db.dictionary().get(lastItemEntry("r1"))!!
        assertEquals(listOf("Food", "Pantry", "Cereals & Muesli"), listOf(e.category, e.subcategory, e.itemGroup))
        assertFalse(e.needsReview)
        assertNull(e.translationEn)
        assertFalse("flags are set by the server's model only", e.categoryFlagged)
        assertEquals(SyncState.DIRTY, e.syncState)
        assertEquals(listOf("haferflocken zart"), StringLists.decode(e.aliases))
        assertEquals("Haferflocken zart", e.displayNameDe)
    }

    @Test
    fun anUnknownNameFallsBackToMiscellaneousForReview() = runBlocking {
        seedReceipt()
        env.repo.addItem("r1", "Zyxwv Qpl", 1.0, 3.0)
        val e = env.db.dictionary().get(lastItemEntry("r1"))!!
        assertEquals(listOf("Other", "Miscellaneous", "General"), listOf(e.category, e.subcategory, e.itemGroup))
        assertTrue(e.needsReview)
        assertEquals("Zyxwv Qpl", e.translationEn)
        assertFalse(e.categoryFlagged); assertNull(e.suggestedCategory)
        assertEquals("zyxwv qpl", e.canonicalName)
    }

    @Test
    fun aDeletedEntryIsNotReused() = runBlocking {
        seedReceipt()
        env.dict("old", "zyxwv qpl", "Food", "Pantry", "Legumes", deletedAt = "2026-03-02T00:00:00.000Z")
        env.repo.addItem("r1", "Zyxwv Qpl", 1.0, 3.0)
        assertTrue(lastItemEntry("r1") != "old")
    }

    @Test
    fun correctItemStillPinsTheEntryAsManual() = runBlocking {
        seedReceipt()
        env.repo.correctItem("milch", "Food", "Dairy & Eggs", "Cheese", " cheese ")
        val e = env.db.dictionary().get("milch")!!
        assertEquals("Cheese", e.itemGroup); assertEquals("cheese", e.translationEn)
        assertTrue(e.isManualOverride); assertFalse(e.needsReview)
        assertEquals(SyncState.DIRTY, e.syncState)
    }
}
