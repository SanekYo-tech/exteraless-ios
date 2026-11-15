import Foundation

/// Actor-isolated disk work; rendering uses a separately predecoded image cache.
public actor AppearanceIconPackStore {
    private let root: URL

    public init(directory: URL) {
        self.root = directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func list() throws -> [AppearanceIconPackMetadata] {
        try prepareRoot()
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var result: [AppearanceIconPackMetadata] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(100) {
            guard AppearanceIconPackMetadata.isIdentifier(url.lastPathComponent),
                  try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let metadata = try readMetadata(id: url.lastPathComponent)
            result.append(metadata)
        }
        return result
    }

    public func create(name: String) throws -> AppearanceIconPackMetadata {
        let metadata = AppearanceIconPackMetadata(packId: "ios_" + UUID().uuidString.lowercased(), packName: name.trimmingCharacters(in: .whitespacesAndNewlines))
        try metadata.validate()
        try install(metadata: metadata, files: ["metadata.json": try encoded(metadata)])
        return metadata
    }

    public func install(archive: Data, inflate: @Sendable (Data, Int) throws -> Data) throws -> AppearanceIconPackMetadata {
        let files = try AppearanceIconArchive.decode(archive, inflate: inflate)
        let (metadata, contents) = try AppearanceIconArchive.unpack(files)
        try install(metadata: metadata, files: contents)
        return metadata
    }

    public func export(id: String) throws -> Data {
        let metadata = try readMetadata(id: id)
        var files = try iconFiles(id: id)
        files["metadata.json"] = try encoded(metadata)
        return try AppearanceIconArchive.encode(files)
    }

    public func iconFiles(id: String) throws -> [String: Data] {
        let metadata = try readMetadata(id: id)
        let directory = try packDirectory(id)
        var files: [String: Data] = [:]
        var total = 0
        for path in Set(metadata.icons.values) {
            let data = try read(path, root: directory, maximum: AppearanceIconArchive.maximumFileBytes)
            total += data.count
            guard total <= AppearanceIconArchive.maximumArchiveBytes else { throw AppearanceIconPackError.sizeLimit }
            files[path] = data
        }
        return files
    }

    public func rename(id: String, name: String) throws {
        var metadata = try readMetadata(id: id)
        metadata.packName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try writeMetadata(metadata)
    }

    public func replaceIcon(id: String, resource: String, data: Data?, fileExtension: String = "png") throws {
        guard AppearanceIconNames.mapping(for: resource) != nil else { throw AppearanceIconPackError.invalidMetadata }
        var metadata = try readMetadata(id: id)
        let directory = try packDirectory(id)
        let previous = metadata.icons[resource]
        var createdFile: URL?
        var committed = false
        defer {
            if !committed, let createdFile { try? FileManager.default.removeItem(at: createdFile) }
        }
        if let data {
            guard !data.isEmpty, data.count <= AppearanceIconArchive.maximumFileBytes else { throw AppearanceIconPackError.sizeLimit }
            var total = data.count
            for path in Set(metadata.icons.filter { $0.key != resource }.values) {
                let size = try checked(path, root: directory).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                total += size
                guard total <= AppearanceIconArchive.maximumArchiveBytes else { throw AppearanceIconPackError.sizeLimit }
            }
            let ext = fileExtension.lowercased()
            guard ["png", "jpg", "jpeg", "svg", "webp"].contains(ext) else { throw AppearanceIconPackError.unsupportedImage }
            let path = "icons/" + UUID().uuidString.lowercased() + "." + ext
            let url = try checked(path, root: directory)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            createdFile = url
            metadata.icons[resource] = path
        } else {
            metadata.icons.removeValue(forKey: resource)
        }
        try writeMetadata(metadata)
        committed = true
        if let previous, !metadata.icons.values.contains(previous) {
            try? FileManager.default.removeItem(at: checked(previous, root: directory))
        }
    }

    public func remove(id: String) throws {
        _ = try readMetadata(id: id)
        try FileManager.default.removeItem(at: packDirectory(id))
    }

    private func prepareRoot() throws {
        guard root.isFileURL else { throw AppearanceIconPackError.unsafePath }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard root.resolvingSymlinksInPath().path == root.path else { throw AppearanceIconPackError.unsafePath }
    }

    private func packDirectory(_ id: String) throws -> URL {
        guard AppearanceIconPackMetadata.isIdentifier(id) else { throw AppearanceIconPackError.unsafePath }
        return try checked(id, root: root)
    }

    private func readMetadata(id: String) throws -> AppearanceIconPackMetadata {
        let directory = try packDirectory(id)
        guard FileManager.default.fileExists(atPath: directory.path) else { throw AppearanceIconPackError.missingPack }
        let data = try read("metadata.json", root: directory, maximum: AppearanceIconArchive.maximumMetadataBytes)
        let metadata = try JSONDecoder().decode(AppearanceIconPackMetadata.self, from: data)
        try metadata.validate()
        guard metadata.packId == id else { throw AppearanceIconPackError.invalidMetadata }
        return metadata
    }

    private func writeMetadata(_ metadata: AppearanceIconPackMetadata) throws {
        try metadata.validate()
        try encoded(metadata).write(to: checked("metadata.json", root: packDirectory(metadata.packId)), options: .atomic)
    }

    private func install(metadata: AppearanceIconPackMetadata, files: [String: Data]) throws {
        try prepareRoot()
        let destination = try packDirectory(metadata.packId)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw AppearanceIconPackError.alreadyInstalled }
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).filter({ !$0.hasPrefix(".") }).count < 100 else { throw AppearanceIconPackError.sizeLimit }
        let staging = root.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        for (path, data) in files {
            let url = try checked(path, root: staging)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    private func encoded(_ metadata: AppearanceIconPackMetadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let result = try encoder.encode(metadata)
        guard result.count <= AppearanceIconArchive.maximumMetadataBytes else { throw AppearanceIconPackError.sizeLimit }
        return result
    }

    private func checked(_ path: String, root: URL) throws -> URL {
        try AppearanceIconArchive.validatePath(path)
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath().path == url.path else { throw AppearanceIconPackError.unsafePath }
        return url
    }

    private func read(_ path: String, root: URL, maximum: Int) throws -> Data {
        let url = try checked(path, root: root)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximum else { throw AppearanceIconPackError.sizeLimit }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximum else { throw AppearanceIconPackError.sizeLimit }
        return data
    }
}
