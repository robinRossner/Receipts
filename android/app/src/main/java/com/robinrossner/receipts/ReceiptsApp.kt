package com.robinrossner.receipts

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.robinrossner.receipts.data.ReceiptImporter
import com.robinrossner.receipts.data.ReceiptRepository
import com.robinrossner.receipts.data.SyncSettings
import com.robinrossner.receipts.data.Taxonomy
import com.robinrossner.receipts.data.db.AppDatabase
import com.robinrossner.receipts.data.sync.AppPaths
import com.robinrossner.receipts.data.sync.SyncCoordinator
import com.robinrossner.receipts.data.sync.SyncStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Plain manual wiring: one of each, created at launch. */
class AppContainer(app: Application) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val settings = SyncSettings(app)
    val paths = AppPaths(app.filesDir)
    val db = AppDatabase.open(app)
    val taxonomy: Taxonomy = Taxonomy.parse(app.assets.open("category_taxonomy.json").bufferedReader().use { it.readText() })
    val syncStore = SyncStore(db, paths)
    val coordinator = SyncCoordinator(scope, syncStore, settings, debugBuild = BuildConfig.DEBUG)
    val repository = ReceiptRepository(db, paths, taxonomy, scope) { coordinator.noteLocalChange() }
    val importer = ReceiptImporter(app, scope, syncStore, db, paths) { coordinator.expectServerWork() }
}

class ReceiptsApp : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
        // Sync at launch (a no-op until the server is set up) and whenever the app comes back to the foreground.
        var first = true
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                container.scope.launch {
                    if (first) { first = false; container.coordinator.configure() } else container.coordinator.syncIfStale()
                }
            }
        })
    }
}
