import Darwin
import Foundation

/// File access of the photo archive, behind a protocol so tests can simulate a full disk or a corrupted read-back.
protocol ArchiveFileSystem: Sendable {
    func writeAtomically(_ data: Data, to url: URL) throws
    func read(_ url: URL) throws -> Data
    func exists(_ url: URL) -> Bool
    func remove(_ url: URL)
}

struct DiskFileSystem: ArchiveFileSystem {
    func writeAtomically(_ data: Data, to url: URL) throws { try AtomicFile.write(data, to: url) }
    func read(_ url: URL) throws -> Data { try Data(contentsOf: url, options: .uncached) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

enum AtomicFile {
    struct WriteError: Error, LocalizedError {
        let operation: String
        let path: String
        let errnoValue: Int32
        var isDiskFull: Bool { errnoValue == ENOSPC || errnoValue == EDQUOT }
        var errorDescription: String? {
            "\(operation) \(path): \(String(cString: strerror(errnoValue)))" + (isDiskFull ? " (disk full)" : "")
        }
    }

    /// Writes `data` so that `url` is either the old file or the complete new one, never a partial one: temp file
    /// in the same folder, `F_FULLFSYNC` (the data really reached the disk), `rename` over the target, then the
    /// folder is synced so the rename itself survives a crash. On any failure the temp file is removed and an
    /// existing target is left untouched.
    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).part")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw WriteError(operation: "create", path: temp.path, errnoValue: errno) }
        var finished = false
        var closed = false
        defer {
            if !closed { close(fd) }
            if !finished { unlink(temp.path) }
        }

        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw WriteError(operation: "write", path: temp.path, errnoValue: errno)
                }
                offset += n
            }
        }
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            throw WriteError(operation: "sync", path: temp.path, errnoValue: errno)
        }
        closed = true
        guard close(fd) == 0 else { throw WriteError(operation: "close", path: temp.path, errnoValue: errno) }
        guard rename(temp.path, url.path) == 0 else { throw WriteError(operation: "rename to", path: url.path, errnoValue: errno) }
        finished = true
        syncDirectory(dir)
    }

    private static func syncDirectory(_ dir: URL) {
        let fd = open(dir.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_FULLFSYNC)
        close(fd)
    }
}
