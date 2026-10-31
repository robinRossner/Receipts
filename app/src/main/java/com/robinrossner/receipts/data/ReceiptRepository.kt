package com.robinrossner.receipts.data

import androidx.room.withTransaction
import com.robinrossner.receipts.data.db.AppDatabase
import com.robinrossner.receipts.data.db.DictionaryEntity
import com.robinrossner.receipts.data.db.ItemRow
import com.robinrossner.receipts.data.db.LineItemEntity
import com.robinrossner.receipts.data.db.ReceiptEntity
import com.robinrossner.receipts.data.db.ReceiptSummary
import com.robinrossner.receipts.data.db.SyncState
import com.robinrossner.receipts.data.sync.AppPaths
import com.robinrossner.receipts.data.sync.StringLists
import com.robinrossner.receipts.data.sync.SyncDate
import kotlinx.coroutines.flow.Flow
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
    private val onLocalChange: () -> Unit = {},
) {
    private val receipts get() = db.receipts()
    private val items get() = db.lineItems()
    private val dictionary get() = db.dictionary()

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

    // ---- clock ----

    /** `now`, but never not-after the record's previous stamp (a clock that runs behind must not make an edit lose). */
    private fun stamp(previous: String?): String {
        val now = Instant.now()
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

    suspend fun confirm(uuid: String) = editReceipt(uuid) { it.copy(reviewedAt = SyncDate.now()) }

    /** Unreviewed receipts without any review reason ("Confirm all without flags"). */
    suspend fun confirmAllWithoutFlags(candidates: List<String>) {
        db.withTransaction {
            for (uuid in candidates) {
                val r = receipts.get(uuid) ?: continue
                if (r.reviewedAt == null && r.deletedAt == null && !r.needsReview && StringLists.decode(r.reviewReasons).isEmpty()) {
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
        items.upsert(li.copy(deletedAt = stamp(li.updatedAt), updatedAt = stamp(li.updatedAt), syncState = SyncState.DIRTY, syncError = null))
        recompute(li.receiptId)
    }

    /**
     * Adds a missing item. The phone has no AI, so the item gets the dictionary entry of the same normalised name, or a
     * new one in "Other > Miscellaneous > General" marked for review; the category pickers fix it afterwards.
     */
    suspend fun addItem(receiptUuid: String, name: String, quantity: Double, unitPrice: Double) {
        val trimmed = name.trim()
        if (trimmed.isEmpty() || receipts.get(receiptUuid) == null) return
        val normalized = Rules.normalizeName(trimmed).ifEmpty { trimmed.lowercase() }
        val now = SyncDate.now()
        val entry = dictionary.findByName(normalized) ?: DictionaryEntity(
            uuid = UUID.randomUUID().toString(), canonicalName = normalized, displayNameDe = trimmed, translationEn = trimmed,
            category = Taxonomy.FALLBACK_CATEGORY, subcategory = Taxonomy.FALLBACK_SUBCATEGORY, itemGroup = Taxonomy.FALLBACK_GROUP,
            aliases = StringLists.encode(listOf(normalized)), isManualOverride = false, needsReview = true, timesSeen = 1,
            createdAt = now, lastSeenAt = now, updatedAt = now, syncState = SyncState.DIRTY,
        ).also { dictionary.upsert(it) }
        db.withTransaction {
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

    /** A category correction changes the shared dictionary entry (every receipt that uses it), and pins it as manual. */
    suspend fun correctItem(dictId: String, category: String, subcategory: String, itemGroup: String, translationEn: String?) {
        val d = dictionary.get(dictId) ?: return
        dictionary.upsert(
            d.copy(
                category = category, subcategory = subcategory, itemGroup = itemGroup,
                translationEn = translationEn?.trim()?.ifEmpty { null } ?: d.translationEn,
                isManualOverride = true, needsReview = false, updatedAt = stamp(d.updatedAt), syncState = SyncState.DIRTY, syncError = null,
            ),
        )
        changed()
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
