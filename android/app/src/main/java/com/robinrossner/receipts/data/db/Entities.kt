package com.robinrossner.receipts.data.db

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/** Local sync state of a record: `synced`, `dirty` (edited here, not acknowledged by the server yet), `rejected`. */
object SyncState {
    const val SYNCED = "synced"
    const val DIRTY = "dirty"
    const val REJECTED = "rejected"
}

/** Extraction states that exist only on the phone, before the server knows the receipt. */
object LocalStatus {
    const val PENDING_UPLOAD = "pending_upload"
    const val UPLOAD_FAILED = "upload_failed"
}

/**
 * A receipt. Deletes are tombstones (`deletedAt`), never removed rows, so a later undelete or a stale copy from the
 * server resolves by last-write-wins. `purged` hides a receipt the user deleted for good (its tombstone is still pushed).
 */
@Entity(tableName = "receipts", indices = [Index("syncState"), Index("date"), Index("imageHash")])
data class ReceiptEntity(
    @PrimaryKey val uuid: String,
    val store: String? = null,
    val date: String? = null,
    val time: String? = null,
    val total: Double? = null,
    val computedSum: Double? = null,
    val needsReview: Boolean = false,
    /** JSON array of strings. */
    val reviewReasons: String = "[]",
    val reviewedAt: String? = null,
    val createdAt: String,
    val updatedAt: String,
    val deletedAt: String? = null,
    // server-owned
    val photoLocation: String? = null,
    val photoSha256: String? = null,
    val photoBytes: Long? = null,
    val photoMediaType: String? = null,
    val archivedAt: String? = null,
    val extractionStatus: String? = null,
    val extractionError: String? = null,
    // local only
    /** Path of the local copy of the photo, relative to the app's files dir (outbox or cache); null = none. */
    val localPhoto: String? = null,
    val imageHash: String? = null,
    val purged: Boolean = false,
    val syncState: String = SyncState.SYNCED,
    val syncError: String? = null,
)

@Entity(
    tableName = "line_items",
    indices = [Index("receiptId"), Index("itemDictionaryId"), Index("syncState")],
)
data class LineItemEntity(
    @PrimaryKey val uuid: String,
    val receiptId: String,
    val itemDictionaryId: String,
    val position: Int = 0,
    val rawText: String? = null,
    val nameDe: String? = null,
    val quantity: Double = 1.0,
    val unitPrice: Double = 0.0,
    val totalPrice: Double = 0.0,
    val priceNormalized: Boolean = false,
    val updatedAt: String,
    val deletedAt: String? = null,
    val syncState: String = SyncState.SYNCED,
    val syncError: String? = null,
)

@Entity(tableName = "item_dictionary", indices = [Index("canonicalName"), Index("syncState"), Index("categoryFlagged")])
data class DictionaryEntity(
    @PrimaryKey val uuid: String,
    val canonicalName: String,
    val displayNameDe: String? = null,
    val translationEn: String? = null,
    val category: String? = null,
    val subcategory: String? = null,
    val itemGroup: String? = null,
    /** JSON array of strings. */
    val aliases: String = "[]",
    val isManualOverride: Boolean = false,
    val needsReview: Boolean = false,
    /**
     * "No good category": the server's categoriser found no fitting category and filed the item under the fallback.
     * The suggestions are non-null only while flagged ("Category" or "Category > Subcategory" for the parent).
     */
    @ColumnInfo(defaultValue = "0") val categoryFlagged: Boolean = false,
    val suggestedCategory: String? = null,
    val suggestedParent: String? = null,
    val timesSeen: Int = 1,
    val createdAt: String? = null,
    val lastSeenAt: String? = null,
    val updatedAt: String,
    val deletedAt: String? = null,
    val syncState: String = SyncState.SYNCED,
    val syncError: String? = null,
)

/**
 * A category path (category > subcategory > item group) the user added to the taxonomy. Append-only: never edited or
 * deleted, so the merge with the bundled taxonomy is the same on every device. Room cannot index `lower(...)`, so the
 * lower-cased path is stored as [pathKey] and is unique: the same path in another case is the same row.
 */
@Entity(tableName = "taxonomy_additions", indices = [Index("pathKey", unique = true)])
data class TaxonomyAdditionEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val category: String,
    val subcategory: String,
    val itemGroup: String,
    val createdAt: String,
    val pathKey: String,
    @ColumnInfo(defaultValue = "'dirty'") val syncState: String = SyncState.DIRTY,
    val syncError: String? = null,
) {
    companion object {
        /** `"$category > $subcategory > $itemGroup"` lower-cased: how the server spells a path in push results, too. */
        fun keyOf(category: String, subcategory: String, itemGroup: String) =
            "$category > $subcategory > $itemGroup".lowercase(java.util.Locale.ROOT)
    }
}

@Entity(tableName = "sync_meta")
data class MetaEntity(@PrimaryKey val key: String, val value: String?)
