package com.robinrossner.receipts.data

import com.robinrossner.receipts.data.sync.StringLists
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToLong

/** Business rules shared with the Mac and iPhone apps (receipt_pipeline.py / ReceiptPipeline.swift), pure for tests. */
object Rules {
    const val SUM_MISMATCH_TOLERANCE = 0.02

    /** The chain names the extraction can produce (store-name suggestions). */
    val canonicalStoreNames: List<String> = listOf("Aldi Nord", "Aldi Süd", "Edeka", "Kaufland", "Lidl", "Penny", "Rewe", "Rossmann", "dm")

    private val anywhereChains = mapOf("edeka" to "Edeka", "rewe" to "Rewe", "lidl" to "Lidl", "kaufland" to "Kaufland", "rossmann" to "Rossmann")
    private val diacritics = Regex("\\p{M}+")

    /**
     * The chain a printed store name stands for ("EDEKA Musterstadt" -> "Edeka"), else the trimmed name as printed.
     * Chains are recognised by whole words, never by substring (ReceiptPipeline.canonicalizeStore, mirrored by the
     * backend's `canonicalize_store`): lower-case, diacritics folded, every run of characters other than a-z / 0-9 is a
     * word break. Reading the words left to right, the first rule that fits wins: `dm` only as the whole name or
     * "dm drogerie ...", `penny` only as the first word, the other chains as a word anywhere, "aldi" + sud|sued|nord.
     */
    fun canonicalizeStore(raw: String?): String {
        val trimmed = raw?.trimSpaces().orEmpty()
        if (trimmed.isEmpty()) return "Unknown"
        return chain(storeWords(trimmed)) ?: trimmed
    }

    /** ß is not folded (it is a word break), like Swift's diacritic-insensitive folding. */
    private fun storeWords(raw: String): List<String> {
        val folded = diacritics.replace(java.text.Normalizer.normalize(raw.lowercase(Locale.ROOT), java.text.Normalizer.Form.NFD), "")
        val words = mutableListOf<String>()
        val current = StringBuilder()
        for (c in folded) {
            if (c in 'a'..'z' || c in '0'..'9') current.append(c) else if (current.isNotEmpty()) { words += current.toString(); current.clear() }
        }
        if (current.isNotEmpty()) words += current.toString()
        return words
    }

    private fun chain(words: List<String>): String? {
        if (words == listOf("dm") || (words.size >= 2 && words[0] == "dm" && words[1] == "drogerie")) return "dm"
        if (words.firstOrNull() == "penny") return "Penny"
        for ((i, word) in words.withIndex()) {
            anywhereChains[word]?.let { return it }
            if (word == "aldi" && i + 1 < words.size) when (words[i + 1]) {
                "sud", "sued" -> return "Aldi Süd"
                "nord" -> return "Aldi Nord"
            }
        }
        return null
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
