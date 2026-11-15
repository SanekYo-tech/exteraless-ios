import Foundation

/// Persisted cleanup authority, never evidence of a client-setting write. No path
/// may be deleted merely because it resembles a transaction's scratch filename.
struct ToolsDirectoryOwnership: Codable, Equatable, Sendable {
    let directory: ToolsFileIdentity
    let files: [String: ToolsFileMetadata]
}

final class ToolsScratchRegistry {
    #if canImport(Darwin) || canImport(Glibc)
    var directories: [String: ToolsOwnedDirectory] = [:]
    var ownership: [String: ToolsDirectoryOwnership] { directories.mapValues(\.ownership) }
    #else
    var ownership: [String: ToolsDirectoryOwnership] { [:] }
    #endif
}

#if canImport(Darwin) || canImport(Glibc)
/// A bounded image keeps the descriptors that supplied the checked bytes. Moving
/// its directory changes the binding, not the identity of those descriptors.
final class ToolsDirectoryImage {
    let directory: ToolsDirectoryDescriptor
    let identity: ToolsFileIdentity
    let manifest: [String: String]
    let versions: [String: ToolsFileMetadata]
    private let inputs: [String: ToolsReadDescriptor]

    private init(directory: ToolsDirectoryDescriptor, identity: ToolsFileIdentity, manifest: [String: String],
                 versions: [String: ToolsFileMetadata], inputs: [String: ToolsReadDescriptor]) {
        self.directory = directory; self.identity = identity; self.manifest = manifest
        self.versions = versions; self.inputs = inputs
    }

    static func capture(parent: ToolsDirectoryDescriptor, name: String, directory: ToolsDirectoryDescriptor? = nil,
                        expectedManifest: [String: String]? = nil,
                        expectedVersions: [String: ToolsFileMetadata]? = nil) throws -> ToolsDirectoryImage {
        let directory = try directory ?? parent.child(name, create: false)
        let identity = try directory.identity
        try parent.verify()
        guard ToolsFileIdentity(try parent.metadata(name)) == identity else { throw ToolsError.unsafePath }
        let names = try directory.names(maximum: ToolsBackupPolicy.maximumPluginFiles, verifyBinding: false)
        if let expectedManifest {
            guard Set(names) == Set(expectedManifest.keys) else { throw ToolsError.rollbackFailed }
        }
        if let expectedVersions {
            guard Set(names) == Set(expectedVersions.keys) else { throw ToolsError.rollbackFailed }
        }
        var seen = Set<String>(), total = 0
        var manifest: [String: String] = [:], versions: [String: ToolsFileMetadata] = [:]
        var inputs: [String: ToolsReadDescriptor] = [:]
        for file in names {
            try ToolsBackupPolicy.validatePluginPath(file)
            guard seen.insert(file.lowercased()).inserted else { throw ToolsError.unsafePath }
            let limit = min(ToolsBackupPolicy.maximumPluginFileBytes, ToolsBackupPolicy.maximumPayloadBytes - total)
            let input = try ToolsReadDescriptor(directory.url.appendingPathComponent(file), maximumBytes: Int64(limit),
                                                parent: directory, verifyParentBinding: false)
            if let expectedVersions { guard expectedVersions[file] == input.version else { throw ToolsError.rollbackFailed } }
            let bytes = try input.readAll(maximumBytes: limit)
            let hash = ToolsSHA256.hex(bytes)
            if let expectedManifest { guard expectedManifest[file] == hash else { throw ToolsError.rollbackFailed } }
            total += bytes.count
            manifest[file] = hash; versions[file] = input.version; inputs[file] = input
        }
        let result = ToolsDirectoryImage(directory: directory, identity: identity, manifest: manifest, versions: versions, inputs: inputs)
        try result.verify(parent: parent, name: name, rehash: false)
        return result
    }

    func verify(parent: ToolsDirectoryDescriptor, name: String, rehash: Bool = true) throws {
        try parent.verify()
        try directory.verifyIdentity(identity)
        guard ToolsFileIdentity(try parent.metadata(name)) == identity,
              Set(try directory.names(maximum: ToolsBackupPolicy.maximumPluginFiles, verifyBinding: false)) == Set(manifest.keys) else { throw ToolsError.rollbackFailed }
        for (file, input) in inputs {
            try input.verifyFile()
            if rehash {
                let actual = try input.digest(maximumBytes: Int64(ToolsBackupPolicy.maximumPluginFileBytes))
                guard actual.sha256 == manifest[file] else { throw ToolsError.rollbackFailed }
            }
        }
        // A later read must not hide replacement of an earlier entry or of the
        // directory binding while this bounded image was being checked.
        try parent.verify()
        guard ToolsFileIdentity(try parent.metadata(name)) == identity,
              Set(try directory.names(maximum: ToolsBackupPolicy.maximumPluginFiles, verifyBinding: false)) == Set(manifest.keys) else { throw ToolsError.rollbackFailed }
        for input in inputs.values { try input.verifyFile() }
    }

    func bytes(for file: String) throws -> Data? {
        guard let input = inputs[file] else { return nil }
        try input.verifyFile()
        try input.rewind()
        let bytes = try input.readAll(maximumBytes: ToolsBackupPolicy.maximumPluginFileBytes)
        guard ToolsSHA256.hex(bytes) == manifest[file] else { throw ToolsError.rollbackFailed }
        return bytes
    }

    func copy(to destination: ToolsOwnedDirectory) throws {
        for name in manifest.keys.sorted() {
            guard let bytes = try bytes(for: name) else { throw ToolsError.rollbackFailed }
            try destination.write(bytes, name: name)
        }
        let copied = try destination.image(expectedManifest: manifest)
        guard copied.manifest == manifest else { throw ToolsError.rollbackFailed }
    }
}

/// Created here or acquired as the displaced side of a confirmed directory swap.
/// The transaction/transfer serializes I/O; the lock also protects handoff of file
/// versions between URLSession's delegate and its awaiting caller.
final class ToolsOwnedDirectory: @unchecked Sendable {
    let parent: ToolsDirectoryDescriptor
    let name: String
    let directory: ToolsDirectoryDescriptor
    let identity: ToolsFileIdentity
    private let lock = NSRecursiveLock()
    private var files: [String: ToolsFileMetadata]
    var url: URL { parent.url.appendingPathComponent(name, isDirectory: true) }
    var ownership: ToolsDirectoryOwnership {
        lock.lock(); defer { lock.unlock() }
        return .init(directory: identity, files: files)
    }

    private init(parent: ToolsDirectoryDescriptor, name: String, directory: ToolsDirectoryDescriptor,
                 identity: ToolsFileIdentity, files: [String: ToolsFileMetadata]) {
        self.parent = parent; self.name = name; self.directory = directory
        self.identity = identity; self.files = files
    }
    static func create(parent: ToolsDirectoryDescriptor, name: String) throws -> ToolsOwnedDirectory {
        let directory = try parent.createNewDirectory(name)
        return ToolsOwnedDirectory(parent: parent, name: name, directory: directory, identity: try directory.identity, files: [:])
    }
    static func displaced(_ image: ToolsDirectoryImage, parent: ToolsDirectoryDescriptor, name: String) throws -> ToolsOwnedDirectory {
        try image.verify(parent: parent, name: name)
        return ToolsOwnedDirectory(parent: parent, name: name, directory: image.directory, identity: image.identity, files: image.versions)
    }
    static func reopen(parent: ToolsDirectoryDescriptor, name: String, ownership: ToolsDirectoryOwnership) throws -> ToolsOwnedDirectory {
        guard ToolsFileIdentity(try parent.metadata(name)) == ownership.directory else { throw ToolsError.unsafePath }
        let directory = try parent.child(name, create: false)
        try directory.verifyIdentity(ownership.directory)
        return ToolsOwnedDirectory(parent: parent, name: name, directory: directory, identity: ownership.directory, files: ownership.files)
    }
    func verifyBinding() throws {
        try parent.verify(); try directory.verifyIdentity(identity)
        guard ToolsFileIdentity(try parent.metadata(name)) == identity else { throw ToolsError.unsafePath }
    }
    func remember(_ name: String, version: ToolsFileMetadata) {
        lock.lock(); files[name] = version; lock.unlock()
    }
    func forget(_ name: String) { lock.lock(); files.removeValue(forKey: name); lock.unlock() }

    func write(_ data: Data, name: String) throws {
        lock.lock(); defer { lock.unlock() }
        try verifyBinding()
        let output = try ToolsWriteDescriptor(parent: directory, name: "owned-\(UUID().uuidString).partial")
        defer { output.discard() }
        try output.write(data); try output.synchronize()
        let hash = ToolsSHA256.hex(data)
        guard try output.readReceipt().digest(maximumBytes: Int64(data.count)).sha256 == hash else { throw ToolsError.unsafePath }
        try directory.replacePrivateFile(output.name, as: name, expected: files[name])
        let receipt = try output.readReceipt(at: name)
        guard try receipt.digest(maximumBytes: Int64(data.count)).sha256 == hash else { throw ToolsError.unsafePath }
        files[name] = receipt.version
    }

    func image(expectedManifest: [String: String]) throws -> ToolsDirectoryImage {
        let ownership = self.ownership
        try verifyBinding()
        return try ToolsDirectoryImage.capture(parent: parent, name: name, directory: directory,
                                               expectedManifest: expectedManifest, expectedVersions: ownership.files)
    }

    func removeFile(_ name: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let version = files[name] else { throw ToolsError.unsafePath }
        try directory.verifyIdentity(identity)
        try directory.removeOwnedVersion(name, version: version)
        files.removeValue(forKey: name)
    }

    /// False means retained foreign/unconfirmed entries or a renamed binding.
    /// It never recursively removes a directory and never traverses an unknown one.
    @discardableResult func cleanup() -> Bool {
        lock.lock(); defer { lock.unlock() }
        do { try directory.verifyIdentity(identity) } catch { return false }
        var complete = true
        for (name, version) in files {
            do { try directory.removeOwnedVersion(name, version: version) }
            catch { complete = false }
        }
        do {
            try directory.synchronize(verifyBinding: false)
            guard try directory.names(maximum: ToolsBackupPolicy.maximumPluginFiles + 1, verifyBinding: false).isEmpty else { return false }
            try parent.removeEmptyDirectory(name, identity: identity)
        } catch { complete = false }
        return complete
    }
}

/// A verified-file capability survives the delegate/caller handoff. No URL-only
/// publication, recursive folder cleanup, or newly observed replacement is owned.
final class ToolsVerifiedFileReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var input: ToolsReadDescriptor
    private let owner: ToolsOwnedDirectory?
    let count: Int64
    let sha256: String
    let prefix: Data
    private var published = false

    init(input: ToolsReadDescriptor, count: Int64, sha256: String, owner: ToolsOwnedDirectory? = nil) throws {
        let actual = try input.digest(maximumBytes: count)
        guard actual.count == count, actual.sha256 == sha256 else { throw ToolsError.checksumMismatch }
        self.input = input; self.owner = owner; self.count = count; self.sha256 = sha256; self.prefix = actual.prefix
        owner?.remember(input.name, version: input.version)
    }

    func publish(as name: String) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard !published else { throw ToolsError.unsafePath }
        if let owner { try owner.verifyBinding() } else { try input.parent.verify() }
        // This exact fd/version supplied the checked digest, including before the
        // delegate closed its write handle. A fresh path read cannot renew it.
        let current = try input.digest(maximumBytes: count)
        guard current.count == count, current.sha256 == sha256 else { throw ToolsError.checksumMismatch }
        try Task.checkCancellation()
        let oldName = input.name
        guard try input.parent.publishNoReplace(oldName, as: name) else { throw ToolsError.unavailable("The destination already exists.") }
        // A rename/link may update ctime. Accept its new version only after the
        // same held inode and the exact checked content have been proved again.
        let rebound = try input.reboundAfterPublication(as: name, verifyParentBinding: false)
        // Once a name is published, drain verification before observing task
        // cancellation, so a cancelled caller can remove its confirmed own file.
        let actual = try rebound.digest(maximumBytes: count, checkCancellation: false)
        guard actual.count == count, actual.sha256 == sha256 else { throw ToolsError.checksumMismatch }
        owner?.remember(name, version: rebound.version)
        input = rebound
        #if canImport(Glibc)
        // linkat updated ctime on both names. Do not unlink an unchecked source
        // name, and rebind only this held inode after our own link removal.
        owner?.remember(oldName, version: rebound.version)
        try input.parent.removeOwnedVersion(oldName, version: input.version)
        let unlinked = try input.reboundAfterPublication(as: name, verifyParentBinding: false)
        let final = try unlinked.digest(maximumBytes: count, checkCancellation: false)
        guard final.count == count, final.sha256 == sha256 else { throw ToolsError.checksumMismatch }
        input = unlinked
        owner?.remember(name, version: unlinked.version)
        #endif
        owner?.forget(oldName)
        if let owner { try owner.verifyBinding() } else { try input.parent.verify() }
        try input.parent.synchronize()
        try input.verifyFile()
        try Task.checkCancellation()
        published = true
        return input.parent.url.appendingPathComponent(name)
    }

    func discard() {
        lock.lock(); defer { lock.unlock() }
        // Also useful after a caller cancellation immediately following publish.
        if let owner { try? owner.removeFile(input.name) }
        else { try? input.parent.removeOwnedVersion(input.name, version: input.version) }
    }
}
#endif
