package com.robinrossner.receipts.data.api

/**
 * What a device may do besides the sync every client does (upload, push, pull, status, photo download).
 *
 * The laptop is the permanent photo archive: it is the only device that may tell the server to delete its copy of a
 * photo (`archive-confirm`, with `accept_failed` when the user gave up on a receipt) and that reports archive runs
 * (`archive/sync`). The phone is NOT the archive: if it ever confirmed a photo it had only cached, the server would
 * delete the only permanent copy. So this is not a matter of leaving out a call: the sync engine talks to the server
 * only through [CapabilityGuardedApi], which refuses those calls for a device without [archivesPhotos].
 * Tests pin it (CapabilityTest).
 */
data class SyncCapabilities(
    /** May call `archive/pending`, `archive-confirm` (incl. `accept_failed`) and `archive/sync`. */
    val archivesPhotos: Boolean,
    /** Keeps photos in a bounded local cache and downloads server photos on demand. */
    val cachesPhotos: Boolean,
    val photoCacheBytes: Long,
) {
    companion object {
        val ARCHIVE_DEVICE = SyncCapabilities(archivesPhotos = true, cachesPhotos = false, photoCacheBytes = 0)

        /** The phone: never archives, keeps at most 300 MB of photos. */
        val MOBILE = SyncCapabilities(archivesPhotos = false, cachesPhotos = true, photoCacheBytes = 300L * 1_000_000)
    }
}

/**
 * Forwards every call to [base], except the archive calls, which throw [ReceiptsApiException.NotPermitted] unless the
 * device has the `archivesPhotos` capability. [com.robinrossner.receipts.data.sync.SyncEngine] always uses this wrapper.
 */
class CapabilityGuardedApi(private val base: ReceiptsApi, val capabilities: SyncCapabilities) : ReceiptsApi {
    private fun requireArchive(what: String) {
        if (!capabilities.archivesPhotos) {
            throw ReceiptsApiException.NotPermitted("This device is not the photo archive and must not call $what.")
        }
    }

    override suspend fun health() = base.health()
    override suspend fun status() = base.status()
    override suspend fun uploadPhoto(id: String, data: ByteArray, mediaType: String, createdAtMillis: Long?) =
        base.uploadPhoto(id, data, mediaType, createdAtMillis)
    override suspend fun retryExtraction(id: String) = base.retryExtraction(id)
    override suspend fun push(request: PushRequest) = base.push(request)
    override suspend fun pull(since: String?, limit: Int) = base.pull(since, limit)
    override suspend fun downloadPhoto(path: String) = base.downloadPhoto(path)

    override suspend fun archivePending(): List<ArchivePendingPhoto> {
        requireArchive("archive/pending")
        return base.archivePending()
    }

    override suspend fun archiveConfirm(id: String, sha256: String, deviceId: String, acceptFailed: Boolean): ArchiveConfirmResponse {
        requireArchive("archive-confirm")
        return base.archiveConfirm(id, sha256, deviceId, acceptFailed)
    }

    override suspend fun archiveSync(deviceId: String) {
        requireArchive("archive/sync")
        base.archiveSync(deviceId)
    }
}
