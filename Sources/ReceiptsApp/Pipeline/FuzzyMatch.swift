import Foundation

/// A Swift stand-in for rapidfuzz's `fuzz.token_sort_ratio` (there's no Swift equivalent
/// library, and pulling one in would add a network-resolved SPM dependency). Sorts each
/// string's tokens alphabetically, then scores similarity via an Indel (insert/delete-only)
/// edit distance normalized to 0-100 - the same formula rapidfuzz's `fuzz.ratio` uses
/// internally, so this should track it closely for the near-duplicate German grocery item
/// names it's actually applied to.
enum FuzzyMatch {
    static func tokenSortRatio(_ a: String, _ b: String) -> Int {
        let sortedA = Array(sortedTokens(a))
        let sortedB = Array(sortedTokens(b))
        let distance = indelDistance(sortedA, sortedB)
        let total = sortedA.count + sortedB.count
        guard total > 0 else { return 100 }
        return Int((100.0 * Double(total - distance) / Double(total)).rounded())
    }

    private static func sortedTokens(_ s: String) -> String {
        s.split(separator: " ").sorted().joined(separator: " ")
    }

    /// Levenshtein distance restricted to insertions/deletions (substitution costs 2, i.e.
    /// delete + insert) - this is what makes it "Indel" distance rather than plain Levenshtein.
    private static func indelDistance(_ a: [Character], _ b: [Character]) -> Int {
        let n = a.count, m = b.count
        if n == 0 { return m }
        if m == 0 { return n }
        var previousRow = Array(0...m)
        var currentRow = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            currentRow[0] = i
            for j in 1...m {
                if a[i - 1] == b[j - 1] {
                    currentRow[j] = previousRow[j - 1]
                } else {
                    currentRow[j] = 1 + min(previousRow[j], currentRow[j - 1])
                }
            }
            previousRow = currentRow
        }
        return previousRow[m]
    }

    /// Mirrors `process.extractOne(..., scorer=fuzz.token_sort_ratio)`.
    static func bestMatch(_ query: String, among candidates: [String]) -> (match: String, score: Int)? {
        var best: (String, Int)?
        for candidate in candidates {
            let score = tokenSortRatio(query, candidate)
            if best == nil || score > best!.1 {
                best = (candidate, score)
            }
        }
        return best
    }
}
