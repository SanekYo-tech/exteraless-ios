import Foundation

public struct ToolsDownloadBudget: Equatable, Sendable {
    public let partBytes: Int64
    public let parallelParts: Int
    public init(partBytes: Int64, parallelParts: Int) { self.partBytes = partBytes; self.parallelParts = parallelParts }
}

public enum ToolsDownloadPolicy {
    /// Preserve iOS small-file/story/encrypted/unknown-size behavior. For ordinary
    /// large files, Android's 512-KiB/8 and 1-MiB/12 profiles are floors, never a
    /// downgrade of a faster native/Rust transport. Protocol range/hash logic stays
    /// in the download manager; this policy neither retries nor issues a request.
    public static func budget(level: Int, size: Int64?, isStory: Bool, encrypted: Bool, native: ToolsDownloadBudget) -> ToolsDownloadBudget {
        guard (1...2).contains(level), let size, size > 512 * 1_024, !isStory, !encrypted else { return native }
        let bytes: Int64 = level == 2 ? 1_024 * 1_024 : 512 * 1_024
        let parts = level == 2 ? 12 : 8
        return ToolsDownloadBudget(partBytes: min(1_024 * 1_024, max(native.partBytes, bytes)), parallelParts: max(native.parallelParts, parts))
    }
}
