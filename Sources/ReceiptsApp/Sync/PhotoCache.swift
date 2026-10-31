import Foundation

/// The phone's bounded local copy of receipt photos (`photo_cache/<uuid>.jpg|png`). It is only a convenience for
/// showing photos offline: the permanent archive is the laptop. When the total exceeds `maxBytes` the oldest files
/// (by modification time) are removed first; the newest file is always kept.
struct PhotoCache: Sendable {
    let dir: URL
    let maxBytes: Int

    private var fm: FileManager { .default }

    static func fileExtension(mediaType: String?) -> String { PhotoArchiver.fileExtension(mediaType: mediaType) }

    func fileURL(uuid: String, mediaType: String?) -> URL {
        dir.appendingPathComponent("\(uuid).\(Self.fileExtension(mediaType: mediaType))")
    }

    private func ensureDir() { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }

    /// Moves an existing file (the prepared upload) into the cache.
    @discardableResult
    func adopt(_ file: URL, uuid: String, mediaType: String?) throws -> URL {
        ensureDir()
        let dest = fileURL(uuid: uuid, mediaType: mediaType)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: file, to: dest)
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
        trim()
        return dest
    }

    @discardableResult
    func write(_ data: Data, uuid: String, mediaType: String?) throws -> URL {
        ensureDir()
        let dest = fileURL(uuid: uuid, mediaType: mediaType)
        try AtomicFile.write(data, to: dest)
        trim()
        return dest
    }

    private func entries() -> [(url: URL, bytes: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return (url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }
    }

    var totalBytes: Int { entries().reduce(0) { $0 + $1.bytes } }
    var count: Int { entries().count }

    /// Removes the oldest files until the cache fits; returns the uuids (file names) removed.
    @discardableResult
    func trim() -> [String] {
        var all = entries().sorted { $0.date < $1.date }
        var total = all.reduce(0) { $0 + $1.bytes }
        var removed: [String] = []
        while total > maxBytes, all.count > 1 {
            let oldest = all.removeFirst()
            if (try? fm.removeItem(at: oldest.url)) != nil {
                total -= oldest.bytes
                removed.append(oldest.url.deletingPathExtension().lastPathComponent)
            }
        }
        return removed
    }

    /// Deletes every cached photo ("Clear cached photos").
    func removeAll() {
        for e in entries() { try? fm.removeItem(at: e.url) }
    }
}
