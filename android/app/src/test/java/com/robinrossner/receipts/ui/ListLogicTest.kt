package com.robinrossner.receipts.ui

import com.robinrossner.receipts.data.ImportJob
import com.robinrossner.receipts.data.db.LocalStatus
import com.robinrossner.receipts.data.db.ReceiptSummary
import com.robinrossner.receipts.data.sync.SyncPhase
import com.robinrossner.receipts.data.sync.SyncUiState
import com.robinrossner.receipts.ui.list.ActiveFilter
import com.robinrossner.receipts.ui.list.ListLogic
import com.robinrossner.receipts.ui.list.SyncDot
import com.robinrossner.receipts.ui.list.SyncRow
import com.robinrossner.receipts.ui.list.UploadPanel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** Texts and rules of the Receipts list screen must read like the iPhone's. */
class ListLogicTest {
    private fun receipt(
        uuid: String = "r1", store: String? = "ALDI", reviewedAt: String? = null, needsReview: Boolean = false,
        status: String? = null, total: Double? = 5.0,
    ) = ReceiptSummary(uuid, store, "2026-03-01", null, total, needsReview, reviewedAt, status, null, null, null)

    private val relative = { then: Long, now: Long -> "${(now - then) / 60_000} Minutes Ago" }

    // ---- sync row

    @Test fun syncRowTexts() {
        val now = 10_000_000L
        assertNull(SyncRow.make(SyncUiState(SyncPhase.OFF), now, relative))
        assertEquals("Syncing…", SyncRow.make(SyncUiState(SyncPhase.SYNCING), now, relative)!!.text)
        assertEquals(SyncDot.SPINNER, SyncRow.make(SyncUiState(SyncPhase.SYNCING), now, relative)!!.dot)
        val never = SyncRow.make(SyncUiState(SyncPhase.IDLE), now, relative)!!
        assertEquals("Not synced yet", never.text); assertEquals(SyncDot.NEVER, never.dot)
        val hard = SyncRow.make(SyncUiState(SyncPhase.IDLE, lastError = "x"), now, relative)!!
        assertEquals("Sync failed", hard.text); assertEquals(SyncDot.RED, hard.dot); assertTrue(hard.hardFailure)
        val retry = SyncRow.make(SyncUiState(SyncPhase.IDLE, lastError = "x", nextRetryAtMillis = now + 1), now, relative)!!
        assertEquals("Sync failed, retrying", retry.text); assertEquals(SyncDot.AMBER, retry.dot); assertFalse(retry.hardFailure)
    }

    @Test fun syncedRelativeTime() {
        val now = 10_000_000L
        val recent = SyncUiState(SyncPhase.IDLE, lastSyncAt = Instant.ofEpochMilli(now - 59_999))
        assertEquals("Synced now", SyncRow.make(recent, now, relative)!!.text)
        val older = SyncUiState(SyncPhase.IDLE, lastSyncAt = Instant.ofEpochMilli(now - 5 * 60_000))
        val row = SyncRow.make(older, now, relative)!!
        assertEquals("Synced 5 minutes ago", row.text); assertEquals(SyncDot.GREEN, row.dot)
    }

    // ---- filters

    @Test fun dateRangeLabelsAndFilterTags() {
        assertEquals(listOf("All time", "This month", "Last 3 months", "This year"), DateRange.entries.map { it.label })
        assertTrue(ListLogic.activeFilters("", DateRange.ALL, null).isEmpty())
        assertTrue(ListLogic.activeFilters("   ", DateRange.ALL, null).isEmpty())
        val all = ListLogic.activeFilters("milk", DateRange.THIS_MONTH, "REWE")
        assertEquals(listOf("“milk”", "This month", "REWE"), all.map { it.text })
        assertEquals(listOf(ActiveFilter.Kind.SEARCH, ActiveFilter.Kind.DATE, ActiveFilter.Kind.STORE), all.map { it.kind })
    }

    @Test fun resultCountAndConfirmTexts() {
        assertEquals("1 receipt", ListLogic.resultCount(1))
        assertEquals("0 receipts", ListLogic.resultCount(0))
        assertEquals("12 receipts", ListLogic.resultCount(12))
        assertEquals("Confirm 1 receipts without flags?", ListLogic.confirmAllTitle(1))
        assertEquals("Confirm all without flags (3)", ListLogic.confirmAllButton(3))
        assertEquals("2 to review", ListLogic.toReviewBadge(2))
    }

    // ---- rows

    @Test fun rowNameAndTotal() {
        assertEquals("ALDI", ListLogic.rowName(receipt()))
        assertEquals("Unknown", ListLogic.rowName(receipt(store = null)))
        assertEquals("New receipt", ListLogic.rowName(receipt(store = null, status = LocalStatus.PENDING_UPLOAD)))
        assertEquals("Still ALDI", ListLogic.rowName(receipt(store = "Still ALDI", status = "processing")))
        assertFalse(ListLogic.showsTotal(receipt(total = null, status = "processing")))
        assertTrue(ListLogic.showsTotal(receipt(total = 3.0, status = "processing")))
        assertTrue(ListLogic.showsTotal(receipt(total = null)))
    }

    @Test fun warningLines() {
        val reasons = mapOf("r1" to listOf("Item prices sum to €4.00", "No total found on receipt"))
        assertEquals("Item prices sum to €4.00", ListLogic.inlineWarning(receipt(needsReview = true), reasons))
        assertEquals("Needs review", ListLogic.inlineWarning(receipt(uuid = "other", needsReview = true), reasons))
        assertNull(ListLogic.inlineWarning(receipt(needsReview = false), reasons))
        val reviewedFlagged = receipt(needsReview = true, reviewedAt = "2026-03-02")
        assertNull(ListLogic.inlineWarning(reviewedFlagged, reasons))
        assertTrue(ListLogic.showsWarningIcon(reviewedFlagged))
        assertFalse(ListLogic.showsWarningIcon(receipt(needsReview = true)))
    }

    @Test fun swipeToConfirmOnlyForUnreviewedFinishedReceipts() {
        assertTrue(ListLogic.canConfirmBySwipe(receipt()))
        assertFalse(ListLogic.canConfirmBySwipe(receipt(reviewedAt = "2026-03-02")))
        assertFalse(ListLogic.canConfirmBySwipe(receipt(status = LocalStatus.PENDING_UPLOAD)))
        assertFalse(ListLogic.canConfirmBySwipe(receipt(status = "failed")))
        assertEquals("ALDI reviewed", ListLogic.reviewedSnack(receipt()))
        assertEquals("Receipt reviewed", ListLogic.reviewedSnack(receipt(store = null)))
    }

    @Test fun deletedLineAndCaptureNotes() {
        assertEquals("2026-03-01 · €5.00", ListLogic.deletedLine(receipt(), "€5.00"))
        assertEquals("3 photo(s) could not be loaded.", ListLogic.photosNotLoaded(3))
        assertEquals(
            "Only the first of 4 pages was added. A receipt is one photo; scan the other pages as separate receipts.",
            ListLogic.onlyFirstPage(4),
        )
    }

    // ---- upload panel

    @Test fun uploadPanelCounts() {
        val jobs = listOf(
            ImportJob("1", "a.jpg", ImportJob.State.Saved("u1")),
            ImportJob("2", "b.jpg", ImportJob.State.Preparing),
            ImportJob("3", "c.jpg", ImportJob.State.Failed("Couldn't read the file.")),
            ImportJob("4", "d.jpg", ImportJob.State.Cancelled),
        )
        assertEquals("Uploads - 3 of 4", UploadPanel.title(jobs))
        assertEquals(0.75f, UploadPanel.progress(jobs), 0.0001f)
        assertEquals(0f, UploadPanel.progress(emptyList()), 0f)
        assertTrue(UploadPanel.canCancelAll(jobs))
        assertTrue(UploadPanel.canRetry(jobs))
        assertFalse(UploadPanel.canCancelAll(jobs.filter { it.finished }))
        assertFalse(UploadPanel.canRetry(jobs.take(2)))
    }

    @Test fun uploadStatusTexts() {
        assertEquals("Waiting", UploadPanel.status(ImportJob.State.Queued))
        assertEquals("Preparing…", UploadPanel.status(ImportJob.State.Preparing))
        assertEquals("Saved; uploads when the server is reachable", UploadPanel.status(ImportJob.State.Saved("u")))
        assertEquals("Already imported", UploadPanel.status(ImportJob.State.Duplicate("u")))
        assertEquals("boom", UploadPanel.status(ImportJob.State.Failed("boom")))
        assertEquals("Cancelled", UploadPanel.status(ImportJob.State.Cancelled))
        assertEquals("u", UploadPanel.receiptOf(ImportJob.State.Saved("u")))
        assertEquals("u", UploadPanel.receiptOf(ImportJob.State.Duplicate("u")))
        assertNull(UploadPanel.receiptOf(ImportJob.State.Cancelled))
    }
}
