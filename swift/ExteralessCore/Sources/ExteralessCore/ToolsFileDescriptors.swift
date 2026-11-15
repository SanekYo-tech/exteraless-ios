import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Deterministic barriers for self-owned file fixtures. Production uses empty hooks.
public struct ToolsFileOperationHooks: Sendable {
    public enum Point: Sendable { case afterSourceMetadata, afterSourceRead, beforePublication }
    let body: @Sendable (Point, URL) throws -> Void
    public init(_ body: @escaping @Sendable (Point, URL) throws -> Void = { _, _ in }) { self.body = body }
}

struct ToolsFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let kind: UInt32

    #if canImport(Darwin) || canImport(Glibc)
    init(_ value: stat) {
        device = UInt64(truncatingIfNeeded: value.st_dev)
        inode = UInt64(truncatingIfNeeded: value.st_ino)
        kind = UInt32(value.st_mode) & UInt32(S_IFMT)
    }
    #endif
}

struct ToolsFileMetadata: Codable, Equatable, Sendable {
    let identity: ToolsFileIdentity
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64

    func matchesContentVersion(_ other: ToolsFileMetadata) -> Bool {
        identity == other.identity && size == other.size && modifiedSeconds == other.modifiedSeconds && modifiedNanos == other.modifiedNanos
    }

    #if canImport(Darwin) || canImport(Glibc)
    init(_ value: stat) {
        identity = ToolsFileIdentity(value)
        size = Int64(value.st_size)
        #if canImport(Darwin)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanos = Int64(value.st_ctimespec.tv_nsec)
        #else
        modifiedSeconds = Int64(value.st_mtim.tv_sec)
        modifiedNanos = Int64(value.st_mtim.tv_nsec)
        changedSeconds = Int64(value.st_ctim.tv_sec)
        changedNanos = Int64(value.st_ctim.tv_nsec)
        #endif
    }
    #endif
}

#if canImport(Darwin) || canImport(Glibc)
private func toolsFileIOError() -> Error {
    if errno == ELOOP || errno == ENOTDIR { return ToolsError.unsafePath }
    return POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

private final class ToolsOwnedDescriptor {
    private(set) var value: Int32
    init(_ value: Int32) throws {
        guard value >= 0 else { throw toolsFileIOError() }
        self.value = value
    }
    func close() throws {
        guard value >= 0 else { return }
        let descriptor = value
        value = -1
        #if canImport(Darwin)
        let result = Darwin.close(descriptor)
        #else
        let result = Glibc.close(descriptor)
        #endif
        guard result == 0 else { throw toolsFileIOError() }
    }
    deinit { try? close() }
}

private func toolsDescriptorStat(_ descriptor: Int32) throws -> stat {
    var value = stat()
    guard fstat(descriptor, &value) == 0 else { throw toolsFileIOError() }
    return value
}

/// Every ancestor descriptor stays open. Revalidation compares directory entries
/// to those identities, rather than resolving a path and subsequently trusting it.
final class ToolsDirectoryDescriptor {
    private struct Link {
        let parent: ToolsOwnedDescriptor
        let name: String
        let child: ToolsOwnedDescriptor
        let identity: ToolsFileIdentity
    }
    private let descriptor: ToolsOwnedDescriptor
    private let links: [Link]
    private let requestedURL: URL
    let url: URL
    var rawValue: Int32 { descriptor.value }
    var identity: ToolsFileIdentity { get throws { ToolsFileIdentity(try toolsDescriptorStat(rawValue)) } }

    private init(descriptor: ToolsOwnedDescriptor, links: [Link], requestedURL: URL, url: URL) {
        self.descriptor = descriptor; self.links = links; self.requestedURL = requestedURL; self.url = url
    }

    static func open(_ url: URL, create: Bool = false) throws -> ToolsDirectoryDescriptor {
        guard url.isFileURL, !url.path.contains("\0") else { throw ToolsError.unsafePath }
        let requested = url.standardizedFileURL
        // Translate fixed Darwin OS aliases, then walk every caller-controlled
        // component with O_NOFOLLOW. Never resolve an attacker-substituted ancestor.
        let canonical = ToolsFileSafety.canonicalFileURL(requested)
        #if canImport(Darwin)
        let initial = try ToolsOwnedDescriptor(Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW))
        #else
        let initial = try ToolsOwnedDescriptor(Glibc.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW))
        #endif
        var descriptor = initial
        var links: [Link] = []
        for component in canonical.pathComponents where component != "/" {
            var opened = component.withCString { openat(descriptor.value, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            if opened < 0, errno == ENOENT, create {
                if component.withCString({ mkdirat(descriptor.value, $0, 0o700) }) != 0 && errno != EEXIST { throw toolsFileIOError() }
                guard fsync(descriptor.value) == 0 else { throw toolsFileIOError() }
                opened = component.withCString { openat(descriptor.value, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            }
            let next = try ToolsOwnedDescriptor(opened)
            let identity = ToolsFileIdentity(try toolsDescriptorStat(next.value))
            guard identity.kind == UInt32(S_IFDIR) else { throw ToolsError.unsafePath }
            links.append(Link(parent: descriptor, name: component, child: next, identity: identity))
            descriptor = next
        }
        let result = ToolsDirectoryDescriptor(descriptor: descriptor, links: links, requestedURL: requested, url: canonical)
        try result.verify()
        return result
    }

    func verify() throws {
        guard ToolsFileSafety.canonicalFileURL(requestedURL).pathComponents == url.pathComponents else { throw ToolsError.unsafePath }
        for link in links {
            var current = stat()
            guard link.name.withCString({ fstatat(link.parent.value, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0,
                  ToolsFileIdentity(current) == link.identity,
                  ToolsFileIdentity(try toolsDescriptorStat(link.child.value)) == link.identity else { throw ToolsError.unsafePath }
        }
    }

    func verifyIdentity(_ expected: ToolsFileIdentity) throws {
        guard try identity == expected else { throw ToolsError.unsafePath }
    }

    func child(_ name: String, create: Bool) throws -> ToolsDirectoryDescriptor {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw ToolsError.unsafePath }
        try verify()
        if create {
            let created = name.withCString { mkdirat(rawValue, $0, 0o700) }
            if created != 0 && errno != EEXIST { throw toolsFileIOError() }
            if created == 0 { try synchronize() }
        }
        let next = try ToolsOwnedDescriptor(name.withCString { openat(rawValue, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) })
        let identity = ToolsFileIdentity(try toolsDescriptorStat(next.value))
        guard identity.kind == UInt32(S_IFDIR) else { throw ToolsError.unsafePath }
        let result = ToolsDirectoryDescriptor(descriptor: next,
            links: links + [Link(parent: descriptor, name: name, child: next, identity: identity)],
            requestedURL: requestedURL.appendingPathComponent(name), url: url.appendingPathComponent(name))
        try result.verify()
        return result
    }

    func createNewDirectory(_ name: String) throws -> ToolsDirectoryDescriptor {
        guard ToolsFileSafety.isComponent(name) else { throw ToolsError.unsafePath }
        try verify()
        guard name.withCString({ mkdirat(rawValue, $0, 0o700) }) == 0 else { throw toolsFileIOError() }
        let created = ToolsFileIdentity(try metadata(name))
        let directory = try child(name, create: false)
        try directory.verifyIdentity(created)
        guard try directory.names(maximum: 1).isEmpty else { throw ToolsError.unsafePath }
        try synchronize()
        return directory
    }

    /// Atomic replacement for the private journal/staged files, only under their
    /// operation's exclusive lease. An existing symlink or changed entry is refused.
    func replacePrivateFile(_ source: String, as target: String, expected: ToolsFileMetadata?) throws {
        try verify()
        let current: ToolsFileMetadata?
        do { current = ToolsFileMetadata(try metadata(target)) }
        catch let error as POSIXError where error.code == .ENOENT { current = nil }
        guard current == expected, current?.identity.kind == nil || current?.identity.kind == UInt32(S_IFREG) else { throw ToolsError.unsafePath }
        guard source.withCString({ from in target.withCString { to in renameat(rawValue, from, rawValue, to) } }) == 0 else { throw toolsFileIOError() }
        try synchronize()
    }

    func metadata(_ name: String) throws -> stat {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw ToolsError.unsafePath }
        var value = stat()
        guard name.withCString({ fstatat(rawValue, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else { throw toolsFileIOError() }
        return value
    }

    func names(maximum: Int, verifyBinding: Bool = true) throws -> [String] {
        if verifyBinding { try verify() }
        let duplicate = dup(rawValue)
        guard duplicate >= 0 else { throw toolsFileIOError() }
        guard let directory = fdopendir(duplicate) else {
            let error = toolsFileIOError()
            _ = close(duplicate)
            throw error
        }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name != "." && name != ".." {
                guard result.count < maximum else { throw ToolsError.sizeLimit }
                result.append(name)
            }
            errno = 0
        }
        guard errno == 0 else { throw toolsFileIOError() }
        if verifyBinding { try verify() }
        return result.sorted()
    }

    func synchronize(verifyBinding: Bool = true) throws {
        if verifyBinding { try verify() }
        guard fsync(rawValue) == 0 else { throw toolsFileIOError() }
    }

    /// Removal is fd-relative and only for the inode this operation owns.
    func removeOwned(_ name: String, identity: ToolsFileIdentity) {
        try? removeOwnedChecked(name, identity: identity)
    }

    func removeOwnedChecked(_ name: String, identity: ToolsFileIdentity) throws {
        let value: stat
        do { value = try metadata(name) }
        catch let error as POSIXError where error.code == .ENOENT { return }
        guard ToolsFileIdentity(value) == identity else { throw ToolsError.unsafePath }
        guard name.withCString({ unlinkat(rawValue, $0, 0) }) == 0 else { throw toolsFileIOError() }
    }

    func removeOwnedVersion(_ name: String, version: ToolsFileMetadata) throws {
        let current: stat
        do { current = try metadata(name) }
        catch let error as POSIXError where error.code == .ENOENT { return }
        guard ToolsFileMetadata(current) == version else { throw ToolsError.unsafePath }
        guard name.withCString({ unlinkat(rawValue, $0, 0) }) == 0 else { throw toolsFileIOError() }
    }

    /// No recursive removal. Callers first clean only recorded file versions from
    /// the held directory; an unknown/replaced/nonempty directory is retained.
    func removeEmptyDirectory(_ name: String, identity: ToolsFileIdentity) throws {
        let current: stat
        do { current = try metadata(name) }
        catch let error as POSIXError where error.code == .ENOENT { return }
        guard ToolsFileIdentity(current) == identity else { throw ToolsError.unsafePath }
        guard name.withCString({ unlinkat(rawValue, $0, AT_REMOVEDIR) }) == 0 else { throw toolsFileIOError() }
        guard fsync(rawValue) == 0 else { throw toolsFileIOError() }
    }

    /// Darwin moves, Glibc adds a link. The caller retains its fd/version receipt
    /// and must verify the published inode before removing the original Glibc link.
    func publishNoReplace(_ source: String, as target: String) throws -> Bool {
        try verify()
        guard ToolsFileSafety.isComponent(source), ToolsFileSafety.isComponent(target), source != target else { throw ToolsError.unsafePath }
        let result: Int32
        #if canImport(Darwin)
        result = source.withCString { from in target.withCString { to in renameatx_np(rawValue, from, rawValue, to, UInt32(RENAME_EXCL)) } }
        #else
        result = source.withCString { from in target.withCString { to in linkat(rawValue, from, rawValue, to, 0) } }
        #endif
        if result != 0 {
            if errno == EEXIST { return false }
            throw toolsFileIOError()
        }
        return true
    }

    /// Atomic no-replace publication, including a racing creator of the same name.
    func publish(_ source: String, as target: String, identity: ToolsFileIdentity) throws -> Bool {
        try verify()
        guard ToolsFileIdentity(try metadata(source)) == identity else { throw ToolsError.unsafePath }
        let result: Int32
        #if canImport(Darwin)
        result = source.withCString { from in target.withCString { to in renameatx_np(rawValue, from, rawValue, to, UInt32(RENAME_EXCL)) } }
        #else
        result = source.withCString { from in target.withCString { to in linkat(rawValue, from, rawValue, to, 0) } }
        #endif
        if result != 0 {
            if errno == EEXIST { return false }
            throw toolsFileIOError()
        }
        #if !canImport(Darwin)
        // The new link is already published; the owned temporary link is removed
        // by this operation and again by its defer on any later failure.
        removeOwned(source, identity: identity)
        #endif
        do {
            try verify()
            guard ToolsFileIdentity(try metadata(target)) == identity else { throw ToolsError.unsafePath }
            try synchronize()
        } catch {
            removeOwned(target, identity: identity)
            throw error
        }
        return true
    }
}

final class ToolsReadDescriptor {
    private let descriptor: ToolsOwnedDescriptor
    let parent: ToolsDirectoryDescriptor
    let name: String
    private let initial: ToolsFileMetadata
    private let verifyParentBinding: Bool
    let url: URL
    var size: Int64 { initial.size }
    var version: ToolsFileMetadata { initial }

    init(_ url: URL, maximumBytes: Int64, hooks: ToolsFileOperationHooks = .init(), parent: ToolsDirectoryDescriptor? = nil,
         verifyParentBinding: Bool = true) throws {
        guard url.isFileURL, maximumBytes >= 0 else { throw ToolsError.unsafePath }
        let parent = try parent ?? ToolsDirectoryDescriptor.open(url.deletingLastPathComponent())
        let name = url.lastPathComponent
        let initial = ToolsFileMetadata(try parent.metadata(name))
        guard initial.identity.kind == UInt32(S_IFREG) else { throw ToolsError.unsafePath }
        guard initial.size >= 0, initial.size <= maximumBytes else { throw ToolsError.sizeLimit }
        try hooks.body(.afterSourceMetadata, url)
        let descriptor = try ToolsOwnedDescriptor(name.withCString { openat(parent.rawValue, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) })
        self.parent = parent; self.name = name; self.url = url
        self.initial = initial; self.descriptor = descriptor
        self.verifyParentBinding = verifyParentBinding
        try verify()
    }

    fileprivate init(duplicating descriptor: Int32, parent: ToolsDirectoryDescriptor, name: String,
                     version: ToolsFileMetadata, verifyParentBinding: Bool = true) throws {
        self.descriptor = try ToolsOwnedDescriptor(dup(descriptor))
        self.parent = parent; self.name = name; self.url = parent.url.appendingPathComponent(name)
        self.initial = version; self.verifyParentBinding = verifyParentBinding
        try verify()
    }

    func verify() throws {
        if verifyParentBinding { try parent.verify() }
        try verifyFile()
    }

    func verifyFile() throws {
        guard ToolsFileMetadata(try toolsDescriptorStat(descriptor.value)) == initial,
              ToolsFileMetadata(try parent.metadata(name)) == initial else { throw ToolsError.unsafePath }
    }

    func rewind() throws {
        guard lseek(descriptor.value, 0, SEEK_SET) == 0 else { throw toolsFileIOError() }
    }

    /// Only after this operation's successful rename. ctime may change because of
    /// rename/link; bytes are rehashed through this same inode before acceptance.
    func reboundAfterPublication(as name: String, verifyParentBinding: Bool = true) throws -> ToolsReadDescriptor {
        let version = ToolsFileMetadata(try toolsDescriptorStat(descriptor.value))
        guard version.matchesContentVersion(initial) else { throw ToolsError.unsafePath }
        return try ToolsReadDescriptor(duplicating: descriptor.value, parent: parent, name: name, version: version, verifyParentBinding: verifyParentBinding)
    }

    func digest(maximumBytes: Int64, checkCancellation: Bool = true) throws -> (count: Int64, sha256: String, prefix: Data) {
        guard size >= 0, size <= maximumBytes else { throw ToolsError.sizeLimit }
        try verify()
        try rewind()
        var hash = ToolsSHA256(), prefix = Data()
        var count: Int64 = 0
        while true {
            if checkCancellation { try Task.checkCancellation() }
            let chunk = try readChunk(65_536)
            if chunk.isEmpty { break }
            guard Int64(chunk.count) <= maximumBytes - count else { throw ToolsError.sizeLimit }
            count += Int64(chunk.count)
            hash.update(chunk)
            if prefix.count < 4 { prefix.append(chunk.prefix(4 - prefix.count)) }
        }
        try verify()
        guard count == size else { throw ToolsError.unsafePath }
        return (count, hash.hexDigest(), prefix)
    }

    func readChunk(_ maximum: Int) throws -> Data {
        guard maximum > 0, maximum <= 65_536 else { throw ToolsError.sizeLimit }
        var chunk = Data(count: maximum)
        let count: Int = try chunk.withUnsafeMutableBytes { buffer in
            while true {
                let count = read(descriptor.value, buffer.baseAddress, maximum)
                if count >= 0 { return count }
                if errno != EINTR { throw toolsFileIOError() }
            }
        }
        chunk.count = count
        return chunk
    }

    func readAll(maximumBytes: Int, hooks: ToolsFileOperationHooks = .init()) throws -> Data {
        guard maximumBytes >= 0, size <= Int64(maximumBytes) else { throw ToolsError.sizeLimit }
        var result = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try readChunk(min(65_535, maximumBytes - result.count) + 1)
            if chunk.isEmpty { break }
            guard chunk.count <= maximumBytes - result.count else { throw ToolsError.sizeLimit }
            result.append(chunk)
        }
        try hooks.body(.afterSourceRead, url)
        try verify()
        guard Int64(result.count) == size else { throw ToolsError.unsafePath }
        return result
    }
}

final class ToolsWriteDescriptor {
    private let descriptor: ToolsOwnedDescriptor
    let parent: ToolsDirectoryDescriptor
    let name: String
    let identity: ToolsFileIdentity
    var version: ToolsFileMetadata { get throws { ToolsFileMetadata(try toolsDescriptorStat(descriptor.value)) } }

    init(parent: ToolsDirectoryDescriptor, name: String) throws {
        guard ToolsFileSafety.isComponent(name) else { throw ToolsError.unsafePath }
        try parent.verify()
        let descriptor = try ToolsOwnedDescriptor(name.withCString { openat(parent.rawValue, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) })
        let identity = ToolsFileIdentity(try toolsDescriptorStat(descriptor.value))
        guard identity.kind == UInt32(S_IFREG) else { throw ToolsError.unsafePath }
        self.parent = parent; self.name = name
        self.descriptor = descriptor; self.identity = identity
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                #if canImport(Darwin)
                let count = Darwin.write(descriptor.value, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #else
                let count = Glibc.write(descriptor.value, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw toolsFileIOError() }
                offset += count
            }
        }
    }

    func synchronize() throws {
        guard fsync(descriptor.value) == 0 else { throw toolsFileIOError() }
        try parent.verify()
    }

    func readReceipt(at name: String? = nil, expectedVersion: ToolsFileMetadata? = nil,
                     verifyParentBinding: Bool = true) throws -> ToolsReadDescriptor {
        let version = try expectedVersion ?? self.version
        return try ToolsReadDescriptor(duplicating: descriptor.value, parent: parent, name: name ?? self.name, version: version, verifyParentBinding: verifyParentBinding)
    }

    func discard() { parent.removeOwned(name, identity: identity) }
    func discardChecked() throws { try parent.removeOwnedChecked(name, identity: identity) }
    func close() throws { try descriptor.close() }
}
#endif
