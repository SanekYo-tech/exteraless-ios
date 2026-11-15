import Foundation

struct CloudRepairSnapshot: Equatable, Sendable {
    let values: [String: Data]

    func removing(_ keys: Set<String>) -> Self {
        Self(values: values.filter { !keys.contains($0.key) })
    }
}

/// Conservative repair authorization, not another namespace-wide delete. Valid
/// records (and all their parents/chunks) are protected even when another record
/// is malformed. Unknown orphan chunks might belong to an in-flight writer.
struct CloudRepairPlan: Sendable {
    let keys: Set<String>
    let abandonedIDs: Set<UUID>

    static func make(snapshot: CloudRepairSnapshot, owner: CloudRemoteOwner, abandoned: Set<UUID>) throws -> Self {
        var manifests: [UUID: Data] = [:]
        var chunks: [UUID: Set<String>] = [:]
        for (key, bytes) in snapshot.values {
            if key.hasPrefix(CloudProtocol.nativePrefix + "r.") {
                let raw = String(key.dropFirst((CloudProtocol.nativePrefix + "r.").count))
                guard let id = UUID(uuidString: raw), key == CloudProtocol.manifestKey(id) else { throw CloudError.conflict }
                manifests[id] = bytes
            } else if key.hasPrefix(CloudProtocol.nativePrefix + "c.") {
                let parts = key.dropFirst((CloudProtocol.nativePrefix + "c.").count).split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), let index = Int(parts[1]),
                      (0..<CloudProtocol.maximumChunks).contains(index), key == CloudProtocol.chunkKey(id, index) else { throw CloudError.conflict }
                chunks[id, default: []].insert(key)
            } else {
                throw CloudError.conflict // A future/unknown native record is not garbage.
            }
        }
        guard manifests.count <= CloudProtocol.maximumRevisions else { throw CloudError.storageFull }
        var valid: [UUID: CloudRevision] = [:]
        var malformed = Set<UUID>()
        for (id, bytes) in manifests {
            do {
                let revision = try CloudProtocol.decode(CloudRevision.self, bytes, limit: CloudProtocol.chunkCharacters)
                try revision.validate(owner: owner)
                guard revision.id == id else { throw CloudError.malformedRemote }
                valid[id] = revision
            } catch let error as CloudError {
                guard error == .malformedRemote else { throw error }
                malformed.insert(id)
            }
        }
        // A malformed/missing parent may still be needed by a valid revision.
        // Reject that ambiguity rather than destroying a usable descendant.
        var visited = Set<UUID>(), visiting = Set<UUID>()
        func visit(_ id: UUID) throws {
            if visited.contains(id) { return }
            guard visiting.insert(id).inserted, let revision = valid[id] else { throw CloudError.conflict }
            for parent in revision.parents { try visit(parent) }
            visiting.remove(id)
            visited.insert(id)
        }
        for id in valid.keys { try visit(id) }
        var keys = Set(malformed.map(CloudProtocol.manifestKey))
        for id in malformed { keys.formUnion(chunks[id] ?? []) }
        let provenAbandoned = abandoned.filter { manifests[$0] == nil }
        for id in provenAbandoned { keys.formUnion(chunks[id] ?? []) }
        guard !keys.isEmpty else { throw snapshot.values.isEmpty ? CloudError.noBackup : .conflict }
        return Self(keys: keys, abandonedIDs: Set(provenAbandoned))
    }
}
