import Foundation

/// Immutable revisions form a bounded DAG. Telegram's original bot storage has
/// no CAS: concurrent children remain separate heads instead of silently replacing
/// one shared manifest. A later sync must explicitly acknowledge ALL visible heads.
public actor CloudRemoteStore {
    private let owner: CloudRemoteOwner
    private let transport: any CloudKeyValueTransport
    private let compression: CloudCompression
    private var abandonedUploads = Set<UUID>()

    public init(owner: CloudRemoteOwner, transport: any CloudKeyValueTransport, compression: CloudCompression) {
        self.owner = owner
        self.transport = transport
        self.compression = compression
    }

    public func catalog() async throws -> CloudCatalog {
        try Task.checkCancellation()
        let listed = try await transport.keys()
        guard listed.count <= CloudProtocol.maximumKeys, Set(listed).count == listed.count,
              listed.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw CloudError.malformedRemote }
        let allKeys = Set(listed)
        let manifestKeys = listed.filter { $0.hasPrefix(CloudProtocol.nativePrefix + "r.") }.sorted()
        guard manifestKeys.count <= CloudProtocol.maximumRevisions else { throw CloudError.storageFull }
        var revisions: [CloudRevision] = []
        for batch in batches(manifestKeys) {
            try Task.checkCancellation()
            let values = try await transport.get(batch)
            for key in batch {
                guard let raw = values[key], raw.utf8.count <= CloudProtocol.chunkCharacters else { throw CloudError.malformedRemote }
                let revision = try CloudProtocol.decode(CloudRevision.self, Data(raw.utf8), limit: CloudProtocol.chunkCharacters)
                try revision.validate(owner: owner)
                guard key == CloudProtocol.manifestKey(revision.id) else { throw CloudError.malformedRemote }
                revisions.append(revision)
            }
        }
        let byId = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0) })
        let referenced = Set(revisions.flatMap(\.parents))
        guard referenced.isSubset(of: Set(byId.keys)) else { throw CloudError.malformedRemote }
        var visited = Set<UUID>()
        var visiting = Set<UUID>()
        func visit(_ id: UUID) throws {
            if visited.contains(id) { return }
            guard visiting.insert(id).inserted, let revision = byId[id] else { throw CloudError.malformedRemote }
            for parent in revision.parents { try visit(parent) }
            visiting.remove(id)
            visited.insert(id)
        }
        for revision in revisions { try visit(revision.id) }
        let heads = Set(byId.keys).subtracting(referenced)
        return CloudCatalog(revisions: revisions, heads: heads,
                            hasAndroidBackup: allKeys.contains("neko_settings"), allKeys: allKeys)
    }

    public func publish(_ payload: Data, expectedHeads: Set<UUID>, date: Date = Date(),
                        allowed: @escaping @Sendable () -> Bool = { true }) async throws -> CloudRevision {
        guard payload.count <= CloudProtocol.maximumPayloadBytes else { throw CloudError.sizeLimit }
        guard expectedHeads.count <= CloudProtocol.maximumHeads else { throw CloudError.conflict }
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds > 0, milliseconds < Double(Int64.max) else { throw CloudError.malformedRemote }
        let before = try await catalog()
        guard before.heads == expectedHeads else { throw CloudError.conflict }
        guard allowed() else { throw CancellationError() }
        let compressed = try compression.compress(payload)
        let encoded = compressed.base64EncodedString()
        let bytes = Array(encoded.utf8)
        let count = (bytes.count + CloudProtocol.chunkCharacters - 1) / CloudProtocol.chunkCharacters
        guard count > 0, count <= CloudProtocol.maximumChunks else { throw CloudError.sizeLimit }
        guard before.allKeys.count + count + 1 <= CloudProtocol.maximumKeys,
              before.revisions.count < CloudProtocol.maximumRevisions else { throw CloudError.storageFull }
        let id = UUID()
        var manifestStarted = false
        defer {
            // Only this process knows a failed local uploader will never publish
            // a commit record. Unknown orphan chunks are not repair authority.
            if !manifestStarted { abandonedUploads.insert(id) }
        }
        let revision = CloudRevision(version: 1, id: id, parents: expectedHeads.sorted { $0.uuidString < $1.uuidString }, owner: owner,
            createdAtMilliseconds: Int64(milliseconds), encoding: CloudProtocol.encoding,
            chunks: count, encodedCharacters: bytes.count, sha256: ToolsSHA256.hex(compressed))
        try revision.validate(owner: owner)
        for index in 0..<count {
            try Task.checkCancellation()
            guard allowed() else { throw CancellationError() }
            let start = index * CloudProtocol.chunkCharacters
            let value = String(decoding: bytes[start..<min(bytes.count, start + CloudProtocol.chunkCharacters)], as: UTF8.self)
            try await transport.set(key: CloudProtocol.chunkKey(id, index), value: value)
        }
        // Verify the complete stored data before publishing the commit record.
        guard try await readCompressed(revision) == compressed else { throw CloudError.checksumMismatch }
        guard try await catalog().heads == expectedHeads else { throw CloudError.conflict }
        try Task.checkCancellation()
        guard allowed() else { throw CancellationError() }
        let manifest = try CloudProtocol.encode(revision)
        guard manifest.count <= CloudProtocol.chunkCharacters else { throw CloudError.sizeLimit }
        manifestStarted = true
        try await transport.set(key: CloudProtocol.manifestKey(id), value: String(decoding: manifest, as: UTF8.self))
        try Task.checkCancellation()
        let after = try await catalog()
        guard after.heads == [id], after.revisions.contains(revision) else { throw CloudError.conflict }
        return revision
    }

    public func read(_ revision: CloudRevision) async throws -> Data {
        try revision.validate(owner: owner)
        let bytes = try await readCompressed(revision)
        let result = try compression.decompress(bytes, CloudProtocol.maximumPayloadBytes)
        guard result.count <= CloudProtocol.maximumPayloadBytes else { throw CloudError.sizeLimit }
        return result
    }

    /// Explicit settings-restore action only. Reading legacy chunks is separate
    /// from importing Android preferences; no personal document is searched.
    public func readAndroidArchive() async throws -> Data {
        try await readAndroidSnapshot().data
    }

    public func readAndroidSnapshot() async throws -> CloudLegacyRemoteSnapshot {
        let metadata = try await transport.get(["neko_settings", "neko_settings_encoding", "neko_settings_updated_at"])
        guard let rawCount = metadata["neko_settings"], let count = Int(rawCount), count > 0 else { throw CloudError.noBackup }
        guard count <= CloudProtocol.maximumChunks else { throw CloudError.sizeLimit }
        let encoding = metadata["neko_settings_encoding"] ?? ""
        guard encoding.isEmpty || encoding == CloudProtocol.encoding else { throw CloudError.unsupportedVersion }
        let payload = try await readAndroidChunks(count: count, plain: encoding.isEmpty)
        guard try await transport.get(["neko_settings", "neko_settings_encoding", "neko_settings_updated_at"]) == metadata else { throw CloudError.conflict }
        // Original storage has no transaction/CAS. Two identical chunk reads and
        // metadata bookends detect mixed/in-flight writes without claiming a lock.
        guard try await readAndroidChunks(count: count, plain: encoding.isEmpty) == payload,
              try await transport.get(["neko_settings", "neko_settings_encoding", "neko_settings_updated_at"]) == metadata else { throw CloudError.conflict }
        let result: Data
        if encoding == CloudProtocol.encoding {
            guard let compressed = Data(base64Encoded: payload) else { throw CloudError.malformedRemote }
            result = try compression.decompress(compressed, CloudProtocol.maximumPayloadBytes)
        } else {
            result = Data(payload.utf8)
        }
        guard result.count <= CloudProtocol.maximumPayloadBytes else { throw CloudError.sizeLimit }
        struct Version: Encodable { let metadata: [String: String]; let payload: String }
        let fingerprint = ToolsSHA256.hex(try CloudProtocol.encode(Version(metadata: metadata, payload: payload)))
        let reportedDate = metadata["neko_settings_updated_at"].flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil }
        return CloudLegacyRemoteSnapshot(owner: owner, fingerprint: fingerprint, reportedUpdatedAtMilliseconds: reportedDate, data: result)
    }

    private func readAndroidChunks(count: Int, plain: Bool) async throws -> String {
        var payload = ""
        let names = (0..<count).map { "neko_settings_\($0)" }
        let batchSize = plain ? 16 : CloudProtocol.batchSize
        for start in stride(from: 0, to: names.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(names[start..<min(names.count, start + batchSize)])
            let values = try await transport.get(batch)
            for key in batch {
                guard let value = values[key], value.utf16.count <= CloudProtocol.chunkCharacters else { throw CloudError.malformedRemote }
                payload += value
                guard payload.utf8.count <= CloudProtocol.maximumPayloadBytes else { throw CloudError.sizeLimit }
            }
        }
        return payload
    }

    /// Deletes only the captured native namespace after a user action. An Android
    /// backup and unrelated Mini App keys are never part of this deletion.
    public func deleteNativeHistory(expectedHeads: Set<UUID>) async throws {
        let before = try await catalog()
        guard before.heads == expectedHeads else { throw CloudError.conflict }
        let keys = before.allKeys.filter { $0.hasPrefix(CloudProtocol.nativePrefix) }.sorted()
        try await deleteCapturedKeys(keys)
    }

    /// Delete only a stable captured set proven malformed or locally abandoned.
    /// Healthy revisions, required parents and unknown/in-flight chunks survive.
    public func deleteDamagedNativeData() async throws {
        let abandoned = abandonedUploads
        let captured = try await repairSnapshot()
        let plan = try CloudRepairPlan.make(snapshot: captured, owner: owner, abandoned: abandoned)
        var expected = captured
        for batch in batches(plan.keys.sorted()) {
            try Task.checkCancellation()
            // A second listing can only invalidate this plan, never add targets.
            guard try await repairSnapshot() == expected else { throw CloudError.conflict }
            try await transport.remove(batch)
            expected = expected.removing(Set(batch))
        }
        try Task.checkCancellation()
        guard try await repairSnapshot() == expected else { throw CloudError.conflict }
        abandonedUploads.subtract(plan.abandonedIDs)
    }

    private func repairSnapshot() async throws -> CloudRepairSnapshot {
        try Task.checkCancellation()
        let all = try await transport.keys()
        guard all.count <= CloudProtocol.maximumKeys, Set(all).count == all.count,
              all.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw CloudError.malformedRemote }
        let keys = all.filter { $0.hasPrefix(CloudProtocol.nativePrefix) }.sorted()
        var result: [String: Data] = [:]
        for batch in batches(keys) {
            try Task.checkCancellation()
            let values = try await transport.get(batch)
            for key in batch {
                guard let value = values[key], value.utf8.count <= CloudProtocol.chunkCharacters else { throw CloudError.conflict }
                result[key] = Data(value.utf8)
            }
        }
        return CloudRepairSnapshot(values: result)
    }

    private func deleteCapturedKeys(_ keys: [String]) async throws {
        for batch in batches(keys) {
            try Task.checkCancellation()
            try await transport.remove(batch)
        }
        try Task.checkCancellation()
        guard try await transport.keys().allSatisfy({ !$0.hasPrefix(CloudProtocol.nativePrefix) }) else { throw CloudError.conflict }
    }

    private func readCompressed(_ revision: CloudRevision) async throws -> Data {
        var joined = ""
        let keys = (0..<revision.chunks).map { CloudProtocol.chunkKey(revision.id, $0) }
        for batch in batches(keys) {
            try Task.checkCancellation()
            let values = try await transport.get(batch)
            for key in batch {
                guard let value = values[key], value.utf8.count <= CloudProtocol.chunkCharacters else { throw CloudError.malformedRemote }
                joined += value
            }
        }
        guard joined.utf8.count == revision.encodedCharacters, let bytes = Data(base64Encoded: joined) else { throw CloudError.malformedRemote }
        guard ToolsSHA256.hex(bytes) == revision.sha256 else { throw CloudError.checksumMismatch }
        return bytes
    }

    private func batches(_ keys: [String]) -> [[String]] {
        stride(from: 0, to: keys.count, by: CloudProtocol.batchSize).map {
            Array(keys[$0..<min(keys.count, $0 + CloudProtocol.batchSize)])
        }
    }
}
