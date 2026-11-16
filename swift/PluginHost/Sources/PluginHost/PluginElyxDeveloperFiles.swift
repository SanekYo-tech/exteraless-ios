import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc

// Linux's atomic exchange/no-replace ABI, independent of Swift Glibc's feature
// macro projection. No shell, link/unlink approximation or pathname fallback.
@_silgen_name("renameat2")
private func elyxRenameAt2(_ fromFD: Int32, _ from: UnsafePointer<CChar>, _ toFD: Int32,
                           _ to: UnsafePointer<CChar>, _ flags: UInt32) -> Int32
@_silgen_name("inotify_init1")
private func elyxInotifyInit(_ flags: Int32) -> Int32
@_silgen_name("inotify_add_watch")
private func elyxInotifyWatch(_ fd: Int32, _ path: UnsafePointer<CChar>, _ mask: UInt32) -> Int32
#endif

/// Deterministic native-fixture barriers; production uses the actual syscalls.
public struct PluginElyxDeveloperFileHooks: Sendable {
    public enum Point: Sendable {
        case directoryOpened, sourceCaptured, stageCreated, candidateSealed, inspectionFinished
        case beforeExchange, afterExchange, beforeDirectorySync, committed, beforeCleanup, cleanupLookup
    }
    let body: @Sendable (Point, URL) throws -> Void
    // Native syscall fault injection for owned durability tests only. Production
    // defaults to the actual fsync operation, with no injected implementation.
    let directorySync: (@Sendable (Int32) throws -> Void)?
    public init(_ body: @escaping @Sendable (Point, URL) throws -> Void = { _, _ in },
                directorySync: (@Sendable (Int32) throws -> Void)? = nil) {
        self.body = body; self.directorySync = directorySync
    }
}

/// Publication has an explicit commit boundary. Callers must not describe a
/// durability/recovery error as a refused/no-write operation or a successful load.
public struct PluginElyxDeveloperPublicationFailure: Error, Sendable, CustomStringConvertible {
    public enum Outcome: String, Sendable { case refused, rolledBack, committed, recoveryRequired }
    public let outcome: Outcome
    public let detail: String
    public let kind: String
    public init(outcome: Outcome, detail: String, underlying: (any Error)? = nil) {
        self.outcome = outcome; self.detail = detail
        kind = underlying.map { PluginElyxDeveloperOperationFailure($0, pluginId: nil, outcome: nil).kind } ?? "PublicationFailure"
    }
    public var sourceChanged: Bool? {
        switch outcome {
        case .refused, .rolledBack: return false
        case .committed: return true
        case .recoveryRequired: return nil
        }
    }
    public var description: String { "Elyx publication \(outcome.rawValue): \(detail)" }
}

/// The real native developer file authority. Staging is a private sibling of
/// plugins/, outside cache/<plugin>/elyx; an old archive unload cannot sweep it.
public final class PluginElyxDeveloperFiles: PluginElyxDeveloperFileAuthority, @unchecked Sendable {
    public let activity = PluginElyxDeveloperFileActivity()
    #if canImport(Darwin) || canImport(Glibc)
    private let state: ElyxFileState
    #endif

    /// currentTarget checks the captured owner/model/consent before staging;
    /// currentConsent checks consent after Host deliberately retires that owner
    /// and publishes changed metadata. Host's own mutation reservation checks the
    /// model transition. Neither closure is a Python-supplied policy/capability.
    public init(pluginsDirectory: URL, registry: PluginElyxDeveloperDescriptorRegistry,
                bridge: PluginElyxDeveloperDescriptorBridge,
                currentTarget: @escaping @Sendable (PluginElyxDeveloperTarget) -> Bool,
                currentConsent: @escaping @Sendable (PluginElyxDeveloperTarget) -> Bool,
                diagnostic: @escaping @Sendable (String) -> Void,
                hooks: PluginElyxDeveloperFileHooks = .init()) throws {
        _ = try bridge.requireReady(registry)
        #if canImport(Darwin) || canImport(Glibc)
        state = try ElyxFileState(directory: pluginsDirectory, registry: registry, bridge: bridge,
            currentTarget: currentTarget, currentConsent: currentConsent, diagnostic: diagnostic, hooks: hooks, activity: activity)
        #else
        throw PluginElyxDeveloperError.unavailable("native Elyx files require Darwin/Linux directory-FD syscalls")
        #endif
    }

    public func open(_ target: PluginElyxDeveloperTarget) throws -> any PluginElyxDeveloperSource {
        #if canImport(Darwin) || canImport(Glibc)
        return try state.open(target)
        #else
        throw PluginElyxDeveloperError.unavailable("native Elyx files require Darwin/Linux directory-FD syscalls")
        #endif
    }
}

/// Data-only observation survives provider retirement without retaining any fd.
public final class PluginElyxDeveloperFileActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var sources = 0
    private var stages = 0
    private var authorities = 0
    public var snapshot: (sources: Int, stages: Int) { lock.lock(); defer { lock.unlock() }; return (sources, stages) }
    public var authorityCount: Int { lock.lock(); defer { lock.unlock() }; return authorities }
    fileprivate func source(_ delta: Int) { lock.lock(); sources += delta; lock.unlock() }
    fileprivate func stage(_ delta: Int) { lock.lock(); stages += delta; lock.unlock() }
    fileprivate func authority(_ delta: Int) { lock.lock(); authorities += delta; lock.unlock() }
}

#if canImport(Darwin) || canImport(Glibc)
private func elyxIO(_ operation: String) -> Error {
    let code = errno
    if code == ELOOP || code == ENOTDIR { return PluginElyxDeveloperError.stale("\(operation): redirected/non-directory entry") }
    return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(operation): errno \(code)"])
}

private struct ElyxIdentity: Equatable, Sendable {
    let device: UInt64, inode: UInt64, kind: UInt32
    init(_ value: stat) {
        device = UInt64(truncatingIfNeeded: value.st_dev); inode = UInt64(truncatingIfNeeded: value.st_ino)
        kind = UInt32(value.st_mode) & UInt32(S_IFMT)
    }
}

private struct ElyxVersion: Equatable, Sendable {
    let identity: ElyxIdentity
    let size: Int64, links: UInt64, mode: UInt32
    let modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64
    init(_ value: stat) {
        identity = ElyxIdentity(value); size = Int64(value.st_size)
        links = UInt64(value.st_nlink); mode = UInt32(value.st_mode)
        #if canImport(Darwin)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
        #else
        modifiedSeconds = Int64(value.st_mtim.tv_sec); modifiedNanos = Int64(value.st_mtim.tv_nsec)
        changedSeconds = Int64(value.st_ctim.tv_sec); changedNanos = Int64(value.st_ctim.tv_nsec)
        #endif
    }
    /// rename updates ctime; both sides' full versions are checked BEFORE exchange.
    func matchesRenamed(_ other: Self) -> Bool {
        identity == other.identity && size == other.size && links == other.links && mode == other.mode
            && modifiedSeconds == other.modifiedSeconds && modifiedNanos == other.modifiedNanos
    }
}

private final class ElyxFD: @unchecked Sendable {
    let raw: Int32
    init(_ value: Int32) throws { guard value >= 0 else { throw elyxIO("open descriptor") }; raw = value }
    deinit { _ = close(raw) } // Never retry close(EINTR) on a possibly recycled fd.
    func metadata() throws -> ElyxVersion {
        var value = stat()
        guard fstat(raw, &value) == 0 else { throw elyxIO("fstat") }
        return ElyxVersion(value)
    }
}

private final class ElyxDirectory: @unchecked Sendable {
    let fd: ElyxFD
    let identity: ElyxIdentity
    let parent: ElyxDirectory?
    let name: String?
    let url: URL
    private let aliases: [(String, ElyxVersion, String)]

    private init(fd: ElyxFD, parent: ElyxDirectory?, name: String?, url: URL,
                 aliases: [(String, ElyxVersion, String)] = []) throws {
        let value = try fd.metadata()
        guard value.identity.kind == UInt32(S_IFDIR) else { throw PluginElyxDeveloperError.stale("held fd is not a directory") }
        self.fd = fd; identity = value.identity; self.parent = parent; self.name = name; self.url = url; self.aliases = aliases
    }

    static func component(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255 && !name.contains("/") && !name.contains("\0")
    }

    static func open(_ url: URL, hooks: PluginElyxDeveloperFileHooks) throws -> ElyxDirectory {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), !url.path.contains("\0"), url.path.utf8.count <= 4096 else {
            throw PluginElyxDeveloperError.malformed("invalid native installation root")
        }
        var parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy(component) else { throw PluginElyxDeveloperError.malformed("unsafe native root components") }
        #if canImport(Darwin)
        let rootFD = try ElyxFD(Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        #else
        let rootFD = try ElyxFD(Glibc.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        #endif
        var pins: [(String, ElyxVersion, String)] = []
        #if canImport(Darwin)
        if let first = parts.first, ["var", "tmp", "etc"].contains(first) {
            let value = try metadata(rootFD.raw, first)
            if value.identity.kind == UInt32(S_IFLNK) {
                let target = try link(rootFD.raw, first)
                guard target == "private/" + first || target == "/private/" + first else {
                    throw PluginElyxDeveloperError.stale("unexpected trusted OS-root alias")
                }
                pins.append((first, value, target)); parts.insert("private", at: 0)
            }
        }
        #endif
        var current = try ElyxDirectory(fd: rootFD, parent: nil, name: nil, url: URL(fileURLWithPath: "/"), aliases: pins)
        for part in parts {
            current = try current.child(part)
            try hooks.body(.directoryOpened, current.url)
            try current.verify()
        }
        return current
    }

    static func metadata(_ fd: Int32, _ name: String) throws -> ElyxVersion {
        guard component(name) else { throw PluginElyxDeveloperError.malformed("invalid FD-relative component") }
        var value = stat()
        guard name.withCString({ fstatat(fd, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else { throw elyxIO("fstatat") }
        return ElyxVersion(value)
    }

    private static func link(_ fd: Int32, _ name: String) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = bytes.withUnsafeMutableBytes { buffer in name.withCString { readlinkat(fd, $0, buffer.baseAddress!.assumingMemoryBound(to: CChar.self), buffer.count) } }
        guard count > 0, count < bytes.count, let value = String(bytes: bytes.prefix(count), encoding: .utf8) else {
            throw PluginElyxDeveloperError.stale("invalid OS-root alias")
        }
        return value
    }

    func metadata(_ name: String) throws -> ElyxVersion { try Self.metadata(fd.raw, name) }

    func verify() throws {
        try parent?.verify()
        guard try fd.metadata().identity == identity else { throw PluginElyxDeveloperError.stale("held directory inode changed") }
        if let parent, let name, try parent.metadata(name).identity != identity {
            throw PluginElyxDeveloperError.stale("native directory namespace binding changed")
        }
        for (name, version, value) in aliases {
            guard try metadata(name) == version, try Self.link(fd.raw, name) == value else {
                throw PluginElyxDeveloperError.stale("trusted OS-root alias changed")
            }
        }
    }

    func child(_ name: String, create: Bool = false) throws -> ElyxDirectory {
        guard Self.component(name) else { throw PluginElyxDeveloperError.malformed("invalid directory component") }
        try verify()
        if create {
            let result = name.withCString { mkdirat(fd.raw, $0, 0o700) }
            guard result == 0 || errno == EEXIST else { throw elyxIO("mkdirat staging root") }
        }
        let expected = try metadata(name)
        guard expected.identity.kind == UInt32(S_IFDIR), !create || expected.mode & 0o077 == 0 else {
            throw PluginElyxDeveloperError.stale("staging/directory is redirected or has unsafe permissions")
        }
        let child = try ElyxDirectory(fd: ElyxFD(name.withCString { openat(fd.raw, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }),
                                      parent: self, name: name, url: url.appendingPathComponent(name, isDirectory: true))
        guard try child.fd.metadata() == expected else { throw PluginElyxDeveloperError.stale("directory replaced during openat") }
        try child.verify()
        return child
    }

    func chain() -> [ElyxDirectory] { (parent?.chain() ?? []) + [self] }
    func synchronize() throws { guard fsync(fd.raw) == 0 else { throw elyxIO("fsync directory") } }
    func isEmpty() throws -> Bool {
        try verify()
        let copy = dup(fd.raw)
        guard copy >= 0 else { throw elyxIO("dup staging directory") }
        guard let stream = fdopendir(copy) else { let error = elyxIO("fdopendir staging"); _ = close(copy); throw error }
        defer { closedir(stream) }
        rewinddir(stream)
        errno = 0
        while let entry = readdir(stream) {
            let width = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: width) { String(cString: $0) }
            }
            if name != "." && name != ".." { return false }
            errno = 0
        }
        guard errno == 0 else { throw elyxIO("readdir staging") }
        try verify()
        return true
    }
}

/// Namespace-self rename/delete/revoke observation, independent of ordinary
/// metadata writes in ancestor directories (Host persists plugins.json there).
/// Polling a held kernel notification fd is synchronous; no thread is spawned.
private final class ElyxNamespaceWatch: @unchecked Sendable {
    private let fd: ElyxFD
    private let lock = NSLock()
    private var revoked = false

    init(_ directories: [ElyxDirectory]) throws {
        #if canImport(Darwin)
        fd = try ElyxFD(kqueue())
        guard fcntl(fd.raw, F_SETFD, FD_CLOEXEC) == 0 else { throw elyxIO("seal namespace watch fd") }
        for directory in directories {
            var event = kevent()
            event.ident = UInt(directory.fd.raw)
            event.filter = Int16(EVFILT_VNODE)
            event.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR)
            event.fflags = UInt32(NOTE_RENAME | NOTE_DELETE | NOTE_REVOKE)
            guard Darwin.kevent(fd.raw, &event, 1, nil, 0, nil) == 0 else { throw elyxIO("watch native directory") }
        }
        #else
        fd = try ElyxFD(elyxInotifyInit(O_NONBLOCK | O_CLOEXEC))
        for directory in directories {
            // A kernel-owned fd magic link selects the already held inode, not
            // a caller path or application symlink. No pathname is reopened.
            let path = "/proc/self/fd/\(directory.fd.raw)"
            guard path.withCString({ elyxInotifyWatch(fd.raw, $0, 0x01000000 | 0x400 | 0x800) }) >= 0 else {
                throw elyxIO("watch native directory inode")
            }
        }
        #endif
    }

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if revoked { throw PluginElyxDeveloperError.stale("native directory namespace was renamed/revoked") }
        #if canImport(Darwin)
        var events = [kevent](repeating: kevent(), count: 32)
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        while true {
            let count = events.withUnsafeMutableBufferPointer {
                Darwin.kevent(fd.raw, nil, 0, $0.baseAddress, Int32($0.count), &timeout)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { revoked = true; throw elyxIO("poll native directory watch") }
            if count == 0 { break }
            if events.prefix(Int(count)).contains(where: {
                $0.flags & UInt16(EV_ERROR) != 0 || $0.fflags & UInt32(NOTE_RENAME | NOTE_DELETE | NOTE_REVOKE) != 0
            }) { revoked = true; break }
        }
        #else
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd.raw, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { break }
            guard count > 0 else { revoked = true; throw elyxIO("poll native namespace watch") }
            var offset = 0
            while offset + 16 <= count {
                let mask = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self) }
                let length = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self) }
                guard Int(length) <= count - offset - 16 else { revoked = true; break }
                if mask & (0x400 | 0x800 | 0x2000 | 0x4000 | 0x8000) != 0 { revoked = true }
                offset += 16 + Int(length)
            }
            if offset != count { revoked = true }
            if revoked { break }
        }
        #endif
        if revoked { throw PluginElyxDeveloperError.stale("native directory namespace was renamed/revoked") }
    }
}

/// Continuous namespace observation detects ancestor ABA while allowing Host's
/// ordinary metadata writes. The installation directory's own content version
/// also stays pinned, except for this operation's validated atomic publication.
private struct ElyxNamespace: Sendable {
    let entries: [(ElyxDirectory, ElyxVersion)]
    let watch: ElyxNamespaceWatch
    init(_ root: ElyxDirectory) throws {
        watch = try ElyxNamespaceWatch(root.chain())
        entries = try root.chain().map { ($0, try $0.fd.metadata()) }
        try verify()
    }
    private init(entries: [(ElyxDirectory, ElyxVersion)], watch: ElyxNamespaceWatch) { self.entries = entries; self.watch = watch }
    func verify(allowLeafMutation: Bool = false) throws {
        try watch.check()
        for (index, pair) in entries.enumerated() {
            try pair.0.verify()
            if !allowLeafMutation && index == entries.count - 1 {
                guard try pair.0.fd.metadata() == pair.1 else { throw PluginElyxDeveloperError.stale("native namespace version changed") }
            }
        }
        try watch.check()
    }
    func afterOwnPublication() throws -> ElyxNamespace {
        try verify(allowLeafMutation: true)
        var updated = entries
        guard let last = updated.last else { throw PluginElyxDeveloperError.stale("empty native namespace") }
        updated[updated.count - 1] = (last.0, try last.0.fd.metadata())
        let next = ElyxNamespace(entries: updated, watch: watch)
        try next.verify()
        return next
    }
}

private final class ElyxReadFile: @unchecked Sendable {
    let directory: ElyxDirectory, name: String, fd: ElyxFD, version: ElyxVersion
    init(_ directory: ElyxDirectory, _ name: String) throws {
        try directory.verify()
        let before = try directory.metadata(name)
        guard before.identity.kind == UInt32(S_IFREG), before.links == 1,
              before.size > 0, before.size <= PluginElyxArchiveCandidate.maximumBytes else {
            throw PluginElyxDeveloperError.stale("archive must be a bounded, singly-linked regular file")
        }
        let file = try ElyxFD(name.withCString { openat(directory.fd.raw, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) })
        guard try file.metadata() == before else { throw PluginElyxDeveloperError.stale("archive replaced during openat") }
        self.directory = directory; self.name = name; fd = file; version = before
        try check()
    }
    func check() throws {
        try directory.verify()
        guard fcntl(fd.raw, F_GETFL) & O_ACCMODE == O_RDONLY,
              try fd.metadata() == version, try directory.metadata(name) == version else {
            throw PluginElyxDeveloperError.stale("archive descriptor, inode or content version changed")
        }
    }
    func read() throws -> Data {
        try check()
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while result.count < Int(version.size) {
            let limit = min(buffer.count, Int(version.size) - result.count)
            let offset = result.count
            let count = buffer.withUnsafeMutableBytes { pread(fd.raw, $0.baseAddress!, limit, off_t(offset)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw elyxIO("pread archive") }
            result.append(contentsOf: buffer.prefix(count))
        }
        try check()
        return result
    }
}

private func elyxRename(_ from: ElyxDirectory, _ old: String, _ to: ElyxDirectory, _ new: String, exchange: Bool) throws {
    let status = old.withCString { left in new.withCString { right in
        #if canImport(Darwin)
        return renameatx_np(from.fd.raw, left, to.fd.raw, right, UInt32(exchange ? RENAME_SWAP : RENAME_EXCL))
        #else
        return elyxRenameAt2(from.fd.raw, left, to.fd.raw, right, exchange ? 2 : 1)
        #endif
    } }
    guard status == 0 else { throw elyxIO(exchange ? "atomic archive exchange" : "exclusive stage rename") }
}

/// Remove only a captured inode. Move to a unique private quarantine first;
/// recheck the actual moved inode before unlinking. A racing replacement is
/// restored without overwrite or retained with a diagnostic, never erased.
@discardableResult
private func elyxRemoveOwned(_ directory: ElyxDirectory, name: String, identity: ElyxIdentity,
                             beforeRename: () throws -> Void, parentCurrent: () throws -> Void,
                             afterLookup: () throws -> Void,
                             diagnostic: @Sendable (String) -> Void) -> Bool {
    do {
        try beforeRename(); try directory.verify()
        let before: ElyxVersion?
        do { before = try directory.metadata(name) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { before = nil }
        try afterLookup()
        try beforeRename(); try directory.verify()
        guard let before else { return true }
        guard before.identity == identity else { throw PluginElyxDeveloperError.stale("cleanup found a replacement inode") }
        let quarantine = ".discard-" + UUID().uuidString
        try elyxRename(directory, name, directory, quarantine, exchange: false)
        // For an operation-directory removal its own quarantine rename is
        // expected. Only the parent's *continuously held* namespace authorizes
        // subsequent deletion/restoration; a lost parent always retains data.
        try parentCurrent(); try directory.verify()
        let moved = try directory.metadata(quarantine)
        guard moved.identity == identity else {
            try parentCurrent(); try directory.verify()
            try? elyxRename(directory, quarantine, directory, name, exchange: false)
            throw PluginElyxDeveloperError.stale("cleanup raced a replacement; retained without unlink")
        }
        let flags = identity.kind == UInt32(S_IFDIR) ? AT_REMOVEDIR : 0
        try parentCurrent(); try directory.verify()
        guard quarantine.withCString({ unlinkat(directory.fd.raw, $0, flags) }) == 0 else {
            let error = elyxIO("unlinkat owned staging inode")
            try parentCurrent(); try directory.verify()
            try? elyxRename(directory, quarantine, directory, name, exchange: false)
            throw error
        }
        return true
    } catch { diagnostic("Native Elyx staging cleanup retained data: \(error)"); return false }
}

private final class ElyxStage: @unchecked Sendable {
    let namespace = elyxNativeNonce()
    let version = elyxNativeNonce()
    let directory: ElyxDirectory
    let name: String
    let candidate: ElyxReadFile
    private let namespaceWatch: ElyxNamespaceWatch
    private let state: ElyxFileState
    private let permit: ElyxStagePermit
    private let lock = NSLock()
    private var cleanupIdentity: ElyxIdentity
    private var mayRemove = true

    init(state: ElyxFileState, candidate data: Data, format: PluginFileFormat) throws {
        let permit = try ElyxStagePermit(state)
        let operation = "op-" + UUID().uuidString
        try state.staging.verify()
        guard operation.withCString({ mkdirat(state.staging.fd.raw, $0, 0o700) }) == 0 else { throw elyxIO("mkdirat operation stage") }
        let owned: ElyxDirectory
        do { owned = try state.staging.child(operation) }
        catch {
            // mkdir has no inode return value. Without a captured descriptor we
            // cannot prove a racing replacement is ours, so never path-delete it.
            state.requireRecovery("Native Elyx stage capture failed before inode custody; unclaimed slot retained: \(error)")
            throw error
        }
        let leaf = "candidate." + format.rawValue
        var created: ElyxIdentity?
        var cleanupWatch: ElyxNamespaceWatch?
        do {
            let watched = try ElyxNamespaceWatch(owned.chain())
            cleanupWatch = watched
            try state.hooks.body(.stageCreated, owned.url)
            try watched.check(); try owned.verify()
            let writer = try ElyxFD(leaf.withCString { openat(owned.fd.raw, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600) })
            created = try writer.metadata().identity
            guard created?.kind == UInt32(S_IFREG) else { throw PluginElyxDeveloperError.stale("candidate fd is not regular") }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(writer.raw, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw elyxIO("write candidate") }
                    offset += count
                }
            }
            guard fchmod(writer.raw, 0o400) == 0, fsync(writer.raw) == 0 else { throw elyxIO("seal candidate") }
            let reader = try ElyxReadFile(owned, leaf)
            guard reader.version.identity == created, try reader.read() == data else { throw PluginElyxDeveloperError.stale("candidate changed during sealing") }
            try state.hooks.body(.candidateSealed, owned.url.appendingPathComponent(leaf))
            try watched.check(); try owned.verify(); try reader.check(); try watched.check()
            // Do not finish initializing self until all throwing preparation has
            // completed: failed-init cleanup must have exactly one owner.
            self.state = state; self.permit = permit; directory = owned; name = leaf; candidate = reader
            namespaceWatch = watched; cleanupIdentity = reader.version.identity
        } catch {
            do {
                guard let cleanupWatch else { throw PluginElyxDeveloperError.stale("no captured staging namespace watch") }
                let eligible = { try cleanupWatch.check(); try owned.verify(); try cleanupWatch.check() }
                try eligible()
                let parentWatch = try ElyxNamespaceWatch(state.staging.chain())
                let parentCurrent = { try parentWatch.check(); try state.staging.verify(); try parentWatch.check() }
                if let created, !elyxRemoveOwned(owned, name: leaf, identity: created,
                    beforeRename: eligible, parentCurrent: eligible,
                    afterLookup: { try state.hooks.body(.cleanupLookup, owned.url.appendingPathComponent(leaf)) },
                    diagnostic: { state.requireRecovery($0) }) { throw error }
                _ = elyxRemoveOwned(state.staging, name: operation, identity: owned.identity,
                    beforeRename: eligible, parentCurrent: parentCurrent,
                    afterLookup: { try state.hooks.body(.cleanupLookup, owned.url) }, diagnostic: { state.requireRecovery($0) })
            } catch { state.requireRecovery("Native Elyx failed-preparation cleanup retained lost namespace: \(error)") }
            throw error
        }
    }

    func checkNamespace() throws { try namespaceWatch.check(); try directory.verify(); try namespaceWatch.check() }
    func checkCandidate() throws { try checkNamespace(); try candidate.check(); try namespaceWatch.check() }

    func displaced(_ identity: ElyxIdentity) { lock.lock(); cleanupIdentity = identity; lock.unlock() }
    func preserveForRecovery() {
        lock.lock(); mayRemove = false; lock.unlock()
        state.requireRecovery("Native Elyx staging retained for publication recovery")
    }
    deinit {
        lock.lock(); let allowed = mayRemove; let expected = cleanupIdentity; lock.unlock()
        guard allowed else { return }
        do {
            try state.hooks.body(.beforeCleanup, directory.url)
            try checkNamespace() // Stolen/ABA parent means retention before ANY rename/unlink.
            guard let parent = directory.parent, let operation = directory.name else { throw PluginElyxDeveloperError.stale("missing staging parent custody") }
            let parentWatch = try ElyxNamespaceWatch(parent.chain())
            let eligible = { try self.checkNamespace() }
            let parentCurrent = { try parentWatch.check(); try parent.verify(); try parentWatch.check() }
            guard elyxRemoveOwned(directory, name: name, identity: expected,
                beforeRename: eligible, parentCurrent: eligible,
                afterLookup: { try self.state.hooks.body(.cleanupLookup, self.directory.url.appendingPathComponent(self.name)) },
                diagnostic: { self.state.requireRecovery($0) }) else { return }
            _ = elyxRemoveOwned(parent, name: operation, identity: directory.identity,
                beforeRename: eligible, parentCurrent: parentCurrent,
                afterLookup: { try self.state.hooks.body(.cleanupLookup, self.directory.url) }, diagnostic: { self.state.requireRecovery($0) })
        } catch { state.requireRecovery("Native Elyx cleanup retained lost staging namespace: \(error)") }
    }
}

private final class ElyxStagePermit: @unchecked Sendable {
    private let state: ElyxFileState
    init(_ state: ElyxFileState) throws { try state.acquireStage(); self.state = state }
    deinit { state.releaseStage() }
}

private final class ElyxPreparationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func cancel() { lock.lock(); active = false; lock.unlock() }
    func check() throws { lock.lock(); let value = active; lock.unlock(); if !value { throw CancellationError() } }
}

private final class ElyxFileState: @unchecked Sendable {
    let activity: PluginElyxDeveloperFileActivity
    let root: ElyxDirectory, staging: ElyxDirectory
    let namespace = elyxNativeNonce()
    let originalPath: String
    let registry: PluginElyxDeveloperDescriptorRegistry
    let bridge: PluginElyxDeveloperDescriptorBridge
    let currentTarget: @Sendable (PluginElyxDeveloperTarget) -> Bool
    let currentConsent: @Sendable (PluginElyxDeveloperTarget) -> Bool
    let diagnostic: @Sendable (String) -> Void
    let hooks: PluginElyxDeveloperFileHooks
    // Recursive because an admission predicate may recheck its own source lease.
    let lock = NSRecursiveLock()
    private var activeSources = 0
    private var activeStages = 0
    private var stagingRecoveryRequired = false
    private var versions: [String: (String, Int)] = [:]

    init(directory: URL, registry: PluginElyxDeveloperDescriptorRegistry, bridge: PluginElyxDeveloperDescriptorBridge,
         currentTarget: @escaping @Sendable (PluginElyxDeveloperTarget) -> Bool,
         currentConsent: @escaping @Sendable (PluginElyxDeveloperTarget) -> Bool,
         diagnostic: @escaping @Sendable (String) -> Void, hooks: PluginElyxDeveloperFileHooks,
         activity: PluginElyxDeveloperFileActivity) throws {
        root = try ElyxDirectory.open(directory, hooks: hooks)
        guard let parent = root.parent else { throw PluginElyxDeveloperError.malformed("installation root needs its native storage parent") }
        staging = try parent.child(".elyx-developer-staging", create: true)
        guard root.identity.device == staging.identity.device else { throw PluginElyxDeveloperError.unavailable("archive and staging must share a filesystem") }
        guard try staging.isEmpty() else { throw PluginElyxDeveloperError.unavailable("existing native Elyx staging requires owned recovery") }
        originalPath = directory.path
        self.registry = registry; self.bridge = bridge; self.currentTarget = currentTarget
        self.currentConsent = currentConsent; self.diagnostic = diagnostic; self.hooks = hooks
        self.activity = activity
        activity.authority(1)
    }
    deinit { activity.authority(-1) }

    func open(_ target: PluginElyxDeveloperTarget) throws -> ElyxFileSource {
        lock.lock(); defer { lock.unlock() }
        let readiness = try bridge.requireReady(registry)
        let plugin = target.plugin
        guard activeSources < 8 else { throw PluginElyxDeveloperError.unavailable("native Elyx source capacity exhausted") }
        guard plugin.fileFormat.isArchive, plugin.engine == "python", plugin.loaded, plugin.isEnabled, !plugin.notResponding,
              target.owner.pluginId == plugin.id, Plugin.isValidID(plugin.id, format: plugin.fileFormat), !Plugin.isReservedID(plugin.id) else {
            throw PluginElyxDeveloperError.malformed("native source requires the actual archive ID/format")
        }
        guard currentTarget(target), currentConsent(target) else {
            throw PluginElyxDeveloperError.stale("native archive target/consent expired")
        }
        let name = PluginServiceStorage.component(plugin.id) + "." + plugin.fileFormat.rawValue
        guard plugin.path == originalPath + "/" + name || plugin.path == root.url.path + "/" + name else {
            throw PluginElyxDeveloperError.stale("plugin is not at its native archive installation slot")
        }
        let pinned = try ElyxNamespace(root)
        let file = try ElyxReadFile(root, name)
        let bytes = try file.read()
        let hash = ElyxNativeSHA256.hex(bytes)
        try hooks.body(.sourceCaptured, root.url.appendingPathComponent(name))
        try pinned.verify(); try file.check()
        guard currentTarget(target), currentConsent(target) else { throw PluginElyxDeveloperError.stale("archive target retired during native capture") }
        let version = versions[name]?.0 ?? elyxNativeNonce()
        versions[name] = (version, (versions[name]?.1 ?? 0) + 1)
        activeSources += 1
        activity.source(1)
        let source = ElyxFileSource(state: self, target: target, name: name, file: file, pin: pinned,
                                    bytes: bytes, hash: hash, version: version, readiness: readiness)
        source.receipt = try registry.registerSource(source)
        return source
    }

    func release(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        activeSources -= 1
        activity.source(-1)
        if let value = versions[name] {
            if value.1 <= 1 { versions.removeValue(forKey: name) }
            else { versions[name] = (value.0, value.1 - 1) }
        }
    }
    func acquireStage() throws {
        lock.lock(); defer { lock.unlock() }
        guard !stagingRecoveryRequired else { throw PluginElyxDeveloperError.unavailable("native Elyx staging requires recovery before further writes") }
        guard activeStages < 8 else { throw PluginElyxDeveloperError.unavailable("native Elyx staging capacity exhausted") }
        activeStages += 1
        activity.stage(1)
    }
    func releaseStage() { lock.lock(); activeStages -= 1; activity.stage(-1); lock.unlock() }
    func requireRecovery(_ message: String) {
        lock.lock(); stagingRecoveryRequired = true; lock.unlock()
        diagnostic(message)
    }
    func requireVersion(_ name: String, _ version: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard versions[name]?.0 == version else { throw PluginElyxDeveloperError.stale("native archive operation version retired") }
    }
    func advance(_ name: String) -> String {
        let next = elyxNativeNonce()
        versions[name] = (next, versions[name]?.1 ?? 1)
        return next
    }
}

private final class ElyxFileSource: PluginElyxDeveloperSource, ElyxManifestSource, @unchecked Sendable {
    let state: ElyxFileState, target: PluginElyxDeveloperTarget, name: String
    let file: ElyxReadFile, pin: ElyxNamespace, version: String
    let archiveBytes: Data, sha256: String
    let readiness: PluginElyxDeveloperBridgeReadiness
    var receipt: String?
    var manifestOwner: PluginHost.CallbackOwner { target.owner }
    var manifestDigest: String { sha256 }
    init(state: ElyxFileState, target: PluginElyxDeveloperTarget, name: String, file: ElyxReadFile,
         pin: ElyxNamespace, bytes: Data, hash: String, version: String, readiness: PluginElyxDeveloperBridgeReadiness) {
        self.state = state; self.target = target; self.name = name; self.file = file; self.pin = pin
        archiveBytes = bytes; sha256 = hash; self.version = version
        self.readiness = readiness
    }
    deinit { if let receipt { state.registry.unregisterSource(receipt) }; state.release(name) }

    func checkCurrent() throws {
        state.lock.lock(); defer { state.lock.unlock() }
        _ = try state.bridge.requireReady(state.registry, expected: readiness)
        guard state.currentConsent(target) else { throw PluginElyxDeveloperError.stale("archive consent/model changed") }
        try state.requireVersion(name, version)
        try pin.verify(); try file.check()
        // Full SHA is checked at capture and claim. Every chunk checks immutable
        // fd/inode/size/mtime/ctime/namespace custody, not O(n) rehashing per 64 KiB.
    }

    func manifestBacking() throws -> ElyxDescriptorBacking {
        try checkCurrent()
        guard state.currentTarget(target) else { throw PluginElyxDeveloperError.stale("manifest owner retired") }
        let held = try ElyxReadFile(state.root, name)
        guard held.version == file.version else { throw PluginElyxDeveloperError.stale("manifest capture differs from Source.open receipt") }
        let check: @Sendable () throws -> Void = { [self, held] in
            try checkCurrent(); try held.check()
            guard state.currentTarget(target) else { throw PluginElyxDeveloperError.stale("manifest owner retired") }
        }
        return ElyxDescriptorBacking(descriptor: held.fd.raw,
            claims: .init(purpose: .manifest, pluginId: target.plugin.id, format: target.plugin.fileFormat, owner: target.owner,
                          namespace: state.namespace, version: version, sha256: sha256, byteCount: archiveBytes.count),
            check: check, verify: { [self, held] in
                try check()
                guard ElyxNativeSHA256.hex(try held.read()) == sha256 else { throw PluginElyxDeveloperError.stale("manifest source digest changed") }
            })
    }

    func prepare(_ candidate: Data, shouldExecute: @escaping @Sendable () -> Bool) async throws -> any PluginElyxDeveloperPrepared {
        let cancellation = ElyxPreparationCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            guard !candidate.isEmpty, candidate.count <= PluginElyxArchiveCandidate.maximumBytes else {
                throw PluginElyxDeveloperError.malformed("candidate exceeds 32 MiB or is empty")
            }
            let ready = try state.bridge.requireReady(state.registry)
            try checkCurrent()
            guard shouldExecute(), state.currentTarget(target) else { throw PluginElyxDeveloperError.stale("archive staging was not admitted") }
            let stage = try ElyxStage(state: state, candidate: candidate, format: target.plugin.fileFormat)
            let digest = ElyxNativeSHA256.hex(candidate)
            let current: @Sendable () throws -> Void = { [self, stage] in
                try cancellation.check()
                guard shouldExecute(), state.currentTarget(target) else { throw PluginElyxDeveloperError.stale("archive inspection scope retired") }
                _ = try state.bridge.requireReady(state.registry, expected: ready)
                try checkCurrent(); try stage.checkCandidate()
            }
            let descriptor = try state.registry.issue(ElyxDescriptorBacking(descriptor: stage.candidate.fd.raw,
                claims: .init(purpose: .inspect, pluginId: target.plugin.id, format: target.plugin.fileFormat, owner: nil,
                              namespace: stage.namespace, version: stage.version, sha256: digest, byteCount: candidate.count), check: current,
                verify: {
                    try current()
                    guard ElyxNativeSHA256.hex(try stage.candidate.read()) == digest else { throw PluginElyxDeveloperError.stale("candidate changed after sealing") }
                }))
            let metadata = try await state.bridge.inspect(.init(descriptor: descriptor, format: target.plugin.fileFormat,
                isCurrent: { (try? current()) != nil }))
            try Task.checkCancellation(); try current(); try descriptor.requireConsumed()
            guard metadata.id == target.plugin.id, metadata.fileFormat == target.plugin.fileFormat, metadata.engine == "python" else {
                throw PluginElyxDeveloperError.malformed("static candidate inspection changed ID/format/engine")
            }
            try state.hooks.body(.inspectionFinished, stage.directory.url)
            try current()
            return ElyxPreparedFile(source: self, stage: stage, metadata: metadata, digest: digest, readiness: ready)
        }, onCancel: { cancellation.cancel() })
    }
}

private final class ElyxPreparedFile: PluginElyxDeveloperPrepared, @unchecked Sendable {
    let source: ElyxFileSource, stage: ElyxStage
    let metadata: Plugin, sha256: String
    let readiness: PluginElyxDeveloperBridgeReadiness
    private enum Phase {
        case prepared
        case published(ElyxReadFile, ElyxNamespace, String)
        case failed(PluginElyxDeveloperPublicationFailure)
    }
    private var phase = Phase.prepared // guarded by source.state.lock

    init(source: ElyxFileSource, stage: ElyxStage, metadata: Plugin, digest: String, readiness: PluginElyxDeveloperBridgeReadiness) {
        self.source = source; self.stage = stage; self.metadata = metadata; sha256 = digest; self.readiness = readiness
    }

    func checkBeforePublication() throws {
        let state = source.state
        state.lock.lock(); defer { state.lock.unlock() }
        guard case .prepared = phase else { throw PluginElyxDeveloperError.stale("candidate is already published or failed") }
        _ = try state.bridge.requireReady(state.registry, expected: readiness)
        try source.checkCurrent(); try stage.checkCandidate()
        guard ElyxNativeSHA256.hex(try stage.candidate.read()) == sha256 else { throw PluginElyxDeveloperError.stale("inspected candidate hash changed") }
    }

    func publish(shouldExecute: @escaping @Sendable () -> Bool) throws {
        let state = source.state
        state.lock.lock(); defer { state.lock.unlock() }
        switch phase {
        case .prepared: break
        case .published: throw PluginElyxDeveloperError.stale("candidate was already published")
        case let .failed(error): throw error
        }
        var exchanged = false
        var displaced: ElyxIdentity?
        var confirmed = false
        do {
            try checkBeforePublication()
            guard shouldExecute() else { throw PluginElyxDeveloperError.stale("native archive publication not admitted") }
            try state.hooks.body(.beforeExchange, state.root.url.appendingPathComponent(source.name))
            try checkBeforePublication()
            guard shouldExecute(), state.currentConsent(source.target) else { throw PluginElyxDeveloperError.stale("publication consent/session retired") }
            try elyxRename(stage.directory, stage.name, state.root, source.name, exchange: true)
            exchanged = true
            displaced = try stage.directory.metadata(stage.name).identity
            try state.hooks.body(.afterExchange, state.root.url.appendingPathComponent(source.name))
            try source.pin.verify(allowLeafMutation: true)
            try stage.checkNamespace()
            let installed = try ElyxReadFile(state.root, source.name)
            let previous = try ElyxReadFile(stage.directory, stage.name)
            guard stage.candidate.version.matchesRenamed(installed.version), source.file.version.matchesRenamed(previous.version),
                  ElyxNativeSHA256.hex(try installed.read()) == sha256,
                  ElyxNativeSHA256.hex(try previous.read()) == source.sha256,
                  shouldExecute(), state.currentConsent(source.target) else {
                throw PluginElyxDeveloperError.stale("atomic exchange displaced a different version or lost authority")
            }
            try state.hooks.body(.beforeDirectorySync, state.root.url)
            try source.pin.verify(allowLeafMutation: true); try stage.checkNamespace()
            try installed.check(); try previous.check()
            guard shouldExecute(), state.currentConsent(source.target) else {
                throw PluginElyxDeveloperError.stale("publication authority retired before commit confirmation")
            }
            // After a confirmed exchange, a sync error is a committed/durability
            // failure, not a claimed rollback or permission to bootstrap Python.
            confirmed = true
            stage.displaced(previous.version.identity)
            if let sync = state.hooks.directorySync {
                try sync(state.root.fd.raw); try sync(stage.directory.fd.raw)
            } else { try state.root.synchronize(); try stage.directory.synchronize() }
            try source.pin.verify(allowLeafMutation: true); try installed.check()
            let pin = try source.pin.afterOwnPublication()
            let version = state.advance(source.name)
            phase = .published(installed, pin, version)
            try state.hooks.body(.committed, state.root.url.appendingPathComponent(source.name))
        } catch let publicationError {
            if confirmed {
                let failure: PluginElyxDeveloperPublicationFailure
                do {
                    try source.pin.verify(allowLeafMutation: true)
                    let current = try ElyxReadFile(state.root, source.name)
                    guard current.version.identity == stage.candidate.version.identity,
                          ElyxNativeSHA256.hex(try current.read()) == sha256 else {
                        throw PluginElyxDeveloperError.stale("committed installation slot changed")
                    }
                    failure = PluginElyxDeveloperPublicationFailure(outcome: .committed,
                        detail: "installed bytes changed; \(publicationError)", underlying: publicationError)
                } catch {
                    stage.preserveForRecovery()
                    failure = PluginElyxDeveloperPublicationFailure(outcome: .recoveryRequired,
                        detail: "committed namespace/version could not be confirmed; staging retained: \(publicationError); confirmation: \(error)",
                        underlying: publicationError)
                }
                phase = .failed(failure)
                throw failure
            }
            if exchanged {
                do {
                    guard let displaced, try state.root.metadata(source.name).identity == stage.candidate.version.identity,
                          try stage.directory.metadata(stage.name).identity == displaced else {
                        throw PluginElyxDeveloperError.stale("rollback slots were replaced")
                    }
                    try elyxRename(stage.directory, stage.name, state.root, source.name, exchange: true)
                    guard try state.root.metadata(source.name).identity == displaced,
                          try stage.directory.metadata(stage.name).identity == stage.candidate.version.identity else {
                        throw PluginElyxDeveloperError.stale("rollback could not confirm both captured inodes")
                    }
                    stage.displaced(stage.candidate.version.identity)
                    try state.root.synchronize(); try stage.directory.synchronize()
                    _ = state.advance(source.name) // never revive an older source lease after rollback
                    let failure = PluginElyxDeveloperPublicationFailure(outcome: .rolledBack,
                        detail: String(describing: publicationError), underlying: publicationError)
                    phase = .failed(failure)
                    throw failure
                } catch let failure as PluginElyxDeveloperPublicationFailure { throw failure }
                catch {
                    stage.preserveForRecovery()
                    let failure = PluginElyxDeveloperPublicationFailure(outcome: .recoveryRequired,
                        detail: "atomic exchange state needs recovery; staging retained: \(publicationError); rollback: \(error)",
                        underlying: publicationError)
                    phase = .failed(failure)
                    throw failure
                }
            }
            let failure = PluginElyxDeveloperPublicationFailure(outcome: .refused,
                detail: String(describing: publicationError), underlying: publicationError)
            phase = .failed(failure)
            throw failure
        }
    }

    private func published() throws -> (ElyxReadFile, ElyxNamespace, String) {
        switch phase {
        case let .published(file, pin, version): return (file, pin, version)
        case let .failed(error): throw error
        case .prepared: throw PluginElyxDeveloperError.stale("archive was not published")
        }
    }

    func checkPublished() throws {
        let state = source.state
        state.lock.lock(); defer { state.lock.unlock() }
        let (file, pin, version) = try published()
        _ = try state.bridge.requireReady(state.registry, expected: readiness)
        guard state.currentConsent(source.target) else { throw PluginElyxDeveloperError.stale("published archive consent retired") }
        try state.requireVersion(source.name, version); try pin.verify(); try file.check()
    }

    func loadSource(owner: PluginHost.CallbackOwner) throws -> any PluginElyxDeveloperDescriptorLease {
        let state = source.state
        state.lock.lock(); defer { state.lock.unlock() }
        try checkPublished()
        guard owner.pluginId == source.target.plugin.id, owner != source.target.owner, state.bridge.currentOwner(owner) else {
            throw PluginElyxDeveloperError.stale("verified load requires the actual NEW native callback owner")
        }
        let (_, _, version) = try published()
        let file = try ElyxReadFile(state.root, source.name) // independent read-only open file description
        guard ElyxNativeSHA256.hex(try file.read()) == sha256 else { throw PluginElyxDeveloperError.stale("load source changed") }
        return try state.registry.issue(ElyxDescriptorBacking(descriptor: file.fd.raw,
            claims: .init(purpose: .load, pluginId: owner.pluginId, format: metadata.fileFormat, owner: owner,
                          namespace: state.namespace, version: version, sha256: sha256, byteCount: Int(file.version.size)),
            check: { [self, file] in
                try checkPublished(); try file.check()
                guard state.bridge.currentOwner(owner) else { throw PluginElyxDeveloperError.stale("verified load owner retired") }
            }, verify: { [self, file] in
                try checkPublished(); try file.check()
                guard state.bridge.currentOwner(owner), ElyxNativeSHA256.hex(try file.read()) == sha256 else {
                    throw PluginElyxDeveloperError.stale("verified load owner/digest changed")
                }
            }))
    }
}
#endif
