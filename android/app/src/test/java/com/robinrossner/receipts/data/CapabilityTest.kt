package com.robinrossner.receipts.data

import com.robinrossner.receipts.data.api.CapabilityGuardedApi
import com.robinrossner.receipts.data.api.ReceiptsApiException
import com.robinrossner.receipts.data.api.SyncCapabilities
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The phone is NOT the photo archive: it must never tell the server to delete its copy of a photo. These pin that the
 * guarantee sits in the shared code (the engine's API wrapper), not in the UI leaving a button out.
 */
@RunWith(RobolectricTestRunner::class)
class CapabilityTest {
    private val server = FakeReceiptsServer(bundledTaxonomy())
    private var env: TestEnv? = null

    @After fun tearDown() { env?.close() }

    private fun expectNotPermitted(block: suspend () -> Unit) = runBlocking {
        try {
            block()
            fail("the phone must not call this")
        } catch (e: ReceiptsApiException.NotPermitted) {
            assertTrue(e.message!!.contains("not the photo archive"))
        }
    }

    @Test
    fun theMobileCapabilitiesCannotArchive() {
        assertEquals(false, SyncCapabilities.MOBILE.archivesPhotos)
        assertEquals(true, SyncCapabilities.MOBILE.cachesPhotos)
        assertEquals(300_000_000L, SyncCapabilities.MOBILE.photoCacheBytes)
        assertEquals(true, SyncCapabilities.ARCHIVE_DEVICE.archivesPhotos)
    }

    @Test
    fun everyArchiveCallIsRefusedOnTheMobileWrapperAndNeverReachesTheServer() {
        val guarded = CapabilityGuardedApi(server, SyncCapabilities.MOBILE)
        expectNotPermitted { guarded.archivePending() }
        expectNotPermitted { guarded.archiveConfirm("id", "sha", "android-test", acceptFailed = false) }
        expectNotPermitted { guarded.archiveConfirm("id", "sha", "android-test", acceptFailed = true) }
        expectNotPermitted { guarded.archiveSync("android-test") }
        assertEquals(0, server.archivePendingCalls)
        assertTrue("accept_failed in particular never goes out", server.confirmCalls.isEmpty())
        assertEquals(0, server.archiveSyncCalls)
    }

    @Test
    fun theArchiveDeviceIsForwarded() = runBlocking {
        val guarded = CapabilityGuardedApi(server, SyncCapabilities.ARCHIVE_DEVICE)
        guarded.archivePending()
        guarded.archiveConfirm("id", "sha", "mac", acceptFailed = true)
        guarded.archiveSync("mac")
        assertEquals(1, server.archivePendingCalls); assertEquals(1, server.confirmCalls.size); assertEquals(1, server.archiveSyncCalls)
    }

    @Test
    fun aPhoneSyncNeverCallsAnArchiveEndpoint() = runBlocking {
        val e = TestEnv(api = server).also { env = it }
        e.dict("d", "milch", syncState = com.robinrossner.receipts.data.db.SyncState.DIRTY)
        server.seedReceipt(
            com.robinrossner.receipts.data.api.WireReceipt(
                "r", store = "Edeka", photoLocation = "server", photoSha256 = "abc", extractionStatus = "done", updatedAt = "2026-03-01T10:00:00.000Z",
            ),
        )
        val report = e.engine!!.syncNow()
        assertTrue("${report.errors}", report.succeeded)
        assertEquals(0, server.archivePendingCalls)
        assertTrue(server.confirmCalls.isEmpty())
        assertEquals(0, server.archiveSyncCalls)
        assertEquals("server", server.receipts.getValue("r").photoLocation)
    }
}
