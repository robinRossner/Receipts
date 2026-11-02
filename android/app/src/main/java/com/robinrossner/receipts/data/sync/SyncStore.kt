package com.robinrossner.receipts.data.sync

import androidx.room.withTransaction
import com.robinrossner.receipts.data.api.PushEntity
import com.robinrossner.receipts.data.api.PushResponse
import com.robinrossner.receipts.data.api.PushStatus
import com.robinrossner.receipts.data.api.WireDictionaryEntry
import com.robinrossner.receipts.data.api.WireLineItem
import com.robinrossner.receipts.data.api.WireReceipt
import com.robinrossner.receipts.data.api.WireTaxonomyAddition
import com.robinrossner.receipts.data.Taxonomy
import com.robinrossner.receipts.data.db.AppDatabase
import com.robinrossner.receipts.data.db.DictionaryEntity
import com.robinrossner.receipts.data.db.LineItemEntity
import com.robinrossner.receipts.data.db.LocalStatus
import com.robinrossner.receipts.data.db.MetaEntity
import com.robinrossner.receipts.data.db.ReceiptEntity
import com.robinrossner.receipts.data.db.SyncState
import com.robinrossner.receipts.data.db.TaxonomyAdditionEntity
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import java.util.Locale

/** JSON arrays of strings in text columns (aliases, review reasons). */
object StringLists {
    private val serializer = ListSerializer(String.serializer())
    fun decode(text: String?): List<String> =
        if (text.isNullOrBlank()) emptyList() else runCatching { com.robinrossner.receipts.data.api.WireJson.json.decodeFromString(serializer, text) }.getOrDefault(emptyList())

    fun encode(list: List<String>): String = com.robinrossner.receipts.data.api.WireJson.json.encodeToString(serializer, list)
}

/** One chunk of local changes of ONE entity kind, plus the clock values it was read with (a row edited again while the push is in flight keeps its dirty mark). */
data class PushBatch(
    val dictionary: List<WireDictionaryEntry> = emptyList(),
    val receipts: List<WireReceipt> = emptyList(),
    val lineItems: List<WireLineItem> = emptyList(),
    val taxonomyAdditions: List<WireTaxonomyAddition> = emptyList(),
    /** `entity:uuid` -> the `updated_at` that was sent. */
    val stamps: Map<String, String> = emptyMap(),
) {
    val isEmpty get() = dictionary.isEmpty() && receipts.isEmpty() && lineItems.isEmpty() && taxonomyAdditions.isEmpty()

    companion object {
        fun key(entity: PushEntity, id: String) = "${entity.name}:$id"
    }
}

data class PushSummary(var applied: Int = 0, var stale: Int = 0, val rejected: MutableList<String> = mutableListOf())

data class ApplySummary(
    var dictionary: Int = 0, var receipts: Int = 0, var lineItems: Int = 0, var deletedLocally: Int = 0,
    /** User-added categories that were new on this phone. */
    var taxonomyAdditions: Int = 0,
) {
    val total get() = dictionary + receipts + lineItems + deletedLocally + taxonomyAdditions
}

/** Local persistence of the sync engine, over Room. */
class SyncStore(val db: AppDatabase, val paths: AppPaths) {
    private val receipts get() = db.receipts()
    private val items get() = db.lineItems()
    private val dictionary get() = db.dictionary()
    private val sync get() = db.sync()
    private val taxonomy get() = db.taxonomy()

    suspend fun meta(key: String): String? = sync.meta(key)
    suspend fun setMeta(key: String, value: String?) {
        if (value == null) sync.deleteMeta(key) else sync.setMeta(MetaEntity(key, value))
    }

    suspend fun unsentChangeCount() = receipts.unsentChangeCount()
    suspend fun rejectedCount() = receipts.rejectedCount()
    suspend fun inFlightCount() = receipts.inFlightCount()

    // ---- push ----

    /**
     * One chunk of the local changes of one entity kind (live records and tombstones alike: a delete is an edit with
     * `deleted_at`). The engine sends the new categories first, then all dictionary entries, then all receipts, then
     * all line items, so references always exist on the server (an entry using a path the server does not know yet is
     * rejected).
     */
    suspend fun collectPush(entity: PushEntity, limit: Int = 400): PushBatch = when (entity) {
        PushEntity.TAXONOMY_ADDITION ->
            PushBatch(taxonomyAdditions = taxonomy.dirty(limit).map { WireTaxonomyAddition(it.category, it.subcategory, it.itemGroup, it.createdAt) })
        PushEntity.DICTIONARY -> {
            val rows = sync.dirtyDictionary(limit).map { it.toWire().forPush() }
            PushBatch(dictionary = rows, stamps = rows.associate { PushBatch.key(entity, it.id) to it.updatedAt })
        }
        PushEntity.RECEIPT -> {
            val rows = sync.dirtyReceipts(limit).map { it.toWire().forPush() }
            PushBatch(receipts = rows, stamps = rows.associate { PushBatch.key(entity, it.id) to it.updatedAt })
        }
        PushEntity.LINE_ITEM -> {
            val rows = sync.dirtyLineItems(limit).map { it.toWire().forPush() }
            PushBatch(lineItems = rows, stamps = rows.associate { PushBatch.key(entity, it.id) to it.updatedAt })
        }
    }

    /**
     * Marks what the server acknowledged (`applied` or `stale`: either way our copy is no longer ahead of it) as synced,
     * but only rows that were not edited again in the meantime; keeps `rejected` ones out of the dirty set (with the
     * reason) until the user edits them again.
     */
    suspend fun applyPushResults(batch: PushBatch, response: PushResponse): PushSummary = db.withTransaction {
        val summary = PushSummary()
        for (result in response.results) {
            val id = result.id
            if (result.entity == PushEntity.TAXONOMY_ADDITION) {
                // `id` is the path as the server spells it ("Household > Pets > Pet Food"; it may fix the case of an
                // existing category), so match on the lower-cased path. A rejected result without an id cannot be matched.
                val key = id?.lowercase(Locale.ROOT)
                when (result.status) {
                    PushStatus.APPLIED, PushStatus.STALE -> {   // stale: the path already exists, which is what we wanted
                        if (result.status == PushStatus.APPLIED) summary.applied++ else summary.stale++
                        if (key != null) taxonomy.mark(key, SyncState.SYNCED, null)
                    }
                    PushStatus.REJECTED -> {
                        val reason = result.reason ?: "rejected"
                        summary.rejected += "taxonomy_addition ${id ?: "?"}: $reason"
                        if (key != null) taxonomy.mark(key, SyncState.REJECTED, reason)
                    }
                }
                continue
            }
            if (id == null) {
                if (result.status == PushStatus.REJECTED) summary.rejected += result.reason ?: "rejected"
                continue
            }
            val stamp = batch.stamps[PushBatch.key(result.entity, id)]
            when (result.status) {
                PushStatus.APPLIED, PushStatus.STALE -> {
                    if (result.status == PushStatus.APPLIED) summary.applied++ else summary.stale++
                    if (stamp != null) when (result.entity) {
                        PushEntity.DICTIONARY -> sync.dictionarySynced(id, stamp)
                        PushEntity.RECEIPT -> sync.receiptSynced(id, stamp)
                        PushEntity.LINE_ITEM -> sync.lineItemSynced(id, stamp)
                        PushEntity.TAXONOMY_ADDITION -> Unit
                    }
                }
                PushStatus.REJECTED -> {
                    val reason = result.reason ?: "rejected"
                    summary.rejected += "${result.entity.name.lowercase()} $id: $reason"
                    if (stamp != null) when (result.entity) {
                        PushEntity.DICTIONARY -> sync.dictionaryRejected(id, stamp, reason)
                        PushEntity.RECEIPT -> sync.receiptRejected(id, stamp, reason)
                        PushEntity.LINE_ITEM -> sync.lineItemRejected(id, stamp, reason)
                        PushEntity.TAXONOMY_ADDITION -> Unit
                    }
                }
            }
        }
        summary
    }

    // ---- pull ----

    /** Applies the pulled pages (already merged: the last version of a record wins) in ONE transaction. */
    suspend fun applyPull(
        dictionaryEntries: List<WireDictionaryEntry>, receiptList: List<WireReceipt>, lineItemList: List<WireLineItem>,
        taxonomyAdditions: List<WireTaxonomyAddition> = emptyList(),
    ): ApplySummary = db.withTransaction {
        val summary = ApplySummary()
        // 0. new category paths first: a dictionary entry may use one. Additions are append-only: a local one the
        // server lacks (not pushed yet, or an older server) stays.
        for (a in taxonomyAdditions) upsertAddition(a, summary)
        // 1. dictionary (live), 2. receipts, 3. line items, 4. dictionary tombstones last: a merge delivers the line
        // items' new dictionary id and the merged-away entry's tombstone together.
        for (e in dictionaryEntries) if (e.deletedAt == null) upsertDictionary(e, summary)
        for (r in receiptList) upsertReceipt(r, summary)
        for (l in lineItemList) upsertLineItem(l, summary)
        for (e in dictionaryEntries) if (e.deletedAt != null) tombstoneDictionary(e, summary)
        summary
    }

    private suspend fun upsertAddition(a: WireTaxonomyAddition, summary: ApplySummary) {
        if (Taxonomy.additionProblem(a.path) != null) return   // the server vouches for its paths, but a malformed one would break the pickers
        val key = TaxonomyAdditionEntity.keyOf(a.category, a.subcategory, a.itemGroup)
        val inserted = taxonomy.insert(
            TaxonomyAdditionEntity(
                category = a.category, subcategory = a.subcategory, itemGroup = a.itemGroup, createdAt = a.createdAt ?: SyncDate.now(),
                pathKey = key, syncState = SyncState.SYNCED,
            ),
        )
        if (inserted == -1L) taxonomy.acknowledge(key)   // we had it (maybe unsent): the server knows it now
        else summary.taxonomyAdditions++
    }

    private suspend fun upsertDictionary(e: WireDictionaryEntry, summary: ApplySummary) {
        val local = dictionary.get(e.id.lowercase())
        if (local == null) {
            val clash = dictionary.findAnyByName(e.canonicalName)
            if (clash != null) {
                // The name belongs to a different local row (never synced under this uuid). Move its items to the
                // server's entry (a local change as far as the server is concerned) and drop it: nothing duplicated.
                dictionary.parkName(clash.uuid, clash.uuid.take(8))
            }
            dictionary.upsert(e.toEntity())
            if (clash != null) {
                dictionary.repointItems(clash.uuid, e.id.lowercase(), SyncDate.now())
                dictionary.delete(clash.uuid)
            }
            summary.dictionary++
            return
        }
        // server-owned counters always follow the server
        dictionary.updateCounters(e.id.lowercase(), e.timesSeen ?: 1, e.lastSeenAt)
        val decision = SyncMerge.decide(SyncDate.parse(local.updatedAt), local.syncState == SyncState.DIRTY, SyncDate.parse(e.updatedAt))
        if (decision != SyncMerge.Decision.TAKE_SERVER) return
        dictionary.findAnyByName(e.canonicalName)?.takeIf { it.uuid != e.id.lowercase() }?.let { dictionary.parkName(it.uuid, it.uuid.take(8)) }
        dictionary.upsert(e.toEntity(local).copy(createdAt = local.createdAt ?: e.createdAt))
        summary.dictionary++
    }

    private suspend fun tombstoneDictionary(e: WireDictionaryEntry, summary: ApplySummary) {
        val local = dictionary.get(e.id.lowercase()) ?: return
        val decision = SyncMerge.decide(SyncDate.parse(local.updatedAt), local.syncState == SyncState.DIRTY, SyncDate.parse(e.updatedAt))
        if (decision != SyncMerge.Decision.TAKE_SERVER) return
        dictionary.upsert(local.copy(deletedAt = e.deletedAt, updatedAt = e.updatedAt, syncState = SyncState.SYNCED, syncError = null))
        summary.deletedLocally++
    }

    private suspend fun upsertReceipt(r: WireReceipt, summary: ApplySummary) {
        val local = receipts.get(r.id.lowercase())
        if (local == null) {
            receipts.upsert(r.toEntity())
            summary.receipts++
            return
        }
        if (local.purged) return   // a receipt the user deleted for good stays gone
        // server-owned fields always follow the server, next to a local edit too
        var merged = local.copy(
            photoLocation = r.photoLocation, photoSha256 = r.photoSha256, photoBytes = r.photoBytes, photoMediaType = r.photoMediaType,
            archivedAt = r.archivedAt, extractionStatus = r.extractionStatus, extractionError = r.extractionError,
        )
        val decision = SyncMerge.decide(SyncDate.parse(local.updatedAt), local.syncState == SyncState.DIRTY, SyncDate.parse(r.updatedAt))
        if (decision == SyncMerge.Decision.TAKE_SERVER) {
            merged = merged.copy(
                store = r.store, date = r.date, time = r.time, total = r.total, computedSum = r.computedSum, needsReview = r.needsReview,
                reviewReasons = StringLists.encode(r.reviewReasons), reviewedAt = r.reviewedAt, deletedAt = r.deletedAt,
                updatedAt = r.updatedAt, syncState = SyncState.SYNCED, syncError = null,
            )
            summary.receipts++
        }
        receipts.upsert(merged)
    }

    private suspend fun upsertLineItem(l: WireLineItem, summary: ApplySummary) {
        if (receipts.get(l.receiptId.lowercase())?.purged == true) return
        val local = items.get(l.id.lowercase())
        val decision = SyncMerge.decide(SyncDate.parse(local?.updatedAt), local?.syncState == SyncState.DIRTY, SyncDate.parse(l.updatedAt))
        if (decision != SyncMerge.Decision.TAKE_SERVER) return
        if (l.deletedAt != null && local == null) return   // a tombstone for something we never had
        items.upsert(l.toEntity())
        if (l.deletedAt != null) summary.deletedLocally++ else summary.lineItems++
    }

    // ---- uploads ----

    /** A receipt for a photo that is prepared but not uploaded yet: invisible to push until the upload succeeded. */
    suspend fun insertPendingUpload(uuid: String, createdAt: String, localPhoto: String, imageHash: String?, mediaType: String = "image/jpeg") {
        receipts.insert(
            ReceiptEntity(
                uuid = uuid, createdAt = createdAt, updatedAt = createdAt, localPhoto = localPhoto, imageHash = imageHash,
                photoLocation = "server", photoMediaType = mediaType, extractionStatus = LocalStatus.PENDING_UPLOAD,
            ),
        )
    }

    suspend fun pendingUploads(): List<ReceiptEntity> = receipts.pendingUploads()

    /** The server has the photo: take over what it says about the receipt (status, sha) without touching content. */
    suspend fun markUploaded(uuid: String, server: WireReceipt) = receipts.markUploaded(
        uuid, server.extractionStatus ?: "queued", server.extractionError, server.photoLocation ?: "server", server.photoSha256,
        server.photoBytes, server.photoMediaType, server.updatedAt,
    )

    /** `permanent`: the server will never take these bytes (not an image, too large): needs the user. */
    suspend fun markUploadFailed(uuid: String, message: String, permanent: Boolean) =
        receipts.markUploadFailed(uuid, message, if (permanent) LocalStatus.UPLOAD_FAILED else LocalStatus.PENDING_UPLOAD)

    suspend fun requeueUpload(uuid: String) = receipts.requeueUpload(uuid)

    /** Drops a local receipt that never reached the server (the server already has the same photo). Returns its photo path. */
    suspend fun discardLocalReceipt(uuid: String): String? = db.withTransaction {
        val path = receipts.get(uuid)?.localPhoto
        receipts.deleteItemsOf(uuid)
        receipts.delete(uuid)
        path
    }

    suspend fun setLocalPhoto(uuid: String, path: String?) = receipts.setLocalPhoto(uuid, path)
    suspend fun receipt(uuid: String) = receipts.get(uuid)
}

// ---- entity <-> wire ----

fun DictionaryEntity.toWire() = WireDictionaryEntry(
    id = uuid, canonicalName = canonicalName, displayNameDe = displayNameDe, translationEn = translationEn, category = category,
    subcategory = subcategory, itemGroup = itemGroup, aliases = StringLists.decode(aliases), isManualOverride = isManualOverride,
    needsReview = needsReview, categoryFlagged = categoryFlagged, suggestedCategory = suggestedCategory.takeIf { categoryFlagged },
    suggestedParent = suggestedParent.takeIf { categoryFlagged }, timesSeen = timesSeen, createdAt = createdAt, lastSeenAt = lastSeenAt,
    updatedAt = updatedAt, deletedAt = deletedAt,
)

/**
 * The flag is the server's when it sends one. A server that does not know the flag omits it: [local]'s stays, unless
 * the category changed (somebody chose a category, which resolves the flag).
 */
fun WireDictionaryEntry.toEntity(local: DictionaryEntity? = null): DictionaryEntity {
    var flagged = categoryFlagged ?: false
    var suggestedCategory = suggestedCategory
    var suggestedParent = suggestedParent
    if (local != null && categoryFlagged == null) {
        val sameCategory = local.category == category && local.subcategory == subcategory && local.itemGroup == itemGroup
        flagged = sameCategory && local.categoryFlagged
        suggestedCategory = local.suggestedCategory
        suggestedParent = local.suggestedParent
    }
    if (!flagged) { suggestedCategory = null; suggestedParent = null }
    return DictionaryEntity(
        uuid = id.lowercase(), canonicalName = canonicalName, displayNameDe = displayNameDe, translationEn = translationEn, category = category,
        subcategory = subcategory, itemGroup = itemGroup, aliases = StringLists.encode(aliases), isManualOverride = isManualOverride,
        needsReview = needsReview, categoryFlagged = flagged, suggestedCategory = suggestedCategory, suggestedParent = suggestedParent,
        timesSeen = timesSeen ?: 1, createdAt = createdAt ?: updatedAt, lastSeenAt = lastSeenAt ?: updatedAt,
        updatedAt = updatedAt, deletedAt = deletedAt, syncState = SyncState.SYNCED,
    )
}

fun ReceiptEntity.toWire() = WireReceipt(
    id = uuid, store = store, date = date, time = time, total = total, computedSum = computedSum, needsReview = needsReview,
    reviewReasons = StringLists.decode(reviewReasons), reviewedAt = reviewedAt, createdAt = createdAt, photoLocation = photoLocation,
    photoSha256 = photoSha256, updatedAt = updatedAt, deletedAt = deletedAt,
)

fun WireReceipt.toEntity() = ReceiptEntity(
    uuid = id.lowercase(), store = store, date = date, time = time, total = total, computedSum = computedSum, needsReview = needsReview,
    reviewReasons = StringLists.encode(reviewReasons), reviewedAt = reviewedAt, createdAt = createdAt ?: updatedAt, updatedAt = updatedAt,
    deletedAt = deletedAt, photoLocation = photoLocation, photoSha256 = photoSha256, photoBytes = photoBytes, photoMediaType = photoMediaType,
    archivedAt = archivedAt, extractionStatus = extractionStatus, extractionError = extractionError, syncState = SyncState.SYNCED,
)

fun LineItemEntity.toWire() = WireLineItem(
    id = uuid, receiptId = receiptId, itemDictionaryId = itemDictionaryId, position = position, rawText = rawText, nameDe = nameDe,
    quantity = quantity, unitPrice = unitPrice, totalPrice = totalPrice, priceNormalized = priceNormalized, updatedAt = updatedAt, deletedAt = deletedAt,
)

fun WireLineItem.toEntity() = LineItemEntity(
    uuid = id.lowercase(), receiptId = receiptId.lowercase(), itemDictionaryId = itemDictionaryId.lowercase(), position = position,
    rawText = rawText, nameDe = nameDe, quantity = quantity, unitPrice = unitPrice, totalPrice = totalPrice, priceNormalized = priceNormalized,
    updatedAt = updatedAt, deletedAt = deletedAt, syncState = SyncState.SYNCED,
)
