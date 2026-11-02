package com.robinrossner.receipts.data

import com.robinrossner.receipts.data.api.PushEntity
import com.robinrossner.receipts.data.api.PushResponse
import com.robinrossner.receipts.data.api.PushResult
import com.robinrossner.receipts.data.api.PushStatus
import com.robinrossner.receipts.data.api.WireDictionaryEntry
import com.robinrossner.receipts.data.api.WireLineItem
import com.robinrossner.receipts.data.api.WireReceipt
import com.robinrossner.receipts.data.api.WireTaxonomyAddition
import com.robinrossner.receipts.data.db.SyncState
import com.robinrossner.receipts.data.db.TaxonomyAdditionEntity
import com.robinrossner.receipts.data.sync.ApplySummary
import com.robinrossner.receipts.data.sync.SyncDate
import com.robinrossner.receipts.data.sync.SyncReport
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
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

/** Push, pull and the flag / category-path semantics, end to end through [com.robinrossner.receipts.data.sync.SyncEngine] against [FakeReceiptsServer]. */
@RunWith(RobolectricTestRunner::class)
class SyncTest {
    private val pets = TaxonomyPath("Household", "Pets", "Pet Food")
    private lateinit var server: FakeReceiptsServer
    private val envs = mutableListOf<TestEnv>()

    @Before fun setUp() { server = FakeReceiptsServer(bundledTaxonomy()) }
    @After fun tearDown() { envs.forEach { it.close() } }

    private fun device(id: String = "android-test") = TestEnv(api = server, deviceId = id).also { envs += it }

    private suspend fun TestEnv.sync(): SyncReport = engine!!.syncNow().also { assertTrue("${it.errors}", it.succeeded) }

    /** What the Mac's categoriser leaves behind: a flagged fallback entry that has not reached the server yet. */
    private suspend fun TestEnv.seedFlagged(id: String = "pedigree") = dict(
        id, "pedigree hundefutter", "Other", "Miscellaneous", "General", flagged = true, suggestedCategory = "Pet Food",
        suggestedParent = "Household > Pets", syncState = SyncState.DIRTY,
    )

    private fun now() = SyncDate.now()

    // ---- flags between devices ----

    @Test
    fun aFlagAndItsResolutionRoundTripBetweenDevicesThroughTheServer() = runBlocking {
        val a = device("android-a"); val b = device("android-b")
        a.seedFlagged()
        a.sync()
        val onServer = server.dictionary.values.single()
        assertEquals(true, onServer.categoryFlagged)
        assertEquals("Pet Food", onServer.suggestedCategory); assertEquals("Household > Pets", onServer.suggestedParent)

        // device B receives the flag
        b.sync()
        val seen = b.db.dictionary().get("pedigree")!!
        assertTrue(seen.categoryFlagged); assertEquals("Pet Food", seen.suggestedCategory); assertEquals("Household > Pets", seen.suggestedParent)
        assertEquals("Other", seen.category)
        assertEquals(SyncState.SYNCED, seen.syncState)

        // B adds the category and resolves; the server gets the path and the resolved entry
        assertEquals(FlagResolution.Resolved(1), b.repo.resolveFlaggedItemsAdding(listOf("pedigree"), pets))
        b.sync()
        assertEquals(listOf("Household > Pets > Pet Food"), server.additions.map { it.label })
        val resolved = server.dictionary.values.single()
        assertEquals(false, resolved.categoryFlagged)
        assertNull(resolved.suggestedCategory); assertNull(resolved.suggestedParent)
        assertEquals("Pet Food", resolved.itemGroup); assertTrue(resolved.isManualOverride)
        assertEquals(SyncState.SYNCED, b.db.taxonomy().all().single().syncState)
        assertEquals(SyncState.SYNCED, b.db.dictionary().get("pedigree")!!.syncState)

        // the new path is pushed BEFORE the entry that uses it, and the entry states the flag explicitly
        val addIndex = server.pushLog.indexOfFirst { !it.taxonomyAdditions.isNullOrEmpty() }
        val dictIndex = server.pushLog.indexOfLast { it.dictionary.isNotEmpty() }
        assertTrue("the path goes out first ($addIndex < $dictIndex)", addIndex in 0 until dictIndex)
        val dictBody = server.pushBodies[dictIndex]["dictionary"]!!.jsonArray.single().jsonObject
        assertEquals(false, dictBody["category_flagged"]!!.jsonPrimitive.boolean)

        // A receives the resolution and the new category
        a.sync()
        val back = a.db.dictionary().get("pedigree")!!
        assertFalse(back.categoryFlagged); assertNull(back.suggestedCategory); assertEquals("Pet Food", back.itemGroup)
        assertEquals(listOf(pets), a.db.taxonomy().all().map { TaxonomyPath(it.category, it.subcategory, it.itemGroup) })
        assertEquals(SyncState.SYNCED, a.db.taxonomy().all().single().syncState)
        assertTrue(a.awaitTaxonomy { it.contains(pets) }.contains(pets))
    }

    @Test
    fun resolvingInPlaceSendsAnExplicitFalseSoTheServerClearsTheFlag() = runBlocking {
        val a = device()
        a.seedFlagged(); a.sync()
        assertEquals(true, server.dictionary.values.single().categoryFlagged)
        // "keep it in Other > Miscellaneous > General": the category does not change, only the flag
        assertEquals(FlagResolution.Resolved(1), a.repo.resolveFlaggedItemsTo(listOf("pedigree"), Taxonomy.FALLBACK))
        a.sync()
        assertEquals(false, server.dictionary.values.single().categoryFlagged)
        assertNull(server.dictionary.values.single().suggestedParent)
    }

    @Test
    fun anUnflaggedDirtyEntryPushesFalseAndNeverWipesAServerFlagOnItsOwn() = runBlocking {
        // the server flagged the entry after our last pull; our (stale, unflagged, dirty) copy loses on LWW if older, wins if newer
        val a = device()
        a.dict("pedigree", "pedigree hundefutter", "Other", "Miscellaneous", "General", syncState = SyncState.DIRTY, updatedAt = "2026-03-01T10:00:00.000Z")
        server.seedDictionary(
            WireDictionaryEntry("pedigree", canonicalName = "pedigree hundefutter", category = "Other", subcategory = "Miscellaneous", itemGroup = "General",
                categoryFlagged = true, suggestedCategory = "Pet Food", suggestedParent = "Household", updatedAt = "2026-03-02T10:00:00.000Z"),
        )
        val report = a.sync()
        assertEquals("our copy is older: stale, nothing changes on the server", 1, report.push.stale)
        assertEquals(true, server.dictionary.values.single().categoryFlagged)
        assertTrue("and the next pull brings the flag", a.db.dictionary().get("pedigree")!!.categoryFlagged)
    }

    @Test
    fun aPulledRecordFromAnOlderServerKeepsTheLocalFlagUnlessTheCategoryChanged() = runBlocking {
        server.legacyServer = true
        val h = device()
        h.seedFlagged(); h.sync()
        assertTrue(h.db.dictionary().get("pedigree")!!.categoryFlagged)

        // another (old) client changes only the translation: the server sends the record without the flag keys
        var entry = server.dictionary.values.single().copy(translationEn = "dog food", updatedAt = now(), categoryFlagged = null)
        server.seedDictionary(entry)
        h.sync()
        val kept = h.db.dictionary().get("pedigree")!!
        assertEquals("dog food", kept.translationEn)
        assertTrue("the server did not say anything about the flag: ours stays", kept.categoryFlagged)
        assertEquals("Pet Food", kept.suggestedCategory); assertEquals("Household > Pets", kept.suggestedParent)

        // an old client picks a category: the flag is resolved
        entry = entry.copy(category = "Household", subcategory = "Cleaning", itemGroup = "Laundry", updatedAt = now())
        server.seedDictionary(entry)
        h.sync()
        val resolved = h.db.dictionary().get("pedigree")!!
        assertFalse(resolved.categoryFlagged); assertNull(resolved.suggestedCategory); assertNull(resolved.suggestedParent)
        assertEquals("Laundry", resolved.itemGroup)
    }

    @Test
    fun anExplicitFalseFromTheServerDropsTheLocalSuggestionsAndATrueTakesTheServersText() = runBlocking {
        val h = device()
        h.dict("e", "thing", "Other", "Miscellaneous", "General", flagged = true, suggestedCategory = "Old", suggestedParent = "Household")
        server.seedDictionary(WireDictionaryEntry("e", canonicalName = "thing", category = "Other", subcategory = "Miscellaneous", itemGroup = "General",
            categoryFlagged = true, suggestedCategory = "New", suggestedParent = "Garden > Tools", updatedAt = now()))
        h.sync()
        assertEquals("New", h.db.dictionary().get("e")!!.suggestedCategory)
        assertEquals("Garden > Tools", h.db.dictionary().get("e")!!.suggestedParent)
        server.seedDictionary(server.dictionary.getValue("e").copy(categoryFlagged = false, suggestedCategory = "ignored", updatedAt = now()))
        h.sync()
        val e = h.db.dictionary().get("e")!!
        assertFalse(e.categoryFlagged); assertNull(e.suggestedCategory); assertNull(e.suggestedParent)
    }

    @Test
    fun aKeepLocalDecisionLeavesTheFlagsAlone() = runBlocking {
        val h = device()
        h.dict("e", "thing", "Other", "Miscellaneous", "General", flagged = true, suggestedCategory = "Pet Food", suggestedParent = "Household",
            syncState = SyncState.DIRTY, updatedAt = "2026-06-01T00:00:00.000Z")
        server.seedDictionary(WireDictionaryEntry("e", canonicalName = "thing", category = "Other", subcategory = "Miscellaneous", itemGroup = "General",
            categoryFlagged = false, updatedAt = "2026-05-01T00:00:00.000Z"))
        val store = h.store
        store.applyPull(server.dictionary.values.toList(), emptyList(), emptyList())
        val e = h.db.dictionary().get("e")!!
        assertTrue(e.categoryFlagged); assertEquals("Pet Food", e.suggestedCategory); assertEquals(SyncState.DIRTY, e.syncState)
    }

    // ---- additions ----

    @Test
    fun anAdditionAgainstAnOlderServerStaysQueuedUntilItIsAcknowledged() = runBlocking {
        server.legacyServer = true
        val h = device()
        assertEquals(FlagResolution.Resolved(1), h.repo.addTaxonomyPath(pets))
        // a legacy server ignores the key and answers with no result for it: nothing is lost, the path stays dirty
        val batch = h.store.collectPush(PushEntity.TAXONOMY_ADDITION)
        assertEquals(listOf("Household > Pets > Pet Food"), batch.taxonomyAdditions.map { it.label })
        val summary = h.store.applyPushResults(batch, PushResponse(now(), emptyList()))
        assertEquals(0, summary.applied + summary.stale)
        assertEquals(SyncState.DIRTY, h.db.taxonomy().all().single().syncState)
        assertEquals(1, h.store.unsentChangeCount())
        // the engine does not loop on it, and keeps it for later
        val report = h.sync()
        assertEquals(1, server.pushLog.size)
        assertEquals(0, report.push.applied)
        assertEquals(SyncState.DIRTY, h.db.taxonomy().all().single().syncState)
        assertTrue("a legacy server sends no list: the local path stays", h.db.taxonomy().all().isNotEmpty())
    }

    @Test
    fun additionResultsAppliedStaleRejectedAndMissingAreHandled() = runBlocking {
        val h = device()
        for (g in listOf("Pet Food", "Cat Litter", "Leashes", "Bowls")) h.repo.addTaxonomyPath(TaxonomyPath("Household", "Pets", g))
        val batch = h.store.collectPush(PushEntity.TAXONOMY_ADDITION)
        assertEquals(4, batch.taxonomyAdditions.size)
        val summary = h.store.applyPushResults(
            batch,
            PushResponse(
                now(),
                listOf(
                    PushResult(PushEntity.TAXONOMY_ADDITION, "Household > Pets > Pet Food", PushStatus.APPLIED),
                    // the server may fix the case of an existing category
                    PushResult(PushEntity.TAXONOMY_ADDITION, "HOUSEHOLD > Pets > Cat Litter", PushStatus.STALE, "path already exists"),
                    PushResult(PushEntity.TAXONOMY_ADDITION, "Household > Pets > Leashes", PushStatus.REJECTED, "too many additions"),
                    PushResult(PushEntity.TAXONOMY_ADDITION, null, PushStatus.REJECTED, "empty part"),
                ),
            ),
        )
        assertEquals(1, summary.applied); assertEquals(1, summary.stale)
        assertEquals(listOf("taxonomy_addition Household > Pets > Leashes: too many additions", "taxonomy_addition ?: empty part"), summary.rejected)
        val byKey = h.db.taxonomy().all().associateBy { it.itemGroup }
        assertEquals(SyncState.SYNCED, byKey.getValue("Pet Food").syncState)
        assertEquals(SyncState.SYNCED, byKey.getValue("Cat Litter").syncState)
        assertEquals(SyncState.REJECTED, byKey.getValue("Leashes").syncState)
        assertEquals("too many additions", byKey.getValue("Leashes").syncError)
        assertEquals("no result: still waiting", SyncState.DIRTY, byKey.getValue("Bowls").syncState)
        assertEquals(1, h.store.unsentChangeCount())
        assertEquals(1, h.store.rejectedCount())
    }

    @Test
    fun anEntryUsingAPathTheServerRejectedIsRejectedAndDoesNotLoop() = runBlocking {
        val h = device()
        val tooLong = "x".repeat(61)
        // a bad addition can only come from a bug or an older build; the server refuses it, and so the entries that use it
        h.db.taxonomy().insert(TaxonomyAdditionEntity(category = "Household", subcategory = "Pets", itemGroup = tooLong, createdAt = now(), pathKey = "household > pets > $tooLong"))
        h.dict("e", "thing", "Household", "Pets", tooLong, syncState = SyncState.DIRTY)
        val report = engineRun(h)
        assertEquals(2, report.push.rejected.size)
        assertEquals(SyncState.REJECTED, h.db.taxonomy().all().single().syncState)
        assertEquals(SyncState.REJECTED, h.db.dictionary().get("e")!!.syncState)
        assertTrue(h.db.dictionary().get("e")!!.syncError!!.startsWith("unknown category path Household > Pets > "))
        assertEquals(2, h.store.rejectedCount()); assertEquals(0, h.store.unsentChangeCount())
        val pushes = server.pushLog.size
        h.sync()
        assertEquals("nothing is dirty any more: nothing is sent again", pushes, server.pushLog.size)
    }

    /** A sync that is expected to report rejections (the report is not "succeeded" then). */
    private suspend fun engineRun(h: TestEnv): SyncReport = h.engine!!.syncNow()

    @Test
    fun pullAppliesAdditionsIdempotentlyAndACaseVariantIsTheSameRow() = runBlocking {
        server.seedAddition(WireTaxonomyAddition("Household", "Pets", "Pet Food", "2026-03-01T10:00:00.000Z"))
        server.seedAddition(WireTaxonomyAddition("household", "PETS", "pet food", "2026-03-02T10:00:00.000Z"))
        server.seedAddition(WireTaxonomyAddition("Garden", "Plants", "Seeds", "2026-03-03T10:00:00.000Z"))
        val h = device()
        val first = h.sync()
        assertEquals(2, first.pulled.taxonomyAdditions)
        assertTrue("arriving additions are local changes views must reload", first.changedLocalData)
        val rows = h.db.taxonomy().all()
        assertEquals(listOf("Household > Pets > Pet Food", "Garden > Plants > Seeds"), rows.map { "${it.category} > ${it.subcategory} > ${it.itemGroup}" })
        assertTrue(rows.all { it.syncState == SyncState.SYNCED })
        assertEquals("2026-03-01T10:00:00.000Z", rows[0].createdAt)
        val second = h.sync()
        assertEquals(0, second.pulled.taxonomyAdditions)
        assertEquals(2, h.db.taxonomy().all().size)
        assertTrue(h.awaitTaxonomy { it.contains(TaxonomyPath("Garden", "Plants", "Seeds")) }.contains(pets))
    }

    @Test
    fun aDirtyLocalCopyIsAcknowledgedByThePullAndInvalidServerPathsAreSkipped() = runBlocking {
        val h = device()
        h.repo.addTaxonomyPath(pets)
        val summary = h.store.applyPull(
            emptyList(), emptyList(), emptyList(),
            listOf(
                WireTaxonomyAddition("household", "pets", "PET FOOD", "2026-03-01T10:00:00.000Z"),
                WireTaxonomyAddition("Household", "Pets", "x".repeat(61), null),
                WireTaxonomyAddition("Household", "A > B", "x", null),
                WireTaxonomyAddition("", "B", "x", null),
            ),
        )
        assertEquals("the known path is no new addition", 0, summary.taxonomyAdditions)
        val rows = h.db.taxonomy().all()
        assertEquals(1, rows.size)
        assertEquals("our spelling stays", "Pets", rows.single().subcategory)
        assertEquals(SyncState.SYNCED, rows.single().syncState)
        assertEquals(0, h.store.unsentChangeCount())
    }

    @Test
    fun aPullNeverDeletesLocalAdditionsAndAServerWithoutTheFeatureLeavesThemAlone() = runBlocking {
        val h = device()
        h.repo.addTaxonomyPath(pets)
        h.repo.addTaxonomyPath(TaxonomyPath("Garden", "Plants", "Seeds"))
        h.db.taxonomy().acknowledge("garden > plants > seeds")
        // the server's list lacks both (it never got the first; the second was lost on its side): both stay
        h.store.applyPull(emptyList(), emptyList(), emptyList(), listOf(WireTaxonomyAddition("Other", "Odd", "Thing", null)))
        assertEquals(3, h.db.taxonomy().all().size)
        // no list at all (a legacy server)
        h.store.applyPull(emptyList(), emptyList(), emptyList())
        assertEquals(3, h.db.taxonomy().all().size)
        assertEquals(SyncState.DIRTY, h.db.taxonomy().all().first { it.itemGroup == "Pet Food" }.syncState)
        // a legacy server through the engine
        server.legacyServer = true
        h.sync()
        assertEquals(3, h.db.taxonomy().all().size)
    }

    @Test
    fun anAdditionTheServerAlreadyHasIsAcknowledgedAsStale() = runBlocking {
        server.seedAddition(WireTaxonomyAddition("Household", "Pets", "Pet Food", "2026-03-01T10:00:00.000Z"))
        val h = device()
        h.repo.addTaxonomyPath(pets)
        val report = h.sync()
        assertEquals(1, report.push.stale)
        assertEquals(SyncState.SYNCED, h.db.taxonomy().all().single().syncState)
        assertEquals(1, server.additions.size)
    }

    // ---- regression guards for the rest of the merge ----

    @Test
    fun aDirtyNewerLocalCopyKeepsAndATieGoesToTheServer() = runBlocking {
        val h = device()
        h.dict("a", "alpha", syncState = SyncState.DIRTY, updatedAt = "2026-03-10T00:00:00.000Z")
        h.dict("b", "bravo", syncState = SyncState.DIRTY, updatedAt = "2026-03-10T00:00:00.000Z")
        server.seedDictionary(WireDictionaryEntry("a", canonicalName = "alpha", translationEn = "server older", category = "Food", subcategory = "Dairy & Eggs", itemGroup = "Milk", updatedAt = "2026-03-09T00:00:00.000Z"))
        server.seedDictionary(WireDictionaryEntry("b", canonicalName = "bravo", translationEn = "server tie", category = "Food", subcategory = "Dairy & Eggs", itemGroup = "Milk", updatedAt = "2026-03-10T00:00:00.000Z"))
        h.store.applyPull(server.dictionary.values.toList(), emptyList(), emptyList())
        val a = h.db.dictionary().get("a")!!
        assertEquals("alpha", a.translationEn); assertEquals(SyncState.DIRTY, a.syncState)
        val b = h.db.dictionary().get("b")!!
        assertEquals("server tie", b.translationEn); assertEquals(SyncState.SYNCED, b.syncState)
    }

    @Test
    fun staleMarksSyncedAndAReEditDuringThePushKeepsTheRowDirty() = runBlocking {
        val h = device()
        h.dict("a", "alpha", syncState = SyncState.DIRTY, updatedAt = "2026-03-10T00:00:00.000Z")
        h.dict("b", "bravo", syncState = SyncState.DIRTY, updatedAt = "2026-03-10T00:00:00.000Z")
        val batch = h.store.collectPush(PushEntity.DICTIONARY)
        // "a" is edited again while the push is in flight
        h.db.dictionary().upsert(h.db.dictionary().get("a")!!.copy(translationEn = "edited", updatedAt = "2026-03-10T00:00:01.000Z"))
        val summary = h.store.applyPushResults(
            batch,
            PushResponse(now(), listOf(PushResult(PushEntity.DICTIONARY, "a", PushStatus.APPLIED), PushResult(PushEntity.DICTIONARY, "b", PushStatus.STALE))),
        )
        assertEquals(1, summary.applied); assertEquals(1, summary.stale)
        assertEquals("re-edited: still dirty", SyncState.DIRTY, h.db.dictionary().get("a")!!.syncState)
        assertEquals("stale: our copy is no longer ahead", SyncState.SYNCED, h.db.dictionary().get("b")!!.syncState)
    }

    @Test
    fun tombstonesApplyToWhatWeHaveAndAreIgnoredForWhatWeNeverHad() = runBlocking {
        val h = device()
        h.dict("d", "thing"); h.receipt("r"); h.item("keep", "r", "d"); h.item("gone", "r", "d", position = 1)
        h.store.applyPull(
            listOf(WireDictionaryEntry("d", canonicalName = "thing", category = "Food", subcategory = "Dairy & Eggs", itemGroup = "Milk", updatedAt = now(), deletedAt = now())),
            emptyList(),
            listOf(
                WireLineItem("gone", receiptId = "r", itemDictionaryId = "d", updatedAt = now(), deletedAt = now()),
                WireLineItem("never-had", receiptId = "r", itemDictionaryId = "d", updatedAt = now(), deletedAt = now()),
            ),
        )
        assertNotNull(h.db.dictionary().get("d")!!.deletedAt)
        assertNotNull(h.db.lineItems().get("gone")!!.deletedAt)
        assertNull(h.db.lineItems().get("keep")!!.deletedAt)
        assertNull("a tombstone for something we never had adds nothing", h.db.lineItems().get("never-had"))
    }

    @Test
    fun aNameClashMovesTheLocalOnlyEntrysItemsToTheServersEntry() = runBlocking {
        val h = device()
        h.dict("local-only", "milch", syncState = SyncState.DIRTY); h.receipt("r"); h.item("i", "r", "local-only")
        val summary = h.store.applyPull(
            listOf(WireDictionaryEntry("server-id", canonicalName = "milch", category = "Food", subcategory = "Dairy & Eggs", itemGroup = "Milk", updatedAt = now())),
            emptyList(), emptyList(),
        )
        assertEquals(1, summary.dictionary)
        assertEquals(listOf("server-id"), h.db.dictionary().live().map { it.uuid })
        val moved = h.db.lineItems().get("i")!!
        assertEquals("server-id", moved.itemDictionaryId)
        assertEquals("the move is a local change for the server", SyncState.DIRTY, moved.syncState)
    }

    @Test
    fun aRenameOntoAnotherLocalRowsNameParksThatRow() = runBlocking {
        val h = device()
        h.dict("s", "old name"); h.dict("l", "new name", syncState = SyncState.DIRTY)
        h.store.applyPull(
            listOf(WireDictionaryEntry("s", canonicalName = "new name", category = "Food", subcategory = "Dairy & Eggs", itemGroup = "Milk", updatedAt = now())),
            emptyList(), emptyList(),
        )
        assertEquals("new name", h.db.dictionary().get("s")!!.canonicalName)
        assertTrue(h.db.dictionary().get("l")!!.canonicalName.startsWith("new name #moved-"))
    }

    @Test
    fun applySummaryCountsAdditionsAsChangedLocalData() {
        assertEquals(1, ApplySummary(taxonomyAdditions = 1).total)
        assertTrue(SyncReport(pulled = ApplySummary(taxonomyAdditions = 1)).changedLocalData)
        assertFalse(SyncReport().changedLocalData)
    }

    @Test
    fun receiptsAndItemsStillRoundTrip() = runBlocking {
        val a = device("android-a"); val b = device("android-b")
        a.dict("d", "milch"); a.receipt("r", syncState = SyncState.DIRTY, total = 3.0, updatedAt = now()); a.item("i", "r", "d", 3.0, syncState = SyncState.DIRTY)
        a.db.dictionary().upsert(a.db.dictionary().get("d")!!.copy(syncState = SyncState.DIRTY, updatedAt = now()))
        a.sync(); b.sync()
        assertEquals("milch", b.db.dictionary().get("d")!!.canonicalName)
        assertEquals(3.0, b.db.lineItems().get("i")!!.totalPrice, 0.0001)
        assertEquals("Edeka", b.db.receipts().get("r")!!.store)
        // a confirmation on B and its undo reach A
        b.repo.confirm("r"); b.sync(); a.sync()
        assertNotNull(a.db.receipts().get("r")!!.reviewedAt)
        b.repo.unconfirm("r"); b.sync(); a.sync()
        assertNull(a.db.receipts().get("r")!!.reviewedAt)
    }

    @Test
    fun aRestoredLineItemUndeletesOnTheServer() = runBlocking {
        val a = device()
        a.dict("d", "milch", syncState = SyncState.DIRTY); a.receipt("r", syncState = SyncState.DIRTY, total = 1.0, updatedAt = now()); a.item("i", "r", "d", 1.0, syncState = SyncState.DIRTY)
        a.sync()
        a.repo.deleteLineItem("i"); a.sync()
        assertNotNull(server.lineItems.getValue("i").deletedAt)
        a.repo.restoreLineItem("i"); a.sync()
        assertNull(server.lineItems.getValue("i").deletedAt)
    }
}
