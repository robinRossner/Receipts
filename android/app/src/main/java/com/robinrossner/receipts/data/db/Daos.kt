package com.robinrossner.receipts.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

/** Row shape for the list. */
data class ReceiptSummary(
    val uuid: String,
    val store: String?,
    val date: String?,
    val time: String?,
    val total: Double?,
    val needsReview: Boolean,
    val reviewedAt: String?,
    val extractionStatus: String?,
    val extractionError: String?,
    val photoLocation: String?,
    val deletedAt: String?,
)

/** A line item joined with its dictionary entry. */
data class ItemRow(
    val uuid: String,
    val itemDictionaryId: String,
    val position: Int,
    val rawText: String?,
    val nameDe: String?,
    val quantity: Double,
    val unitPrice: Double,
    val totalPrice: Double,
    val translationEn: String?,
    val category: String?,
    val subcategory: String?,
    val itemGroup: String?,
    val dictNeedsReview: Boolean,
    val categoryFlagged: Boolean,
    val suggestedCategory: String?,
    val suggestedParent: String?,
)

data class GroupTotalRow(val category: String, val subcategory: String, val itemGroup: String, val total: Double)
data class MonthTotalRow(val month: String, val category: String, val total: Double)
data class StoreTotalRow(val store: String, val total: Double)
data class PurchaseDbRow(
    val date: String?,
    val store: String?,
    val translationEn: String?,
    val nameDe: String?,
    val quantity: Double,
    val unitPrice: Double,
    val totalPrice: Double,
    val receiptId: String,
    val itemDictionaryId: String,
)
data class PricePointRow(val date: String?, val item: String?, val unitPrice: Double, val dictId: String)
data class UsageRow(val items: Int, val receipts: Int)

/** A flagged dictionary entry with how often live receipts use it. */
data class FlaggedDbRow(
    val dictionaryId: String,
    val name: String,
    val translationEn: String?,
    val suggestedCategory: String?,
    val suggestedParent: String?,
    val itemCount: Int,
    val totalSpend: Double,
)
data class FlaggedReceiptDbRow(val dictionaryId: String, val receiptId: String)
data class ReviewReasonRow(val uuid: String, val reviewReasons: String)

@Dao
interface ReceiptDao {
    @Query(
        """SELECT uuid, store, date, time, total, needsReview, reviewedAt, extractionStatus, extractionError, photoLocation, deletedAt
           FROM receipts WHERE deletedAt IS NULL AND purged = 0
           ORDER BY CASE WHEN extractionStatus IN ('pending_upload','upload_failed','queued','processing','failed') THEN 0 ELSE 1 END,
                    date DESC, createdAt DESC""",
    )
    fun observeLive(): Flow<List<ReceiptSummary>>

    @Query(
        """SELECT uuid, store, date, time, total, needsReview, reviewedAt, extractionStatus, extractionError, photoLocation, deletedAt
           FROM receipts WHERE deletedAt IS NOT NULL AND purged = 0 ORDER BY deletedAt DESC""",
    )
    fun observeDeleted(): Flow<List<ReceiptSummary>>

    @Query("SELECT * FROM receipts WHERE uuid = :uuid")
    suspend fun get(uuid: String): ReceiptEntity?

    /** Review reasons of the flagged, unreviewed, live receipts (the inline line on a list row). */
    @Query("SELECT uuid, reviewReasons FROM receipts WHERE deletedAt IS NULL AND purged = 0 AND reviewedAt IS NULL AND needsReview = 1")
    fun observeReviewReasons(): Flow<List<ReviewReasonRow>>

    @Query("SELECT * FROM receipts WHERE uuid = :uuid")
    fun observe(uuid: String): Flow<ReceiptEntity?>

    @Upsert
    suspend fun upsert(receipt: ReceiptEntity)

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(receipt: ReceiptEntity)

    @Query(
        """SELECT DISTINCT r.uuid FROM receipts r
           LEFT JOIN line_items li ON li.receiptId = r.uuid AND li.deletedAt IS NULL
           LEFT JOIN item_dictionary d ON d.uuid = li.itemDictionaryId
           WHERE r.deletedAt IS NULL AND r.purged = 0
             AND (r.store LIKE :like OR li.nameDe LIKE :like OR d.translationEn LIKE :like OR printf('%.2f', r.total) LIKE :amount)""",
    )
    suspend fun search(like: String, amount: String): List<String>

    // ---- local counters ----
    @Query(
        """SELECT (SELECT COUNT(*) FROM receipts WHERE syncState = 'dirty' AND COALESCE(extractionStatus, '') NOT IN ('pending_upload','upload_failed'))
             + (SELECT COUNT(*) FROM line_items WHERE syncState = 'dirty')
             + (SELECT COUNT(*) FROM item_dictionary WHERE syncState = 'dirty')
             + (SELECT COUNT(*) FROM taxonomy_additions WHERE syncState = 'dirty')""",
    )
    suspend fun unsentChangeCount(): Int

    @Query(
        """SELECT (SELECT COUNT(*) FROM receipts WHERE syncState = 'rejected')
             + (SELECT COUNT(*) FROM line_items WHERE syncState = 'rejected')
             + (SELECT COUNT(*) FROM item_dictionary WHERE syncState = 'rejected')
             + (SELECT COUNT(*) FROM taxonomy_additions WHERE syncState = 'rejected')""",
    )
    suspend fun rejectedCount(): Int

    @Query(
        """SELECT COUNT(*) FROM receipts WHERE deletedAt IS NULL AND purged = 0
           AND extractionStatus IN ('pending_upload','queued','processing')""",
    )
    suspend fun inFlightCount(): Int

    @Query("SELECT COUNT(*) FROM receipts WHERE extractionStatus = 'pending_upload'")
    fun observePendingUploadCount(): Flow<Int>

    // ---- uploads ----
    @Query("SELECT * FROM receipts WHERE extractionStatus = 'pending_upload' ORDER BY createdAt")
    suspend fun pendingUploads(): List<ReceiptEntity>

    @Query("SELECT uuid FROM receipts WHERE imageHash = :hash AND deletedAt IS NULL AND purged = 0 LIMIT 1")
    suspend fun findByImageHash(hash: String): String?

    @Query("UPDATE receipts SET extractionStatus = 'pending_upload', extractionError = NULL WHERE uuid = :uuid AND extractionStatus = 'upload_failed'")
    suspend fun requeueUpload(uuid: String)

    @Query("UPDATE receipts SET extractionError = :message, extractionStatus = :status WHERE uuid = :uuid")
    suspend fun markUploadFailed(uuid: String, message: String, status: String)

    @Query(
        """UPDATE receipts SET extractionStatus = :status, extractionError = :error, photoLocation = :location, photoSha256 = :sha,
             photoBytes = :bytes, photoMediaType = :mediaType, updatedAt = :updatedAt, syncState = 'synced', syncError = NULL
           WHERE uuid = :uuid""",
    )
    suspend fun markUploaded(
        uuid: String, status: String, error: String?, location: String, sha: String?, bytes: Long?, mediaType: String?, updatedAt: String,
    )

    @Query("DELETE FROM line_items WHERE receiptId = :uuid")
    suspend fun deleteItemsOf(uuid: String)

    @Query("DELETE FROM receipts WHERE uuid = :uuid")
    suspend fun delete(uuid: String)

    // ---- photos ----
    @Query("UPDATE receipts SET localPhoto = :path WHERE uuid = :uuid")
    suspend fun setLocalPhoto(uuid: String, path: String?)

    @Query("UPDATE receipts SET localPhoto = NULL WHERE localPhoto LIKE 'photo_cache/%'")
    suspend fun forgetCachedPhotos()

    @Query("UPDATE receipts SET localPhoto = NULL WHERE localPhoto = :path")
    suspend fun forgetPhotoPath(path: String)

    @Query("UPDATE receipts SET photoLocation = 'archived' WHERE uuid = :uuid AND photoLocation = 'server'")
    suspend fun markPhotoArchived(uuid: String)

    // ---- stats ----
    @Query(
        """SELECT COALESCE(d.category, '') AS category, COALESCE(d.subcategory, '') AS subcategory,
                  COALESCE(d.itemGroup, '') AS itemGroup, SUM(li.totalPrice) AS total
           FROM line_items li
           JOIN item_dictionary d ON li.itemDictionaryId = d.uuid
           JOIN receipts r ON li.receiptId = r.uuid
           WHERE r.deletedAt IS NULL AND r.purged = 0 AND li.deletedAt IS NULL
             AND (:start IS NULL OR r.date >= :start) AND (:end IS NULL OR r.date <= :end)
           GROUP BY d.category, d.subcategory, d.itemGroup""",
    )
    suspend fun statsGroups(start: String?, end: String?): List<GroupTotalRow>

    @Query(
        """SELECT substr(r.date, 1, 7) AS month, COALESCE(d.category, '') AS category, SUM(li.totalPrice) AS total
           FROM line_items li
           JOIN item_dictionary d ON li.itemDictionaryId = d.uuid
           JOIN receipts r ON li.receiptId = r.uuid
           WHERE r.deletedAt IS NULL AND r.purged = 0 AND li.deletedAt IS NULL AND r.date IS NOT NULL
             AND (:start IS NULL OR r.date >= :start) AND (:end IS NULL OR r.date <= :end)
           GROUP BY 1, 2 ORDER BY 1""",
    )
    suspend fun statsMonthly(start: String?, end: String?): List<MonthTotalRow>

    @Query(
        """SELECT COALESCE(NULLIF(r.store, ''), 'Unknown') AS store, SUM(li.totalPrice) AS total
           FROM line_items li JOIN receipts r ON li.receiptId = r.uuid
           WHERE r.deletedAt IS NULL AND r.purged = 0 AND li.deletedAt IS NULL
             AND (:start IS NULL OR r.date >= :start) AND (:end IS NULL OR r.date <= :end)
           GROUP BY 1 ORDER BY 2 DESC""",
    )
    suspend fun statsByStore(start: String?, end: String?): List<StoreTotalRow>

    @Query(
        """SELECT r.date AS date, r.store AS store, d.translationEn AS translationEn, li.nameDe AS nameDe, li.quantity AS quantity,
                  li.unitPrice AS unitPrice, li.totalPrice AS totalPrice, li.receiptId AS receiptId, d.uuid AS itemDictionaryId
           FROM line_items li
           JOIN item_dictionary d ON li.itemDictionaryId = d.uuid
           JOIN receipts r ON li.receiptId = r.uuid
           WHERE r.deletedAt IS NULL AND r.purged = 0 AND li.deletedAt IS NULL
             AND d.category = :category AND d.subcategory = :subcategory AND d.itemGroup = :itemGroup
             AND (:start IS NULL OR r.date >= :start) AND (:end IS NULL OR r.date <= :end)
           ORDER BY r.date DESC""",
    )
    suspend fun statsPurchases(category: String, subcategory: String, itemGroup: String, start: String?, end: String?): List<PurchaseDbRow>

    @Query(
        """SELECT r.date AS date, COALESCE(d.translationEn, li.nameDe, d.canonicalName) AS item, li.unitPrice AS unitPrice, d.uuid AS dictId
           FROM line_items li
           JOIN item_dictionary d ON li.itemDictionaryId = d.uuid
           JOIN receipts r ON li.receiptId = r.uuid
           WHERE r.deletedAt IS NULL AND r.purged = 0 AND li.deletedAt IS NULL AND r.date IS NOT NULL
             AND d.category = :category AND d.subcategory = :subcategory AND d.itemGroup = :itemGroup AND li.unitPrice > 0
           ORDER BY r.date""",
    )
    suspend fun statsPriceHistory(category: String, subcategory: String, itemGroup: String): List<PricePointRow>

    @Query("SELECT DISTINCT store FROM receipts WHERE store IS NOT NULL AND store != '' AND deletedAt IS NULL AND purged = 0")
    fun observeStoresInUse(): Flow<List<String>>

    /** Changes whenever receipts or items change (drives the stats reload). */
    @Query("SELECT COUNT(*) || '|' || COALESCE(MAX(updatedAt), '') FROM receipts")
    fun observeReceiptVersion(): Flow<String>

    @Query("SELECT COUNT(*) || '|' || COALESCE(MAX(updatedAt), '') FROM line_items")
    fun observeItemVersion(): Flow<String>
}

@Dao
interface LineItemDao {
    @Query(
        """SELECT li.uuid AS uuid, li.itemDictionaryId AS itemDictionaryId, li.position AS position, li.rawText AS rawText,
                  li.nameDe AS nameDe, li.quantity AS quantity, li.unitPrice AS unitPrice, li.totalPrice AS totalPrice,
                  d.translationEn AS translationEn, d.category AS category, d.subcategory AS subcategory, d.itemGroup AS itemGroup,
                  d.needsReview AS dictNeedsReview, d.categoryFlagged AS categoryFlagged, d.suggestedCategory AS suggestedCategory,
                  d.suggestedParent AS suggestedParent
           FROM line_items li JOIN item_dictionary d ON li.itemDictionaryId = d.uuid
           WHERE li.receiptId = :receiptId AND li.deletedAt IS NULL ORDER BY li.position, li.uuid""",
    )
    fun observeItems(receiptId: String): Flow<List<ItemRow>>

    @Query("SELECT * FROM line_items WHERE uuid = :uuid")
    suspend fun get(uuid: String): LineItemEntity?

    @Query("SELECT * FROM line_items WHERE receiptId = :receiptId AND deletedAt IS NULL")
    suspend fun liveItems(receiptId: String): List<LineItemEntity>

    @Query("SELECT COALESCE(SUM(totalPrice), 0) FROM line_items WHERE receiptId = :receiptId AND deletedAt IS NULL")
    suspend fun sumOf(receiptId: String): Double

    @Query("SELECT COALESCE(MAX(position), -1) FROM line_items WHERE receiptId = :receiptId")
    suspend fun maxPosition(receiptId: String): Int

    @Upsert
    suspend fun upsert(item: LineItemEntity)

    @Query(
        """SELECT COUNT(*) AS items, COUNT(DISTINCT li.receiptId) AS receipts FROM line_items li
           JOIN receipts r ON r.uuid = li.receiptId
           WHERE li.itemDictionaryId = :dictId AND li.deletedAt IS NULL AND r.deletedAt IS NULL AND r.purged = 0""",
    )
    suspend fun usage(dictId: String): UsageRow
}

@Dao
interface DictionaryDao {
    @Query("SELECT * FROM item_dictionary WHERE uuid = :uuid")
    suspend fun get(uuid: String): DictionaryEntity?

    @Query("SELECT * FROM item_dictionary WHERE canonicalName = :name AND deletedAt IS NULL LIMIT 1")
    suspend fun findByName(name: String): DictionaryEntity?

    @Query("SELECT * FROM item_dictionary WHERE canonicalName = :name LIMIT 1")
    suspend fun findAnyByName(name: String): DictionaryEntity?

    @Query("SELECT * FROM item_dictionary WHERE deletedAt IS NULL")
    suspend fun live(): List<DictionaryEntity>

    @Upsert
    suspend fun upsert(entry: DictionaryEntity)

    @Query("UPDATE item_dictionary SET timesSeen = :timesSeen, lastSeenAt = COALESCE(:lastSeenAt, lastSeenAt) WHERE uuid = :uuid")
    suspend fun updateCounters(uuid: String, timesSeen: Int, lastSeenAt: String?)

    @Query("UPDATE item_dictionary SET canonicalName = canonicalName || ' #moved-' || :suffix WHERE uuid = :uuid")
    suspend fun parkName(uuid: String, suffix: String)

    @Query("DELETE FROM item_dictionary WHERE uuid = :uuid")
    suspend fun delete(uuid: String)

    @Query("UPDATE line_items SET itemDictionaryId = :newId, syncState = 'dirty', updatedAt = :now WHERE itemDictionaryId = :oldId")
    suspend fun repointItems(oldId: String, newId: String, now: String)
}

@Dao
interface FlaggedDao {
    /** Entries a live receipt uses, grouped by suggestion later (`Flagged.kt`); the spend counts live items only. */
    @Query(
        """SELECT d.uuid AS dictionaryId, COALESCE(NULLIF(d.displayNameDe, ''), d.canonicalName) AS name, d.translationEn AS translationEn,
                  d.suggestedCategory AS suggestedCategory, d.suggestedParent AS suggestedParent,
                  COUNT(li.uuid) AS itemCount, COALESCE(SUM(li.totalPrice), 0) AS totalSpend
           FROM item_dictionary d
           JOIN line_items li ON li.itemDictionaryId = d.uuid AND li.deletedAt IS NULL
           JOIN receipts r ON r.uuid = li.receiptId AND r.deletedAt IS NULL AND r.purged = 0
           WHERE d.categoryFlagged = 1 AND d.deletedAt IS NULL
           GROUP BY d.uuid
           ORDER BY lower(COALESCE(d.suggestedParent, '')), lower(COALESCE(d.suggestedCategory, '')), d.uuid""",
    )
    fun observeList(): Flow<List<FlaggedDbRow>>

    @Query(
        """SELECT d.uuid AS dictionaryId, COALESCE(NULLIF(d.displayNameDe, ''), d.canonicalName) AS name, d.translationEn AS translationEn,
                  d.suggestedCategory AS suggestedCategory, d.suggestedParent AS suggestedParent,
                  COUNT(li.uuid) AS itemCount, COALESCE(SUM(li.totalPrice), 0) AS totalSpend
           FROM item_dictionary d
           JOIN line_items li ON li.itemDictionaryId = d.uuid AND li.deletedAt IS NULL
           JOIN receipts r ON r.uuid = li.receiptId AND r.deletedAt IS NULL AND r.purged = 0
           WHERE d.categoryFlagged = 1 AND d.deletedAt IS NULL
           GROUP BY d.uuid
           ORDER BY lower(COALESCE(d.suggestedParent, '')), lower(COALESCE(d.suggestedCategory, '')), d.uuid""",
    )
    suspend fun list(): List<FlaggedDbRow>

    /** Live receipts per flagged entry, newest first. */
    @Query(
        """SELECT li.itemDictionaryId AS dictionaryId, r.uuid AS receiptId FROM line_items li
           JOIN receipts r ON r.uuid = li.receiptId AND r.deletedAt IS NULL AND r.purged = 0
           JOIN item_dictionary d ON d.uuid = li.itemDictionaryId AND d.categoryFlagged = 1 AND d.deletedAt IS NULL
           WHERE li.deletedAt IS NULL GROUP BY li.itemDictionaryId, r.uuid ORDER BY r.createdAt DESC, r.uuid""",
    )
    suspend fun receiptRows(): List<FlaggedReceiptDbRow>

    /** The badge: entries a live receipt uses, not all flagged rows. */
    @Query(
        """SELECT COUNT(*) FROM item_dictionary d WHERE d.categoryFlagged = 1 AND d.deletedAt IS NULL AND EXISTS
             (SELECT 1 FROM line_items li JOIN receipts r ON r.uuid = li.receiptId AND r.deletedAt IS NULL AND r.purged = 0
              WHERE li.itemDictionaryId = d.uuid AND li.deletedAt IS NULL)""",
    )
    fun observeCount(): Flow<Int>
}

@Dao
interface TaxonomyDao {
    @Query("SELECT * FROM taxonomy_additions ORDER BY createdAt, id")
    fun observeAll(): Flow<List<TaxonomyAdditionEntity>>

    @Query("SELECT * FROM taxonomy_additions ORDER BY createdAt, id")
    suspend fun all(): List<TaxonomyAdditionEntity>

    /** -1 = the path (in any case) is already there. */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insert(e: TaxonomyAdditionEntity): Long

    @Query("SELECT * FROM taxonomy_additions WHERE syncState = 'dirty' ORDER BY createdAt, id LIMIT :limit")
    suspend fun dirty(limit: Int): List<TaxonomyAdditionEntity>

    @Query("UPDATE taxonomy_additions SET syncState = :state, syncError = :error WHERE syncState = 'dirty' AND pathKey = :key")
    suspend fun mark(key: String, state: String, error: String?)

    @Query("UPDATE taxonomy_additions SET syncState = 'synced', syncError = NULL WHERE pathKey = :key")
    suspend fun acknowledge(key: String)
}

@Dao
interface SyncDao {
    @Query("SELECT * FROM item_dictionary WHERE syncState = 'dirty' ORDER BY updatedAt LIMIT :limit")
    suspend fun dirtyDictionary(limit: Int): List<DictionaryEntity>

    @Query(
        """SELECT * FROM receipts WHERE syncState = 'dirty' AND COALESCE(extractionStatus, '') NOT IN ('pending_upload','upload_failed')
           ORDER BY updatedAt LIMIT :limit""",
    )
    suspend fun dirtyReceipts(limit: Int): List<ReceiptEntity>

    @Query(
        """SELECT li.* FROM line_items li JOIN receipts r ON r.uuid = li.receiptId
           WHERE li.syncState = 'dirty' AND COALESCE(r.extractionStatus, '') NOT IN ('pending_upload','upload_failed')
           ORDER BY li.updatedAt LIMIT :limit""",
    )
    suspend fun dirtyLineItems(limit: Int): List<LineItemEntity>

    @Query("UPDATE item_dictionary SET syncState = 'synced', syncError = NULL WHERE uuid = :uuid AND syncState = 'dirty' AND updatedAt = :stamp")
    suspend fun dictionarySynced(uuid: String, stamp: String)

    @Query("UPDATE receipts SET syncState = 'synced', syncError = NULL WHERE uuid = :uuid AND syncState = 'dirty' AND updatedAt = :stamp")
    suspend fun receiptSynced(uuid: String, stamp: String)

    @Query("UPDATE line_items SET syncState = 'synced', syncError = NULL WHERE uuid = :uuid AND syncState = 'dirty' AND updatedAt = :stamp")
    suspend fun lineItemSynced(uuid: String, stamp: String)

    @Query("UPDATE item_dictionary SET syncState = 'rejected', syncError = :reason WHERE uuid = :uuid AND syncState = 'dirty' AND updatedAt = :stamp")
    suspend fun dictionaryRejected(uuid: String, stamp: String, reason: String)

    @Query("UPDATE receipts SET syncState = 'rejected', syncError = :reason WHERE uuid = :uuid AND syncState = 'dirty' AND updatedAt = :stamp")
    suspend fun receiptRejected(uuid: String, stamp: String, reason: String)

    @Query("UPDATE line_items SET syncState = 'rejected', syncError = :reason WHERE uuid = :uuid AND syncState = 'dirty' AND updatedAt = :stamp")
    suspend fun lineItemRejected(uuid: String, stamp: String, reason: String)

    @Query("SELECT value FROM sync_meta WHERE `key` = :key")
    suspend fun meta(key: String): String?

    @Upsert
    suspend fun setMeta(entry: MetaEntity)

    @Query("DELETE FROM sync_meta WHERE `key` = :key")
    suspend fun deleteMeta(key: String)
}
