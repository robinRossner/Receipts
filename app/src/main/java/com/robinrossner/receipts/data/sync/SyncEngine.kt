package com.robinrossner.receipts.data.sync

import com.robinrossner.receipts.data.api.CapabilityGuardedApi
import com.robinrossner.receipts.data.api.PushEntity
import com.robinrossner.receipts.data.api.PushRequest
import com.robinrossner.receipts.data.api.ReceiptsApi
import com.robinrossner.receipts.data.api.ReceiptsApiException
import com.robinrossner.receipts.data.api.ServerStatus
import com.robinrossner.receipts.data.api.ServerUrl
import com.robinrossner.receipts.data.api.SyncCapabilities
import com.robinrossner.receipts.data.db.ReceiptEntity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

data class SyncConfig(
    /** What this device calls itself in push (`device_id`). */
    val deviceId: String,
    /** Cursor key, one per server (cursors are global to the server's database). */
    val cursorKey: String,
    val capabilities: SyncCapabilities = SyncCapabilities.MOBILE,
    val pageLimit: Int = 2000,
    val pushChunk: Int = 400,
) {
    companion object {
        const val MAX_PAGES = 500
    }
}

data class SyncReport(
    var uploaded: Int = 0,
    /** local uuid -> uuid of the receipt the server already has for the same photo (local copy dropped). */
    val duplicates: MutableMap<String, String> = mutableMapOf(),
    val push: PushSummary = PushSummary(),
    var pulled: ApplySummary = ApplySummary(),
    var status: ServerStatus? = null,
    val errors: MutableList<String> = mutableListOf(),
    /** The run stopped early because the server is unreachable / refuses us (retry with backoff). */
    var connectionProblem: Boolean = false,
    var finishedAtMillis: Long = System.currentTimeMillis(),
) {
    val succeeded get() = errors.isEmpty()

    /** Something changed locally that views should reload. */
    val changedLocalData get() = uploaded > 0 || duplicates.isNotEmpty() || pulled.total > 0
}

sealed interface PhotoFetchResult {
    /** The photo is in the local cache (stored path, relative to the files dir). */
    data class Cached(val storedPath: String) : PhotoFetchResult

    /** The server released its copy to the laptop and there is no copy here. */
    data object OnLaptop : PhotoFetchResult
    data class Unavailable(val message: String) : PhotoFetchResult
}

/**
 * Offline-first sync with the receipts backend (docs/api/receipts.md): upload queued photos, push local edits, then
 * pull the server's changes with the stored cursor.
 *
 * Last write wins per record by `updated_at` ([SyncMerge]), deletes are tombstones, and the cursor is persisted only
 * after a pulled page was applied. Every phase may fail on its own (the failure is reported, the rest still runs
 * unless the server itself is unreachable); nothing is lost, the next run repeats what failed.
 *
 * This is NOT the archive device: the engine never runs the archive protocol and talks to the server only through
 * [CapabilityGuardedApi].
 */
class SyncEngine(
    api: ReceiptsApi,
    val store: SyncStore,
    val config: SyncConfig,
) {
    /** Always the capability-guarded wrapper: a device that is not the archive cannot reach the archive endpoints. */
    val api: ReceiptsApi = CapabilityGuardedApi(api, config.capabilities)
    val photoCache = PhotoCache(store.paths.photoCacheDir, config.capabilities.photoCacheBytes)

    private val runMutex = Mutex()
    private var inFlight: CompletableDeferred<SyncReport>? = null

    /** A push answered `stale` for a record we thought was ahead: the next pull starts from scratch (applying a record twice is harmless). */
    private var needsFullPull = false

    /** One full run. Calls made while a run is in progress join it. */
    suspend fun syncNow(): SyncReport {
        val running = runMutex.withLock {
            inFlight?.let { return@withLock it to false }
            CompletableDeferred<SyncReport>().also { inFlight = it } to true
        }
        if (!running.second) return running.first.await()
        val report = runOnce()
        runMutex.withLock { inFlight = null }
        running.first.complete(report)
        return report
    }

    private suspend fun runOnce(): SyncReport {
        val report = SyncReport()
        fun fail(phase: String, error: Throwable): Boolean {
            report.errors += "$phase: ${error.message}"
            if ((error as? ReceiptsApiException)?.isConnectionLevel == true) report.connectionProblem = true
            return report.connectionProblem
        }

        try { uploadPending(report) } catch (e: ReceiptsApiException) { if (fail("Upload", e)) return finish(report) }
        var pushedOk = false
        var pulledOk = false
        try { pushAll(report); pushedOk = true } catch (e: ReceiptsApiException) { if (fail("Push", e)) return finish(report) }
        try { pullAll(report); pulledOk = true } catch (e: ReceiptsApiException) { if (fail("Pull", e)) return finish(report) }
        // "Synced" = what we had was sent and what the server had was received (a record the server rejected or a
        // photo problem does not change that).
        if (pushedOk && pulledOk) store.setMeta(META_LAST_SYNC, SyncDate.now())
        try { report.status = api.status() } catch (e: ReceiptsApiException) { fail("Status", e) }
        return finish(report)
    }

    private fun finish(report: SyncReport): SyncReport = report.also { it.finishedAtMillis = System.currentTimeMillis() }

    // ---- upload queue ----

    private suspend fun uploadPending(report: SyncReport) {
        for (pending in store.pendingUploads()) upload(pending, report)
    }

    private suspend fun upload(pending: ReceiptEntity, report: SyncReport) {
        val file = store.paths.resolve(pending.localPhoto)
        val data = file?.takeIf { it.isFile }?.let { withContext(Dispatchers.IO) { it.readBytes() } }
        if (data == null) {
            store.markUploadFailed(pending.uuid, "The prepared photo file is missing; add the photo again.", permanent = true)
            return
        }
        try {
            val mediaType = mediaTypeOf(data)
            val response = api.uploadPhoto(pending.uuid, data, mediaType, SyncDate.parse(pending.createdAt)?.toEpochMilli())
            store.markUploaded(pending.uuid, response.receipt)
            keepCachedCopy(pending, file, mediaType)
            report.uploaded++
        } catch (e: ReceiptsApiException) {
            val duplicateOf = e.takeIf { it is ReceiptsApiException.Http && it.code == "duplicate_image" } as? ReceiptsApiException.Http
            if (duplicateOf != null && duplicateOf.extra["duplicate_of"] != null) {
                // "drop your local receipt and use the existing one" (it arrives through pull)
                store.discardLocalReceipt(pending.uuid)?.let { store.paths.resolve(it)?.delete() }
                report.duplicates[pending.uuid] = duplicateOf.extra.getValue("duplicate_of").lowercase()
            } else if (e.isConnectionLevel || e.isRetryable) {
                store.markUploadFailed(pending.uuid, e.message.orEmpty(), permanent = false)
                throw e
            } else {
                store.markUploadFailed(pending.uuid, e.message.orEmpty(), permanent = true)
            }
        }
    }

    /** A phone keeps the photo it just uploaded as its (bounded) cached copy instead of deleting it. Best effort. */
    private suspend fun keepCachedCopy(pending: ReceiptEntity, source: File, mediaType: String) {
        if (!config.capabilities.cachesPhotos) return
        runCatching {
            val cached = withContext(Dispatchers.IO) { photoCache.adopt(source, pending.uuid, mediaType) }
            store.setLocalPhoto(pending.uuid, store.paths.stored(cached))
        }
    }

    // ---- push ----

    private suspend fun pushAll(report: SyncReport) {
        // dictionary, then receipts, then line items: a record may only reference what the server already has
        for (entity in listOf(PushEntity.DICTIONARY, PushEntity.RECEIPT, PushEntity.LINE_ITEM)) {
            var rounds = 0
            while (rounds < 100) {
                rounds++
                val batch = store.collectPush(entity, config.pushChunk)
                if (batch.isEmpty) break
                val request = PushRequest(config.deviceId, batch.dictionary, batch.receipts, batch.lineItems)
                val response = api.push(request)
                val summary = store.applyPushResults(batch, response)
                report.push.applied += summary.applied
                report.push.stale += summary.stale
                report.push.rejected += summary.rejected
                if (summary.stale > 0) needsFullPull = true
                // Nothing acknowledged and nothing rejected means the same chunk would come back: stop.
                if (summary.applied + summary.stale + summary.rejected.size == 0) break
            }
        }
        if (report.push.rejected.isNotEmpty()) {
            report.errors += "Push: ${report.push.rejected.size} record(s) rejected by the server, first: ${report.push.rejected[0]}"
        }
    }

    // ---- pull ----

    private suspend fun pullAll(report: SyncReport) {
        var cursor: String? = if (needsFullPull) null else store.meta(config.cursorKey)
        var restarted = false
        val dictionary = LinkedHashMap<String, com.robinrossner.receipts.data.api.WireDictionaryEntry>()
        val receipts = LinkedHashMap<String, com.robinrossner.receipts.data.api.WireReceipt>()
        val items = LinkedHashMap<String, com.robinrossner.receipts.data.api.WireLineItem>()
        var pages = 0
        while (true) {
            pages++
            val page = try {
                api.pull(cursor, config.pageLimit)
            } catch (e: ReceiptsApiException.Http) {
                if (e.code == "bad_cursor" && !restarted) {
                    restarted = true; cursor = null
                    dictionary.clear(); receipts.clear(); items.clear()
                    continue
                }
                throw e
            }
            // Later versions of a record supersede earlier ones; everything is applied together below.
            page.dictionary.forEach { dictionary[it.id.lowercase()] = it }
            page.receipts.forEach { receipts[it.id.lowercase()] = it }
            page.lineItems.forEach { items[it.id.lowercase()] = it }
            cursor = page.cursor
            if (!page.hasMore || pages >= SyncConfig.MAX_PAGES) break
        }
        // Applied first, cursor persisted second: a crash in between just repeats the pull.
        report.pulled = store.applyPull(dictionary.values.toList(), receipts.values.toList(), items.values.toList())
        if (cursor != null) store.setMeta(config.cursorKey, cursor)
        needsFullPull = false
    }

    // ---- user actions ----

    /** "Retry" on a failed receipt: the server queues the extraction again with a fresh attempt budget. */
    suspend fun retryExtraction(uuid: String) {
        try {
            api.retryExtraction(uuid)
        } catch (e: ReceiptsApiException.Http) {
            if (e.code != "already_queued") throw e   // already queued or running: fine
        }
        store.db.receipts().get(uuid)?.let { store.db.receipts().upsert(it.copy(extractionStatus = "queued", extractionError = null)) }
    }

    // ---- photos on the phone ----

    /**
     * Makes sure a cached copy of a receipt's photo exists: downloads it from the server when the server still holds
     * it. A photo that was archived (410) and is not here is "on your laptop". The checksum must equal the server's
     * `photo_sha256`, else nothing is kept.
     */
    suspend fun ensurePhoto(uuid: String): PhotoFetchResult {
        if (!config.capabilities.cachesPhotos) return PhotoFetchResult.Unavailable("This device does not keep photo copies.")
        return try {
            val receipt = store.receipt(uuid) ?: return PhotoFetchResult.Unavailable("Unknown receipt.")
            val existing = store.paths.resolve(receipt.localPhoto)
            if (existing != null && existing.isFile) return PhotoFetchResult.Cached(receipt.localPhoto.orEmpty())
            if (receipt.photoLocation == "archived") return PhotoFetchResult.OnLaptop
            if (receipt.photoLocation != "server") return PhotoFetchResult.Unavailable("This receipt has no photo.")
            val download = try {
                api.downloadPhoto("${ServerUrl.API_PATH}/$uuid/photo")
            } catch (e: ReceiptsApiException.Http) {
                if (e.code == "photo_archived") return PhotoFetchResult.OnLaptop
                throw e
            }
            val expected = receipt.photoSha256
            if (expected != null && Sha256.hex(download.data) != expected.lowercase()) {
                return PhotoFetchResult.Unavailable("The downloaded photo did not match the server's checksum.")
            }
            val file = withContext(Dispatchers.IO) { photoCache.write(download.data, uuid, download.mediaType) }
            store.setLocalPhoto(uuid, store.paths.stored(file))
            PhotoFetchResult.Cached(store.paths.stored(file))
        } catch (e: ReceiptsApiException) {
            PhotoFetchResult.Unavailable(e.message.orEmpty())
        } catch (e: java.io.IOException) {
            PhotoFetchResult.Unavailable(e.message.orEmpty())
        }
    }

    /** "Clear cached photos": removes the local copies (receipts keep their data). */
    suspend fun clearPhotoCache() {
        withContext(Dispatchers.IO) { PhotoCache(store.paths.photoCacheDir, 0).removeAll() }
        store.db.receipts().forgetCachedPhotos()
    }

    companion object {
        const val META_LAST_SYNC = "last_sync_at"
    }
}
