package com.robinrossner.receipts.ui.components

import java.time.LocalDate
import java.time.LocalTime
import java.util.Locale

/** `€12.34`, `—` for none (the iPhone's `fmtMoney`; negative shows `€-1.20`). */
fun fmtMoney(v: Double?): String = if (v == null) "—" else String.format(Locale.US, "€%.2f", v)

/** `2`, `0.5`, `1.25`: no trailing zeros. */
fun trimmedNumber(v: Double): String {
    val rounded = Math.round(v * 1000) / 1000.0
    if (rounded == Math.rint(rounded) && Math.abs(rounded) < 1e9) return rounded.toLong().toString()
    return String.format(Locale.US, "%.3f", rounded).trimEnd('0').trimEnd('.')
}

/** A quantity: three decimals at most, no trailing zeros. */
fun fmtQty(q: Double): String = trimmedNumber(Math.round(q * 1000) / 1000.0)

/** Parses "2,5" and "2.5". */
fun parseDecimal(text: String): Double? = text.trim().replace(',', '.').toDoubleOrNull()

/** A size the way the iPhone's `ByteCountFormatter(.file)` writes it (decimal units): `Zero KB`, `1 byte`, `512 bytes`, `45 KB`, `1.5 MB`, `300 MB`, `1.25 GB`. */
fun formatFileSize(bytes: Long): String = when {
    bytes <= 0L -> "Zero KB"
    bytes == 1L -> "1 byte"
    bytes < 1_000L -> "$bytes bytes"
    bytes < 1_000_000L -> "${Math.round(bytes / 1_000.0)} KB"
    bytes < 1_000_000_000L -> "${trimmedDecimals(bytes / 1_000_000.0, 1)} MB"
    else -> "${trimmedDecimals(bytes / 1_000_000_000.0, 2)} GB"
}

private fun trimmedDecimals(v: Double, decimals: Int): String {
    val text = String.format(Locale.US, "%.${decimals}f", v)
    return if ('.' in text) text.trimEnd('0').trimEnd('.') else text
}

/** The receipt date and time as the server stores them: `yyyy-MM-dd` and `HH:mm`, no locale. Parsing reads the first 10 / 5 characters only. */
object ReceiptDateFormat {
    fun date(d: LocalDate): String = d.toString()
    fun time(t: LocalTime): String = String.format(Locale.ROOT, "%02d:%02d", t.hour, t.minute)
    fun parseDate(s: String?): LocalDate? = s?.take(10)?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
    fun parseTime(s: String?): LocalTime? = s?.take(5)?.let { runCatching { LocalTime.parse(it) }.getOrNull() }
}
