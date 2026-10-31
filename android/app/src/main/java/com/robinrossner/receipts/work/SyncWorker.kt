package com.robinrossner.receipts.work

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.robinrossner.receipts.ReceiptsApp
import java.util.concurrent.TimeUnit

/**
 * Uploads prepared photos and syncs, whenever the network is there. Enqueued after every capture, so a photo taken
 * offline (or an app that is killed before the upload finished) is uploaded later without the app being open. The
 * upload is idempotent (client UUID + same bytes), so a retry is always safe.
 */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val container = (applicationContext as ReceiptsApp).container
        container.coordinator.ensureEngine()
        val report = container.coordinator.syncNow() ?: return Result.success()   // sync not set up
        val pendingUploads = container.syncStore.pendingUploads().isNotEmpty()
        return if (report.connectionProblem || (pendingUploads && !report.succeeded)) Result.retry() else Result.success()
    }

    companion object {
        const val UNIQUE_NAME = "receipts-upload-sync"

        fun enqueue(context: Context) {
            val request = OneTimeWorkRequestBuilder<SyncWorker>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .build()
            // APPEND_OR_REPLACE: a capture made while an older run is finishing still gets its own run afterwards.
            WorkManager.getInstance(context).enqueueUniqueWork(UNIQUE_NAME, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
        }
    }
}
