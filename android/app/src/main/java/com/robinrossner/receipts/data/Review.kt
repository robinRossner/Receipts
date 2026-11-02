package com.robinrossner.receipts.data

import com.robinrossner.receipts.data.db.LocalStatus
import com.robinrossner.receipts.data.db.ReceiptEntity
import com.robinrossner.receipts.data.db.ReceiptSummary

object ReceiptStatus {
    /**
     * Receipts the server has not (successfully) read yet, or whose photo has not reached it: nothing to review or
     * confirm. A confirmation of one the server is still reading is an applied push that keeps the extraction out for good.
     */
    val UNFINISHED: Set<String> = setOf(LocalStatus.PENDING_UPLOAD, LocalStatus.UPLOAD_FAILED, "queued", "processing", "failed")

    fun isUnfinished(status: String?): Boolean = status != null && status in UNFINISHED
}

val ReceiptSummary.isUnfinished: Boolean get() = ReceiptStatus.isUnfinished(extractionStatus)
val ReceiptEntity.isUnfinished: Boolean get() = ReceiptStatus.isUnfinished(extractionStatus)

/**
 * What "Looks good" does next and says beforehand (PhoneReviewLogic.swift). Receipts still being read or that failed
 * have nothing to confirm yet, so the queue skips them. [receipts] is the full list in list order.
 */
object ReviewQueue {
    fun waiting(receipts: List<ReceiptSummary>, excluding: String): List<ReceiptSummary> =
        receipts.filter { it.reviewedAt == null && !it.isUnfinished && it.uuid != excluding }

    /** The next unreviewed receipt after [after] in the list, else the first one; null when nothing is left. */
    fun next(after: String, receipts: List<ReceiptSummary>): ReceiptSummary? {
        val queue = waiting(receipts, after)
        val index = receipts.indexOfFirst { it.uuid == after }
        if (index >= 0) {
            val later = receipts.drop(index + 1).map { it.uuid }.toSet()
            queue.firstOrNull { it.uuid in later }?.let { return it }
        }
        return queue.firstOrNull()
    }

    /** `3 more to review · next: ALDI SÜD`. */
    fun hint(forReceipt: String, receipts: List<ReceiptSummary>): String {
        val more = waiting(receipts, forReceipt).size
        if (more == 0) return "Last one to review"
        val store = next(forReceipt, receipts)?.store
        return if (!store.isNullOrEmpty()) "$more more to review · next: $store" else "$more more to review"
    }
}
