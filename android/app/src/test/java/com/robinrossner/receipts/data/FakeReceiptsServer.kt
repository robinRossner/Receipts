package com.robinrossner.receipts.data

import com.robinrossner.receipts.data.api.ArchiveConfirmResponse
import com.robinrossner.receipts.data.api.ArchivePendingPhoto
import com.robinrossner.receipts.data.api.DownloadedPhoto
import com.robinrossner.receipts.data.api.PullResponse
import com.robinrossner.receipts.data.api.PushEntity
import com.robinrossner.receipts.data.api.PushRequest
import com.robinrossner.receipts.data.api.PushResponse
import com.robinrossner.receipts.data.api.PushResult
import com.robinrossner.receipts.data.api.PushStatus
import com.robinrossner.receipts.data.api.ReceiptsApi
import com.robinrossner.receipts.data.api.ServerStatus
import com.robinrossner.receipts.data.api.UploadResponse
import com.robinrossner.receipts.data.api.WireDictionaryEntry
import com.robinrossner.receipts.data.api.WireJson
import com.robinrossner.receipts.data.api.WireLineItem
import com.robinrossner.receipts.data.api.WireReceipt
import com.robinrossner.receipts.data.api.WireTaxonomyAddition
import com.robinrossner.receipts.data.sync.SyncDate
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/**
 * The receipts backend in memory, enough of it for the sync tests. The push rules are copied from
 * `backend/receipts/sync/push.py` (flag keys apply only when present, a pushed path must be in the merged taxonomy,
 * LWW needs a STRICTLY newer `updated_at`), not invented. Requests and responses go through JSON, so the wire types
 * are exercised, and "key absent" is seen as the server sees it.
 *
 * [legacyServer] = a server from before the flag work: it ignores the flag keys and the additions, never sends them.
 */
class FakeReceiptsServer(private val base: Taxonomy, var legacyServer: Boolean = false) : ReceiptsApi {
    val dictionary = LinkedHashMap<String, WireDictionaryEntry>()
    val receipts = LinkedHashMap<String, WireReceipt>()
    val lineItems = LinkedHashMap<String, WireLineItem>()
    val additions = mutableListOf<WireTaxonomyAddition>()
    val pushLog = mutableListOf<PushRequest>()

    /** Raw JSON bodies of the pushes, as sent (to check which keys are on the wire). */
    val pushBodies = mutableListOf<JsonObject>()
    var pullCalls = 0
    var archivePendingCalls = 0
    val confirmCalls = mutableListOf<Triple<String, String, Boolean>>()
    var archiveSyncCalls = 0

    private var seq = 0L
    private val seqOf = HashMap<String, Long>()

    private fun touch(key: String) { seqOf[key] = ++seq }

    val mergedTaxonomy: Taxonomy get() = base.adding(additions.map { it.path })

    /** A record as another device left it on the server. */
    fun seedDictionary(e: WireDictionaryEntry) { dictionary[e.id.lowercase()] = e; touch("d:" + e.id.lowercase()) }
    fun seedReceipt(r: WireReceipt) { receipts[r.id.lowercase()] = r; touch("r:" + r.id.lowercase()) }
    fun seedLineItem(l: WireLineItem) { lineItems[l.id.lowercase()] = l; touch("l:" + l.id.lowercase()) }
    fun seedAddition(a: WireTaxonomyAddition) { additions += a }

    private fun newer(incoming: String, stored: String): Boolean {
        val a = SyncDate.parse(incoming)!!
        val b = SyncDate.parse(stored) ?: return true
        return a.isAfter(b)
    }

    private fun result(entity: PushEntity, id: String?, status: PushStatus, reason: String? = null) = PushResult(entity, id, status, reason)

    override suspend fun push(request: PushRequest): PushResponse {
        val body = WireJson.json.encodeToString(request)
        val raw = WireJson.json.parseToJsonElement(body).jsonObject
        pushBodies += raw
        val req = WireJson.json.decodeFromString<PushRequest>(body)
        pushLog += req
        val results = mutableListOf<PushResult>()
        if (!legacyServer) req.taxonomyAdditions.orEmpty().forEach { results += addition(it) }
        val rawDictionary = raw["dictionary"]?.jsonArray.orEmpty().map { it.jsonObject }
        req.dictionary.forEachIndexed { i, rec -> results += dictionary(rec, rawDictionary[i]) }
        req.receipts.forEach { results += receipt(it) }
        req.lineItems.forEach { results += lineItem(it) }
        return WireJson.json.decodeFromString(WireJson.json.encodeToString(PushResponse(SyncDate.now(), results)))
    }

    private fun addition(a: WireTaxonomyAddition): PushResult {
        val label = a.label
        Taxonomy.additionProblem(a.path)?.let { return result(PushEntity.TAXONOMY_ADDITION, label, PushStatus.REJECTED, it) }
        val merged = mergedTaxonomy
        val existing = merged.canonicalPath(a.path)
        if (existing != null) return result(PushEntity.TAXONOMY_ADDITION, existing.label, PushStatus.STALE, "path already exists")
        // the server spells an existing category / subcategory as it knows it
        val category = merged.canonicalCategory(a.category) ?: a.category
        val sub = merged.canonicalSubcategory(a.subcategory, category) ?: a.subcategory
        additions += WireTaxonomyAddition(category, sub, a.itemGroup, a.createdAt ?: SyncDate.now())
        return result(PushEntity.TAXONOMY_ADDITION, "$category > $sub > ${a.itemGroup}", PushStatus.APPLIED)
    }

    private fun flagText(value: String?): String? = value?.trim()?.split(Regex("\\s+"))?.joinToString(" ")?.take(80)?.ifEmpty { null }

    private fun dictionary(rec: WireDictionaryEntry, rawRec: JsonObject): PushResult {
        val id = rec.id.lowercase()
        val triple = listOf(rec.category, rec.subcategory, rec.itemGroup)
        if (triple.all { it != null } && !mergedTaxonomy.contains(rec.category, rec.subcategory, rec.itemGroup)) {
            return result(PushEntity.DICTIONARY, rec.id, PushStatus.REJECTED, "unknown category path " + triple.joinToString(" > "))
        }
        val row = dictionary[id]
        if (row != null && !newer(rec.updatedAt, row.updatedAt)) return result(PushEntity.DICTIONARY, rec.id, PushStatus.STALE)
        val clash = dictionary.values.firstOrNull { it.canonicalName == rec.canonicalName && it.deletedAt == null && it.id.lowercase() != id }
        if (rec.deletedAt == null && clash != null) {
            return result(PushEntity.DICTIONARY, rec.id, PushStatus.REJECTED, "canonical_name already used by entry ${clash.id}; merge into it instead")
        }
        var flagged = false
        var suggestedCategory: String? = null
        var suggestedParent: String? = null
        if (!legacyServer) {
            val flagSent = "category_flagged" in rawRec && rec.categoryFlagged != null
            if (row != null) {
                flagged = row.categoryFlagged == true
                suggestedCategory = row.suggestedCategory; suggestedParent = row.suggestedParent
                if (triple != listOf(row.category, row.subcategory, row.itemGroup) && !flagSent) { flagged = false; suggestedCategory = null; suggestedParent = null }
            }
            if (flagSent) flagged = rec.categoryFlagged == true
            if ("suggested_category" in rawRec && (flagSent || flagged)) suggestedCategory = rec.suggestedCategory
            if ("suggested_parent" in rawRec && (flagSent || flagged)) suggestedParent = rec.suggestedParent
        }
        dictionary[id] = rec.copy(
            categoryFlagged = if (legacyServer) null else flagged,
            suggestedCategory = if (flagged) flagText(suggestedCategory) else null,
            suggestedParent = if (flagged) flagText(suggestedParent) else null,
            aliases = ((row?.aliases.orEmpty()) + rec.aliases).distinct(),
            createdAt = row?.createdAt ?: rec.updatedAt, timesSeen = row?.timesSeen ?: 1,
        )
        touch("d:$id")
        return result(PushEntity.DICTIONARY, rec.id, PushStatus.APPLIED)
    }

    private fun receipt(rec: WireReceipt): PushResult {
        val id = rec.id.lowercase()
        val row = receipts[id]
        if (row != null && !newer(rec.updatedAt, row.updatedAt)) return result(PushEntity.RECEIPT, rec.id, PushStatus.STALE)
        // server-owned fields stay
        receipts[id] = rec.copy(
            createdAt = row?.createdAt ?: rec.updatedAt, photoLocation = row?.photoLocation ?: rec.photoLocation,
            photoSha256 = row?.photoSha256, extractionStatus = row?.extractionStatus,
        )
        touch("r:$id")
        return result(PushEntity.RECEIPT, rec.id, PushStatus.APPLIED)
    }

    private fun lineItem(rec: WireLineItem): PushResult {
        val id = rec.id.lowercase()
        if (rec.receiptId.lowercase() !in receipts) return result(PushEntity.LINE_ITEM, rec.id, PushStatus.REJECTED, "unknown receipt")
        val row = lineItems[id]
        if (row != null && !newer(rec.updatedAt, row.updatedAt)) return result(PushEntity.LINE_ITEM, rec.id, PushStatus.STALE)
        lineItems[id] = rec
        touch("l:$id")
        return result(PushEntity.LINE_ITEM, rec.id, PushStatus.APPLIED)
    }

    override suspend fun pull(since: String?, limit: Int): PullResponse {
        pullCalls++
        val after = since?.toLongOrNull() ?: 0L
        fun <T> select(map: Map<String, T>, prefix: String) = map.filter { (seqOf[prefix + it.key] ?: 0) > after }.values.toList()
        val page = PullResponse(
            cursor = seq.toString(), hasMore = false, serverTime = SyncDate.now(),
            dictionary = select(dictionary, "d:").map { if (legacyServer) it.copy(categoryFlagged = null, suggestedCategory = null, suggestedParent = null) else it },
            receipts = select(receipts, "r:"), lineItems = select(lineItems, "l:"),
            taxonomyAdditions = if (legacyServer) null else additions.toList(),
        )
        return WireJson.json.decodeFromString(WireJson.json.encodeToString(page))
    }

    override suspend fun health() {}
    override suspend fun status(): ServerStatus = ServerStatus()
    override suspend fun uploadPhoto(id: String, data: ByteArray, mediaType: String, createdAtMillis: Long?): UploadResponse = error("no uploads in this fake")
    override suspend fun retryExtraction(id: String) {}
    override suspend fun archivePending(): List<ArchivePendingPhoto> { archivePendingCalls++; return emptyList() }
    override suspend fun downloadPhoto(path: String): DownloadedPhoto = error("no photos in this fake")
    override suspend fun archiveConfirm(id: String, sha256: String, deviceId: String, acceptFailed: Boolean): ArchiveConfirmResponse {
        confirmCalls += Triple(id, sha256, acceptFailed)
        return ArchiveConfirmResponse("archived", id)
    }
    override suspend fun archiveSync(deviceId: String) { archiveSyncCalls++ }
}
