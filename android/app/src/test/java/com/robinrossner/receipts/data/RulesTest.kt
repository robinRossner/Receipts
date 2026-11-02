package com.robinrossner.receipts.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class RulesTest {
    // The table of backend/tests/test_receipts_store_names.py and Tests/ReceiptsAppTests/StoreNameAndModelImageTests.swift.
    private val cases: List<Pair<String?, String>> = listOf(
        "EDEKA Musterstadt" to "Edeka", "Edeka" to "Edeka", "EDEKA Center Nord" to "Edeka", "Edeka-Markt Müller" to "Edeka",
        "Getränke EDEKA Musterstadt" to "Edeka", "REWE Markt GmbH" to "Rewe", "REWE" to "Rewe", "Rewe City" to "Rewe",
        "Penny-Markt" to "Penny", "PENNY-Markt GmbH" to "Penny", "Penny" to "Penny", "Lidl Dienstleistung GmbH & Co. KG" to "Lidl",
        "Kaufland Filiale 1234" to "Kaufland", "Rossmann Drogeriemarkt" to "Rossmann", "ROSSMANN" to "Rossmann", "dm" to "dm", "DM" to "dm",
        "dm-drogerie markt" to "dm", "dm-drogerie markt GmbH + Co. KG" to "dm", "DM Drogerie Markt Filiale 12" to "dm",
        "ALDI SÜD" to "Aldi Süd", "Aldi Sud" to "Aldi Süd", "ALDI SUED" to "Aldi Süd", "Aldi Süd Dienstleistungs-GmbH" to "Aldi Süd",
        "ALDI Nord" to "Aldi Nord", "ALDI-NORD" to "Aldi Nord", "  Edeka\t" to "Edeka", "Kaufland-Tankstelle X" to "Kaufland",
        // no chain: kept as printed (trimmed)
        "Bäckerei Schmidt" to "Bäckerei Schmidt", "ALDI" to "ALDI", "Cafe Penny Lane" to "Cafe Penny Lane", "Edekabank" to "Edekabank",
        "Rewerk GmbH" to "Rewerk GmbH", "Lidlington" to "Lidlington", "Rossmannshof" to "Rossmannshof", "Dmitri's Kiosk" to "Dmitri's Kiosk",
        "Bäckerei DM Müller" to "Bäckerei DM Müller", "Pennywise" to "Pennywise", "Aldi Nordsee Imbiss" to "Aldi Nordsee Imbiss",
        // empty
        null to "Unknown", "" to "Unknown", "   " to "Unknown",
    )

    @Test
    fun storeNamesAreRecognisedByWholeWords() {
        for ((raw, expected) in cases) assertEquals("canonicalizeStore($raw)", expected, Rules.canonicalizeStore(raw))
    }

    @Test
    fun theChainNamesAreTheLiteralSortedList() {
        assertEquals(listOf("Aldi Nord", "Aldi Süd", "Edeka", "Kaufland", "Lidl", "Penny", "Rewe", "Rossmann", "dm"), Rules.canonicalStoreNames)
    }

    @Test
    fun theSumMismatchReasonIsRederivedAndOthersStay() {
        val reasons = "[\"Item #1 (x): product has a negative amount\",\"Item prices sum to 5.0, but printed total is 7.0 (difference: 2.0). Check raw_text per item.\"]"
        val ok = Rules.recomputeTotals(7.0, 7.0, reasons)
        assertEquals(listOf("Item #1 (x): product has a negative amount"), ok.reasons)
        assertTrue(ok.needsReview)
        val bad = Rules.recomputeTotals(5.0, 7.0, "[]")
        assertTrue(bad.reasons.single().startsWith("Item prices sum to 5.0, but printed total is 7.0"))
        assertNull(Rules.recomputeTotals(1.0, 1.0, "[]").reasons.firstOrNull())
    }
}

class FuzzyMatchTest {
    // A straight port of the oracle of backend/tests/test_receipts_port.py (the Swift algorithm).
    private fun indel(a: String, b: String): Int {
        val n = a.length; val m = b.length
        if (n == 0) return m
        if (m == 0) return n
        var prev = IntArray(m + 1) { it }
        for (i in 1..n) {
            val cur = IntArray(m + 1)
            cur[0] = i
            for (j in 1..m) cur[j] = if (a[i - 1] == b[j - 1]) prev[j - 1] else 1 + minOf(prev[j], cur[j - 1])
            prev = cur
        }
        return prev[m]
    }

    private fun oracle(a: String, b: String): Int {
        val sa = a.split(" ").sorted().joinToString(" ")
        val sb = b.split(" ").sorted().joinToString(" ")
        val total = sa.length + sb.length
        if (total == 0) return 100
        return (100.0 * (total - indel(sa, sb)) / total + 0.5).toInt()
    }

    @Test
    fun theRatioMatchesTheReferenceAlgorithm() {
        val rng = Random(7)
        val words = listOf("milch", "bio", "vollmilch", "käse", "gouda", "jogurt", "natur", "bananen", "ß", "x")
        repeat(300) {
            val a = (1..rng.nextInt(1, 5)).joinToString(" ") { words.random(rng) }
            val b = (1..rng.nextInt(1, 5)).joinToString(" ") { words.random(rng) }
            assertEquals("$a | $b", oracle(a, b), FuzzyMatch.tokenSortRatio(a, b))
        }
        assertEquals("token order is ignored", 100, FuzzyMatch.tokenSortRatio("bio milch", "milch bio"))
        assertEquals(100, FuzzyMatch.tokenSortRatio("", ""))
        assertEquals(0, FuzzyMatch.tokenSortRatio("abc", ""))
    }

    @Test
    fun theBestMatchKeepsTheFirstBest() {
        assertNull(FuzzyMatch.bestMatch("x", emptyList()))
        assertEquals("milch" to 100, FuzzyMatch.bestMatch("milch", listOf("kase", "milch", "milch")))
        assertEquals("first of equal scores", "milch bio" to 100, FuzzyMatch.bestMatch("bio milch", listOf("kase", "milch bio", "bio milch")))
    }
}
