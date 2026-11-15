import Darwin
import Foundation

struct RetentionFileSystem {
    var synchronizeFile: (FileHandle, URL) throws -> Void = { handle, _ in try handle.synchronize() }
    var synchronizeDirectory: (URL) throws -> Void = { url in
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw ExteralessRetentionError.mediaIO }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw ExteralessRetentionError.mediaIO }
    }

    func synchronizeChain(from directory: URL, through root: URL) throws {
        let root = root.standardizedFileURL
        var current = directory.standardizedFileURL
        guard root.isFileURL, current.pathComponents.starts(with: root.pathComponents) else { throw ExteralessRetentionError.mediaIO }
        var chain: [URL] = []
        while true {
            var info = stat()
            guard lstat(current.path, &info) == 0, (UInt32(info.st_mode) & UInt32(S_IFMT)) == UInt32(S_IFDIR) else { throw ExteralessRetentionError.mediaIO }
            chain.append(current)
            if current.path == root.path { break }
            let parent = current.deletingLastPathComponent()
            guard parent != current else { throw ExteralessRetentionError.mediaIO }
            current = parent
        }
        // Child contents, its link in the parent, then every newly created ancestor link.
        for url in chain { try self.synchronizeDirectory(url) }
    }
}

/// The lock inode lives outside the vault and is never unlinked by retention reset.
/// Only file workers acquire it. A Postbox transaction must never wait on this lock.
final class RetentionFileLock: Sendable {
    private let path: String
    init(accountRoot: URL) { self.path = accountRoot.appendingPathComponent(".exteraless-retention.lock").path }

    func withLock<T>(cancelled: () -> Bool, _ body: () throws -> T) throws -> T {
        let fd = Darwin.open(self.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { throw ExteralessRetentionError.mediaIO }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (UInt32(info.st_mode) & UInt32(S_IFMT)) == UInt32(S_IFREG), info.st_nlink == 1 else { throw ExteralessRetentionError.mediaIO }
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if cancelled() { throw ExteralessRetentionError.cancelled }
            guard errno == EWOULDBLOCK || errno == EAGAIN, ProcessInfo.processInfo.systemUptime < deadline else { throw ExteralessRetentionError.mediaIO }
            usleep(10_000)
        }
        defer { flock(fd, LOCK_UN) }
        if cancelled() { throw ExteralessRetentionError.cancelled }
        return try body()
    }
}
