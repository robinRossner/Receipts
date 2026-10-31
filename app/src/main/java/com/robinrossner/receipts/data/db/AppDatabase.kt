package com.robinrossner.receipts.data.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

@Database(
    entities = [ReceiptEntity::class, LineItemEntity::class, DictionaryEntity::class, MetaEntity::class],
    version = 1,
    exportSchema = true,
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun receipts(): ReceiptDao
    abstract fun lineItems(): LineItemDao
    abstract fun dictionary(): DictionaryDao
    abstract fun sync(): SyncDao

    companion object {
        fun open(context: Context, name: String = "receipts.db"): AppDatabase =
            Room.databaseBuilder(context.applicationContext, AppDatabase::class.java, name).build()
    }
}
