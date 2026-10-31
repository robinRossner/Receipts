package com.robinrossner.receipts.data.sync

import java.io.File
import java.security.MessageDigest
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

object Sha256 {
    fun hex(data: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(data).toHex()

    fun hex(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                md.update(buffer, 0, n)
            }
        }
        return md.digest().toHex()
    }

    private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }
}

/**
 * Timestamps on the wire and in the local database. The server speaks UTC ISO 8601 with milliseconds and `Z`; older
 * rows hold `2026-07-14T10:20:30Z` or `2026-07-14 10:20:30`. Last-write-wins compares INSTANTS, never strings
 * (`...:30.5Z` sorts before `...:30Z` as text).
 */
object SyncDate {
    private val pattern = Regex(
        """^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?)?\s*(Z|[+-]\d{2}(?::?\d{2})?)?$""",
        RegexOption.IGNORE_CASE,
    )
    private val formatter: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

    /** What Python's `datetime.fromisoformat` accepts (none = UTC); null when it is not a timestamp. */
    fun parse(raw: String?): Instant? {
        val m = pattern.matchEntire(raw?.trim().orEmpty()) ?: return null
        val g = m.groupValues
        return runCatching {
            val local = LocalDateTime.of(g[1].toInt(), g[2].toInt(), g[3].toInt(), g[4].ifEmpty { "0" }.toInt(), g[5].ifEmpty { "0" }.toInt(), g[6].ifEmpty { "0" }.toInt())
            val nanos = if (g[7].isEmpty()) 0 else g[7].padEnd(9, '0').take(9).toInt()
            var offset = 0
            val tz = g[8]
            if (tz.isNotEmpty() && !tz.equals("Z", ignoreCase = true)) {
                val sign = if (tz[0] == '-') -1 else 1
                val digits = tz.drop(1).replace(":", "")
                offset = sign * (digits.take(2).toInt() * 3600 + (digits.drop(2).ifEmpty { "0" }.toInt()) * 60)
            }
            local.toInstant(ZoneOffset.UTC).plusNanos(nanos.toLong()).minusSeconds(offset.toLong())
        }.getOrNull()
    }

    /** `2026-10-31T12:21:21.775Z`, the wire format. */
    fun format(instant: Instant): String = formatter.format(instant)

    fun now(): String = format(Instant.now())

    /** Same instant (to the millisecond), whatever the text format. */
    fun sameInstant(a: String?, b: String?): Boolean {
        val x = parse(a)
        val y = parse(b)
        if (x == null || y == null) return a == b
        return kotlin.math.abs(x.toEpochMilli() - y.toEpochMilli()) < 1
    }
}

/**
 * Last-write-wins between a local record and the server's copy of it (docs/api/receipts.md, "Client rules when
 * applying a pulled record"). Pure, so it is tested without a database.
 */
object SyncMerge {
    enum class Decision { TAKE_SERVER, KEEP_LOCAL }

    /**
     * No local copy or no unsent local edit -> the server's copy wins. With an unsent edit the newer `updated_at` wins,
     * like the server's own push rule (a pushed record replaces the stored one only if STRICTLY newer), so a tie goes
     * to the server: pushing our copy would be answered `stale` anyway.
     */
    fun decide(localUpdatedAt: Instant?, dirty: Boolean, serverUpdatedAt: Instant?): Decision {
        if (localUpdatedAt == null || !dirty) return Decision.TAKE_SERVER
        if (serverUpdatedAt == null) return Decision.KEEP_LOCAL
        return if (localUpdatedAt.isAfter(serverUpdatedAt)) Decision.KEEP_LOCAL else Decision.TAKE_SERVER
    }
}
