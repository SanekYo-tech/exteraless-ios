import Foundation

public enum RetentionArchiveError: Error, Equatable, Sendable {
    case invalidData, unsupportedVersion, limitExceeded
}

/// Native peer namespace is packed by PeerId.toInt64(); do not use abs(peerId).
public struct RetentionMessageKey: Codable, Hashable, Comparable, Sendable {
    public let peerId: Int64
    public let namespace: Int32
    public let id: Int32

    public init(peerId: Int64, namespace: Int32, id: Int32) {
        self.peerId = peerId
        self.namespace = namespace
        self.id = id
    }

    public var storageKey: String { "\(self.peerId):\(self.namespace):\(self.id)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.peerId != rhs.peerId { return lhs.peerId < rhs.peerId }
        if lhs.namespace != rhs.namespace { return lhs.namespace < rhs.namespace }
        return lhs.id < rhs.id
    }

    public init(from decoder: Decoder) throws {
        try retentionRejectUnknownKeys(decoder, allowed: ["peerId", "namespace", "id"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.peerId = try c.decode(Int64.self, forKey: .peerId)
        self.namespace = try c.decode(Int32.self, forKey: .namespace)
        self.id = try c.decode(Int32.self, forKey: .id)
        guard self.peerId != 0, self.namespace >= 0, self.id != 0 else { throw RetentionArchiveError.invalidData }
    }
}

/// The payload is the native, versioned message snapshot. This module never interprets Telegram data.
public struct RetentionVersion: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case edit, deleted, expired }

    public let sequence: UInt64
    public let capturedAt: Int64
    public let messageVersionDate: Int32
    public let fingerprint: String
    public let reason: Reason
    public let payload: Data
    public let resourceIds: [String]

    public init(sequence: UInt64, capturedAt: Int64, messageVersionDate: Int32, fingerprint: String, reason: Reason, payload: Data, resourceIds: [String]) throws {
        self.sequence = sequence
        self.capturedAt = capturedAt
        self.messageVersionDate = messageVersionDate
        self.fingerprint = fingerprint
        self.reason = reason
        self.payload = payload
        self.resourceIds = resourceIds
        try self.validate()
    }

    public init(from decoder: Decoder) throws {
        try retentionRejectUnknownKeys(decoder, allowed: ["sequence", "capturedAt", "messageVersionDate", "fingerprint", "reason", "payload", "resourceIds"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sequence = try c.decode(UInt64.self, forKey: .sequence)
        self.capturedAt = try c.decode(Int64.self, forKey: .capturedAt)
        self.messageVersionDate = try c.decode(Int32.self, forKey: .messageVersionDate)
        self.fingerprint = try c.decode(String.self, forKey: .fingerprint)
        self.reason = try c.decode(Reason.self, forKey: .reason)
        self.payload = try c.decode(Data.self, forKey: .payload)
        self.resourceIds = try c.decode([String].self, forKey: .resourceIds)
        try self.validate()
    }

    private func validate() throws {
        guard self.sequence > 0, self.capturedAt > 0, self.messageVersionDate > 0,
              self.fingerprint.utf8.count == 64, self.fingerprint.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }),
              !self.payload.isEmpty, self.payload.count <= RetentionPolicy.maximumVersionBytes,
              self.resourceIds.count <= RetentionPolicy.maximumResourcesPerVersion,
              Set(self.resourceIds).count == self.resourceIds.count,
              self.resourceIds.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("/") && !$0.contains("\\") && !$0.contains("\0") && $0 != "." && $0 != ".." }) else {
            throw RetentionArchiveError.invalidData
        }
    }
}

/// Per-message transaction journal. Sequence numbers are LOCAL, never pts/seq/message IDs.
public struct RetentionPolicyRecord: Codable, Equatable, Sendable {
    public static let formatVersion = 2

    public let key: RetentionMessageKey
    public private(set) var versions: [RetentionVersion]
    public private(set) var deletedAt: Int64?
    public private(set) var lastEditDate: Int32?
    public private(set) var nextSequence: UInt64
    private var events: [String]

    public init(key: RetentionMessageKey) {
        self.key = key
        self.versions = []
        self.deletedAt = nil
        self.lastEditDate = nil
        self.nextSequence = 1
        self.events = []
    }

    /// Captures the old locally known version. A stale server edit does not roll back the archive.
    /// The caller still applies every update to Telegram's real state machinery.
    @discardableResult
    public mutating func captureEdit(payload: Data, fingerprint: String, resourceIds: [String], previousVersionDate: Int32, incomingFingerprint: String, incomingEditDate: Int32?, now: Int64, expired: Bool = false) throws -> Bool {
        guard self.deletedAt == nil, expired || fingerprint != incomingFingerprint else { return false }
        if let incomingEditDate {
            if incomingEditDate < previousVersionDate { return false }
            if let lastEditDate = self.lastEditDate, incomingEditDate < lastEditDate { return false }
        }
        let event = "\(previousVersionDate):\(fingerprint):\(incomingEditDate ?? 0):\(incomingFingerprint):\(expired ? 1 : 0)"
        guard incomingFingerprint.utf8.count == 64, incomingFingerprint.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }) else { throw RetentionArchiveError.invalidData }
        guard !self.events.contains(event), !self.versions.contains(where: { $0.messageVersionDate == previousVersionDate && $0.fingerprint == fingerprint && $0.reason != .deleted }) else { return false }
        let version = try RetentionVersion(sequence: self.nextSequence, capturedAt: now, messageVersionDate: previousVersionDate, fingerprint: fingerprint, reason: expired ? .expired : .edit, payload: payload, resourceIds: resourceIds)
        try self.append(version)
        self.events.append(event)
        if self.events.count > 64 { self.events.removeFirst(self.events.count - 64) }
        if let incomingEditDate { self.lastEditDate = max(self.lastEditDate ?? 0, incomingEditDate) }
        return true
    }

    @discardableResult
    public mutating func captureDeletion(payload: Data, fingerprint: String, resourceIds: [String], messageVersionDate: Int32, now: Int64) throws -> Bool {
        guard self.deletedAt == nil else { return false }
        let version = try RetentionVersion(sequence: self.nextSequence, capturedAt: now, messageVersionDate: messageVersionDate, fingerprint: fingerprint, reason: .deleted, payload: payload, resourceIds: resourceIds)
        try self.append(version)
        self.deletedAt = now
        return true
    }

    private mutating func append(_ version: RetentionVersion) throws {
        guard self.nextSequence < UInt64.max else { throw RetentionArchiveError.limitExceeded }
        self.versions.append(version)
        self.nextSequence += 1
        if self.versions.count > RetentionPolicy.maximumVersions {
            self.versions.removeFirst(self.versions.count - RetentionPolicy.maximumVersions)
        }
    }

    /// Ordering remains deterministic for multiple edits with the same server second.
    public var chronologicalVersions: [RetentionVersion] {
        self.versions.sorted {
            if $0.messageVersionDate != $1.messageVersionDate { return $0.messageVersionDate < $1.messageVersionDate }
            return $0.sequence < $1.sequence
        }
    }

    public mutating func prune(cutoff: Int64) {
        self.versions.removeAll { $0.capturedAt <= cutoff }
        // Keep a deletion tombstone until its original deadline, even if a version was removed.
        if let deletedAt = self.deletedAt, deletedAt <= cutoff { self.deletedAt = nil }
    }

    public mutating func removeVersion(sequence: UInt64) {
        self.versions.removeAll { $0.sequence == sequence }
    }

    /// Explicit history import is a local archive merge, not a received server update. Ayu's
    /// deleted key is the message identity; its edit key adds capture date and edit date.
    @discardableResult
    public mutating func mergeImported(payload: Data, fingerprint: String, resourceIds: [String], reason: RetentionVersion.Reason, versionDate: Int32, capturedAt: Int64) throws -> Bool {
        if reason == .deleted, self.deletedAt != nil { return false }
        if self.versions.contains(where: { $0.reason == reason && $0.capturedAt == capturedAt && $0.messageVersionDate == versionDate }) { return false }
        guard self.nextSequence < UInt64.max else { throw RetentionArchiveError.limitExceeded }
        let version = try RetentionVersion(sequence: self.nextSequence, capturedAt: capturedAt, messageVersionDate: versionDate, fingerprint: fingerprint, reason: reason, payload: payload, resourceIds: resourceIds)
        self.versions.append(version)
        self.nextSequence += 1
        self.versions.sort { $0.capturedAt == $1.capturedAt ? $0.sequence < $1.sequence : $0.capturedAt < $1.capturedAt }
        if self.versions.count > RetentionPolicy.maximumVersions { self.versions.removeFirst(self.versions.count - RetentionPolicy.maximumVersions) }
        if reason == .deleted { self.deletedAt = capturedAt }
        return true
    }

    public var resourceIds: Set<String> { Set(self.versions.flatMap(\.resourceIds)) }
    public var payloadBytes: Int { self.versions.reduce(0) { $0 + $1.payload.count } }

    private enum CodingKeys: String, CodingKey { case formatVersion, key, versions, deletedAt, lastEditDate, nextSequence, events }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .formatVersion)
        guard version == 1 || version == Self.formatVersion else { throw RetentionArchiveError.unsupportedVersion }
        try retentionRejectUnknownKeys(decoder, allowed: version == 1
            ? ["formatVersion", "key", "versions", "deletedAt"]
            : ["formatVersion", "key", "versions", "deletedAt", "lastEditDate", "nextSequence", "events"])
        self.key = try c.decode(RetentionMessageKey.self, forKey: .key)
        self.versions = try c.decode([RetentionVersion].self, forKey: .versions)
        self.deletedAt = try c.decodeIfPresent(Int64.self, forKey: .deletedAt)
        guard self.versions.count <= RetentionPolicy.maximumVersions,
              Set(self.versions.map(\.sequence)).count == self.versions.count,
              self.deletedAt == nil || self.deletedAt! > 0 else { throw RetentionArchiveError.invalidData }
        let maximumSequence = self.versions.map(\.sequence).max() ?? 0
        guard maximumSequence < UInt64.max else { throw RetentionArchiveError.invalidData }
        if version == 1 {
            // v1 had no replay watermark. Derive only what the locally saved versions prove.
            self.lastEditDate = self.versions.map(\.messageVersionDate).max()
            self.nextSequence = maximumSequence + 1
            self.events = []
        } else {
            self.lastEditDate = try c.decodeIfPresent(Int32.self, forKey: .lastEditDate)
            self.nextSequence = try c.decode(UInt64.self, forKey: .nextSequence)
            self.events = try c.decode([String].self, forKey: .events)
        }
        guard self.nextSequence > maximumSequence, self.events.count <= 64,
              self.events.allSatisfy({ $0.utf8.count <= 180 }),
              self.lastEditDate == nil || self.lastEditDate! > 0 else { throw RetentionArchiveError.invalidData }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .formatVersion)
        try c.encode(self.key, forKey: .key)
        try c.encode(self.versions, forKey: .versions)
        try c.encodeIfPresent(self.deletedAt, forKey: .deletedAt)
        try c.encodeIfPresent(self.lastEditDate, forKey: .lastEditDate)
        try c.encode(self.nextSequence, forKey: .nextSequence)
        try c.encode(self.events, forKey: .events)
    }
}
