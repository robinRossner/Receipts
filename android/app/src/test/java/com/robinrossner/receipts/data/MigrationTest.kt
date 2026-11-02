package com.robinrossner.receipts.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.robinrossner.receipts.data.db.AppDatabase
import com.robinrossner.receipts.data.db.MIGRATION_1_2
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * v1 -> v2 (flag columns, taxonomy_additions, cursor reset) on a database that holds real data.
 *
 * The v1 database is built from the committed `schemas/.../1.json` (what Room's MigrationTestHelper does; the helper
 * reads the schemas as assets, which unit tests cannot get), then opened through the real [AppDatabase] with
 * [MIGRATION_1_2]. Room validates the migrated structure (columns, types, NOT NULL, defaults, primary key, indices)
 * against the compiled schema when it opens, so a statement that differs from the generated `2.json` fails here.
 */
@RunWith(RobolectricTestRunner::class)
class MigrationTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val dbName = "migration-test.db"
    private val schemaDir = File("schemas/com.robinrossner.receipts.data.db.AppDatabase")
    private var room: AppDatabase? = null

    @After
    fun close() {
        room?.close()
        context.deleteDatabase(dbName)
    }

    private fun schema(version: Int) = Json.parseToJsonElement(File(schemaDir, "$version.json").readText()).jsonObject["database"]!!.jsonObject

    private fun createV1(populate: (SQLiteDatabase) -> Unit) {
        val v1 = schema(1)
        val file = context.getDatabasePath(dbName).also { it.parentFile?.mkdirs(); it.delete() }
        val db = SQLiteDatabase.openOrCreateDatabase(file, null)
        try {
            for (entity in v1["entities"]!!.jsonArray.map { it.jsonObject }) {
                val table = entity["tableName"]!!.jsonPrimitive.content
                db.execSQL(entity["createSql"]!!.jsonPrimitive.content.replace("\${TABLE_NAME}", table))
                for (index in entity["indices"]?.jsonArray.orEmpty().map { it.jsonObject }) {
                    db.execSQL(index["createSql"]!!.jsonPrimitive.content.replace("\${TABLE_NAME}", table))
                }
            }
            for (sql in v1["setupQueries"]!!.jsonArray.map { it.jsonPrimitive.content }) db.execSQL(sql.replace("\${TABLE_NAME}", "room_master_table"))
            db.version = 1
            populate(db)
        } finally {
            db.close()
        }
    }

    private fun openMigrated(): AppDatabase =
        Room.databaseBuilder(context, AppDatabase::class.java, dbName).addMigrations(MIGRATION_1_2).allowMainThreadQueries().build().also {
            room = it
            it.openHelper.writableDatabase   // runs the migration and Room's schema validation
        }

    private fun SQLiteDatabase.seed() {
        execSQL(
            "INSERT INTO receipts (uuid, store, date, time, total, computedSum, needsReview, reviewReasons, reviewedAt, createdAt, updatedAt, " +
                "photoLocation, photoSha256, extractionStatus, localPhoto, imageHash, purged, syncState, syncError) VALUES " +
                "('r1', 'Edeka', '2026-03-01', '10:15', 7.5, 7.5, 1, '[\"Check it\"]', NULL, '2026-03-01T10:00:00.000Z', '2026-03-01T11:00:00.000Z', " +
                "'server', 'abc', 'done', 'photo_cache/r1.jpg', 'hash1', 0, 'dirty', NULL)",
        )
        execSQL(
            "INSERT INTO line_items (uuid, receiptId, itemDictionaryId, position, rawText, nameDe, quantity, unitPrice, totalPrice, priceNormalized, " +
                "updatedAt, syncState) VALUES ('l1', 'r1', 'd1', 3, 'Milch', 'Milch', 2.0, 1.25, 2.5, 1, '2026-03-01T11:00:00.000Z', 'dirty')",
        )
        execSQL(
            "INSERT INTO item_dictionary (uuid, canonicalName, displayNameDe, translationEn, category, subcategory, itemGroup, aliases, isManualOverride, " +
                "needsReview, timesSeen, createdAt, lastSeenAt, updatedAt, syncState) VALUES " +
                "('d1', 'milch', 'Milch', 'milk', 'Food', 'Dairy & Eggs', 'Milk', '[\"milch\"]', 1, 0, 4, '2026-01-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z', " +
                "'2026-03-01T11:00:00.000Z', 'dirty')",
        )
        execSQL(
            "INSERT INTO item_dictionary (uuid, canonicalName, aliases, isManualOverride, needsReview, timesSeen, updatedAt, syncState) VALUES " +
                "('d2', 'pfand', '[]', 0, 1, 1, '2026-02-01T00:00:00.000Z', 'synced')",
        )
        execSQL("INSERT INTO sync_meta (`key`, value) VALUES ('cursor:https://example.com/api/v1/receipts', 'c-123')")
        execSQL("INSERT INTO sync_meta (`key`, value) VALUES ('cursor:http://localhost:8000/api/v1/receipts', 'c-9')")
        execSQL("INSERT INTO sync_meta (`key`, value) VALUES ('last_sync_at', '2026-03-01T12:00:00.000Z')")
    }

    private fun AppDatabase.rows(sql: String): List<List<String?>> = openHelper.readableDatabase.query(sql).use { c ->
        generateSequence { if (c.moveToNext()) (0 until c.columnCount).map { c.getString(it) } else null }.toList()
    }

    @Test
    fun migrationKeepsEveryRowAndAddsTheFlagColumnsAndTheTaxonomyTable() {
        createV1 { it.seed() }
        val db = openMigrated()

        assertEquals(
            listOf(listOf("Edeka", "2026-03-01", "10:15", "7.5", "7.5", "1", "[\"Check it\"]", null, "2026-03-01T10:00:00.000Z", "2026-03-01T11:00:00.000Z", "server", "abc",
                "done", "photo_cache/r1.jpg", "hash1", "0", "dirty")),
            db.rows("SELECT store, date, time, total, computedSum, needsReview, reviewReasons, reviewedAt, createdAt, updatedAt, photoLocation, photoSha256, " +
                "extractionStatus, localPhoto, imageHash, purged, syncState FROM receipts WHERE uuid = 'r1'"),
        )
        assertEquals(
            listOf(listOf("r1", "d1", "3", "Milch", "2.0", "1.25", "2.5", "1", "dirty")),
            db.rows("SELECT receiptId, itemDictionaryId, position, rawText, CAST(quantity AS TEXT), unitPrice, totalPrice, priceNormalized, syncState FROM line_items WHERE uuid = 'l1'"),
        )
        assertEquals(
            listOf(listOf("milch", "Milch", "milk", "Food", "Dairy & Eggs", "Milk", "[\"milch\"]", "1", "0", "4", "2026-01-01T00:00:00.000Z", "2026-03-01T00:00:00.000Z",
                "2026-03-01T11:00:00.000Z", "dirty", "0", null, null)),
            db.rows("SELECT canonicalName, displayNameDe, translationEn, category, subcategory, itemGroup, aliases, isManualOverride, needsReview, timesSeen, " +
                "createdAt, lastSeenAt, updatedAt, syncState, categoryFlagged, suggestedCategory, suggestedParent FROM item_dictionary WHERE uuid = 'd1'"),
        )
        assertEquals(
            listOf(listOf("0", null, null, "synced")),
            db.rows("SELECT categoryFlagged, suggestedCategory, suggestedParent, syncState FROM item_dictionary WHERE uuid = 'd2'"),
        )
        assertEquals(listOf(listOf("0")), db.rows("SELECT COUNT(*) FROM taxonomy_additions"))
        assertEquals(listOf(listOf("1")), db.rows("SELECT COUNT(*) FROM receipts"))
        assertEquals(listOf(listOf("2")), db.rows("SELECT COUNT(*) FROM item_dictionary"))
        // nothing is re-pushed because of the migration: the dirty rows are the only ones that were dirty
        assertEquals(listOf(listOf("d1")), db.rows("SELECT uuid FROM item_dictionary WHERE syncState = 'dirty'"))
    }

    @Test
    fun migrationForgetsThePullCursorsOnlySoOneFullPullFollows() {
        createV1 { it.seed() }
        val db = openMigrated()
        assertEquals(listOf(listOf("last_sync_at", "2026-03-01T12:00:00.000Z")), db.rows("SELECT `key`, value FROM sync_meta ORDER BY `key`"))
    }

    @Test
    fun theMigratedDatabaseHasTheSchemaOfTheCommittedV2Export() {
        createV1 { it.seed() }
        val db = openMigrated()
        val v2 = schema(2)
        assertEquals(2, v2["version"]!!.jsonPrimitive.content.toInt())
        assertEquals(listOf(listOf(v2["identityHash"]!!.jsonPrimitive.content)), db.rows("SELECT identity_hash FROM room_master_table"))
        // every index of the exported schema exists on the migrated database
        for (entity in v2["entities"]!!.jsonArray.map { it.jsonObject }) {
            val table = entity["tableName"]!!.jsonPrimitive.content
            val wanted = entity["indices"]?.jsonArray.orEmpty().map { it.jsonObject["name"]!!.jsonPrimitive.content }.toSet()
            val have = db.rows("PRAGMA index_list(`$table`)").map { it[1] }.filter { it?.startsWith("index_") == true }.toSet()
            assertEquals("indices of $table", wanted, have)
        }
    }

    @Test
    fun theMigratedDatabaseWorksThroughTheDaos() = runBlocking {
        createV1 { it.seed() }
        val db = openMigrated()
        val d1 = db.dictionary().get("d1")
        assertEquals("milch", d1?.canonicalName)
        assertEquals(false, d1?.categoryFlagged)
        assertNull(d1?.suggestedCategory)
        assertEquals("dirty", d1?.syncState)
        db.dictionary().upsert(d1!!.copy(categoryFlagged = true, suggestedCategory = "Pet Food", suggestedParent = "Household"))
        assertEquals("Pet Food", db.dictionary().get("d1")?.suggestedCategory)
        assertTrue(db.taxonomy().all().isEmpty())
        assertEquals("1 receipt + 1 item + 1 entry", 3, db.receipts().unsentChangeCount())
        Unit
    }
}
