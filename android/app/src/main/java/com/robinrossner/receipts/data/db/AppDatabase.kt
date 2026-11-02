package com.robinrossner.receipts.data.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(
    entities = [ReceiptEntity::class, LineItemEntity::class, DictionaryEntity::class, MetaEntity::class, TaxonomyAdditionEntity::class],
    version = 2,
    exportSchema = true,
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun receipts(): ReceiptDao
    abstract fun lineItems(): LineItemDao
    abstract fun dictionary(): DictionaryDao
    abstract fun flagged(): FlaggedDao
    abstract fun taxonomy(): TaxonomyDao
    abstract fun sync(): SyncDao

    companion object {
        /** Never a destructive fallback: unsent edits and photos waiting for upload live only in this database. */
        fun open(context: Context, name: String = "receipts.db"): AppDatabase =
            Room.databaseBuilder(context.applicationContext, AppDatabase::class.java, name)
                .addMigrations(MIGRATION_1_2)
                .build()
    }
}

/**
 * v2: the "no good category" flag on dictionary entries and the append-only list of user-added categories. Every
 * existing row keeps every value (the flag starts at 0). The last statement forgets the pull cursors: the old build
 * ignored `category_flagged`, so flags it had already pulled would otherwise never show up; one full pull fixes that
 * (applying a record twice is harmless, unsent local edits are protected by the last-write-wins merge).
 */
val MIGRATION_1_2 = object : Migration(1, 2) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("ALTER TABLE `item_dictionary` ADD COLUMN `categoryFlagged` INTEGER NOT NULL DEFAULT 0")
        db.execSQL("ALTER TABLE `item_dictionary` ADD COLUMN `suggestedCategory` TEXT")
        db.execSQL("ALTER TABLE `item_dictionary` ADD COLUMN `suggestedParent` TEXT")
        db.execSQL("CREATE INDEX IF NOT EXISTS `index_item_dictionary_categoryFlagged` ON `item_dictionary` (`categoryFlagged`)")
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS `taxonomy_additions` (`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `category` TEXT NOT NULL, " +
                "`subcategory` TEXT NOT NULL, `itemGroup` TEXT NOT NULL, `createdAt` TEXT NOT NULL, `pathKey` TEXT NOT NULL, " +
                "`syncState` TEXT NOT NULL DEFAULT 'dirty', `syncError` TEXT)",
        )
        db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS `index_taxonomy_additions_pathKey` ON `taxonomy_additions` (`pathKey`)")
        db.execSQL("DELETE FROM `sync_meta` WHERE `key` LIKE 'cursor:%'")
    }
}
