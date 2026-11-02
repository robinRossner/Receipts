package com.robinrossner.receipts.data.api

import com.robinrossner.receipts.data.TaxonomyPath
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Wire types of docs/api/receipts.md (JSON, snake_case). Timestamps stay strings: compare instants with
 * [com.robinrossner.receipts.data.sync.SyncDate], never text.
 */
object WireJson {
    /** Unknown fields are ignored; null fields are left out (the server reads an omitted field as null). */
    val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        encodeDefaults = true
    }
}

@Serializable
data class WireDictionaryEntry(
    val id: String,
    @SerialName("legacy_id") val legacyId: Int? = null,
    @SerialName("canonical_name") val canonicalName: String,
    @SerialName("display_name_de") val displayNameDe: String? = null,
    @SerialName("translation_en") val translationEn: String? = null,
    val category: String? = null,
    val subcategory: String? = null,
    @SerialName("item_group") val itemGroup: String? = null,
    val aliases: List<String> = emptyList(),
    @SerialName("is_manual_override") val isManualOverride: Boolean = false,
    @SerialName("needs_review") val needsReview: Boolean = false,
    /**
     * "No good category" flag and the categoriser's suggestion. Null = the record says nothing about it (key omitted:
     * the server keeps what it has). A push always states the flag, see `DictionaryEntity.toWire`.
     */
    @SerialName("category_flagged") val categoryFlagged: Boolean? = null,
    @SerialName("suggested_category") val suggestedCategory: String? = null,
    @SerialName("suggested_parent") val suggestedParent: String? = null,
    @SerialName("times_seen") val timesSeen: Int? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("last_seen_at") val lastSeenAt: String? = null,
    @SerialName("updated_at") val updatedAt: String,
    @SerialName("deleted_at") val deletedAt: String? = null,
) {
    /** What a push may carry: the server ignores the rest (the flag fields stay: they are written by the phone, too). */
    fun forPush() = copy(legacyId = null, timesSeen = null, createdAt = null, lastSeenAt = null)
}

@Serializable
data class WireReceipt(
    val id: String,
    @SerialName("legacy_id") val legacyId: Int? = null,
    val store: String? = null,
    val date: String? = null,
    val time: String? = null,
    val total: Double? = null,
    @SerialName("computed_sum") val computedSum: Double? = null,
    @SerialName("needs_review") val needsReview: Boolean = false,
    @SerialName("review_reasons") val reviewReasons: List<String> = emptyList(),
    @SerialName("reviewed_at") val reviewedAt: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("photo_location") val photoLocation: String? = null,
    @SerialName("photo_sha256") val photoSha256: String? = null,
    @SerialName("photo_bytes") val photoBytes: Long? = null,
    @SerialName("photo_media_type") val photoMediaType: String? = null,
    @SerialName("uploaded_at") val uploadedAt: String? = null,
    @SerialName("archived_at") val archivedAt: String? = null,
    @SerialName("extraction_status") val extractionStatus: String? = null,
    @SerialName("extraction_attempts") val extractionAttempts: Int? = null,
    @SerialName("extraction_error") val extractionError: String? = null,
    @SerialName("extraction_provider") val extractionProvider: String? = null,
    @SerialName("extraction_completed_at") val extractionCompletedAt: String? = null,
    @SerialName("updated_at") val updatedAt: String,
    @SerialName("deleted_at") val deletedAt: String? = null,
) {
    /**
     * Client-writable fields only. `photo_location` is read by the server only when it does not know the receipt
     * yet, and then accepts `none` or `archived` only (a push saying `server` is rejected). The phone is not the
     * archive and holds no migrated data, so it always sends `none`.
     */
    fun forPush(photoLocation: String = PUSH_PHOTO_LOCATION) = WireReceipt(
        id = id, store = store, date = date, time = time, total = total, computedSum = computedSum,
        needsReview = needsReview, reviewReasons = reviewReasons, reviewedAt = reviewedAt,
        photoLocation = photoLocation, updatedAt = updatedAt, deletedAt = deletedAt,
    )

    companion object {
        const val PUSH_PHOTO_LOCATION = "none"
    }
}

@Serializable
data class WireLineItem(
    val id: String,
    @SerialName("legacy_id") val legacyId: Int? = null,
    @SerialName("receipt_id") val receiptId: String,
    @SerialName("item_dictionary_id") val itemDictionaryId: String,
    val position: Int = 0,
    @SerialName("raw_text") val rawText: String? = null,
    @SerialName("name_de") val nameDe: String? = null,
    val quantity: Double = 1.0,
    @SerialName("unit_price") val unitPrice: Double = 0.0,
    @SerialName("total_price") val totalPrice: Double = 0.0,
    @SerialName("price_normalized") val priceNormalized: Boolean = false,
    @SerialName("updated_at") val updatedAt: String,
    @SerialName("deleted_at") val deletedAt: String? = null,
) {
    fun forPush() = copy(legacyId = null)
}

/** A category path the user added to the taxonomy; the server merges it into its copy and sends the full list with every pull. */
@Serializable
data class WireTaxonomyAddition(
    val category: String,
    val subcategory: String,
    @SerialName("item_group") val itemGroup: String,
    @SerialName("created_at") val createdAt: String? = null,
) {
    /** "Household > Pets > Pet Food" (how the server names it in push results). */
    val path get() = TaxonomyPath(category, subcategory, itemGroup)
    val label get() = path.label
}

// ---- push / pull ----

@Serializable
data class PushRequest(
    @SerialName("device_id") val deviceId: String,
    val dictionary: List<WireDictionaryEntry> = emptyList(),
    val receipts: List<WireReceipt> = emptyList(),
    @SerialName("line_items") val lineItems: List<WireLineItem> = emptyList(),
    /** Null, not empty, when there is nothing: the key is then omitted, as an older server expects. */
    @SerialName("taxonomy_additions") val taxonomyAdditions: List<WireTaxonomyAddition>? = null,
) {
    val isEmpty get() = dictionary.isEmpty() && receipts.isEmpty() && lineItems.isEmpty() && taxonomyAdditions.isNullOrEmpty()
}

@Serializable
enum class PushEntity {
    @SerialName("dictionary") DICTIONARY,
    @SerialName("receipt") RECEIPT,
    @SerialName("line_item") LINE_ITEM,
    @SerialName("taxonomy_addition") TAXONOMY_ADDITION,
}

@Serializable
enum class PushStatus {
    @SerialName("applied") APPLIED,
    @SerialName("stale") STALE,
    @SerialName("rejected") REJECTED,
}

@Serializable
data class PushResult(
    val entity: PushEntity,
    val id: String? = null,
    val status: PushStatus,
    val reason: String? = null,
)

@Serializable
data class PushResponse(
    @SerialName("server_time") val serverTime: String? = null,
    val results: List<PushResult> = emptyList(),
)

@Serializable
data class PullResponse(
    val cursor: String,
    @SerialName("has_more") val hasMore: Boolean = false,
    @SerialName("server_time") val serverTime: String? = null,
    @SerialName("taxonomy_version") val taxonomyVersion: String? = null,
    val dictionary: List<WireDictionaryEntry> = emptyList(),
    val receipts: List<WireReceipt> = emptyList(),
    @SerialName("line_items") val lineItems: List<WireLineItem> = emptyList(),
    /** The full list of user-added categories on every page; null from a server without the feature. */
    @SerialName("taxonomy_additions") val taxonomyAdditions: List<WireTaxonomyAddition>? = null,
)

// ---- upload, archive, status ----

@Serializable
data class UploadResponse(val created: Boolean = false, val receipt: WireReceipt)

@Serializable
data class ArchivePendingPhoto(
    val id: String,
    val sha256: String,
    val bytes: Long? = null,
    @SerialName("media_type") val mediaType: String? = null,
    @SerialName("uploaded_at") val uploadedAt: String? = null,
    @SerialName("extraction_status") val extractionStatus: String? = null,
    val archivable: Boolean = false,
    @SerialName("blocked_reason") val blockedReason: String? = null,
    val download: String,
)

@Serializable
data class ArchivePendingResponse(val count: Int = 0, val photos: List<ArchivePendingPhoto> = emptyList())

@Serializable
data class ArchiveConfirmRequest(
    val sha256: String,
    @SerialName("device_id") val deviceId: String,
    @SerialName("accept_failed") val acceptFailed: Boolean? = null,
)

@Serializable
data class ArchiveConfirmResponse(val status: String, @SerialName("receipt_id") val receiptId: String)

@Serializable
data class ArchiveSyncRequest(@SerialName("device_id") val deviceId: String)

class DownloadedPhoto(val data: ByteArray, val mediaType: String?, val headerSha256: String?)

/** `GET /status`: what the banners show. Unknown extra fields are ignored. */
@Serializable
data class ServerStatus(
    @SerialName("server_time") val serverTime: String? = null,
    @SerialName("last_archive_sync_at") val lastArchiveSyncAt: String? = null,
    @SerialName("archive_device_id") val archiveDeviceId: String? = null,
    @SerialName("unarchived_count") val unarchivedCount: Int = 0,
    @SerialName("unarchived_bytes") val unarchivedBytes: Long = 0,
    @SerialName("oldest_unarchived_at") val oldestUnarchivedAt: String? = null,
    @SerialName("disk_free_bytes") val diskFreeBytes: Long? = null,
    @SerialName("disk_total_bytes") val diskTotalBytes: Long? = null,
    @SerialName("archive_reminder_days") val archiveReminderDays: Int? = null,
    @SerialName("disk_warning_free_mb") val diskWarningFreeMb: Int? = null,
    @SerialName("archive_overdue") val archiveOverdue: Boolean = false,
    @SerialName("disk_warning") val diskWarning: Boolean = false,
    val queue: Queue? = null,
    val llm: Llm? = null,
) {
    @Serializable
    data class Queue(val queued: Int = 0, val processing: Int = 0, val done: Int = 0, val failed: Int = 0)

    @Serializable
    data class Llm(val provider: String? = null, @SerialName("credential_configured") val credentialConfigured: Boolean? = null)
}
