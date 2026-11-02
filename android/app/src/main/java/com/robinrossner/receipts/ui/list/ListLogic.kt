package com.robinrossner.receipts.ui.list

import com.robinrossner.receipts.data.ImportJob
import com.robinrossner.receipts.data.db.ReceiptSummary
import com.robinrossner.receipts.data.sync.SyncPhase
import com.robinrossner.receipts.data.sync.SyncUiState
import com.robinrossner.receipts.ui.DateRange
import com.robinrossner.receipts.ui.processing
import java.time.Instant

/** Pure rules of the Receipts list screen (texts, ordering, what shows when), kept apart from Compose so they are unit-tested. */

/** How the dot in the sync row is coloured. */
enum class SyncDot { SPINNER, RED, AMBER, NEVER, GREEN }

data class SyncRowModel(val text: String, val dot: SyncDot, val hardFailure: Boolean)

object SyncRow {
    /** `relative` renders a past instant ("5 minutes ago"); the screen passes `DateUtils.getRelativeTimeSpanString`. Null for phase OFF (row hidden). */
    fun make(state: SyncUiState, nowMillis: Long, relative: (thenMillis: Long, nowMillis: Long) -> String): SyncRowModel? {
        if (state.phase == SyncPhase.OFF) return null
        if (state.phase == SyncPhase.SYNCING) return SyncRowModel("Syncing…", SyncDot.SPINNER, false)
        val error = state.lastError
        if (error != null) {
            val retrying = state.nextRetryAtMillis != null
            return SyncRowModel(if (retrying) "Sync failed, retrying" else "Sync failed", if (retrying) SyncDot.AMBER else SyncDot.RED, !retrying)
        }
        val last = state.lastSyncAt ?: return SyncRowModel("Not synced yet", SyncDot.NEVER, false)
        return SyncRowModel("Synced " + relativeText(last, nowMillis, relative), SyncDot.GREEN, false)
    }

    /** `now` under a minute, else the system's relative span lowercased (`5 minutes ago`, `yesterday`). */
    fun relativeText(then: Instant, nowMillis: Long, relative: (Long, Long) -> String): String {
        val thenMillis = then.toEpochMilli()
        return if (nowMillis - thenMillis < 60_000) "now" else relative(thenMillis, nowMillis).lowercase()
    }
}

/** One removable chip under the sync row. */
data class ActiveFilter(val kind: Kind, val text: String) {
    enum class Kind { SEARCH, DATE, STORE }
}

object ListLogic {
    /** Search text, date range, store: in this order, each only when set. */
    fun activeFilters(search: String, range: DateRange, store: String?): List<ActiveFilter> = buildList {
        if (search.isNotBlank()) add(ActiveFilter(ActiveFilter.Kind.SEARCH, "“$search”"))
        if (range != DateRange.ALL) add(ActiveFilter(ActiveFilter.Kind.DATE, range.label))
        if (store != null) add(ActiveFilter(ActiveFilter.Kind.STORE, store))
    }

    fun resultCount(n: Int): String = if (n == 1) "1 receipt" else "$n receipts"

    fun confirmAllTitle(n: Int): String = "Confirm $n receipts without flags?"

    fun confirmAllButton(n: Int): String = "Confirm all without flags ($n)"

    fun toReviewBadge(n: Int): String = "$n to review"

    /** The name line of a row: the store, else `Unknown`, but `New receipt` while the server still reads a receipt that has no store yet. */
    fun rowName(r: ReceiptSummary): String = r.store ?: if (r.processing != null) "New receipt" else "Unknown"

    /** The red line under the date of an unreviewed, flagged receipt: its first review reason, else `Needs review`. */
    fun inlineWarning(r: ReceiptSummary, reasons: Map<String, List<String>>): String? =
        if (r.reviewedAt == null && r.needsReview) reasons[r.uuid]?.firstOrNull() ?: "Needs review" else null

    /** A reviewed receipt that still carries warnings gets a small icon beside its date. */
    fun showsWarningIcon(r: ReceiptSummary): Boolean = r.reviewedAt != null && r.needsReview

    fun showsTotal(r: ReceiptSummary): Boolean = r.processing == null || r.total != null

    /** Swipe right ("Looks good") is only offered on an unreviewed receipt the server is not still reading. */
    fun canConfirmBySwipe(r: ReceiptSummary): Boolean = r.reviewedAt == null && r.processing == null

    fun reviewedSnack(r: ReceiptSummary): String = "${r.store ?: "Receipt"} reviewed"

    const val DELETED_SNACK = "Moved to Recently deleted"

    fun deletedLine(r: ReceiptSummary, money: String): String = "${r.date ?: ""} · $money"

    fun photosNotLoaded(failed: Int): String = "$failed photo(s) could not be loaded."

    fun onlyFirstPage(pages: Int): String =
        "Only the first of $pages pages was added. A receipt is one photo; scan the other pages as separate receipts."

    const val SCANNER_UNAVAILABLE = "This device cannot scan documents. Use “Choose photos” instead."
}

/** The upload panel's texts and which action buttons it offers. */
object UploadPanel {
    fun title(jobs: List<ImportJob>): String = "Uploads - ${finished(jobs)} of ${jobs.size}"

    fun finished(jobs: List<ImportJob>): Int = jobs.count { it.finished }

    fun progress(jobs: List<ImportJob>): Float = finished(jobs).toFloat() / jobs.size.coerceAtLeast(1)

    fun status(state: ImportJob.State): String = when (state) {
        ImportJob.State.Queued -> "Waiting"
        ImportJob.State.Preparing -> "Preparing…"
        is ImportJob.State.Saved -> "Saved; uploads when the server is reachable"
        is ImportJob.State.Duplicate -> "Already imported"
        is ImportJob.State.Failed -> state.message
        ImportJob.State.Cancelled -> "Cancelled"
    }

    /** The receipt a finished job produced (or already was), which a tap opens. */
    fun receiptOf(state: ImportJob.State): String? = when (state) {
        is ImportJob.State.Saved -> state.receiptUuid
        is ImportJob.State.Duplicate -> state.receiptUuid
        else -> null
    }

    fun canCancelAll(jobs: List<ImportJob>) = jobs.any { !it.finished }

    fun canRetry(jobs: List<ImportJob>) = jobs.any { it.state is ImportJob.State.Failed }
}
