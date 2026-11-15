import CryptoKit
import ExteralessCore
import Foundation
import Postbox

public enum ExteralessRetentionError: Error, Equatable, Sendable {
    case unavailable, invalidArchive, unsupportedFormat, limitExceeded, mediaUnavailable, mediaIO, cancelled
}

/// Attached only to locally rendered archive messages. It is never inserted into cloud history.
public final class ExteralessRetentionMessageAttribute: MessageAttribute {
    public let sequence: UInt64
    public let capturedAt: Int64
    public let isDeleted: Bool
    public let isExpiredMedia: Bool
    public let isImported: Bool
    public let replyAuthorId: EnginePeer.Id?
    public let albumStableId: Int64?

    public init(sequence: UInt64, capturedAt: Int64, isDeleted: Bool, isExpiredMedia: Bool, isImported: Bool = false, replyAuthorId: EnginePeer.Id? = nil, albumStableId: Int64? = nil) {
        self.sequence = sequence
        self.capturedAt = capturedAt
        self.isDeleted = isDeleted
        self.isExpiredMedia = isExpiredMedia
        self.isImported = isImported
        self.replyAuthorId = replyAuthorId
        self.albumStableId = albumStableId
    }

    public init(decoder: PostboxDecoder) {
        self.sequence = UInt64(bitPattern: decoder.decodeInt64ForKey("s", orElse: 0))
        self.capturedAt = decoder.decodeInt64ForKey("t", orElse: 0)
        self.isDeleted = decoder.decodeInt32ForKey("d", orElse: 0) != 0
        self.isExpiredMedia = decoder.decodeInt32ForKey("e", orElse: 0) != 0
        self.isImported = decoder.decodeInt32ForKey("i", orElse: 0) != 0
        self.replyAuthorId = decoder.decodeOptionalInt64ForKey("ra").map(PeerId.init)
        self.albumStableId = decoder.decodeOptionalInt64ForKey("ag")
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt64(Int64(bitPattern: self.sequence), forKey: "s")
        encoder.encodeInt64(self.capturedAt, forKey: "t")
        encoder.encodeInt32(self.isDeleted ? 1 : 0, forKey: "d")
        encoder.encodeInt32(self.isExpiredMedia ? 1 : 0, forKey: "e")
        encoder.encodeInt32(self.isImported ? 1 : 0, forKey: "i")
        if let id = self.replyAuthorId { encoder.encodeInt64(id.toInt64(), forKey: "ra") } else { encoder.encodeNil(forKey: "ra") }
        if let id = self.albumStableId { encoder.encodeInt64(id, forKey: "ag") } else { encoder.encodeNil(forKey: "ag") }
    }
}

public extension EngineMessage {
    var exteralessRetention: ExteralessRetentionMessageAttribute? {
        self.attributes.first(where: { $0 is ExteralessRetentionMessageAttribute }) as? ExteralessRetentionMessageAttribute
    }
}

extension Message {
    var exteralessRetention: ExteralessRetentionMessageAttribute? {
        self.attributes.first(where: { $0 is ExteralessRetentionMessageAttribute }) as? ExteralessRetentionMessageAttribute
    }

    var retentionKey: RetentionMessageKey {
        RetentionMessageKey(peerId: self.id.peerId.toInt64(), namespace: self.id.namespace, id: self.id.id)
    }

    var retentionVersionDate: Int32 {
        max(self.timestamp, (self.attributes.first(where: { $0 is EditedMessageAttribute }) as? EditedMessageAttribute)?.date ?? 0)
    }
}

extension RetentionMessageKey {
    var messageId: MessageId { MessageId(peerId: PeerId(self.peerId), namespace: self.namespace, id: self.id) }
}

struct ExteralessRetentionCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

func exteralessRetentionCheckKeys(_ decoder: Decoder, _ allowed: Set<String>) throws {
    let c = try decoder.container(keyedBy: ExteralessRetentionCodingKey.self)
    guard c.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw ExteralessRetentionError.invalidArchive }
}

func exteralessRetentionEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

func exteralessRetentionDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func exteralessRetentionEncodeObject(_ object: PostboxCoding) -> Data {
    let encoder = PostboxEncoder()
    encoder.encodeRootObject(object)
    return encoder.makeData()
}

private struct ExteralessRetentionForward: Codable {
    let author: Int64?
    let source: Int64?
    let sourceMessage: RetentionMessageKey?
    let date: Int32
    let signature: String?
    let psa: String?
    let flags: Int32

    init(_ value: MessageForwardInfo) {
        self.author = value.author?.id.toInt64()
        self.source = value.source?.id.toInt64()
        self.sourceMessage = value.sourceMessageId.map { RetentionMessageKey(peerId: $0.peerId.toInt64(), namespace: $0.namespace, id: $0.id) }
        self.date = value.date
        self.signature = value.authorSignature
        self.psa = value.psaType
        self.flags = value.flags.rawValue
    }

    init(from decoder: Decoder) throws {
        try exteralessRetentionCheckKeys(decoder, ["author", "source", "sourceMessage", "date", "signature", "psa", "flags"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.author = try c.decodeIfPresent(Int64.self, forKey: .author)
        self.source = try c.decodeIfPresent(Int64.self, forKey: .source)
        self.sourceMessage = try c.decodeIfPresent(RetentionMessageKey.self, forKey: .sourceMessage)
        self.date = try c.decode(Int32.self, forKey: .date)
        self.signature = try c.decodeIfPresent(String.self, forKey: .signature)
        self.psa = try c.decodeIfPresent(String.self, forKey: .psa)
        self.flags = try c.decode(Int32.self, forKey: .flags)
    }

    func render(peers: SimpleDictionary<PeerId, Peer>) -> MessageForwardInfo {
        MessageForwardInfo(author: self.author.flatMap { peers[PeerId($0)] }, source: self.source.flatMap { peers[PeerId($0)] }, sourceMessageId: self.sourceMessage?.messageId, date: self.date, authorSignature: self.signature, psaType: self.psa, flags: MessageForwardInfo.Flags(rawValue: self.flags))
    }
}

/// A frozen native snapshot; serialization happens before the original row can be overwritten.
/// Native attributes preserve entities, replies, reactions, rich text and media descriptions.
private struct ExteralessRetentionStory: Codable {
    let peerId: Int64
    let id: Int32
    let data: Data

    init(id: StoryId, data: Data) { self.peerId = id.peerId.toInt64(); self.id = id.id; self.data = data }
    init(from decoder: Decoder) throws {
        try exteralessRetentionCheckKeys(decoder, ["peerId", "id", "data"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.peerId = try c.decode(Int64.self, forKey: .peerId)
        self.id = try c.decode(Int32.self, forKey: .id)
        self.data = try c.decode(Data.self, forKey: .data)
        guard self.peerId != 0, self.id > 0, self.data.count <= RetentionPolicy.maximumVersionBytes else { throw ExteralessRetentionError.invalidArchive }
    }
}

struct ExteralessRetentionSnapshot: Codable {
    let formatVersion: Int
    let key: RetentionMessageKey
    let stableId: UInt32
    let stableVersion: UInt32
    let globallyUniqueId: Int64?
    let groupingKey: Int64?
    let threadId: Int64?
    let timestamp: Int32
    let flags: UInt32
    let authorId: Int64?
    let text: String
    let attributes: [Data]
    let media: [Data]
    let peers: [Data]
    let mediaOmitted: Bool
    private let forward: ExteralessRetentionForward?
    private let stories: [ExteralessRetentionStory]
    let ayuSource: Data?
    let replyAuthorId: Int64?

    init(message: Message, includeMedia: Bool, ayuSource: Data? = nil, replyAuthorId: PeerId? = nil) throws {
        guard message.exteralessRetention == nil, message.id.peerId.toInt64() != 0, message.id.id != 0,
              message.timestamp > 0, !message.flags.contains(.Unsent), !message.flags.contains(.Sending),
              message.attributes.count <= 128, message.media.count <= 64, message.peers.count <= 128, message.associatedStories.count <= 64 else { throw ExteralessRetentionError.invalidArchive }
        self.formatVersion = 4
        self.ayuSource = ayuSource
        let replyId = (message.attributes.first(where: { $0 is ReplyMessageAttribute }) as? ReplyMessageAttribute)?.messageId
        self.replyAuthorId = (replyAuthorId ?? replyId.flatMap { message.associatedMessages[$0]?.author?.id })?.toInt64()
        self.key = message.retentionKey
        self.stableId = message.stableId
        self.stableVersion = message.stableVersion
        self.globallyUniqueId = message.globallyUniqueId
        self.groupingKey = message.groupingKey
        self.threadId = message.threadId
        self.timestamp = message.timestamp
        self.flags = message.flags.rawValue
        self.authorId = message.author?.id.toInt64()
        self.text = message.text
        self.attributes = message.attributes.map { attribute in
            if !includeMedia, let rich = attribute as? RichTextMessageAttribute {
                let page = rich.instantPage
                let textPage = InstantPage(blocks: page.blocks, rawMedia: [:], isComplete: page.isComplete, rtl: page.rtl, url: page.url, views: page.views)
                return exteralessRetentionEncodeObject(RichTextMessageAttribute(instantPage: textPage, fullInstantPage: nil))
            }
            if !includeMedia, let translation = attribute as? TranslationMessageAttribute, let page = translation.instantPage {
                let textPage = InstantPage(blocks: page.blocks, rawMedia: [:], isComplete: page.isComplete, rtl: page.rtl, url: page.url, views: page.views)
                return exteralessRetentionEncodeObject(TranslationMessageAttribute(text: translation.text, entities: translation.entities, additional: translation.additional, pollSolution: translation.pollSolution, toLang: translation.toLang, instantPage: textPage))
            }
            return exteralessRetentionEncodeObject(attribute)
        }
        self.media = includeMedia ? message.media.map(exteralessRetentionEncodeObject) : []
        var peers: [PeerId: Peer] = [:]
        for (id, peer) in message.peers { peers[id] = peer }
        if let author = message.author { peers[author.id] = author }
        if let author = message.forwardInfo?.author { peers[author.id] = author }
        if let source = message.forwardInfo?.source { peers[source.id] = source }
        self.peers = peers.sorted(by: { $0.key < $1.key }).map { exteralessRetentionEncodeObject($0.value) }
        self.mediaOmitted = !includeMedia && !message.effectiveMedia.isEmpty
        self.forward = message.forwardInfo.map(ExteralessRetentionForward.init)
        self.stories = includeMedia ? message.associatedStories.map { ExteralessRetentionStory(id: $0.key, data: $0.value.data) }.sorted { $0.peerId == $1.peerId ? $0.id < $1.id : $0.peerId < $1.peerId } : []
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sourceVersion = try c.decode(Int.self, forKey: .formatVersion)
        guard (1 ... 4).contains(sourceVersion) else { throw ExteralessRetentionError.unsupportedFormat }
        self.formatVersion = 4
        var keys: Set<String> = ["formatVersion", "key", "stableId", "stableVersion", "globallyUniqueId", "groupingKey", "threadId", "timestamp", "flags", "authorId", "text", "attributes", "media", "peers", "mediaOmitted", "forward"]
        if sourceVersion >= 2 { keys.insert("stories") }
        if sourceVersion >= 3 { keys.insert("ayuSource") }
        if sourceVersion >= 4 { keys.insert("replyAuthorId") }
        try exteralessRetentionCheckKeys(decoder, keys)
        self.key = try c.decode(RetentionMessageKey.self, forKey: .key)
        self.stableId = try c.decode(UInt32.self, forKey: .stableId)
        self.stableVersion = try c.decode(UInt32.self, forKey: .stableVersion)
        self.globallyUniqueId = try c.decodeIfPresent(Int64.self, forKey: .globallyUniqueId)
        self.groupingKey = try c.decodeIfPresent(Int64.self, forKey: .groupingKey)
        self.threadId = try c.decodeIfPresent(Int64.self, forKey: .threadId)
        self.timestamp = try c.decode(Int32.self, forKey: .timestamp)
        self.flags = try c.decode(UInt32.self, forKey: .flags)
        self.authorId = try c.decodeIfPresent(Int64.self, forKey: .authorId)
        self.text = try c.decode(String.self, forKey: .text)
        self.attributes = try c.decode([Data].self, forKey: .attributes)
        self.media = try c.decode([Data].self, forKey: .media)
        self.peers = try c.decode([Data].self, forKey: .peers)
        self.mediaOmitted = try c.decode(Bool.self, forKey: .mediaOmitted)
        self.forward = try c.decodeIfPresent(ExteralessRetentionForward.self, forKey: .forward)
        self.stories = sourceVersion >= 2 ? try c.decode([ExteralessRetentionStory].self, forKey: .stories) : []
        self.ayuSource = sourceVersion >= 3 ? try c.decodeIfPresent(Data.self, forKey: .ayuSource) : nil
        self.replyAuthorId = sourceVersion >= 4 ? try c.decodeIfPresent(Int64.self, forKey: .replyAuthorId) : nil
        guard self.timestamp > 0, self.attributes.count <= 128, self.media.count <= 64, self.peers.count <= 132,
              self.stories.count <= 64, self.text.utf8.count <= RetentionPolicy.maximumVersionBytes else { throw ExteralessRetentionError.invalidArchive }
    }

    func render(version: RetentionVersion, localMediaIndex: ExteralessRetentionIndex? = nil, albumStableId: Int64? = nil) throws -> Message {
        var peers = SimpleDictionary<PeerId, Peer>()
        for data in self.peers {
            guard let peer = PostboxDecoder(buffer: MemoryBuffer(data: data)).decodeRootObject() as? Peer else { throw ExteralessRetentionError.unsupportedFormat }
            peers[peer.id] = peer
        }
        var attributes: [MessageAttribute] = []
        func localPage(_ value: InstantPage) -> InstantPage {
            guard let index = localMediaIndex else { return value }
            var media: [MediaId: Media] = [:]
            for (id, item) in value.rawMedia {
                if let local = exteralessRetentionLocalMedia(item, index: index) { media[id] = local }
            }
            return InstantPage(blocks: value.blocks, rawMedia: media, isComplete: value.isComplete, rtl: value.rtl, url: value.url, views: value.views)
        }
        for data in self.attributes {
            guard let attribute = PostboxDecoder(buffer: MemoryBuffer(data: data)).decodeRootObject() as? MessageAttribute,
                  !(attribute is ExteralessRetentionMessageAttribute) else { throw ExteralessRetentionError.unsupportedFormat }
            if localMediaIndex != nil, let rich = attribute as? RichTextMessageAttribute {
                attributes.append(RichTextMessageAttribute(instantPage: localPage(rich.instantPage), fullInstantPage: rich.fullInstantPage.map(localPage)))
            } else if localMediaIndex != nil, let translation = attribute as? TranslationMessageAttribute {
                // The native AI display resolver may choose this cached page instead of the
                // original. Both pages must resolve exclusively through archive-owned files.
                attributes.append(TranslationMessageAttribute(text: translation.text, entities: translation.entities, additional: translation.additional, pollSolution: translation.pollSolution, toLang: translation.toLang, instantPage: translation.instantPage.map(localPage)))
            } else if localMediaIndex != nil && (attribute is ReplyMarkupMessageAttribute || attribute is AutoremoveTimeoutMessageAttribute || attribute is AutoclearTimeoutMessageAttribute) {
                // The archived copy has no live keyboard or server countdown. Original attributes
                // remain intact in the snapshot; only this local presentation is read-only.
            } else {
                attributes.append(attribute)
            }
        }
        var media: [Media] = []
        var stories: [StoryId: CodableEntry] = [:]
        for story in self.stories { stories[StoryId(peerId: PeerId(story.peerId), id: story.id)] = CodableEntry(data: story.data) }
        for data in self.media {
            guard let value = PostboxDecoder(buffer: MemoryBuffer(data: data)).decodeRootObject() as? Media else { throw ExteralessRetentionError.unsupportedFormat }
            if let localMediaIndex {
                if let story = value as? TelegramMediaStory, let stored = stories[story.storyId]?.get(Stories.StoredItem.self), case let .item(item) = stored, let source = item.media {
                    // Render the known attachment locally, not a live story viewer/read request.
                    if let local = exteralessRetentionLocalMedia(source, index: localMediaIndex) { media.append(local) }
                } else if let local = exteralessRetentionLocalMedia(value, index: localMediaIndex) { media.append(local) }
            } else { media.append(value) }
        }
        attributes.append(ExteralessRetentionMessageAttribute(sequence: version.sequence, capturedAt: version.capturedAt, isDeleted: version.reason == .deleted, isExpiredMedia: version.reason == .expired, isImported: self.ayuSource != nil, replyAuthorId: self.replyAuthorId.map(PeerId.init), albumStableId: albumStableId))
        var flags = MessageFlags(rawValue: self.flags)
        flags.subtract([.Unsent, .Sending, .Failed, .TopIndexable, .CountedAsIncoming, .ReactionsArePossible])
        let text = localMediaIndex != nil && self.text.isEmpty && (!self.media.isEmpty || self.mediaOmitted) && media.isEmpty && !attributes.contains(where: { $0 is RichTextMessageAttribute }) ? "Media unavailable in the local archive" : self.text
        return Message(stableId: self.stableId, stableVersion: self.stableVersion &+ UInt32(truncatingIfNeeded: version.sequence) &+ UInt32(truncatingIfNeeded: localMediaIndex?.revision ?? 0), id: self.key.messageId, globallyUniqueId: self.globallyUniqueId, groupingKey: self.groupingKey, groupInfo: nil, threadId: self.threadId, timestamp: self.timestamp, flags: flags, tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: self.forward?.render(peers: peers), author: self.authorId.flatMap { peers[PeerId($0)] }, text: text, attributes: attributes, media: media, peers: peers, associatedMessages: SimpleDictionary(), associatedMessageIds: [], associatedMedia: [:], associatedThreadInfo: nil, associatedStories: localMediaIndex == nil ? stories : [:])
    }
}

func exteralessRetentionFingerprint(text: String, attributes: [MessageAttribute], media: [Media]) -> String {
    var parts: [Data] = [Data(text.utf8)]
    for attribute in attributes where attribute is TextEntitiesMessageAttribute || attribute is RichTextMessageAttribute {
        parts.append(exteralessRetentionEncodeObject(attribute))
    }
    for item in media {
        if let image = item as? TelegramMediaImage {
            parts.append(Data("image:\(image.imageId.namespace):\(image.imageId.id)".utf8))
        } else if let file = item as? TelegramMediaFile {
            parts.append(Data("file:\(file.fileId.namespace):\(file.fileId.id)".utf8))
        } else {
            // Ayu's same-media test compares the media kind; photo/document ids refine it.
            // Poll votes, web preview refreshes and live-location ticks are not edit history.
            parts.append(Data(String(reflecting: type(of: item)).utf8))
        }
    }
    var digest = SHA256()
    for part in parts {
        // Length framing prevents text/attribute boundary ambiguity.
        var length = UInt64(part.count).bigEndian
        withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }
        digest.update(data: part)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

struct ExteralessRetentionResource {
    let id: String
    let size: Int64?
}

func exteralessRetentionResources(_ message: Message) -> [ExteralessRetentionResource] {
    var result: [String: ExteralessRetentionResource] = [:]
    func add(_ resource: MediaResource) {
        let id = resource.id.stringRepresentation
        guard !id.isEmpty, id.utf8.count <= 512, !id.contains("/"), !id.contains("\\"), !id.contains("\0"), id != ".", id != "..",
              result.count < RetentionPolicy.maximumResourcesPerVersion || result[id] != nil else { return }
        result[id] = ExteralessRetentionResource(id: id, size: resource.size)
    }
    func visit(_ media: Media, depth: Int) {
        guard depth < 4, result.count < RetentionPolicy.maximumResourcesPerVersion else { return }
        if let image = media as? TelegramMediaImage {
            for representation in image.representations { add(representation.resource) }
            for representation in image.videoRepresentations { add(representation.resource) }
            if let video = image.video { visit(video, depth: depth + 1) }
        } else if let file = media as? TelegramMediaFile {
            add(file.resource)
            for representation in file.previewRepresentations { add(representation.resource) }
            for thumbnail in file.videoThumbnails { add(thumbnail.resource) }
            if let cover = file.videoCover { visit(cover, depth: depth + 1) }
            for alternative in file.alternativeRepresentations { visit(alternative, depth: depth + 1) }
        } else if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content {
            if let image = content.image { visit(image, depth: depth + 1) }
            if let file = content.file { visit(file, depth: depth + 1) }
        } else if let paid = media as? TelegramMediaPaidContent {
            for item in paid.extendedMedia {
                if case let .full(media) = item { visit(media, depth: depth + 1) }
            }
        } else if let poll = media as? TelegramMediaPoll {
            if let media = poll.attachedMedia { visit(media, depth: depth + 1) }
            for option in poll.options { if let media = option.media { visit(media, depth: depth + 1) } }
            if let media = poll.results.solution?.media { visit(media, depth: depth + 1) }
        } else if let story = media as? TelegramMediaStory, let stored = message.associatedStories[story.storyId]?.get(Stories.StoredItem.self), case let .item(item) = stored {
            if let media = item.media { visit(media, depth: depth + 1) }
            for media in item.alternativeMediaList { visit(media, depth: depth + 1) }
        }
    }
    for media in message.effectiveMedia { visit(media, depth: 0) }
    for attribute in message.attributes {
        if let page = (attribute as? TranslationMessageAttribute)?.instantPage {
            for media in page.rawMedia.values { visit(media, depth: 0) }
        }
    }
    return result.values.sorted { $0.id < $1.id }
}
