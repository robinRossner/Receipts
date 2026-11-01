#if os(macOS)  // the iPhone has no Claude CLI provider
import XCTest
@testable import ReceiptsApp

/// Opt-in check against the real model: `RECEIPTS_LIVE_CLAUDE=1 swift test --filter LiveClassificationTests`.
/// Runs the real classification code through the local `claude` CLI login (ClaudeModel: Haiku, high effort) on a
/// temp database and prints what was flagged. Skipped otherwise: it makes real model calls.
final class LiveClassificationTests: XCTestCase {
    func testRealModelFlagsMissingCategoriesAndLeavesCommonGroceriesAlone() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["RECEIPTS_LIVE_CLAUDE"] == "1", "set RECEIPTS_LIVE_CLAUDE=1 to call the real model")
        let binary = try XCTUnwrap(ClaudeCLILocator.resolve(configured: env["RECEIPTS_CLAUDE_PATH"] ?? ""), "claude CLI not found")
        let provider = ClaudeCLIProvider(authMode: .existingLogin, binaryPath: binary, oauthToken: nil)
        let taxonomy = Taxonomy.load()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = ["Vinzenz E Fleisch", "Müller's Berglinsen", "Milch", "Bananen", "Spülmittel"]

        // Straight through the LLM step (no dictionary or keyword rules), then through the whole resolver on a temp DB.
        let direct = try await ItemCategorizer.classifyWithLLM(
            itemNames: names, taxonomy: taxonomy, storeName: "Edeka", logURL: dir.appendingPathComponent("log.jsonl"), provider: provider)
        let db = try openTempDatabase(in: dir)
        let resolved = try await ItemCategorizer.resolveItems(
            db: db, rawNames: names, taxonomy: taxonomy, storeName: "Edeka", logURL: dir.appendingPathComponent("log2.jsonl"), provider: provider)
        print("LIVE providers: \(direct.providerIds)")
        for (name, c) in zip(names, direct.results) {
            print("LIVE classify \(name) -> \(c.category) > \(c.subcategory) > \(c.itemGroup) flagged=\(c.categoryFlagged) review=\(c.needsReview) suggestion=\(c.suggestedCategory ?? "-")/\(c.suggestedParent ?? "-")")
        }
        for e in resolved.entries {
            print("LIVE dictionary \(e.canonicalName) -> \(e.category) > \(e.subcategory) > \(e.itemGroup) flagged=\(e.categoryFlagged)")
        }
        let log = (try? String(contentsOf: dir.appendingPathComponent("log2.jsonl"), encoding: .utf8)) ?? ""
        for line in log.split(separator: "\n") { print("LIVE log \(line.prefix(260))") }
        for c in direct.results.suffix(3) { XCTAssertFalse(c.categoryFlagged, "common grocery flagged: \(c)") }
    }
}
#endif
