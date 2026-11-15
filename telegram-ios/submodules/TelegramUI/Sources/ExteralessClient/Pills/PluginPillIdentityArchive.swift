import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Identity metadata only. Unregister/unload never recycle IDs referenced by dormant layouts.
final class PluginPillIdentityArchive: @unchecked Sendable {
    struct Identity: Codable, Equatable, Sendable {
        let pluginId: String
        let androidId: Int32
        let nativeId: Int32
    }
    enum Failure: Error { case invalidArchive, capacity, storage }
    private struct Document: Codable {
        var format = "exteraless.pill-identities"
        var version = 1
        var nextNativeId: Int64 = 10_000
        var entries: [Identity] = []
    }
    static let maximumIdentities = 4096
    private let url: URL
    private let lock = NSLock()

    init(url: URL) throws {
        guard url.isFileURL, !url.hasDirectoryPath, !url.lastPathComponent.isEmpty else { throw Failure.storage }
        self.url = url.standardizedFileURL
    }

    func identities(pluginId: String) throws -> [Identity] {
        try self.withFileLock { try self.read().entries.filter { $0.pluginId == pluginId } }
    }

    func resolve(pluginId: String, androidId: Int32, reserving occupied: Set<Int>) throws -> Identity {
        guard Self.validPluginId(pluginId), !(1...15).contains(androidId), androidId != -1 else { throw Failure.invalidArchive }
        return try self.withFileLock {
            var document = try self.read()
            if let existing = document.entries.first(where: { $0.pluginId == pluginId && $0.androidId == androidId }) { return existing }
            guard document.entries.count < Self.maximumIdentities else { throw Failure.capacity }
            var next = document.nextNativeId
            let reserved = occupied.union(document.entries.map { Int($0.nativeId) })
            while next <= Int64(Int32.max) && reserved.contains(Int(next)) { next += 1 }
            guard let nativeId = Int32(exactly: next) else { throw Failure.capacity }
            let identity = Identity(pluginId: pluginId, androidId: androidId, nativeId: nativeId)
            document.entries.append(identity)
            document.nextNativeId = next + 1
            try self.write(document)
            return identity
        }
    }

    private func read() throws -> Document {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: self.url.path) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) { return Document() }
            throw Failure.storage
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= 1_048_576 else { throw Failure.invalidArchive }
        let data: Data
        do { data = try Data(contentsOf: self.url) } catch { throw Failure.storage }
        guard data.count <= 1_048_576, let document = try? JSONDecoder().decode(Document.self, from: data),
              document.format == "exteraless.pill-identities", document.version == 1,
              document.nextNativeId >= 10_000, document.nextNativeId <= Int64(Int32.max) + 1,
              document.entries.count <= Self.maximumIdentities else { throw Failure.invalidArchive }
        var keys = Set<String>(); var nativeIds = Set<Int32>()
        for entry in document.entries {
            guard Self.validPluginId(entry.pluginId), !(1...15).contains(entry.androidId), entry.androidId != -1,
                  entry.nativeId >= 10_000, Int64(entry.nativeId) < document.nextNativeId,
                  keys.insert(entry.pluginId + ":" + String(entry.androidId)).inserted,
                  nativeIds.insert(entry.nativeId).inserted else { throw Failure.invalidArchive }
        }
        return document
    }

    static func validPluginId(_ id: String) -> Bool {
        guard (2...32).contains(id.utf8.count), let first = id.first, first.isASCII, first.isLetter else { return false }
        return id.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        self.lock.lock(); defer { self.lock.unlock() }
        #if canImport(Darwin) || canImport(Glibc)
        let directory = self.url.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw Failure.storage }
        let path = self.url.appendingPathExtension("lock").path
        let descriptor = path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
        guard descriptor >= 0 else { throw Failure.storage }
        defer { _ = close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 { if errno != EINTR { throw Failure.storage } }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
        #else
        throw Failure.storage
        #endif
    }

    private func write(_ document: Document) throws {
        #if canImport(Darwin) || canImport(Glibc)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= 1_048_576 else { throw Failure.capacity }
        let directory = self.url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".pill-identities-\(UUID().uuidString).tmp")
        let descriptor = temporary.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
        guard descriptor >= 0 else { throw Failure.storage }
        defer { _ = close(descriptor); _ = temporary.path.withCString { unlink($0) } }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                #if canImport(Darwin)
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                #else
                let written = Glibc.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                #endif
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Failure.storage }
                offset += written
            }
        }
        try Self.sync(descriptor)
        guard temporary.path.withCString({ source in self.url.path.withCString { destination in rename(source, destination) } }) == 0 else { throw Failure.storage }
        // A post-rename error is not rolled back: a retry reads the committed identity.
        for url in [directory, directory.deletingLastPathComponent()] {
            let fd = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
            guard fd >= 0 else { throw Failure.storage }
            defer { _ = close(fd) }
            try Self.sync(fd)
        }
        #else
        throw Failure.storage
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc)
    private static func sync(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 { if errno != EINTR { throw Failure.storage } }
    }
    #endif
}
