import Foundation

/// Native path ownership, independent of grants. Classification resolves path
/// metadata only; it never opens or reads the resource's contents. Consumers must
/// capture their complete permission predicate before opening the returned URL.
public struct PluginResourcePath: Hashable, Sendable {
    public let url: URL
    public let requiresFiles: Bool

    public init(path: String, allowedRoots: [URL]) throws {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0"),
              (path as NSString).isAbsolutePath else {
            throw BridgeFailure.malformed("Resource requires an absolute local path of at most 4096 UTF-8 bytes")
        }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let components = canonical.pathComponents
        let owned = allowedRoots.contains { root in
            guard root.isFileURL else { return false }
            let prefix = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            return components.count > prefix.count && components.starts(with: prefix)
        }
        self.url = canonical
        self.requiresFiles = !owned
    }

    /// Keep the admitted canonical target. A changed symlink/ancestor cannot
    /// select a new resource or acquire a new permission epoch at consumption.
    /// Call on the existing IO queue (or in place of an existing path recheck).
    public func validatedURL() throws -> URL {
        guard url.standardizedFileURL.resolvingSymlinksInPath() == url else {
            throw BridgeFailure.invalidHandle("Resource path changed after native admission")
        }
        return url
    }
}
