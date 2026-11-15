import Foundation

public enum ToolsSavePathPolicy {
    public static func customFolder(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 200, value != ".", value != "..",
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [32, 45, 46, 95].contains($0) }) else {
            throw ToolsError.unsafePath
        }
        return value
    }

    public static func components(customFolder: String, perChat: Bool, accountId: Int64, chatId: Int64?) throws -> [String] {
        let folder = try self.customFolder(customFolder)
        var parts = folder.isEmpty ? [] : [folder]
        if perChat, let chatId {
            parts.append("account-\(accountId)")
            parts.append("chat-\(chatId)")
        }
        return parts
    }

    public static func fileName(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 200, value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"), !value.contains(":"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ToolsError.unsafePath }
        return value
    }
}

/// Bounded streaming copy into an already-authorized directory. Each path is
/// checked after construction; an existing file is never overwritten.
public enum ToolsLocalFileSaver {
    public static func copy(source: URL, destination: URL, components: [String], name: String,
                            maximumBytes: Int64 = 4 * 1_024 * 1_024 * 1_024,
                            progress: (@Sendable (Int64, Int64) -> Void)? = nil) throws -> URL {
        guard source.isFileURL, destination.isFileURL, components.count <= 4 else { throw ToolsError.unsafePath }
        let name = try ToolsSavePathPolicy.fileName(name)
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, let size = (attributes[.size] as? NSNumber)?.int64Value,
              size >= 0, size <= maximumBytes else { throw ToolsError.sizeLimit }
        let base = destination.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw ToolsError.unsafePath }
        var folder = base
        for component in components {
            _ = try ToolsSavePathPolicy.fileName(component)
            folder = folder.appendingPathComponent(component, isDirectory: true)
            try contained(folder, in: base)
            var existsAsDirectory: ObjCBool = false
            if manager.fileExists(atPath: folder.path, isDirectory: &existsAsDirectory) {
                guard existsAsDirectory.boolValue else { throw ToolsError.unsafePath }
            } else {
                try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            try contained(folder, in: base)
        }
        let partial = folder.appendingPathComponent("save-\(UUID().uuidString).partial")
        guard manager.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ToolsError.unavailable("The destination cannot create files.") }
        defer { try? manager.removeItem(at: partial) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        var copied: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try input.read(upToCount: 65_536) ?? Data()
            if data.isEmpty { break }
            guard Int64(data.count) <= maximumBytes - copied else { throw ToolsError.sizeLimit }
            try output.write(contentsOf: data)
            copied += Int64(data.count)
            progress?(copied, size)
        }
        guard copied == size else { throw ToolsError.unavailable("The source file changed while being saved.") }
        try output.synchronize()
        try output.close()
        try Task.checkCancellation()
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 0..<1_000 {
            let candidateName = index == 0 ? name : "\(stem) (\(index))" + (ext.isEmpty ? "" : "." + ext)
            let target = folder.appendingPathComponent(candidateName)
            try contained(target, in: base)
            if manager.fileExists(atPath: target.path) { continue }
            do {
                // FileManager's move fails if another writer won this name; it
                // does not replace the destination as an atomic write would.
                try manager.moveItem(at: partial, to: target)
                return target
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                continue
            }
        }
        throw ToolsError.unavailable("Too many files with this name exist in the selected folder.")
    }

    private static func contained(_ url: URL, in base: URL) throws {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.pathComponents.starts(with: base.pathComponents), resolved.pathComponents == url.standardizedFileURL.pathComponents else { throw ToolsError.unsafePath }
    }
}
