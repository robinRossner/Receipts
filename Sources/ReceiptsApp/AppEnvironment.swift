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

    /// Environment variable that moves the whole data directory (tests, e2e runs). Unset = the real
    /// `~/Library/Application Support/ReceiptsApp/`.
    static let dataDirEnvVar = "RECEIPTS_APP_DATA_DIR"

    static func bootstrap(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppEnvironment {
        let base: URL
        if let override = environment[dataDirEnvVar], !override.isEmpty {
            base = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("ReceiptsApp", isDirectory: true)
        }
        return make(baseDir: base)
    }

    /// Creates the folder layout below `baseDir` and returns the environment for it.
    static func make(baseDir base: URL) -> AppEnvironment {
        let fm = FileManager.default
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

    /// The folders the sync code works with.
    var syncPaths: SyncPaths { SyncPaths(appSupportDir: appSupportDir, archiveDir: archiveDir) }

    /// `source_image` is stored relative to the app-support dir (e.g. `receipts_archive/2026/07/x.jpg`); older rows (and receipts whose
    /// image move failed and still sit in staging) hold absolute paths, which pass through.
    func resolveImagePath(_ stored: String?) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        if stored.hasPrefix("/") { return stored }
        return appSupportDir.appendingPathComponent(stored).path
    }

    /// Inverse of `resolveImagePath` for files inside the app-support dir; anything outside stays absolute.
    func storedImagePath(for absolutePath: String) -> String {
        let prefix = appSupportDir.path.hasSuffix("/") ? appSupportDir.path : appSupportDir.path + "/"
        return absolutePath.hasPrefix(prefix) ? String(absolutePath.dropFirst(prefix.count)) : absolutePath
    }
}
