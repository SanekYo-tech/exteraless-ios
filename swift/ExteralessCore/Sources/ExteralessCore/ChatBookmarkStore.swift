import Foundation

public final class ChatBookmarkStore: @unchecked Sendable {
    public struct Bookmark: Codable, Equatable, Sendable {
        public let peerKey: Int64
        public let namespace: Int32
        public let messageId: Int32
        public let timestamp: Int32
        public init(peerKey: Int64, namespace: Int32, messageId: Int32, timestamp: Int32) {
            self.peerKey = peerKey; self.namespace = namespace; self.messageId = messageId; self.timestamp = timestamp
        }
        public func matches(_ other: Bookmark) -> Bool { peerKey == other.peerKey && namespace == other.namespace && messageId == other.messageId }
    }
    private static let lock = NSLock()
    private let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func list(account: Int64) throws -> [Bookmark] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try read(account: account)
    }
    @discardableResult public func toggle(_ bookmark: Bookmark, account: Int64) throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var items = try read(account: account)
        let isNew = !items.contains { $0.matches(bookmark) }
        items.removeAll { $0.matches(bookmark) }
        if isNew {
            guard items.count < 1000 else { throw CocoaError(.fileWriteOutOfSpace) }
            items.append(bookmark)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: file(account), options: .atomic)
        return isNew
    }
    private func file(_ account: Int64) -> URL { directory.appendingPathComponent("\(account).json") }
    private func read(account: Int64) throws -> [Bookmark] {
        let url = file(account)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 256 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        let decoded = try JSONDecoder().decode([Bookmark].self, from: Data(contentsOf: url))
        guard decoded.count <= 1000 else { throw CocoaError(.fileReadCorruptFile) }
        return decoded
    }
}
