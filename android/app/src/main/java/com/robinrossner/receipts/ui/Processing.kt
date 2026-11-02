package com.robinrossner.receipts.ui

import com.robinrossner.receipts.data.db.LocalStatus
import com.robinrossner.receipts.data.db.ReceiptEntity
import com.robinrossner.receipts.data.db.ReceiptSummary

/** Where a receipt that sync handles stands: waiting for its photo to reach the server, being read there, or failed. */
sealed interface Processing {
    val label: String
    val isActive: Boolean

    data class WaitingForUpload(val error: String?) : Processing {
        override val label get() = "Waiting to upload"
        override val isActive get() = true
    }

    data class UploadFailed(val error: String?) : Processing {
        override val label get() = "Upload failed"
        override val isActive get() = false
    }

    data object Reading : Processing {
        override val label get() = "Reading receipt on the server…"
        override val isActive get() = true
    }

    data class Failed(val error: String?) : Processing {
        override val label get() = "Could not read this receipt"
        override val isActive get() = false
    }

    companion object {
        /** nil = an ordinary finished receipt. */
        fun of(status: String?, error: String?): Processing? = when (status) {
            LocalStatus.PENDING_UPLOAD -> WaitingForUpload(error)
            LocalStatus.UPLOAD_FAILED -> UploadFailed(error)
            "queued", "processing" -> Reading
            "failed" -> Failed(error)
            else -> null
        }
    }
}

val ReceiptSummary.processing get() = Processing.of(extractionStatus, extractionError)
val ReceiptEntity.processing get() = Processing.of(extractionStatus, extractionError)
