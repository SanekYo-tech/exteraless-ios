import Foundation

/// Per-account, app-owned immutable font files and an atomic metadata index.
/// The Android serialized-TL cache is replaced with a bounded, versioned catalog.
public actor EmojiPackStore {
    private struct Index: Codable {
        var version = 1
        let account: Int64
        var packs: [EmojiStoredPack] = []
        var catalog: EmojiCatalog?
    }

    public let accountId: Int64
    private let root: URL

    public init(root: URL, accountId: Int64) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.accountId = accountId
    }

    public func list() throws -> [EmojiStoredPack] { try readIndex().packs }
    public func catalog() throws -> EmojiCatalog? { try readIndex().catalog }

    public func saveCatalog(_ catalog: EmojiCatalog) throws {
        try Task.checkCancellation()
        try catalog.validate()
        var index = try readIndex()
        index.catalog = catalog
        try writeIndex(index)
    }

    public func fontData(for pack: EmojiStoredPack) throws -> Data {
        guard try readIndex().packs.contains(pack) else { throw EmojiPackError.invalidCache }
        let data = try EmojiFontInspection.readFile(child("\(pack.sha256).\(pack.fileExtension)"))
        let inspection = try EmojiFontInspection.inspect(data, fileExtension: pack.fileExtension, expectedSHA256: pack.sha256)
        guard inspection.byteCount == pack.byteCount else { throw EmojiPackError.invalidCache }
        return data
    }

    /// Call after the native font probe succeeded. Persisting this record alone
    /// is never displayed as "installed"; registration is checked each launch.
    @discardableResult public func store(data: Data, name: String, fileExtension: String, origin: EmojiFontOrigin, catalogEntry: EmojiCatalogEntry? = nil, expectedSHA256: String? = nil) throws -> EmojiStoredPack {
        try Task.checkCancellation()
        let inspection = try EmojiFontInspection.inspect(data, fileExtension: fileExtension, expectedSHA256: expectedSHA256)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 240 else { throw EmojiPackError.invalidFont("font name") }
        switch origin {
        case let .bundled(source, license):
            guard expectedSHA256 != nil, !source.isEmpty, !license.isEmpty else { throw EmojiPackError.checksumMismatch }
        case let .https(url): _ = try EmojiFontHTTPClient.validatedURL(url)
        case let .telegram(source, messageId):
            guard source == EmojiCatalog.source, messageId > 0, catalogEntry?.file == messageId else { throw EmojiPackError.invalidCatalog }
        case .imported: break
        }
        try catalogEntry?.validate()
        let id = catalogEntry.map { "remote.\($0.id)" } ?? "font.\(inspection.sha256)"
        var index = try readIndex()
        if let previous = index.packs.first(where: { $0.id == id }), let catalogEntry, previous.version > catalogEntry.version { throw EmojiPackError.invalidCatalog }
        let previous = index.packs.first(where: { $0.id == id })
        // Downloading byte-identical data must not turn a user import into an
        // expendable cache entry removed by Clear Unused Downloads.
        let effectiveOrigin: EmojiFontOrigin = previous?.origin == .imported ? .imported : origin
        let pack = EmojiStoredPack(id: id, name: name, version: catalogEntry?.version ?? 1, sha256: inspection.sha256, byteCount: data.count, fileExtension: inspection.fileExtension, origin: effectiveOrigin, license: inspection.license, addedAt: Date())
        index.packs.removeAll(where: { $0.id == id })
        index.packs.append(pack)
        guard index.packs.count <= EmojiPackLimits.installedCount,
              index.packs.reduce(0, { $0 + $1.byteCount }) <= EmojiPackLimits.libraryBytes else { throw EmojiPackError.quota }
        try prepareRoot()
        let path = try child("\(pack.sha256).\(pack.fileExtension)")
        let existed = FileManager.default.fileExists(atPath: path.path)
        do {
            if existed {
                let existing = try EmojiFontInspection.readFile(path)
                guard ToolsSHA256.hex(existing) == pack.sha256 else { throw EmojiPackError.invalidCache }
            } else {
                try data.write(to: path, options: .atomic)
            }
            try Task.checkCancellation()
            try writeIndex(index)
        } catch {
            if !existed { try? FileManager.default.removeItem(at: path) }
            throw error
        }
        if let previous, previous.sha256 != pack.sha256, !index.packs.contains(where: { $0.sha256 == previous.sha256 }) {
            try? FileManager.default.removeItem(at: child("\(previous.sha256).\(previous.fileExtension)"))
        }
        return pack
    }

    public func remove(id: String) throws {
        try Task.checkCancellation()
        var index = try readIndex()
        guard let pack = index.packs.first(where: { $0.id == id }) else { return }
        index.packs.removeAll(where: { $0.id == id })
        try writeIndex(index)
        if !index.packs.contains(where: { $0.sha256 == pack.sha256 }) {
            try? FileManager.default.removeItem(at: child("\(pack.sha256).\(pack.fileExtension)"))
        }
    }

    public func clearUnusedDownloads(selectedId: String) throws {
        let packs = try readIndex().packs
        for pack in packs where pack.id != selectedId {
            switch pack.origin {
            case .https, .telegram: try remove(id: pack.id)
            case .imported, .bundled: break
            }
        }
    }

    private func readIndex() throws -> Index {
        let path = try child("index.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return Index(account: accountId) }
        let data = try EmojiFontInspection.readFile(path, maximumBytes: EmojiPackLimits.catalogBytes * 2)
        guard let index = try? JSONDecoder().decode(Index.self, from: data), index.version == 1, index.account == accountId,
              index.packs.count <= EmojiPackLimits.installedCount, Set(index.packs.map(\.id)).count == index.packs.count else { throw EmojiPackError.invalidCache }
        for pack in index.packs {
            guard EmojiFontInspection.isSHA256(pack.sha256), ["ttf", "otf"].contains(pack.fileExtension),
                  pack.byteCount > 0, pack.byteCount <= EmojiPackLimits.fontBytes,
                  pack.name.utf8.count <= 240, pack.id.utf8.count <= 128,
                  pack.id.hasPrefix("font.") || pack.id.hasPrefix("remote."), pack.version > 0,
                  (pack.license?.utf8.count ?? 0) <= 8192 else { throw EmojiPackError.invalidCache }
        }
        guard index.packs.reduce(0, { $0 + $1.byteCount }) <= EmojiPackLimits.libraryBytes else { throw EmojiPackError.invalidCache }
        try index.catalog?.validate()
        return index
    }

    private func writeIndex(_ index: Index) throws {
        try prepareRoot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(index)
        guard data.count <= EmojiPackLimits.catalogBytes * 2 else { throw EmojiPackError.tooLarge }
        try data.write(to: child("index.json"), options: .atomic)
    }

    private func prepareRoot() throws {
        guard root.isFileURL else { throw EmojiPackError.storage }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let properties = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw EmojiPackError.storage }
    }

    private func child(_ name: String) throws -> URL {
        guard root.isFileURL, !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { throw EmojiPackError.storage }
        let path = root.appendingPathComponent(name)
        guard root.resolvingSymlinksInPath() == root, path.resolvingSymlinksInPath() == path else { throw EmojiPackError.storage }
        return path
    }
}
