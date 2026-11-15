import Foundation

/// The coordinator supplies this plugin's real files/cache roots and the current
/// .files grant. Canonical path-component checks reject sibling-prefix and symlink
/// escapes before a URL is handed to the system share controller.
public enum PluginUIShareFiles {
    public static func resolve(path: String, allowedRoots: [URL], allowExternal: Bool) throws -> URL {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0"), (path as NSString).isAbsolutePath else {
            throw PluginUIFailure.malformed("A shared file requires an absolute local path")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let components = url.pathComponents
        let owned = allowedRoots.contains { root in
            guard root.isFileURL else { return false }
            let prefix = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            return components.count > prefix.count && components.starts(with: prefix)
        }
        guard owned || allowExternal else { throw PluginUIFailure.permission("Sharing a file outside this plugin's directories requires files") }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
            throw PluginUIFailure.unavailable("Shared file is missing or is not a regular file")
        }
        return url
    }
}
