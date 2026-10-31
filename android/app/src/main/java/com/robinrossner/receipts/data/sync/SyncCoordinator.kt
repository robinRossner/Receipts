package com.robinrossner.receipts.data.sync

import com.robinrossner.receipts.data.SyncSettings
import com.robinrossner.receipts.data.api.HttpReceiptsApi
import com.robinrossner.receipts.data.api.ReceiptsApi
import com.robinrossner.receipts.data.api.ReceiptsApiException
import com.robinrossner.receipts.data.api.ServerStatus
import com.robinrossner.receipts.data.api.ServerUrl
import com.robinrossner.receipts.data.api.SyncCapabilities
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import okhttp3.HttpUrl
import java.time.Instant
import kotlin.math.min
import kotlin.math.pow

enum class SyncPhase { OFF, IDLE, SYNCING }

/** What the UI shows about the sync. */
data class SyncUiState(
    val phase: SyncPhase = SyncPhase.OFF,
    val lastSyncAt: Instant? = null,
    val lastError: String? = null,
    val serverStatus: ServerStatus? = null,
    val unsentChanges: Int = 0,
    val rejectedRecords: Int = 0,
    val nextRetryAtMillis: Long? = null,
) {
    /** The server's archive/disk flags: this phone is not the archive, so the advice is to use the laptop. */
    val banners: List<String>
        get() = SyncBanners.of(serverStatus)
}

object SyncBanners {
    fun of(status: ServerStatus?): List<String> {
        if (status == null) return emptyList()
        val out = mutableListOf<String>()
        if (status.archiveOverdue) {
            val mb = maxOf(1, status.unarchivedBytes / 1_000_000)
            val days = status.archiveReminderDays ?: 30
            out += "${status.unarchivedCount} receipt photo(s) ($mb MB) wait on the server and have not been archived for over $days days. Open Receipts on your laptop to archive them."
        }
        if (status.diskWarning) {
            val free = status.diskFreeBytes?.let { String.format(java.util.Locale.US, "%.1f GB", it / 1e9) } ?: "little"
            out += "The server is low on disk space ($free free). Archive its photos on your laptop."
        }
        return out
    }
}

data class ConnectionTest(val ok: Boolean, val message: String)

/**
 * Runs the sync engine on a schedule and publishes what the UI shows: on launch, shortly after local edits (debounced),
 * every 15 minutes while the app lives, quickly while the server is still extracting something, when the app comes to
 * the foreground and on "Sync now". Failures are retried with a growing delay and shown as a small status, never as a
 * blocking alert. (Uploads additionally resume through WorkManager, see `SyncWorker`.)
 */
class SyncCoordinator(
    private val scope: CoroutineScope,
    private val store: SyncStore,
    private val settings: SyncSettings,
    private val debugBuild: Boolean,
    private val capabilities: SyncCapabilities = SyncCapabilities.MOBILE,
    private val makeApi: (HttpUrl, String) -> ReceiptsApi = { url, token -> HttpReceiptsApi(url, token) },
    /** Called after a run changed local data. */
    var onDataChanged: (suspend () -> Unit)? = null,
) {
    private val _state = MutableStateFlow(SyncUiState())
    val state: StateFlow<SyncUiState> = _state.asStateFlow()

    private var engine: SyncEngine? = null
    private var debounceJob: Job? = null
    private var timerJob: Job? = null
    private var failures = 0
    private var pollingUntilMillis: Long? = null
    private var lastReport: SyncReport? = null

    val isConfigured get() = settings.enabled && ServerUrl.apiBase(settings.serverUrl, debugBuild) != null && settings.vault.contains()

    /** Builds the engine from the settings if there is none yet (a background worker runs without the UI having started it). */
    fun ensureEngine(): Boolean {
        if (engine != null) return true
        if (!settings.enabled) return false
        val base = ServerUrl.apiBase(settings.serverUrl, debugBuild) ?: return false
        val token = settings.vault.read()?.takeIf { it.isNotEmpty() } ?: return false
        engine = SyncEngine(makeApi(base, token), store, SyncConfig(settings.deviceId, ServerUrl.cursorKey(base), capabilities))
        return true
    }

    /** Reads the settings and (re)starts or stops everything. Call at launch and after the settings changed. */
    fun configure() {
        if (!settings.enabled) { stop(); return }
        engine = null
        if (!ensureEngine()) {
            _state.update { it.copy(phase = SyncPhase.IDLE, lastError = "The server URL or token is missing (Settings).") }
            return
        }
        failures = 0
        _state.update { it.copy(phase = SyncPhase.IDLE, lastError = null) }
        scope.launch {
            loadLastSync()
            scheduleTimer(null)
            syncNow()
        }
    }

    fun stop() {
        debounceJob?.cancel(); timerJob?.cancel()
        engine = null
        _state.value = SyncUiState()
    }

    // ---- triggers ----

    /** A local edit happened: sync soon (several edits in a row become one sync). */
    fun noteLocalChange() {
        if (engine == null) return
        debounceJob?.cancel()
        debounceJob = scope.launch {
            delay(DEBOUNCE_MS)
            syncNow()
        }
        scope.launch { refreshCounters() }
    }

    /** The app came to the foreground: sync unless a successful run finished in the last [minIntervalMs]. */
    suspend fun syncIfStale(minIntervalMs: Long = 20_000) {
        val last = lastReport
        if (last != null && last.succeeded && System.currentTimeMillis() - last.finishedAtMillis < minIntervalMs) return
        syncNow()
    }

    /** One run; joins a run in progress. Returns null when sync is not set up. */
    suspend fun syncNow(): SyncReport? {
        val engine = engine ?: return null
        _state.update { it.copy(phase = SyncPhase.SYNCING) }
        val report = engine.syncNow()
        lastReport = report
        _state.update { it.copy(phase = SyncPhase.IDLE, serverStatus = report.status ?: it.serverStatus) }
        refreshCounters()
        if (report.succeeded || !report.connectionProblem) loadLastSync()
        if (report.succeeded) {
            failures = 0
            _state.update { it.copy(lastError = null, nextRetryAtMillis = null) }
        } else {
            failures++
            _state.update { it.copy(lastError = report.errors.firstOrNull()) }
        }
        if (report.changedLocalData) onDataChanged?.invoke()
        scheduleTimer(report)
        return report
    }

    /** Next automatic run: soon while the server still works on receipts, with backoff after a failure, else the interval. */
    private fun scheduleTimer(report: SyncReport?) {
        timerJob?.cancel()
        if (engine == null) return
        var delayMs = INTERVAL_MS
        _state.update { it.copy(nextRetryAtMillis = null) }
        val status = report?.status ?: _state.value.serverStatus
        if (report != null && !report.succeeded && (report.connectionProblem || report.errors.any { !it.startsWith("Push: ") })) {
            delayMs = min((30_000 * 2.0.pow(maxOf(failures - 1, 0))).toLong(), MAX_BACKOFF_MS)
            _state.update { it.copy(nextRetryAtMillis = System.currentTimeMillis() + delayMs) }
        } else if (status?.queue != null && status.queue.queued + status.queue.processing > 0) {
            if (pollingUntilMillis == null) pollingUntilMillis = System.currentTimeMillis() + POLL_WINDOW_MS
            if (System.currentTimeMillis() < pollingUntilMillis!!) delayMs = POLL_INTERVAL_MS
        } else {
            pollingUntilMillis = null
        }
        timerJob = scope.launch {
            delay(delayMs)
            syncNow()
        }
    }

    /** After starting an upload the server needs a few seconds: poll quickly for a while. */
    fun expectServerWork() {
        pollingUntilMillis = System.currentTimeMillis() + POLL_WINDOW_MS
        noteLocalChange()
    }

    private suspend fun refreshCounters() {
        val unsent = runCatching { store.unsentChangeCount() }.getOrDefault(0)
        val rejected = runCatching { store.rejectedCount() }.getOrDefault(0)
        _state.update { it.copy(unsentChanges = unsent, rejectedRecords = rejected) }
    }

    private suspend fun loadLastSync() {
        store.meta(SyncEngine.META_LAST_SYNC)?.let { text -> SyncDate.parse(text)?.let { d -> _state.update { it.copy(lastSyncAt = d) } } }
    }

    // ---- actions the UI offers ----

    suspend fun retryExtraction(uuid: String) {
        val engine = engine ?: throw ReceiptsApiException.NotConfigured("Sync is off.")
        engine.retryExtraction(uuid)
        expectServerWork()
    }

    /** Settings > "Test connection": `/health` (is it a server at all) then `/status` (does it accept the token). */
    suspend fun testConnection(serverUrl: String, token: String?): ConnectionTest {
        val base = ServerUrl.apiBase(serverUrl, debugBuild)
            ?: return ConnectionTest(false, "That is not a valid server URL. Use https://… (plain http only to the emulator host in debug builds).")
        if (token.isNullOrEmpty()) return ConnectionTest(false, "Enter the receipts token first.")
        val api = makeApi(base, token)
        return try {
            api.health()
            val status = api.status()
            ConnectionTest(true, "Connected. ${status.unarchivedCount} photo(s) on the server, extraction provider: ${status.llm?.provider ?: "none"}.")
        } catch (e: ReceiptsApiException) {
            ConnectionTest(false, e.message.orEmpty())
        }
    }

    suspend fun ensurePhoto(uuid: String): PhotoFetchResult =
        engine?.ensurePhoto(uuid) ?: PhotoFetchResult.Unavailable("Sync is not set up.")

    suspend fun clearPhotoCache() {
        val e = engine
        if (e != null) e.clearPhotoCache() else {
            PhotoCache(store.paths.photoCacheDir, 0).removeAll()
            store.db.receipts().forgetCachedPhotos()
        }
    }

    val photoCacheBytes: Long get() = PhotoCache(store.paths.photoCacheDir, capabilities.photoCacheBytes).totalBytes

    companion object {
        const val INTERVAL_MS = 15 * 60 * 1000L
        const val DEBOUNCE_MS = 4_000L
        const val POLL_INTERVAL_MS = 6_000L
        const val POLL_WINDOW_MS = 180_000L
        const val MAX_BACKOFF_MS = 15 * 60 * 1000L
    }
}
