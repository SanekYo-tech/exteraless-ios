import Foundation

public enum ToolsAutomaticDownloadPolicy {
    // Exact original AndroidUtil lists, not a generic MIME/security filter.
    private static let archives: Set<String> = ["apk", "zip", "7z", "tar", "gz", "zst", "iso", "xz", "lha", "lzh"]
    private static let executables: Set<String> = ["cmd", "bat", "com", "exe", "lnk", "msi", "ps1", "reg", "vb", "vbe", "vbs", "vbscript"]

    public static func allows(fileName: String?, skipArchives: Bool, skipWindowsExecutables: Bool) -> Bool {
        guard let fileName, let dot = fileName.lastIndex(of: ".") else { return true }
        let suffix = fileName[fileName.index(after: dot)...]
        guard suffix.utf8.count <= 8 else { return true }
        let ext = suffix.lowercased()
        return !(skipArchives && archives.contains(ext)) && !(skipWindowsExecutables && executables.contains(ext))
    }
}

public enum ToolsUploadPolicy {
    /// Original uploadBoost raises the minimum chunk to 512 KiB; it is not a
    /// download profile or a parallelism multiplier. Native streaming/encryption
    /// geometry is retained; already-larger chunks are never reduced.
    public static func partSize(native: Int64, enabled: Bool, completeSize: Int64?, encrypted: Bool, hasHeader: Bool) -> Int64 {
        guard enabled, !encrypted, !hasHeader, native > 0, let size = completeSize, size > 256 * 1_024 else { return native }
        return max(native, 512 * 1_024)
    }
}
