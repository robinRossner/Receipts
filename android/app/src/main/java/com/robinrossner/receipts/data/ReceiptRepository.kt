package com.robinrossner.receipts.data

import androidx.room.withTransaction
import com.robinrossner.receipts.data.db.AppDatabase
import com.robinrossner.receipts.data.db.DictionaryEntity
import com.robinrossner.receipts.data.db.FlaggedDbRow
import com.robinrossner.receipts.data.db.ItemRow
import com.robinrossner.receipts.data.db.LineItemEntity
import com.robinrossner.receipts.data.db.ReceiptEntity
import com.robinrossner.receipts.data.db.ReceiptSummary
import com.robinrossner.receipts.data.db.SyncState
import com.robinrossner.receipts.data.db.TaxonomyAdditionEntity
import com.robinrossner.receipts.data.sync.AppPaths
import com.robinrossner.receipts.data.sync.StringLists
import com.robinrossner.receipts.data.sync.SyncDate
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import java.time.Instant
import java.util.UUID

/**
 * Local reads and edits. Every edit stamps the record with the time of the edit (`updated_at`, the last-write-wins
 * clock) and marks it `dirty`; the sync pushes dirty records. Deletes are tombstones. [onLocalChange] lets the sync
 * coordinator schedule a debounced sync.
 */
class ReceiptRepository(
    val db: AppDatabase,
    val paths: AppPaths,
    /** The bundled taxonomy; [taxonomy] adds the user's categories to it. */
    private val baseTaxonomy: Taxonomy,
    scope: CoroutineScope,
    private val onLocalChange: () -> Unit = {},
) {
    private val receipts get() = db.receipts()
    private val items get() = db.lineItems()
    private val dictionary get() = db.dictionary()
    private val flagged get() = db.flagged()
    private val additions get() = db.taxonomy()

    /** The bundled categories plus the user-added ones; every category picker uses this, never the bundled tree alone. */
    val taxonomy: StateFlow<Taxonomy> = additions.observeAll()
        .map { list -> baseTaxonomy.adding(list.map { TaxonomyPath(it.category, it.subcategory, it.itemGroup) }) }
        .stateIn(scope, SharingStarted.Eagerly, baseTaxonomy)

    /** The same, read from the database now (a write must not depend on the flow having caught up). */
    private suspend fun currentTaxonomy(): Taxonomy =
        baseTaxonomy.adding(additions.all().map { TaxonomyPath(it.category, it.subcategory, it.itemGroup) })

    // ---- reads ----

    fun observeReceipts(): Flow<List<ReceiptSummary>> = receipts.observeLive()
    fun observeDeleted(): Flow<List<ReceiptSummary>> = receipts.observeDeleted()
    fun observeReceipt(uuid: String): Flow<ReceiptEntity?> = receipts.observe(uuid)
    fun observeItems(uuid: String): Flow<List<ItemRow>> = items.observeItems(uuid)
    fun observeStoresInUse(): Flow<List<String>> = receipts.observeStoresInUse()
    fun observeReceiptVersion() = receipts.observeReceiptVersion()
    fun observeItemVersion() = receipts.observeItemVersion()

    /** Receipt ids matching a search text: store, item name, translation or amount ("12,50" and "€12.50" work). */
    suspend fun search(query: String): Set<String> {
        val q = query.trim()
        if (q.isEmpty()) return emptySet()
        val like = "%" + q.replace("%", "").replace("_", "") + "%"
        val amount = "%" + q.replace(",", ".").replace("€", "").trim() + "%"
        return receipts.search(like, amount).toSet()
    }

    suspend fun dictionaryUsage(dictId: String) = items.usage(dictId)

    /** Review reasons of the flagged, unreviewed receipts by id (reviewed or clean receipts are absent). */
    fun observeReviewReasons(): Flow<Map<String, List<String>>> =
        receipts.observeReviewReasons().map { rows -> rows.associate { it.uuid to StringLists.decode(it.reviewReasons) } }

    // ---- flagged items ("no good category") ----

    /** The badge: flagged entries a live receipt uses. */
    fun observeFlaggedCount(): Flow<Int> = flagged.observeCount()

    fun observeFlaggedItems(): Flow<List<FlaggedItem>> = flagged.observeList().map { assembleFlagged(it) }

    /** Every unresolved flagged item (used by a live receipt), ordered by suggestion. */
    suspend fun flaggedItems(): List<FlaggedItem> = assembleFlagged(flagged.list())

    /** The same, grouped by suggested category (biggest group first, items without a suggestion last). */
    suspend fun flaggedGroups(): List<FlaggedGroup> = FlaggedItems.group(flaggedItems())

    private suspend fun assembleFlagged(rows: List<FlaggedDbRow>): List<FlaggedItem> {
        if (rows.isEmpty()) return emptyList()
        val receiptIds = flagged.receiptRows().groupBy({ it.dictionaryId }, { it.receiptId })
        return rows.map {
            FlaggedItem(
                it.dictionaryId, it.name, it.translationEn, it.suggestedCategory, it.suggestedParent, it.itemCount, it.totalSpend,
                receiptIds[it.dictionaryId].orEmpty(),
            )
        }
    }

    // ---- clock ----

    /** `now`, but never not-after the record's previous stamp (a clock that runs behind must not make an edit lose). */
    private fun stamp(previous: String?): String {
        val now = Instant.now().truncatedTo(java.time.temporal.ChronoUnit.MILLIS)   // stamps have millisecond precision
        val prev = SyncDate.parse(previous)
        val at = if (prev != null && !now.isAfter(prev)) prev.plusMillis(1) else now
        return SyncDate.format(at)
    }

    private fun changed() = onLocalChange()

    // ---- receipt edits ----

    private suspend fun editReceipt(uuid: String, change: (ReceiptEntity) -> ReceiptEntity) {
        val current = receipts.get(uuid) ?: return
        receipts.upsert(change(current).copy(updatedAt = stamp(current.updatedAt), syncState = SyncState.DIRTY, syncError = null))
        changed()
    }

    /**
     * "Looks good". False (nothing changed) for a receipt the server is still reading or that failed: once confirmed,
     * the server treats it as the user's version and keeps the extraction out for good.
     */
    suspend fun confirm(uuid: String): Boolean {
        val r = receipts.get(uuid) ?: return false
        if (r.isUnfinished) return false
        editReceipt(uuid) { it.copy(reviewedAt = SyncDate.now()) }
        return true
    }

    /** Undo of [confirm]: back to unreviewed. The server accepts `reviewed_at: null`, so this also reaches it after the confirmation was pushed. */
    suspend fun unconfirm(uuid: String) = editReceipt(uuid) { it.copy(reviewedAt = null) }

    /** Unreviewed, finished receipts without any review reason ("Confirm all without flags"); receipts still being read are left alone. */
    suspend fun confirmAllWithoutFlags(candidates: List<String>) {
        db.withTransaction {
            for (uuid in candidates) {
                val r = receipts.get(uuid) ?: continue
                if (r.reviewedAt == null && r.deletedAt == null && !r.purged && !r.isUnfinished && !r.needsReview &&
                    StringLists.decode(r.reviewReasons).isEmpty()
                ) {
                    receipts.upsert(r.copy(reviewedAt = SyncDate.now(), updatedAt = stamp(r.updatedAt), syncState = SyncState.DIRTY, syncError = null))
                }
            }
        }
        changed()
    }

    suspend fun updateStore(uuid: String, store: String) {
        val trimmed = store.trim()
        if (trimmed.isEmpty()) return
        editReceipt(uuid) { it.copy(store = Rules.canonicalizeStore(trimmed)) }
    }

    /** `date` is "yyyy-MM-dd", `time` "HH:mm" or null. */
    suspend fun updateDateTime(uuid: String, date: String, time: String?) = editReceipt(uuid) { it.copy(date = date, time = time) }

    /** Saves the printed total, then re-derives the sum-mismatch review reason (other reasons stay). */
    suspend fun updateTotal(uuid: String, total: Double?) {
        editReceipt(uuid) { it.copy(total = total?.let(Rules::round2)) }
        recompute(uuid)
    }

    suspend fun deleteReceipt(uuid: String) = editReceipt(uuid) { it.copy(deletedAt = stamp(it.updatedAt)) }

    suspend fun restoreReceipt(uuid: String) = editReceipt(uuid) { it.copy(deletedAt = null) }

    /**
     * Deletes a receipt for good on this phone: its tombstone is still pushed (so it stays gone everywhere) but the
     * receipt, its items and the photo copy disappear here and never come back through a pull.
     */
    suspend fun purgeReceipt(uuid: String) {
        val r = receipts.get(uuid) ?: return
        val file = paths.resolve(r.localPhoto)
        db.withTransaction {
            val deletedAt = r.deletedAt ?: stamp(r.updatedAt)
            receipts.upsert(r.copy(deletedAt = deletedAt, updatedAt = stamp(r.updatedAt), purged = true, localPhoto = null, syncState = SyncState.DIRTY))
            receipts.deleteItemsOf(uuid)
        }
        file?.delete()
        changed()
    }

    /** Removes a receipt that never reached the server (its photo could not be uploaded). */
    suspend fun discardFailedUpload(uuid: String) {
        val r = receipts.get(uuid) ?: return
        db.withTransaction { receipts.deleteItemsOf(uuid); receipts.delete(uuid) }
        paths.resolve(r.localPhoto)?.delete()
    }

    suspend fun retryUpload(uuid: String) = receipts.requeueUpload(uuid)

    // ---- item edits ----

    private suspend fun recompute(receiptUuid: String) {
        val r = receipts.get(receiptUuid) ?: return
        val totals = Rules.recomputeTotals(items.sumOf(receiptUuid), r.total, r.reviewReasons)
        receipts.upsert(
            r.copy(
                computedSum = totals.computedSum, reviewReasons = StringLists.encode(totals.reasons), needsReview = totals.needsReview,
                updatedAt = stamp(r.updatedAt), syncState = SyncState.DIRTY, syncError = null,
            ),
        )
        changed()
    }

    suspend fun updateLineItem(itemUuid: String, quantity: Double, unitPrice: Double) {
        val li = items.get(itemUuid) ?: return
        items.upsert(
            li.copy(
                quantity = quantity, unitPrice = unitPrice, totalPrice = Rules.round2(quantity * unitPrice),
                updatedAt = stamp(li.updatedAt), syncState = SyncState.DIRTY, syncError = null,
            ),
        )
        recompute(li.receiptId)
    }

    suspend fun deleteLineItem(itemUuid: String) {
        val li = items.get(itemUuid) ?: return
        val at = stamp(li.updatedAt)
        items.upsert(li.copy(deletedAt = at, updatedAt = at, syncState = SyncState.DIRTY, syncError = null))
        recompute(li.receiptId)
    }

    /**
     * Undo of [deleteLineItem]: the same record back at the same place. The row is still there as a tombstone; a newer
     * record with `deleted_at: null` undeletes it on the server, too. Nothing to do for a purged receipt (its rows are gone).
     */
    suspend fun restoreLineItem(itemUuid: String) {
        val li = items.get(itemUuid) ?: return
        if (li.deletedAt == null || receipts.get(li.receiptId)?.purged != false) return
        items.upsert(li.copy(deletedAt = null, updatedAt = stamp(li.updatedAt), syncState = SyncState.DIRTY, syncError = null))
        recompute(li.receiptId)
    }

    /**
     * Adds a missing item. The phone has no AI: the name resolves like the iPhone's offline categoriser does: the
     * dictionary entry of the same normalised name (or an alias of it), a near-identical name (fuzzy, 90+; flagged
     * entries are no candidates), a keyword rule of the taxonomy, else a new entry in "Other > Miscellaneous > General"
     * marked for review. The category pickers fix it afterwards. Flags are set by the server only.
     */
    suspend fun addItem(receiptUuid: String, name: String, quantity: Double, unitPrice: Double) {
        val trimmed = name.trim()
        if (trimmed.isEmpty() || receipts.get(receiptUuid) == null) return
        val normalized = Rules.normalizeName(trimmed).ifEmpty { trimmed.lowercase() }
        val now = SyncDate.now()
        db.withTransaction {
            val entry = resolveEntry(normalized, trimmed, now)
            items.upsert(
                LineItemEntity(
                    uuid = UUID.randomUUID().toString(), receiptId = receiptUuid, itemDictionaryId = entry.uuid,
                    position = items.maxPosition(receiptUuid) + 1, rawText = trimmed, nameDe = trimmed, quantity = quantity,
                    unitPrice = unitPrice, totalPrice = Rules.round2(quantity * unitPrice), updatedAt = now, syncState = SyncState.DIRTY,
                ),
            )
            recompute(receiptUuid)
        }
        changed()
    }

    private suspend fun resolveEntry(normalized: String, name: String, now: String): DictionaryEntity {
        val live = dictionary.live()
        // exact name or alias, flagged entries included (a known flagged item is not classified again)
        live.firstOrNull { it.canonicalName == normalized || normalized in StringLists.decode(it.aliases) }?.let { return it }
        val candidates = live.filter { !it.categoryFlagged }
        val best = FuzzyMatch.bestMatch(normalized, candidates.map { it.canonicalName })
        if (best != null && best.second >= FuzzyMatch.THRESHOLD) {
            val near = candidates.first { it.canonicalName == best.first }
            // the alias is pushed and unioned server side
            return near.copy(aliases = StringLists.encode(StringLists.decode(near.aliases) + normalized), updatedAt = stamp(near.updatedAt), syncState = SyncState.DIRTY, syncError = null)
                .also { dictionary.upsert(it) }
        }
        val keyword = baseTaxonomy.keywordPath(normalized)
        val path = keyword ?: Taxonomy.FALLBACK
        return DictionaryEntity(
            uuid = UUID.randomUUID().toString(), canonicalName = normalized, displayNameDe = name, translationEn = if (keyword == null) name else null,
            category = path.category, subcategory = path.subcategory, itemGroup = path.itemGroup,
            aliases = StringLists.encode(listOf(normalized)), isManualOverride = false, needsReview = keyword == null, timesSeen = 1,
            createdAt = now, lastSeenAt = now, updatedAt = now, syncState = SyncState.DIRTY,
        ).also { dictionary.upsert(it) }
    }

    /** A category correction changes the shared dictionary entry (every receipt that uses it), and pins it as manual. */
    suspend fun correctItem(dictId: String, category: String, subcategory: String, itemGroup: String, translationEn: String?) {
        val d = dictionary.get(dictId) ?: return
        dictionary.upsert(
            d.copy(
                category = category, subcategory = subcategory, itemGroup = itemGroup,
                translationEn = translationEn?.trim()?.ifEmpty { null } ?: d.translationEn,
                isManualOverride = true, needsReview = false, categoryFlagged = false, suggestedCategory = null, suggestedParent = null,
                updatedAt = stamp(d.updatedAt), syncState = SyncState.DIRTY, syncError = null,
            ),
        )
        changed()
    }

    // ---- flagged items: resolving and adding categories ----

    /**
     * Files flagged items under an EXISTING category (the path must be in [taxonomy], case-insensitively; "Other >
     * Miscellaneous > General" keeps them there and just clears the flag). `Resolved(count)` = entries that were
     * flagged and are now filed; entries that are not flagged are left alone.
     */
    suspend fun resolveFlaggedItemsTo(dictionaryIds: List<String>, path: TaxonomyPath): FlagResolution {
        val existing = currentTaxonomy().canonicalPath(path) ?: return FlagResolution.Invalid("${path.label} is not in the category list. Add it first.")
        return finishResolve(dictionaryIds, existing)
    }

    /** Adds [path] to the taxonomy (when it is new; syncs to the server and the other devices) and files the flagged items under it. */
    suspend fun resolveFlaggedItemsAdding(dictionaryIds: List<String>, path: TaxonomyPath): FlagResolution {
        (addTaxonomyPath(path) as? FlagResolution.Invalid)?.let { return it }
        val trimmed = TaxonomyPath(path.category.trimSpaces(), path.subcategory.trimSpaces(), path.itemGroup.trimSpaces())
        val target = currentTaxonomy().canonicalPath(trimmed) ?: return FlagResolution.Invalid("Could not add ${path.label}.")
        return finishResolve(dictionaryIds, target)
    }

    /**
     * Adds a path to the category list without resolving anything (names of an existing category or subcategory are
     * matched ignoring case and take its spelling). `Resolved(0)` = it already existed, `Resolved(1)` = added.
     */
    suspend fun addTaxonomyPath(path: TaxonomyPath): FlagResolution {
        val trimmed = TaxonomyPath(path.category.trimSpaces(), path.subcategory.trimSpaces(), path.itemGroup.trimSpaces())
        Taxonomy.additionProblem(trimmed)?.let { return FlagResolution.Invalid(it) }
        val current = currentTaxonomy()
        if (current.canonicalPath(trimmed) != null) return FlagResolution.Resolved(0)
        val category = current.canonicalCategory(trimmed.category) ?: trimmed.category
        val sub = current.canonicalSubcategory(trimmed.subcategory, category) ?: trimmed.subcategory
        return try {
            val added = additions.insert(
                TaxonomyAdditionEntity(
                    category = category, subcategory = sub, itemGroup = trimmed.itemGroup, createdAt = SyncDate.now(),
                    pathKey = TaxonomyAdditionEntity.keyOf(category, sub, trimmed.itemGroup), syncState = SyncState.DIRTY,
                ),
            ) != -1L
            if (added) changed()   // the debounced sync pushes it
            FlagResolution.Resolved(if (added) 1 else 0)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            FlagResolution.Invalid("Could not save the category: ${e.message}")
        }
    }

    private suspend fun finishResolve(ids: List<String>, path: TaxonomyPath): FlagResolution {
        if (ids.isEmpty()) return FlagResolution.Resolved(0)
        return try {
            val n = db.withTransaction {
                var count = 0
                for (id in ids) {
                    val d = dictionary.get(id) ?: continue
                    if (!d.categoryFlagged || d.deletedAt != null) continue
                    dictionary.upsert(
                        d.copy(
                            category = path.category, subcategory = path.subcategory, itemGroup = path.itemGroup, isManualOverride = true,
                            needsReview = false, categoryFlagged = false, suggestedCategory = null, suggestedParent = null,
                            updatedAt = stamp(d.updatedAt), syncState = SyncState.DIRTY, syncError = null,
                        ),
                    )
                    count++
                }
                count
            }
            if (n > 0) changed()
            FlagResolution.Resolved(n)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            FlagResolution.Invalid("Could not save: ${e.message}")
        }
    }

    // ---- stats ----

    suspend fun statsSummary(start: String?, end: String?) = StatsCalc.summary(receipts.statsGroups(start, end))

    suspend fun statsMonthly(start: String?, end: String?) =
        receipts.statsMonthly(start, end).map { MonthCategoryTotal(it.month, it.category, Rules.round2(it.total)) }

    suspend fun statsByStore(start: String?, end: String?) = receipts.statsByStore(start, end)

    suspend fun statsPurchases(category: String, subcategory: String, itemGroup: String, start: String?, end: String?): List<PurchaseRow> =
        receipts.statsPurchases(category, subcategory, itemGroup, start, end).map {
            PurchaseRow(it.date, it.store, it.translationEn, it.nameDe, it.quantity, it.unitPrice, it.totalPrice, it.receiptId, it.itemDictionaryId)
        }

    suspend fun statsPriceHistory(category: String, subcategory: String, itemGroup: String) =
        StatsCalc.priceHistory(receipts.statsPriceHistory(category, subcategory, itemGroup))
}
