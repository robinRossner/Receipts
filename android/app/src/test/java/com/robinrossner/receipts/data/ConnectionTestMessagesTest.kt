package com.robinrossner.receipts.data

import androidx.test.core.app.ApplicationProvider
import com.robinrossner.receipts.data.sync.SyncCoordinator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Settings > Test connection says the same words as the iPhone (`SyncCoordinator.testConnection`) when the input is unusable. */
@RunWith(RobolectricTestRunner::class)
class ConnectionTestMessagesTest {
    private val env = TestEnv()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val coordinator = SyncCoordinator(scope, env.store, SyncSettings(ApplicationProvider.getApplicationContext()), debugBuild = true)

    @After fun tearDown() { scope.cancel(); env.close() }

    @Test
    fun anInvalidAddressIsReportedBeforeAnythingElse() = runBlocking {
        val result = coordinator.testConnection("not a url", "token")
        assertFalse(result.ok)
        assertEquals("That is not a valid server URL.", result.message)
    }

    @Test
    fun aMissingTokenAsksForTheTokenToBeSavedFirst() = runBlocking {
        val result = coordinator.testConnection("http://10.0.2.2:8787", null)
        assertFalse(result.ok)
        assertEquals("Save the receipts token first.", result.message)
        assertEquals("Save the receipts token first.", coordinator.testConnection("http://10.0.2.2:8787", "").message)
    }
}
