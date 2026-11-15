import Foundation

public struct CloudLocalState: Codable, Equatable, Sendable {
    public let scope: CloudAccountScope
    public var acceptedHeads: [UUID]
    public var lastSuccessfulSyncMilliseconds: Int64
    public var uploadedContentDigest: String?

    public init(scope: CloudAccountScope, acceptedHeads: [UUID] = [], lastSuccessfulSyncMilliseconds: Int64 = -1,
                uploadedContentDigest: String? = nil) {
        self.scope = scope
        self.acceptedHeads = acceptedHeads
        self.lastSuccessfulSyncMilliseconds = lastSuccessfulSyncMilliseconds
        self.uploadedContentDigest = uploadedContentDigest
    }
}

public protocol CloudSyncStateStorage: Sendable {
    func load(scope: CloudAccountScope) throws -> CloudLocalState
    func save(_ state: CloudLocalState) throws
}

/// A small metadata-only file below the already-selected app root. No credentials,
/// archive payload, account authorization or personal document is stored here.
public final class CloudFileStateStorage: CloudSyncStateStorage, @unchecked Sendable {
    private struct Envelope: Codable { let version: Int; let state: CloudLocalState }
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) throws {
        guard directory.isFileURL,
              directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents == directory.standardizedFileURL.pathComponents else {
            throw CloudError.localStorage
        }
        self.directory = directory.standardizedFileURL
    }

    public func load(scope: CloudAccountScope) throws -> CloudLocalState {
        lock.lock()
        defer { lock.unlock() }
        do {
            let file = try ToolsFileSafety.checkedChild(scope.stateFileName, root: directory)
            guard FileManager.default.fileExists(atPath: file.path) else { return CloudLocalState(scope: scope) }
            let bytes = try ToolsFileSafety.read(file, maximumBytes: 8_192)
            let envelope = try CloudProtocol.decode(Envelope.self, bytes, limit: 8_192)
            guard envelope.version == 1, envelope.state.scope == scope else { throw CloudError.localStorage }
            try validate(envelope.state)
            return envelope.state
        } catch { throw CloudError.localStorage }
    }

    public func save(_ state: CloudLocalState) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try validate(state)
            guard directory.resolvingSymlinksInPath().pathComponents == directory.pathComponents else { throw CloudError.localStorage }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = try ToolsFileSafety.checkedChild(state.scope.stateFileName, root: directory)
            let bytes = try CloudProtocol.encode(Envelope(version: 1, state: state))
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { throw CloudError.localStorage }
    }

    private func validate(_ state: CloudLocalState) throws {
        guard state.acceptedHeads.count <= CloudProtocol.maximumHeads,
              Set(state.acceptedHeads).count == state.acceptedHeads.count,
              state.lastSuccessfulSyncMilliseconds == -1 || state.lastSuccessfulSyncMilliseconds > 0 else { throw CloudError.localStorage }
        if let digest = state.uploadedContentDigest {
            guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CloudError.localStorage }
        }
    }
}
