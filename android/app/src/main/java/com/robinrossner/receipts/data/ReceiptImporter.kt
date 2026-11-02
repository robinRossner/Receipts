package com.robinrossner.receipts.data

import android.content.Context
import android.net.Uri
import com.robinrossner.receipts.data.db.AppDatabase
import com.robinrossner.receipts.data.sync.AppPaths
import com.robinrossner.receipts.data.sync.AtomicFile
import com.robinrossner.receipts.data.sync.PhotoPreparer
import com.robinrossner.receipts.data.sync.Sha256
import com.robinrossner.receipts.data.sync.SyncDate
import com.robinrossner.receipts.data.sync.SyncStore
import com.robinrossner.receipts.work.SyncWorker
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** One captured or picked photo on its way from the phone's storage to a receipt waiting for its upload. */
data class ImportJob(val id: String, val name: String, val state: State, val thumbnail: File? = null) {
    sealed interface State {
        data object Queued : State
        data object Preparing : State

        /** Prepared and stored in the outbox; the upload (WorkManager) takes it from there. */
        data class Saved(val receiptUuid: String) : State
        data class Duplicate(val receiptUuid: String) : State
        data class Failed(val message: String) : State
        data object Cancelled : State
    }

    val finished get() = state is State.Saved || state is State.Duplicate || state is State.Failed || state is State.Cancelled
}

/**
 * Turns what the user picked or scanned into a receipt in the outbox: copy to private storage, duplicate check,
 * JPEG of at most 2500 px under 4.5 MB, a receipt row waiting for its upload, and a WorkManager job that uploads it
 * (so nothing is lost offline and uploads resume after a relaunch).
 *
 * A job can be cancelled while it is queued or preparing; the final step (store the file, add the receipt row, schedule
 * the upload) is never interrupted, so a cancel that arrives too late simply leaves a saved receipt.
 */
class ReceiptImporter(
    private val context: Context,
    private val scope: CoroutineScope,
    private val store: SyncStore,
    private val db: AppDatabase,
    private val paths: AppPaths,
    private val onSaved: () -> Unit,
) {
    private val _jobs = MutableStateFlow<List<ImportJob>>(emptyList())
    val jobs: StateFlow<List<ImportJob>> = _jobs.asStateFlow()
    private val gate = Semaphore(2)

    private val sources = ConcurrentHashMap<String, Uri>()
    private val running = ConcurrentHashMap<String, Job>()
    private val unreadable = ConcurrentHashMap.newKeySet<String>()

    private val stagingDir get() = File(context.cacheDir, "receipt-imports").apply { mkdirs() }

    /**
     * Starts one job per picture. [onBatchDone] is called on the main thread once every job of this call has ended,
     * with the number of pictures that could not be read at all (the iPhone's "photo(s) could not be loaded").
     */
    fun import(pictures: List<Uri>, onBatchDone: ((unreadable: Int) -> Unit)? = null) {
        val added = pictures.map { ImportJob(UUID.randomUUID().toString(), it.lastPathSegment?.substringAfterLast('/') ?: "photo", ImportJob.State.Queued) }
        _jobs.update { it + added }
        val started = pictures.zip(added).map { (uri, job) -> sources[job.id] = uri; start(job.id) }
        if (onBatchDone != null) scope.launch {
            started.joinAll()
            val failed = added.count { unreadable.remove(it.id) }
            withContext(Dispatchers.Main) { onBatchDone(failed) }
        }
    }

    private fun start(id: String): Job {
        val uri = sources.getValue(id)
        val job = scope.launch(Dispatchers.IO) {
            try {
                gate.withPermit { run(uri, id) }
            } catch (e: CancellationException) {
                setUnlessFinished(id, ImportJob.State.Cancelled)
                throw e
            } finally {
                running.remove(id)
            }
        }
        running[id] = job
        return job
    }

    fun clearFinished() = _jobs.update { list -> list.filterNot { it.finished } }

    /** Stops a queued or preparing job; one that already reached the final step keeps its saved receipt. */
    fun cancel(id: String) {
        running[id]?.cancel()
        setUnlessFinished(id, ImportJob.State.Cancelled)
    }

    fun cancelAll() = _jobs.value.filterNot { it.finished }.forEach { cancel(it.id) }

    /** Starts every failed job over from its original picture. */
    fun retryFailed() {
        _jobs.value.filter { it.state is ImportJob.State.Failed && sources.containsKey(it.id) }.forEach {
            set(it.id, ImportJob.State.Queued)
            start(it.id)
        }
    }

    private fun set(id: String, state: ImportJob.State, thumbnail: File? = null) =
        _jobs.update { list -> list.map { if (it.id == id) it.copy(state = state, thumbnail = thumbnail ?: it.thumbnail) else it } }

    private fun setUnlessFinished(id: String, state: ImportJob.State) =
        _jobs.update { list -> list.map { if (it.id == id && !it.finished) it.copy(state = state) else it } }

    private suspend fun run(uri: Uri, id: String) {
        set(id, ImportJob.State.Preparing)
        val staged = File(stagingDir, "${UUID.randomUUID()}.img")
        try {
            val copied = runCatching {
                context.contentResolver.openInputStream(uri)?.use { input -> staged.outputStream().use { input.copyTo(it) } } != null
            }.getOrDefault(false)
            if (!copied) { unreadable.add(id); set(id, ImportJob.State.Failed("Couldn't read the file.")); return }
            currentCoroutineContext().ensureActive()

            val hash = Sha256.hex(staged)
            db.receipts().findByImageHash(hash)?.let { set(id, ImportJob.State.Duplicate(it)); return }
            currentCoroutineContext().ensureActive()

            val data = try {
                PhotoPreparer.prepare(staged)
            } catch (e: PhotoPreparer.PrepareException) {
                set(id, ImportJob.State.Failed(e.message.orEmpty() + " Try a clearer, flatter photo.")); return
            } catch (e: OutOfMemoryError) {
                set(id, ImportJob.State.Failed("The photo is too large for this phone to prepare.")); return
            }
            currentCoroutineContext().ensureActive()

            withContext(NonCancellable) {
                val uuid = UUID.randomUUID().toString()
                val file = File(paths.outboxDir, "$uuid.jpg")
                try {
                    AtomicFile.write(file, data)
                    store.insertPendingUpload(uuid, SyncDate.now(), paths.stored(file), hash)
                } catch (e: Exception) {
                    file.delete()
                    set(id, ImportJob.State.Failed("Couldn't store the prepared photo: ${e.message}"))
                    return@withContext
                }
                set(id, ImportJob.State.Saved(uuid), file)
                withContext(Dispatchers.Main) { onSaved() }
                SyncWorker.enqueue(context)
            }
        } finally {
            staged.delete()
        }
    }
}
