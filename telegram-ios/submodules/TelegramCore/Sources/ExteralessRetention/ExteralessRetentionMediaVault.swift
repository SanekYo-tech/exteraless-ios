import CryptoKit
import Darwin
import ExteralessCore
import Foundation

/// Chunk-authenticated files outside MediaBox's evictable directory, inside this account's
/// Postbox directory. The random key exists only in its SQLCipher index. No UserDefaults,
/// global attachment folder, plaintext history export, or remote recovery is involved.
final class ExteralessRetentionMediaVault {
    static let chunkSize = 256 * 1024
    private static let magic = Data([0x45, 0x58, 0x4c, 0x52, 0x4d, 0x01, 0x00, 0x00])
    let directory: URL
    let fileLock: RetentionFileLock
    private let rootLock = NSLock()
    private var durabilityRootURL: URL
    private let fileSystem: RetentionFileSystem

    init(directory: URL, durabilityRootURL: URL? = nil, fileSystem: RetentionFileSystem = RetentionFileSystem()) {
        self.directory = directory.standardizedFileURL
        self.durabilityRootURL = (durabilityRootURL ?? directory.deletingLastPathComponent()).standardizedFileURL
        self.fileSystem = fileSystem
        self.fileLock = RetentionFileLock(accountRoot: directory.deletingLastPathComponent())
    }

    func updateDurabilityRoot(_ root: URL) {
        self.rootLock.lock(); self.durabilityRootURL = root.standardizedFileURL; self.rootLock.unlock()
    }

    func synchronizeDirectories(from directory: URL? = nil) throws {
        self.rootLock.lock(); let root = self.durabilityRootURL; self.rootLock.unlock()
        try self.fileSystem.synchronizeChain(from: directory ?? self.directory, through: root)
    }

    private func prepareDirectory() throws {
        self.rootLock.lock(); let root = self.durabilityRootURL; self.rootLock.unlock()
        guard self.directory.pathComponents.starts(with: root.pathComponents) else { throw ExteralessRetentionError.mediaIO }
        var info = stat()
        guard lstat(root.path, &info) == 0, (UInt32(info.st_mode) & UInt32(S_IFMT)) == UInt32(S_IFDIR) else { throw ExteralessRetentionError.mediaIO }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ])
        var url = self.directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func file(for entry: ExteralessRetentionMediaEntry) throws -> URL {
        guard UUID(uuidString: entry.token)?.uuidString.lowercased() == entry.token else { throw ExteralessRetentionError.invalidArchive }
        return self.directory.appendingPathComponent(entry.token + ".bin", isDirectory: false)
    }

    private func authentication(index: ExteralessRetentionIndex, entry: ExteralessRetentionMediaEntry, length: Int64, chunk: Int) -> Data {
        // Resource id is length-delimited; neither file/key/account substitution nor reordered
        // chunks can authenticate. Length is authenticated on EVERY chunk (including the last).
        Data("EXLRM1|\(index.accountPeerId)|\(index.epoch)|\(entry.token)|\(entry.id.utf8.count):\(entry.id)|\(length)|\(chunk)".utf8)
    }

    func store(source: FileHandle, length: Int64, entry: ExteralessRetentionMediaEntry, index: ExteralessRetentionIndex, cancelled: () -> Bool) throws -> Int64 {
        defer { try? source.close() }
        guard length > 0, length <= entry.reservedBytes, length <= RetentionPolicy.maximumResourceBytes, index.mediaKey.count == 32 else { throw ExteralessRetentionError.limitExceeded }
        try self.prepareDirectory()
        let destination = try self.file(for: entry)
        if FileManager.default.fileExists(atPath: destination.path) {
            // Recovery after rename but before the Postbox acknowledgement. Never trust exists().
            return try self.recover(entry: entry, index: index, expectedLength: length, cancelled: cancelled)
        }
        let temporary = self.directory.appendingPathComponent(".writing-" + UUID().uuidString.lowercased())
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw ExteralessRetentionError.mediaIO }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        try output.write(contentsOf: Self.magic)
        try output.write(contentsOf: self.integerData(UInt64(length)))
        let key = SymmetricKey(data: index.mediaKey)
        var remaining = length
        var chunk = 0
        while remaining > 0 {
            if cancelled() { throw ExteralessRetentionError.cancelled }
            let count = Int(min(Int64(Self.chunkSize), remaining))
            let plaintext = try self.readExactly(source, count: count)
            let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: self.authentication(index: index, entry: entry, length: length, chunk: chunk))
            guard let combined = sealed.combined else { throw ExteralessRetentionError.mediaIO }
            try output.write(contentsOf: self.integerData(UInt32(combined.count)))
            try output.write(contentsOf: combined)
            remaining -= Int64(count)
            chunk += 1
        }
        guard try source.read(upToCount: 1)?.isEmpty != false else { throw ExteralessRetentionError.mediaIO }
        try self.fileSystem.synchronizeFile(output, temporary)
        try output.close()
        if cancelled() { throw ExteralessRetentionError.cancelled }
        try FileManager.default.moveItem(at: temporary, to: destination)
        try self.synchronizeDirectories()
        return length
    }

    /// Authentication alone is not a durable-rename receipt. A retry completes the file and
    /// directory barriers again, including the ancestor link whose fsync previously failed.
    func recover(entry: ExteralessRetentionMediaEntry, index: ExteralessRetentionIndex, expectedLength: Int64?, cancelled: () -> Bool) throws -> Int64 {
        let count = try self.read(entry: entry, index: index, expectedLength: expectedLength, output: nil, cancelled: cancelled)
        let path = try self.file(for: entry)
        let input = try FileHandle(forReadingFrom: path)
        defer { try? input.close() }
        try self.fileSystem.synchronizeFile(input, path)
        try self.synchronizeDirectories()
        if cancelled() { throw ExteralessRetentionError.cancelled }
        return count
    }

    /// The only plaintext output is a transient file in the native MediaBox. The caller installs
    /// it through MediaBox.moveResourceData and keeps the real resource lease until ownership ends.
    func restore(entry: ExteralessRetentionMediaEntry, index: ExteralessRetentionIndex, nativeCacheDirectory: URL, cancelled: () -> Bool) throws -> URL {
        guard let length = entry.storedBytes else { throw ExteralessRetentionError.mediaUnavailable }
        let temporary = nativeCacheDirectory.appendingPathComponent(".exteraless-restore-" + UUID().uuidString.lowercased())
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw ExteralessRetentionError.mediaIO }
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: temporary) } }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        _ = try self.read(entry: entry, index: index, expectedLength: length, output: output, cancelled: cancelled)
        try self.fileSystem.synchronizeFile(output, temporary)
        try output.close()
        succeeded = true
        return temporary
    }

    /// Reads/authenticates the complete file. nil output is used for interrupted-commit recovery.
    func read(entry: ExteralessRetentionMediaEntry, index: ExteralessRetentionIndex, expectedLength: Int64?, output: FileHandle?, cancelled: () -> Bool) throws -> Int64 {
        let input = try FileHandle(forReadingFrom: self.file(for: entry))
        defer { try? input.close() }
        guard try self.readExactly(input, count: Self.magic.count) == Self.magic else { throw ExteralessRetentionError.unsupportedFormat }
        let rawLength = try self.readExactly(input, count: 8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard rawLength > 0, rawLength <= UInt64(entry.reservedBytes), rawLength <= UInt64(RetentionPolicy.maximumResourceBytes),
              expectedLength == nil || rawLength == UInt64(expectedLength!), index.mediaKey.count == 32 else { throw ExteralessRetentionError.invalidArchive }
        let length = Int64(rawLength)
        let key = SymmetricKey(data: index.mediaKey)
        var remaining = length
        var chunk = 0
        while remaining > 0 {
            if cancelled() { throw ExteralessRetentionError.cancelled }
            let count = Int(min(Int64(Self.chunkSize), remaining))
            let sealedSize = try self.readExactly(input, count: 4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard Int(sealedSize) == count + 28 else { throw ExteralessRetentionError.invalidArchive }
            let sealed = try AES.GCM.SealedBox(combined: self.readExactly(input, count: Int(sealedSize)))
            let plaintext = try AES.GCM.open(sealed, using: key, authenticating: self.authentication(index: index, entry: entry, length: length, chunk: chunk))
            guard plaintext.count == count else { throw ExteralessRetentionError.invalidArchive }
            try output?.write(contentsOf: plaintext)
            remaining -= Int64(count)
            chunk += 1
        }
        guard try input.read(upToCount: 1)?.isEmpty != false else { throw ExteralessRetentionError.invalidArchive }
        return length
    }

    func cleanup(keeping tokens: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: self.directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)
        for file in files {
            let name = file.lastPathComponent
            let isKept = name.hasSuffix(".bin") && tokens.contains(String(name.dropLast(4)))
            if !isKept { try FileManager.default.removeItem(at: file) }
        }
    }

    func orphanedTokens(keeping tokens: Set<String>) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: self.directory.path) else { return [] }
        var result = Set<String>()
        for file in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) {
            let name = file.lastPathComponent
            guard name.hasSuffix(".bin") else { continue }
            let token = String(name.dropLast(4))
            if UUID(uuidString: token)?.uuidString.lowercased() == token && !tokens.contains(token) { result.insert(token) }
        }
        return result
    }

    /// Delete only the inspected orphans. A newer capture may have committed while the native
    /// MediaBox deletion was queued; its fresh UUID must not be swept with a stale keep-set.
    func removeOrphans(_ tokens: Set<String>) throws {
        for token in tokens {
            guard UUID(uuidString: token)?.uuidString.lowercased() == token else { throw ExteralessRetentionError.invalidArchive }
            let file = self.directory.appendingPathComponent(token + ".bin")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        if FileManager.default.fileExists(atPath: self.directory.path) {
            for file in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix(".writing-") {
                try FileManager.default.removeItem(at: file)
            }
            try self.synchronizeDirectories()
        }
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: self.directory.path) { try FileManager.default.removeItem(at: self.directory) }
        try self.synchronizeDirectories(from: self.directory.deletingLastPathComponent())
    }

    private func integerData<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let part = try handle.read(upToCount: count - result.count), !part.isEmpty else { throw ExteralessRetentionError.invalidArchive }
            result.append(part)
        }
        return result
    }
}
