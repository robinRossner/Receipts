package com.robinrossner.receipts.data.api

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** Why a call to the receipts backend failed. `code` is the contract's `detail.code` (e.g. `duplicate_image`). */
sealed class ReceiptsApiException(message: String) : Exception(message) {
    class Http(val status: Int, val code: String?, val serverMessage: String?, val extra: Map<String, String> = emptyMap()) :
        ReceiptsApiException(describeHttp(status, code, serverMessage))

    class Transport(detail: String) : ReceiptsApiException("Server not reachable ($detail)")
    class InvalidResponse(detail: String) : ReceiptsApiException("Unexpected answer from the server ($detail)")
    class NotConfigured(detail: String) : ReceiptsApiException(detail)

    /** The calling device lacks a capability (the phone is not the photo archive); never sent to the server. */
    class NotPermitted(detail: String) : ReceiptsApiException(detail)

    /** Worth trying again later: the network, the server being busy, or a rate limit. */
    val isRetryable: Boolean
        get() = when (this) {
            is Transport -> true
            is Http -> status >= 500 || status == 429 || status == 408
            else -> false
        }

    /** The whole server or the credentials are the problem, so other calls of this run would fail too. */
    val isConnectionLevel: Boolean
        get() = when (this) {
            is Transport, is NotConfigured -> true
            is Http -> status == 401 || status == 429 || status >= 500
            else -> false
        }

    private companion object {
        fun describeHttp(status: Int, code: String?, message: String?): String = when (status) {
            401 -> "The server rejected the token (401). Check the receipts token in Settings."
            503 -> "The server has no receipts token configured (503)."
            429 -> "Too many wrong tokens from this network (429); try again later."
            else -> message ?: code?.let { "Server error $status ($it)" } ?: "Server error $status"
        }
    }
}

/** The calls of docs/api/receipts.md the app needs. An interface so the engine can be tested with a fake. */
interface ReceiptsApi {
    suspend fun health()
    suspend fun status(): ServerStatus
    suspend fun uploadPhoto(id: String, data: ByteArray, mediaType: String, createdAtMillis: Long?): UploadResponse
    suspend fun retryExtraction(id: String)
    suspend fun push(request: PushRequest): PushResponse
    suspend fun pull(since: String?, limit: Int): PullResponse
    suspend fun archivePending(): List<ArchivePendingPhoto>
    suspend fun downloadPhoto(path: String): DownloadedPhoto
    suspend fun archiveConfirm(id: String, sha256: String, deviceId: String, acceptFailed: Boolean): ArchiveConfirmResponse
    suspend fun archiveSync(deviceId: String)
}

/** What the user typed as "server URL" -> the receipts API base (`https://host/api/v1/receipts`). */
object ServerUrl {
    const val API_PATH = "/api/v1/receipts"

    /** Hosts plain HTTP may reach in a debug build: this machine, and the emulator's host machine. */
    private val loopbackHosts = setOf("localhost", "127.0.0.1", "::1", "[::1]", "10.0.2.2")

    fun isLoopback(host: String) = host.lowercase() in loopbackHosts

    /** HTTPS always; plain HTTP only in debug builds and only to this machine or the emulator host. */
    fun isAllowed(url: HttpUrl, debugBuild: Boolean): Boolean =
        url.scheme == "https" || (url.scheme == "http" && debugBuild && isLoopback(url.host))

    fun apiBase(input: String, debugBuild: Boolean): HttpUrl? {
        var text = input.trim()
        if (text.isEmpty()) return null
        if (!text.contains("://")) {
            val local = text.startsWith("localhost") || text.startsWith("127.") || text.startsWith("[::1]") || text.startsWith("10.0.2.2")
            text = (if (local) "http://" else "https://") + text
        }
        text = text.trimEnd('/')
        if (!text.endsWith(API_PATH)) text += API_PATH
        val url = text.toHttpUrlOrNull() ?: return null
        return if (isAllowed(url, debugBuild)) url else null
    }

    /** `GET /health` is the one unprefixed route (no token). */
    fun healthUrl(apiBase: HttpUrl): HttpUrl {
        val text = apiBase.toString().removeSuffix(API_PATH)
        return (text.trimEnd('/') + "/health").toHttpUrl()
    }

    /** Cursors are global to the server's database: keep one per server. */
    fun cursorKey(apiBase: HttpUrl) = "cursor:" + apiBase.toString().lowercase()

    private fun String.toHttpUrl(): HttpUrl = toHttpUrlOrNull() ?: error("bad url $this")
}
