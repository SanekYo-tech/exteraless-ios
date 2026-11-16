import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Owned-fixture barriers run after actual descriptor operations, never instead
/// of them. Production supplies the empty hook.
struct PluginArchiveFileHooks: Sendable {
    enum Point: Sendable { case directoryOpened, captured, beforeUnlink }
    let body: @Sendable (Point, URL) throws -> Void
    init(_ body: @escaping @Sendable (Point, URL) throws -> Void = { _, _ in }) { self.body = body }
}

/// A native archive purge capability for the inodes captured before retirement.
/// It contains no interpreter/C-owner state and performs no pathname recursion.
public final class PluginArchiveCacheLease: @unchecked Sendable {
    private let lock = NSLock()
    private var purgeBody: (() throws -> Void)?

    private init(_ purge: @escaping () throws -> Void = {}) { purgeBody = purge }

    public func purge() throws {
        lock.lock(); defer { lock.unlock() }
        let body = purgeBody
        defer { purgeBody = nil } // all held descriptors close, including on failure
        try body?()
    }

    static func capture(root: URL, component: String, hooks: PluginArchiveFileHooks) throws -> PluginArchiveCacheLease {
        #if canImport(Darwin) || canImport(Glibc)
        let directory: ArchiveDirectory
        do {
            directory = try ArchiveDirectory.open(root, hooks: hooks)
                .child("cache").child(component).child("elyx")
        } catch let error as POSIXError where error.code == .ENOENT {
            return PluginArchiveCacheLease()
        }
        var budget = 36_864
        var owners: [ArchiveDirectory] = []
        var loads: [ArchiveLoadReceipt] = []
        for ownerName in try directory.names(maximum: budget) {
            guard isHex(ownerName, count: 64) else { throw archiveUnsafe("unknown archive owner entry") }
            let owner = try directory.child(ownerName)
            owners.append(owner)
            budget -= 1
            for loadName in try owner.names(maximum: budget) {
                let parts = loadName.split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count == 2, isHex(String(parts[0]), count: 64), isHex(String(parts[1]), count: 32) else {
                    throw archiveUnsafe("unknown archive load entry")
                }
                let load = try owner.child(loadName)
                budget -= 1
                loads.append(try ArchiveLoadReceipt.capture(load, budget: &budget))
            }
        }
        try directory.verify()
        try hooks.body(.captured, directory.url)
        // Verify once more after the barrier. Later purge rechecks the SAME fds.
        try directory.verify()
        return PluginArchiveCacheLease {
            for load in loads { try load.purge() }
            for owner in owners { try owner.removeIfEmpty() }
            try directory.removeIfEmpty()
        }
        #else
        throw BridgeFailure.unimplemented("Archive cleanup requires the POSIX directory-FD/O_NOFOLLOW backend")
        #endif
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

#if canImport(Darwin) || canImport(Glibc)
private func archiveUnsafe(_ detail: String) -> BridgeFailure {
    BridgeFailure.permission("Archive descriptor ownership: " + detail)
}

private func archiveIOError() -> Error {
    if errno == ELOOP || errno == ENOTDIR { return archiveUnsafe("symbolic link or non-directory component") }
    return POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

private struct ArchiveIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let kind: UInt32
    init(_ value: stat) {
        device = UInt64(truncatingIfNeeded: value.st_dev)
        inode = UInt64(truncatingIfNeeded: value.st_ino)
        kind = UInt32(value.st_mode) & UInt32(S_IFMT)
    }
}

private final class ArchiveDirectory {
    let fd: Int32
    let identity: ArchiveIdentity
    let parent: ArchiveDirectory?
    let name: String?
    let url: URL
    let hooks: PluginArchiveFileHooks
    private var aliases: [(String, ArchiveIdentity, String)] = []

    private init(fd: Int32, parent: ArchiveDirectory?, name: String?, url: URL, hooks: PluginArchiveFileHooks) throws {
        guard fd >= 0 else { throw archiveIOError() }
        var value = stat()
        guard fstat(fd, &value) == 0 else {
            let error = archiveIOError(); _ = close(fd); throw error
        }
        let identity = ArchiveIdentity(value)
        guard identity.kind == UInt32(S_IFDIR) else {
            _ = close(fd); throw archiveUnsafe("not a directory")
        }
        self.fd = fd; self.parent = parent; self.name = name; self.url = url; self.hooks = hooks
        self.identity = identity
    }

    deinit { _ = close(fd) }

    static func open(_ url: URL, hooks: PluginArchiveFileHooks) throws -> ArchiveDirectory {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"), url.path.utf8.count <= 4096 else {
            throw archiveUnsafe("invalid native anchor")
        }
        var components = url.path.split(separator: "/").map(String.init)
        guard components.allSatisfy(validComponent) else { throw archiveUnsafe("invalid native path component") }
        #if canImport(Darwin)
        let fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        #else
        let fd = Glibc.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        #endif
        let root = try ArchiveDirectory(fd: fd, parent: nil, name: nil, url: URL(fileURLWithPath: "/"), hooks: hooks)
        #if canImport(Darwin)
        // Only known aliases at the actual OS root are accepted. The fixed
        // /private target and every application/cache component remain nofollow.
        if let first = components.first, ["var", "tmp", "etc"].contains(first) {
            let link = try root.metadata(first)
            if ArchiveIdentity(link).kind == UInt32(S_IFLNK) {
                let target = try root.linkValue(first)
                guard target == "private/" + first || target == "/private/" + first else { throw archiveUnsafe("unexpected OS root alias") }
                root.aliases.append((first, ArchiveIdentity(link), target))
                components.insert("private", at: 0)
            }
        }
        #endif
        var current = root
        for component in components { current = try current.child(component) }
        try current.verify()
        return current
    }

    private static func validComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && name.utf8.count <= 255
    }

    func metadata(_ name: String) throws -> stat {
        guard Self.validComponent(name) else { throw archiveUnsafe("invalid relative component") }
        var value = stat()
        guard name.withCString({ fstatat(fd, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else { throw archiveIOError() }
        return value
    }

    private func linkValue(_ name: String) throws -> String {
        var bytes = [CChar](repeating: 0, count: 256)
        let count = bytes.withUnsafeMutableBufferPointer { buffer in
            name.withCString { readlinkat(fd, $0, buffer.baseAddress!, buffer.count) }
        }
        guard count > 0, count < bytes.count,
              let value = String(bytes: bytes.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
            throw archiveUnsafe("invalid OS root alias")
        }
        return value
    }

    func verify() throws {
        try parent?.verify()
        var value = stat()
        guard fstat(fd, &value) == 0, ArchiveIdentity(value) == identity else { throw archiveUnsafe("held descriptor changed") }
        if let parent, let name, try ArchiveIdentity(parent.metadata(name)) != identity {
            throw archiveUnsafe("directory binding changed")
        }
        for (name, expected, target) in aliases {
            guard ArchiveIdentity(try metadata(name)) == expected, try linkValue(name) == target else { throw archiveUnsafe("OS root alias changed") }
        }
    }

    func child(_ name: String) throws -> ArchiveDirectory {
        try verify()
        let expected = ArchiveIdentity(try metadata(name))
        guard expected.kind == UInt32(S_IFDIR) else { throw archiveUnsafe("symbolic link or special directory entry") }
        let descriptor = name.withCString { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        let child = try ArchiveDirectory(fd: descriptor, parent: self, name: name, url: url.appendingPathComponent(name), hooks: hooks)
        guard child.identity == expected else { throw archiveUnsafe("directory replaced during openat") }
        try child.verify()
        try hooks.body(.directoryOpened, child.url)
        try child.verify()
        return child
    }

    func names(maximum: Int) throws -> [String] {
        guard maximum >= 0 else { throw BridgeFailure.storage("Archive purge entry limit") }
        try verify()
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw archiveIOError() }
        guard let stream = fdopendir(duplicate) else {
            let error = archiveIOError(); _ = close(duplicate); throw error
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let count = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: count) { String(cString: $0) }
            }
            if name != "." && name != ".." {
                guard result.count < maximum, Self.validComponent(name) else { throw BridgeFailure.storage("Archive purge entry limit or invalid name") }
                result.append(name)
            }
            errno = 0
        }
        guard errno == 0 else { throw archiveIOError() }
        try verify()
        return result.sorted()
    }

    func remove(_ name: String, expected: ArchiveIdentity) throws {
        try hooks.body(.beforeUnlink, url.appendingPathComponent(name))
        try verify()
        let current: stat
        do { current = try metadata(name) }
        catch let error as POSIXError where error.code == .ENOENT { return }
        guard ArchiveIdentity(current) == expected else { throw archiveUnsafe("refusing to erase a replacement inode") }
        let flags = expected.kind == UInt32(S_IFDIR) ? AT_REMOVEDIR : 0
        if name.withCString({ unlinkat(fd, $0, flags) }) != 0 {
            // Unknown/new entries were not captured by this lease. Retain their
            // nonempty parent, rather than recursively erasing a new generation.
            if expected.kind == UInt32(S_IFDIR), errno == ENOTEMPTY || errno == EEXIST { return }
            throw archiveIOError()
        }
        try verify()
    }

    func removeIfEmpty() throws {
        guard let parent, let name else { throw archiveUnsafe("cannot remove the OS anchor") }
        do { try verify() }
        catch let error as POSIXError where error.code == .ENOENT { return }
        try parent.remove(name, expected: identity)
    }
}

private struct ArchiveLoadReceipt {
    let directory: ArchiveDirectory
    let entries: [String: ArchiveIdentity]

    static func capture(_ directory: ArchiveDirectory, budget: inout Int) throws -> ArchiveLoadReceipt {
        var result: [String: ArchiveIdentity] = [:]
        func visit(_ parent: ArchiveDirectory, prefix: String, depth: Int, budget: inout Int) throws {
            guard depth <= 20 else { throw BridgeFailure.storage("Archive purge depth limit") }
            for name in try parent.names(maximum: budget) {
                budget -= 1
                let identity = ArchiveIdentity(try parent.metadata(name))
                result[prefix + name] = identity
                if identity.kind == UInt32(S_IFDIR) {
                    try visit(parent.child(name), prefix: prefix + name + "/", depth: depth + 1, budget: &budget)
                }
            }
        }
        try visit(directory, prefix: "", depth: 0, budget: &budget)
        return ArchiveLoadReceipt(directory: directory, entries: result)
    }

    func purge() throws {
        do { try directory.verify() }
        catch let error as POSIXError where error.code == .ENOENT { return }
        for path in entries.keys.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            let parts = path.split(separator: "/").map(String.init)
            var parent = directory
            var prefix = ""
            do {
                for name in parts.dropLast() {
                    parent = try parent.child(name)
                    prefix += name
                    guard let expected = entries[prefix], parent.identity == expected else { throw archiveUnsafe("purge directory generation changed") }
                    prefix += "/"
                }
                try parent.remove(parts.last!, expected: entries[path]!)
            } catch let error as POSIXError where error.code == .ENOENT { continue }
        }
        try directory.removeIfEmpty()
    }
}
#endif
