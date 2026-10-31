package com.robinrossner.receipts.data

import com.robinrossner.receipts.data.sync.StringLists
import kotlin.math.abs
import kotlin.math.roundToLong

/** Business rules shared with the Mac and iPhone apps (receipt_pipeline.py / ReceiptPipeline.swift), pure for tests. */
object Rules {
    const val SUM_MISMATCH_TOLERANCE = 0.02

    private val storeNameMap = mapOf(
        "edeka" to "Edeka", "aldi sud" to "Aldi Süd", "aldi süd" to "Aldi Süd", "aldi nord" to "Aldi Nord",
        "dm-drogerie markt" to "dm", "dm" to "dm", "rewe" to "Rewe", "lidl" to "Lidl", "penny-markt gmbh" to "Penny",
        "penny" to "Penny", "rossmann" to "Rossmann", "kaufland" to "Kaufland",
    )

    /** The chain names the extraction can produce (store-name suggestions). */
    val canonicalStoreNames: List<String> = storeNameMap.values.toSet().sorted()

    fun canonicalizeStore(raw: String?): String {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return "Unknown"
        return storeNameMap[trimmed.lowercase()] ?: trimmed
    }

    fun round2(v: Double): Double = (v * 100).roundToLong() / 100.0

    private val packSize = Regex("""\b\d+[.,]?\d*\s?(g|kg|ml|l|cl|stk|stück|x\d*)\b""", RegexOption.IGNORE_CASE)
    private val nonWord = Regex("""[^a-zäöüß0-9\s]""")
    private val spaces = Regex("""\s+""")

    /** The dictionary key of an item name: lowercase, pack sizes and punctuation removed (ItemCategorizer.normalizeName). */
    fun normalizeName(raw: String): String {
        var s = raw.lowercase()
        s = packSize.replace(s, " ")
        s = nonWord.replace(s, " ")
        s = spaces.replace(s, " ")
        return s.trim()
    }

    /** Result of re-deriving the sum-mismatch review reason after an item or total edit. */
    data class Totals(val computedSum: Double, val reasons: List<String>, val needsReview: Boolean)

    /**
     * Re-derives `computed_sum` and the sum-mismatch review reason (other reasons stay), like the Mac app's
     * `recomputeReceiptTotals`.
     */
    fun recomputeTotals(itemSum: Double, total: Double?, currentReasonsJson: String): Totals {
        val computed = round2(itemSum)
        var reasons = StringLists.decode(currentReasonsJson).filterNot { it.contains("sum to") }
        if (total != null) reasons = reasons.filterNot { it.startsWith("No total found") }
        if (total != null) {
            val diff = round2(abs(itemSum - total))
            if (diff > SUM_MISMATCH_TOLERANCE) {
                reasons = reasons + "Item prices sum to ${trimmed(round2(itemSum))}, but printed total is ${trimmed(total)} (difference: ${trimmed(diff)}). Check raw_text per item."
            }
        }
        return Totals(computed, reasons, reasons.isNotEmpty())
    }

    /** Numbers print as the Mac app prints them in review reasons ("7.5", "12.0"). */
    private fun trimmed(v: Double): String = v.toString()

    fun hasSumMismatch(reasons: List<String>) = reasons.any { it.contains("sum to") }
}
