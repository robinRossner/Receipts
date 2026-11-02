package com.robinrossner.receipts.data

import com.robinrossner.receipts.data.api.HttpReceiptsApi
import com.robinrossner.receipts.data.api.PushEntity
import com.robinrossner.receipts.data.api.PushRequest
import com.robinrossner.receipts.data.api.PushStatus
import com.robinrossner.receipts.data.api.WireDictionaryEntry
import com.robinrossner.receipts.data.api.WireTaxonomyAddition
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import okhttp3.OkHttpClient
import okhttp3.ResponseBody.Companion.asResponseBody
import okio.ForwardingSource
import okio.Buffer
import okio.buffer
import org.junit.Test
import java.util.Collections
import java.util.concurrent.Executors

/** The real HTTP client against a mock server: the bytes on the wire for flags and additions, and decoding of answers. */
class HttpPushTest {
    private val mock = MockWebServer()
    private val json = com.robinrossner.receipts.data.api.WireJson.json

    @After fun stop() { mock.shutdown() }

    private fun api(): HttpReceiptsApi {
        mock.start()
        return HttpReceiptsApi(mock.url("/api/v1/receipts"), "secret-token")
    }

    @Test
    fun aPushCarriesTheFlagExplicitlyAndOmitsAdditionsWhenThereAreNone() = runBlocking {
        mock.enqueue(MockResponse().setBody("""{"server_time": "2026-10-31T12:00:00.000Z", "results": [{"entity": "dictionary", "id": "d1", "status": "applied"}]}"""))
        val entry = WireDictionaryEntry("d1", canonicalName = "x", categoryFlagged = false, updatedAt = "2026-10-31T12:00:00.000Z")
        val response = api().push(PushRequest("android-1", dictionary = listOf(entry)))
        assertEquals(PushStatus.APPLIED, response.results.single().status)

        val request = mock.takeRequest()
        assertEquals("/api/v1/receipts/sync/push", request.path)
        assertEquals("Bearer secret-token", request.getHeader("Authorization"))
        val body = json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertFalse("no key when there is nothing to add", body.containsKey("taxonomy_additions"))
        assertEquals(false, body["dictionary"]!!.jsonArray.single().jsonObject["category_flagged"]!!.jsonPrimitive.boolean)
    }

    @Test
    fun aPushWithAdditionsSendsThemAndDecodesTheirResult() = runBlocking {
        mock.enqueue(MockResponse().setBody("""{"results": [{"entity": "taxonomy_addition", "id": "Household > Pets > Pet Food", "status": "applied"}]}"""))
        val response = api().push(PushRequest("android-1", taxonomyAdditions = listOf(WireTaxonomyAddition("Household", "Pets", "Pet Food", "2026-10-31T12:00:00.000Z"))))
        assertEquals(PushEntity.TAXONOMY_ADDITION, response.results.single().entity)
        val body = json.parseToJsonElement(mock.takeRequest().body.readUtf8()).jsonObject
        assertEquals("Pet Food", body["taxonomy_additions"]!!.jsonArray.single().jsonObject["item_group"]!!.jsonPrimitive.content)
        assertFalse(body.containsKey("dictionary") && body["dictionary"]!!.jsonArray.isNotEmpty())
    }

    @Test
    fun aPullFromAnOlderServerHasNoAdditionsAndANewerOneHasThem() = runBlocking {
        mock.enqueue(MockResponse().setBody("""{"cursor": "c1", "has_more": false, "dictionary": [], "receipts": [], "line_items": []}"""))
        mock.enqueue(
            MockResponse().setBody(
                """{"cursor": "c2", "has_more": false, "dictionary": [{"id": "d", "canonical_name": "x", "category_flagged": true, "suggested_category": "Pet Food",
                   "suggested_parent": "Household", "updated_at": "2026-10-31T12:00:00.000Z"}], "receipts": [], "line_items": [],
                   "taxonomy_additions": [{"category": "A", "subcategory": "B", "item_group": "C"}]}""",
            ),
        )
        val client = api()
        assertNull(client.pull(null, 100).taxonomyAdditions)
        val page = client.pull("c1", 100)
        assertEquals("A > B > C", page.taxonomyAdditions?.single()?.label)
        assertTrue(page.dictionary.single().categoryFlagged == true)
    }

    @Test
    fun responseBodiesAreNeverReadOnTheCallersThread() = runBlocking {
        // On a phone the callers are view models on the main thread, where reading a body throws NetworkOnMainThreadException
        // (the photo download crashed the Photo tab). The test's "main" is a thread with a known name.
        val readers = Collections.synchronizedSet(mutableSetOf<String>())
        val client = OkHttpClient.Builder().addNetworkInterceptor { chain ->
            val response = chain.proceed(chain.request())
            val source = object : ForwardingSource(response.body.source()) {
                override fun read(sink: Buffer, byteCount: Long): Long = super.read(sink, byteCount).also { readers += Thread.currentThread().name }
            }.buffer()
            response.newBuilder().body(source.asResponseBody(response.body.contentType(), response.body.contentLength())).build()
        }.build()
        mock.start()
        val api = HttpReceiptsApi(mock.url("/api/v1/receipts"), "secret-token", client)
        val main = Executors.newSingleThreadExecutor { Thread(it, "pretend-main") }
        try {
            mock.enqueue(MockResponse().setHeader("Content-Type", "image/jpeg").setBody("photo-bytes"))
            mock.enqueue(MockResponse().setBody("""{"unarchived_count": 0}"""))
            withContext(main.asCoroutineDispatcher()) {
                assertEquals("photo-bytes", String(api.downloadPhoto("/api/v1/receipts/r1/photo").data))
                api.status()
            }
        } finally {
            main.shutdown()
        }
        assertTrue("bodies were read", readers.isNotEmpty())
        // The coroutine debug agent appends " @coroutine#n" to the thread name.
        assertTrue("a body was read on the caller's thread: $readers", readers.none { it.startsWith("pretend-main") })
    }
}
