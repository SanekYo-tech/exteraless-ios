import Foundation
import Postbox

/// Routing provenance lives with the returned native reference. It is not an ownership grant;
/// materialization still admits the current account, epoch, token and live version in Postbox.
struct RetentionResourceProvenance: Codable, Equatable {
    let accountPeerId: Int64
    let epoch: String
    let token: String
    let sourceId: String

    init(entry: ExteralessRetentionMediaEntry, index: ExteralessRetentionIndex) {
        self.accountPeerId = index.accountPeerId; self.epoch = index.epoch
        self.token = entry.token; self.sourceId = entry.id
    }

    init(from decoder: Decoder) throws {
        try exteralessRetentionCheckKeys(decoder, ["accountPeerId", "epoch", "token", "sourceId"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.accountPeerId = try c.decode(Int64.self, forKey: .accountPeerId)
        self.epoch = try c.decode(String.self, forKey: .epoch)
        self.token = try c.decode(String.self, forKey: .token)
        self.sourceId = try c.decode(String.self, forKey: .sourceId)
        guard self.accountPeerId != 0, UUID(uuidString: self.epoch)?.uuidString.lowercased() == self.epoch,
              RetentionMediaOwnership.nativeId(token: self.token) != nil,
              ExteralessRetentionMediaEntry.validResourceId(self.sourceId) else { throw ExteralessRetentionError.invalidArchive }
    }

    func matches(_ admission: RetentionMediaAdmission) -> Bool {
        admission.index.accountPeerId == self.accountPeerId && admission.index.epoch == self.epoch
            && admission.entry.token == self.token && admission.entry.id == self.sourceId
    }
}

/// A stock local-file identity with an immutable, bounded retention tag. A consumer can retain
/// this object after GC or owner disposal and still receive a terminal denial instead of falling
/// through to the stock unhandled-local-resource path. Ordinary LocalFileMediaResource is intact.
final class ExteralessRetainedLocalFileMediaResource: LocalFileMediaResource {
    let retentionProvenance: RetentionResourceProvenance?

    init(entry: ExteralessRetentionMediaEntry, index: ExteralessRetentionIndex, size: Int64?) {
        self.retentionProvenance = RetentionResourceProvenance(entry: entry, index: index)
        super.init(fileId: entry.cacheFileId, size: size)
    }

    required init(decoder: PostboxDecoder) {
        if let data = decoder.decodeDataForKey("exteraless.retention"), data.count <= 2048 {
            self.retentionProvenance = try? JSONDecoder().decode(RetentionResourceProvenance.self, from: data)
        } else { self.retentionProvenance = nil }
        super.init(decoder: decoder)
    }

    private enum Keys: String, CodingKey { case provenance = "exteraless.retention" }
    required init(from decoder: Decoder) throws {
        self.retentionProvenance = try decoder.container(keyedBy: Keys.self).decodeIfPresent(RetentionResourceProvenance.self, forKey: .provenance)
        try super.init(from: decoder)
    }

    override func encode(_ encoder: PostboxEncoder) {
        super.encode(encoder)
        if let value = self.retentionProvenance, let data = try? JSONEncoder().encode(value) { encoder.encodeData(data, forKey: "exteraless.retention") }
        else { encoder.encodeNil(forKey: "exteraless.retention") }
    }

    override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(self.retentionProvenance, forKey: .provenance)
    }

    override func isEqual(to: MediaResource) -> Bool {
        guard let other = to as? ExteralessRetainedLocalFileMediaResource else { return false }
        return super.isEqual(to: other) && self.retentionProvenance == other.retentionProvenance
    }
}

/// Called only by initializeAccountManagement's once-only declaration block, before concurrent
/// Postbox decoding. The stock global coding registry does not support runtime mutation.
func registerExteralessRetentionResourceCoding() {
    declareEncodable(ExteralessRetainedLocalFileMediaResource.self, f: { ExteralessRetainedLocalFileMediaResource(decoder: $0) })
}

func exteralessRetentionLocalResource(entry: ExteralessRetentionMediaEntry, index: ExteralessRetentionIndex, size: Int64?) -> LocalFileMediaResource {
    return ExteralessRetainedLocalFileMediaResource(entry: entry, index: index, size: size)
}
