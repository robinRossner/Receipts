package com.robinrossner.receipts.data.api

import com.robinrossner.receipts.data.sync.Sha256
import com.robinrossner.receipts.data.sync.SyncDate
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** OkHttp implementation of [ReceiptsApi]. Every request carries the bearer token. */
class HttpReceiptsApi(
    private val baseUrl: HttpUrl,
    private val token: String,
    private val client: OkHttpClient = defaultClient(),
) : ReceiptsApi {

    private val json = WireJson.json

    override suspend fun health() {
        val request = Request.Builder().url(ServerUrl.healthUrl(baseUrl)).get().build()
        client.newBuilder().callTimeout(15, TimeUnit.SECONDS).build().newCall(request).await().use { checkOk(it) }
    }

    override suspend fun status(): ServerStatus = decode(send("GET", "status"))

    override suspend fun uploadPhoto(id: String, data: ByteArray, mediaType: String, createdAtMillis: Long?): UploadResponse {
        val url = baseUrl.newBuilder().addPathSegment(id).addPathSegment("photo").apply {
            if (createdAtMillis != null) addQueryParameter("created_at", SyncDate.format(java.time.Instant.ofEpochMilli(createdAtMillis)))
        }.build()
        val request = Request.Builder().url(url).auth()
            .header("X-Content-SHA256", Sha256.hex(data))
            .put(data.toRequestBody(mediaType.toMediaType()))
            .build()
        return decode(client.newCall(request).await().use { checkOk(it).body.string() })
    }

    override suspend fun retryExtraction(id: String) {
        send("POST", "$id/extraction/retry", body = ByteArray(0).toRequestBody(null))
    }

    override suspend fun push(request: PushRequest): PushResponse =
        decode(send("POST", "sync/push", body = jsonBody(json.encodeToString(request))))

    override suspend fun pull(since: String?, limit: Int): PullResponse =
        decode(send("GET", "sync/pull", query = listOf("since" to (since ?: ""), "limit" to limit.toString())))

    override suspend fun archivePending(): List<ArchivePendingPhoto> =
        decode<ArchivePendingResponse>(send("GET", "archive/pending")).photos

    override suspend fun downloadPhoto(path: String): DownloadedPhoto {
        // `path` is the server-relative `download` value ("/api/v1/receipts/<id>/photo").
        val url = baseUrl.newBuilder().encodedPath(path).query(null).build()
        val request = Request.Builder().url(url).auth().get().build()
        return client.newCall(request).await().use { response ->
            checkOk(response)
            DownloadedPhoto(response.body.bytes(), response.header("Content-Type"), response.header("X-Content-SHA256"))
        }
    }

    override suspend fun archiveConfirm(id: String, sha256: String, deviceId: String, acceptFailed: Boolean): ArchiveConfirmResponse {
        val body = ArchiveConfirmRequest(sha256, deviceId, if (acceptFailed) true else null)
        return decode(send("POST", "$id/archive-confirm", body = jsonBody(json.encodeToString(body))))
    }

    override suspend fun archiveSync(deviceId: String) {
        send("POST", "archive/sync", body = jsonBody(json.encodeToString(ArchiveSyncRequest(deviceId))))
    }

    // ---- plumbing ----

    private fun Request.Builder.auth() = header("Authorization", "Bearer $token").header("Accept", "application/json")

    private fun jsonBody(text: String): RequestBody = text.toRequestBody("application/json".toMediaType())

    private suspend fun send(method: String, path: String, query: List<Pair<String, String>> = emptyList(), body: RequestBody? = null): String {
        val builder = baseUrl.newBuilder()
        path.split('/').forEach { builder.addPathSegment(it) }
        query.forEach { (k, v) -> builder.addQueryParameter(k, v) }
        val request = Request.Builder().url(builder.build()).auth().method(method, body).build()
        return client.newCall(request).await().use { checkOk(it).body.string() }
    }

    private fun checkOk(response: Response): Response {
        if (response.isSuccessful) return response
        val bytes = runCatching { response.body.string() }.getOrDefault("")
        throw httpError(response.code, bytes)
    }

    private inline fun <reified T> decode(text: String): T = try {
        json.decodeFromString<T>(text)
    } catch (e: SerializationException) {
        throw ReceiptsApiException.InvalidResponse("${T::class.simpleName}: ${e.message?.take(200)}")
    }

    companion object {
        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .writeTimeout(120, TimeUnit.SECONDS)
            .callTimeout(10, TimeUnit.MINUTES)
            .build()

        /** `{"detail": {"code", "message", ...extra}}`, or FastAPI's `detail` list / plain text for 422 and friends. */
        fun httpError(status: Int, body: String): ReceiptsApiException.Http {
            var code: String? = null
            var message: String? = null
            val extra = mutableMapOf<String, String>()
            val detail = runCatching { WireJson.json.parseToJsonElement(body).jsonObject["detail"] }.getOrNull()
            when (detail) {
                is JsonObject -> {
                    code = (detail["code"] as? JsonPrimitive)?.contentOrNull
                    message = (detail["message"] as? JsonPrimitive)?.contentOrNull
                    for ((k, v) in detail) if (k != "code" && k != "message") extra[k] = (v as? JsonPrimitive)?.contentOrNull ?: v.toString()
                }
                is JsonPrimitive -> message = detail.contentOrNull
                is JsonArray -> message = detail.mapNotNull { (it as? JsonObject)?.get("msg")?.let { m -> (m as? JsonPrimitive)?.contentOrNull } }
                    .joinToString("; ").ifEmpty { null }
                null -> {}
            }
            return ReceiptsApiException.Http(status, code, message, extra)
        }
    }
}

private suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (!cont.isCancelled) cont.resumeWithException(ReceiptsApiException.Transport(e.message ?: e.javaClass.simpleName))
        }

        override fun onResponse(call: Call, response: Response) {
            cont.resume(response)
        }
    })
    cont.invokeOnCancellation { runCatching { cancel() } }
}
