package com.robinrossner.receipts.data

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.robinrossner.receipts.data.api.ReceiptsApi
import com.robinrossner.receipts.data.db.AppDatabase
import com.robinrossner.receipts.data.db.DictionaryEntity
import com.robinrossner.receipts.data.db.LineItemEntity
import com.robinrossner.receipts.data.db.ReceiptEntity
import com.robinrossner.receipts.data.db.SyncState
import com.robinrossner.receipts.data.sync.AppPaths
import com.robinrossner.receipts.data.sync.StringLists
import com.robinrossner.receipts.data.sync.SyncConfig
import com.robinrossner.receipts.data.sync.SyncEngine
import com.robinrossner.receipts.data.sync.SyncStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeout
import java.io.File
import java.nio.file.Files

/** The bundled taxonomy (the same file the app ships). Unit tests run in the module directory. */
fun bundledTaxonomy(): Taxonomy = Taxonomy.parse(File("src/main/assets/category_taxonomy.json").readText())

/** An in-memory (or file-backed) database with a repository, sync store and engine on top; for Robolectric tests. */
class TestEnv(
    val api: ReceiptsApi? = null,
    name: String? = null,
    val deviceId: String = "android-test",
    var changes: Int = 0,
    capabilities: com.robinrossner.receipts.data.api.SyncCapabilities = com.robinrossner.receipts.data.api.SyncCapabilities.MOBILE,
) {
    val context: Context = ApplicationProvider.getApplicationContext()
    val base = bundledTaxonomy()
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val dir: File = Files.createTempDirectory("receipts-test").toFile()
    val paths = AppPaths(dir)
    val db: AppDatabase = (if (name == null) Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java) else Room.databaseBuilder(context, AppDatabase::class.java, name))
        .allowMainThreadQueries().build()
    val store = SyncStore(db, paths)
    val repo = ReceiptRepository(db, paths, base, scope) { changes++ }
    val engine: SyncEngine? = api?.let { SyncEngine(it, store, SyncConfig(deviceId, "cursor:test", capabilities)) }

    fun close() {
        scope.cancel()
        db.close()
        dir.deleteRecursively()
    }

    /** Waits until the repository's merged taxonomy satisfies [test] (it follows the database through a flow). */
    suspend fun awaitTaxonomy(test: (Taxonomy) -> Boolean): Taxonomy = withTimeout(5_000) { repo.taxonomy.first(test) }

    // ---- seeding ----

    suspend fun receipt(
        uuid: String, store: String? = "Edeka", date: String? = "2026-03-01", status: String? = null, needsReview: Boolean = false,
        reasons: List<String> = emptyList(), reviewedAt: String? = null, createdAt: String = "2026-03-01T10:00:00.000Z",
        deletedAt: String? = null, purged: Boolean = false, syncState: String = SyncState.SYNCED, total: Double? = null,
        updatedAt: String = createdAt,
    ): ReceiptEntity = ReceiptEntity(
        uuid = uuid, store = store, date = date, total = total, needsReview = needsReview, reviewReasons = StringLists.encode(reasons),
        reviewedAt = reviewedAt, createdAt = createdAt, updatedAt = updatedAt, deletedAt = deletedAt, extractionStatus = status, purged = purged,
        syncState = syncState,
    ).also { db.receipts().upsert(it) }

    suspend fun dict(
        uuid: String, name: String = uuid, category: String? = "Food", subcategory: String? = "Dairy & Eggs", group: String? = "Milk",
        flagged: Boolean = false, suggestedCategory: String? = null, suggestedParent: String? = null, syncState: String = SyncState.SYNCED,
        updatedAt: String = "2026-03-01T10:00:00.000Z", aliases: List<String> = listOf(name), deletedAt: String? = null, display: String? = null,
    ): DictionaryEntity = DictionaryEntity(
        uuid = uuid, canonicalName = name, displayNameDe = display ?: name, translationEn = name, category = category, subcategory = subcategory,
        itemGroup = group, aliases = StringLists.encode(aliases), categoryFlagged = flagged, suggestedCategory = suggestedCategory,
        suggestedParent = suggestedParent, createdAt = updatedAt, lastSeenAt = updatedAt, updatedAt = updatedAt, deletedAt = deletedAt, syncState = syncState,
    ).also { db.dictionary().upsert(it) }

    suspend fun item(
        uuid: String, receiptId: String, dictId: String, price: Double = 1.0, position: Int = 0, deletedAt: String? = null,
        syncState: String = SyncState.SYNCED,
    ): LineItemEntity = LineItemEntity(
        uuid = uuid, receiptId = receiptId, itemDictionaryId = dictId, position = position, rawText = uuid, nameDe = uuid, quantity = 1.0,
        unitPrice = price, totalPrice = price, updatedAt = "2026-03-01T10:00:00.000Z", deletedAt = deletedAt, syncState = syncState,
    ).also { db.lineItems().upsert(it) }

    /** A flagged dictionary entry used by one item of a new receipt (the shape the server's categoriser leaves). */
    suspend fun flaggedItem(
        id: String, name: String, price: Double, suggestedCategory: String?, suggestedParent: String?, receiptId: String = "r-$id",
        createdAt: String = "2026-03-01T10:00:00.000Z", receiptDeleted: Boolean = false,
    ) {
        dict(id, name, "Other", "Miscellaneous", "General", flagged = true, suggestedCategory = suggestedCategory, suggestedParent = suggestedParent)
        receipt(receiptId, store = "Fressnapf", createdAt = createdAt, deletedAt = if (receiptDeleted) "2026-04-01T00:00:00.000Z" else null)
        item("li-$id", receiptId, id, price)
    }
}
