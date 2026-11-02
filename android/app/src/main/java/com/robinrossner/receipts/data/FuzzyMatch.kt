package com.robinrossner.receipts.data

/**
 * Port of `FuzzyMatch.swift` (rapidfuzz's `fuzz.token_sort_ratio`): sorts each string's tokens, then scores the
 * similarity with an Indel (insert/delete-only) edit distance normalised to 0-100. Used to attach a new item name to a
 * near-identical dictionary entry.
 */
object FuzzyMatch {
    /** Names scoring at least this attach to the existing dictionary entry (`ItemCategorizer.fuzzyMatchThreshold`). */
    const val THRESHOLD = 90

    fun tokenSortRatio(a: String, b: String): Int {
        val sortedA = sortedTokens(a)
        val sortedB = sortedTokens(b)
        val distance = indelDistance(sortedA, sortedB)
        val total = sortedA.size + sortedB.size
        if (total == 0) return 100
        // rounds half up, like Python's int(x + 0.5) in the backend
        return Math.floor(100.0 * (total - distance) / total + 0.5).toInt()
    }

    private fun sortedTokens(s: String): IntArray =
        s.split(' ').filter { it.isNotEmpty() }.sorted().joinToString(" ").codePoints().toArray()

    /** Levenshtein restricted to insertions and deletions (a substitution costs 2). */
    private fun indelDistance(a: IntArray, b: IntArray): Int {
        val n = a.size
        val m = b.size
        if (n == 0) return m
        if (m == 0) return n
        var previous = IntArray(m + 1) { it }
        var current = IntArray(m + 1)
        for (i in 1..n) {
            current[0] = i
            for (j in 1..m) {
                current[j] = if (a[i - 1] == b[j - 1]) previous[j - 1] else 1 + minOf(previous[j], current[j - 1])
            }
            val swap = previous; previous = current; current = swap
        }
        return previous[m]
    }

    /** The first best-scoring candidate (like `process.extractOne`) and its score; null without candidates. */
    fun bestMatch(query: String, among: List<String>): Pair<String, Int>? {
        var best: Pair<String, Int>? = null
        for (candidate in among) {
            val score = tokenSortRatio(query, candidate)
            if (best == null || score > best.second) best = candidate to score
        }
        return best
    }
}
