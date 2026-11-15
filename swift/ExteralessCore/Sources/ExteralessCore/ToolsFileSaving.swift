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

/// Descriptor-bound streaming copy into an already-authorized directory.
/// Publication is atomic and no-replace, including concurrent filename collisions.
public enum ToolsLocalFileSaver {
    public static func copy(source: URL, destination: URL, components: [String], name: String,
                            maximumBytes: Int64 = 4 * 1_024 * 1_024 * 1_024,
                            progress: (@Sendable (Int64, Int64) -> Void)? = nil,
                            hooks: ToolsFileOperationHooks = .init()) throws -> URL {
        guard source.isFileURL, destination.isFileURL, components.count <= 4 else { throw ToolsError.unsafePath }
        let name = try ToolsSavePathPolicy.fileName(name)
        #if canImport(Darwin) || canImport(Glibc)
        try Task.checkCancellation()
        let input = try ToolsReadDescriptor(source, maximumBytes: maximumBytes, hooks: hooks)
        var folder = try ToolsDirectoryDescriptor.open(destination)
        for component in components {
            _ = try ToolsSavePathPolicy.fileName(component)
            folder = try folder.child(component, create: true)
        }
        let output = try ToolsWriteDescriptor(parent: folder, name: "save-\(UUID().uuidString).partial")
        defer { output.discard() }
        var copied: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try input.readChunk(65_536)
            if data.isEmpty { break }
            guard Int64(data.count) <= maximumBytes - copied else { throw ToolsError.sizeLimit }
            try output.write(data)
            copied += Int64(data.count)
            progress?(copied, input.size)
        }
        try hooks.body(.afterSourceRead, source)
        try input.verify()
        guard copied == input.size else { throw ToolsError.unsafePath }
        try output.synchronize()
        try Task.checkCancellation()
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 0..<1_000 {
            let candidateName = index == 0 ? name : "\(stem) (\(index))" + (ext.isEmpty ? "" : "." + ext)
            let target = folder.url.appendingPathComponent(candidateName)
            try hooks.body(.beforePublication, target)
            try input.verify()
            try Task.checkCancellation()
            if try folder.publish(output.name, as: candidateName, identity: output.identity) {
                return target
            }
        }
        throw ToolsError.unavailable("Too many files with this name exist in the selected folder.")
        #else
        throw ToolsError.unavailable("Descriptor-bound file saving is unavailable on this platform.")
        #endif
    }
}
