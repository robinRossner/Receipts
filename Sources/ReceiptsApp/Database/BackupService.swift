import Foundation

enum BackupError: Error, LocalizedError {
    case zipFailed(String)
    var errorDescription: String? {
        switch self {
        case .zipFailed(let msg): return "Creating the zip failed: \(msg)"
        }
    }
}

/// Zip backups of the database (consistent snapshot via VACUUM INTO) plus the image archive.
/// Restore is deliberately not offered: swapping the DB under the open connection is unsafe.
enum BackupService {
    enum Keys {
        static let autoEnabled = "autoBackupEnabled"
        static let autoFolder = "autoBackupFolder"
        static let lastBackup = "lastBackupDate"
    }
    static let keepCount = 5
    static let interval: TimeInterval = 7 * 24 * 3600
    static let filePrefix = "ReceiptsBackup-"

    static var lastBackupDate: Date? {
        let t = UserDefaults.standard.double(forKey: Keys.lastBackup)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Writes `ReceiptsBackup-<stamp>.zip` into `folder` and returns its URL.
    @discardableResult
    static func createBackup(db: Database, env: AppEnvironment, intoFolder folder: URL) async throws -> URL {
        let fm = FileManager.default
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd-HHmmss"
            return f.string(from: Date())
        }()
        let name = filePrefix + stamp
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stage = tmp.appendingPathComponent(name, isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)

        // Consistent snapshot of the live DB (also compacts it).
        let snapshot = stage.appendingPathComponent("receipts.db").path.replacingOccurrences(of: "'", with: "''")
        try await db.run("VACUUM INTO '\(snapshot)'")
        if fm.fileExists(atPath: env.archiveDir.path) {
            try fm.copyItem(at: env.archiveDir, to: stage.appendingPathComponent("receipts_archive", isDirectory: true))
        }

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent(name + ".zip")
        try await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--keepParent", stage.path, zip.path]
            let err = Pipe()
            p.standardError = err
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "exit \(p.terminationStatus)"
                throw BackupError.zipFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.lastBackup)
        return zip
    }

    /// Deletes all but the newest `keep` of our own `ReceiptsBackup-*.zip` files in the folder.
    static func prune(folder: URL, keep: Int = keepCount) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        let ours = files.filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".zip") }.sorted()   // stamp sorts chronologically
        for old in ours.dropLast(keep) { try? fm.removeItem(at: folder.appendingPathComponent(old)) }
    }
}
