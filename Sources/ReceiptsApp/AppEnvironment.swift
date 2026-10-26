import Foundation

/// Where the app keeps its data - `~/Library/Application Support/ReceiptsApp/`, the standard
/// macOS location, rather than inside the app bundle or wherever the project folder happens to
/// live (that's what `Receipts_process` on Desktop did, since it was just a folder of scripts).
struct AppEnvironment: Sendable {
    let appSupportDir: URL
    let dbPath: String
    let archiveDir: URL
    let debugDir: URL
    let logDir: URL
    let classificationLogURL: URL

    static func bootstrap() -> AppEnvironment {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ReceiptsApp", isDirectory: true)
        let archive = base.appendingPathComponent("receipts_archive", isDirectory: true)
        let debug = base.appendingPathComponent("debug_output", isDirectory: true)
        let logs = base.appendingPathComponent("logs", isDirectory: true)
        for dir in [base, archive, debug, logs] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return AppEnvironment(
            appSupportDir: base,
            dbPath: base.appendingPathComponent("receipts.db").path,
            archiveDir: archive,
            debugDir: debug,
            logDir: logs,
            classificationLogURL: base.appendingPathComponent("classification_log.jsonl")
        )
    }
}
