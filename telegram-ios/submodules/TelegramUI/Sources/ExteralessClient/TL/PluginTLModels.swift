import CoreFoundation
import Foundation
import TelegramCore

enum PluginTLModel {
    static func object(_ value: Any, name: String, keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: keys) else {
            throw ExteralessTLError(.malformed, "\(name): expected an object without unknown/read-only fields")
        }
        return object
    }

    static func integer(_ value: Any?, name: String) throws -> Int64 {
        guard let value, let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              let result = Int64(number.stringValue) else {
            throw ExteralessTLError(.malformed, "\(name): expected an exact Int64 integer")
        }
        return result
    }

    static func string(_ value: Any?, name: String, maximum: Int) throws -> String {
        guard let result = value as? String, result.utf8.count <= maximum, !result.contains("\0") else {
            throw ExteralessTLError(.malformed, "\(name): expected a bounded string without NUL")
        }
        return result
    }

    static func bool(_ value: Any?, name: String, default defaultValue: Bool) throws -> Bool {
        guard let value else { return defaultValue }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ExteralessTLError(.malformed, "\(name): expected a Boolean")
        }
        return number.boolValue
    }

    static func peer(_ value: Any?) throws -> ExteralessTLPeerReference {
        guard let value else { throw ExteralessTLError(.malformed, "peer is required") }
        let object = try self.object(value, name: "peer", keys: ["type", "id"])
        guard let name = object["type"] as? String, let kind = ExteralessTLPeerReference.Kind(rawValue: name) else {
            throw ExteralessTLError(.malformed, "peer.type must be user, group, channel or secret")
        }
        return try ExteralessTLPeerReference(kind: kind, id: self.integer(object["id"], name: "peer.id"))
    }

    static func callbackHandle(_ value: Any) throws -> Int64 {
        let object = try self.object(value, name: "callback", keys: ["__handle__", "__fqcn__", "__fqcn"])
        let handle = try self.integer(object["__handle__"], name: "callback.__handle__")
        guard handle > 0 else { throw ExteralessTLError(.malformed, "callback must have a positive Python-owned C handle") }
        for key in ["__fqcn__", "__fqcn"] {
            if let value = object[key], !(value is NSNull) {
                _ = try self.string(value, name: "callback.\(key)", maximum: 512)
            }
        }
        if let first = object["__fqcn__"] as? String, let second = object["__fqcn"] as? String, first != second {
            throw ExteralessTLError(.malformed, "callback has conflicting native class tags")
        }
        return handle
    }
}

struct PluginTLCommonModel: Sendable {
    let account: Int32
    let timeoutMs: Int

    init(_ object: [String: Any]) throws {
        guard try PluginTLModel.integer(object["schemaVersion"], name: "schemaVersion") == 1 else {
            throw ExteralessTLError(.malformed, "Unsupported TL service schemaVersion")
        }
        let account = try PluginTLModel.integer(object["account"], name: "account")
        guard account >= 0, let index = Int32(exactly: account) else {
            throw ExteralessTLError(.malformed, "account must be a nonnegative Int32 snapshot slot")
        }
        self.account = index
        let timeout = try object["timeoutMs"].map { try PluginTLModel.integer($0, name: "timeoutMs") } ?? 30_000
        guard timeout >= 100, timeout <= 120_000 else {
            throw ExteralessTLError(.malformed, "timeoutMs must be in 100...120000")
        }
        self.timeoutMs = Int(timeout)
    }
}

struct PluginTLRequestModel: Sendable {
    let common: PluginTLCommonModel
    let request: ExteralessTLRequest
    let automaticFloodWait: Bool
    let applyUpdates: Bool

    init(_ value: Any) throws {
        let object = try PluginTLModel.object(value, name: "tlRequest", keys: ["schemaVersion", "account", "request", "timeoutMs", "automaticFloodWait", "applyUpdates"])
        self.common = try PluginTLCommonModel(object)
        guard let request = object["request"] else { throw ExteralessTLError(.malformed, "tlRequest.request is required") }
        self.request = try ExteralessTLCodec.shared.encodeRequest(ExteralessTLValue(jsonObject: request))
        self.automaticFloodWait = try PluginTLModel.bool(object["automaticFloodWait"], name: "automaticFloodWait", default: false)
        self.applyUpdates = try PluginTLModel.bool(object["applyUpdates"], name: "applyUpdates", default: false)
        guard !self.applyUpdates || self.request.resultType == "Updates" else {
            throw ExteralessTLError(.unsupported, "applyUpdates requires a method returning Updates")
        }
    }
}

struct PluginTLPeerModel: Sendable {
    let common: PluginTLCommonModel
    let peer: ExteralessTLPeerReference

    init(_ value: Any) throws {
        let object = try PluginTLModel.object(value, name: "getPeer", keys: ["schemaVersion", "account", "peer", "timeoutMs"])
        self.common = try PluginTLCommonModel(object)
        self.peer = try PluginTLModel.peer(object["peer"])
    }
}

struct PluginTLMediaModel: Sendable {
    enum Kind: String, Sendable { case photo, document, audio, video, text, album }
    let common: PluginTLCommonModel
    let peer: ExteralessTLPeerReference
    let kind: Kind
    let path: String
    let fileName: String?
    let mimeType: String?
    let caption: String
    let entities: [ExteralessTLValue]
    let silent: Bool
    let replyToId: Int32?
    let threadId: Int64?
    let disableLinkPreviews: Bool
    let scheduleTime: Int32?
    let replyToNamespace: Int32?
    let spoiler: Bool
    let ttlSeconds: Int32?
    let items: [PluginTLMediaModel]

    init(_ value: Any, allowEmptyText: Bool = false, deferEntityTextValidation: Bool = false) throws {
        let object = try PluginTLModel.object(value, name: "sendMedia", keys: ["schemaVersion", "account", "peer", "timeoutMs", "kind",
            "path", "fileName", "mimeType", "caption", "entities", "silent", "replyTo", "threadId", "disableLinkPreviews", "scheduleTime", "spoiler", "ttlSeconds", "items"])
        self.common = try PluginTLCommonModel(object)
        self.peer = try PluginTLModel.peer(object["peer"])
        guard let kind = object["kind"] as? String, let mediaKind = Kind(rawValue: kind) else {
            throw ExteralessTLError(.unsupported, "sendMedia.kind must be photo, document, audio, video, text or album")
        }
        self.kind = mediaKind
        if mediaKind == .text || mediaKind == .album {
            guard object["path"] == nil, object["mimeType"] == nil, object["fileName"] == nil else {
                throw ExteralessTLError(.malformed, "Text/album root has no file parameters")
            }
            self.path = ""
        } else {
            self.path = try PluginTLModel.string(object["path"], name: "sendMedia.path", maximum: 4096)
            guard self.path.hasPrefix("/"), !self.path.hasPrefix("//") else {
                throw ExteralessTLError(.malformed, "sendMedia.path must be an absolute local file path")
            }
        }
        self.fileName = try object["fileName"].map { try PluginTLModel.string($0, name: "sendMedia.fileName", maximum: 255) }
        if let fileName = self.fileName, fileName.isEmpty || fileName.contains("/") || fileName.contains("\\") || fileName == "." || fileName == ".." {
            throw ExteralessTLError(.malformed, "sendMedia.fileName must be a single nonempty file name")
        }
        self.mimeType = try object["mimeType"].map { try PluginTLModel.string($0, name: "sendMedia.mimeType", maximum: 128) }
        if let mimeType = self.mimeType {
            let parts = mimeType.split(separator: "/", omittingEmptySubsequences: false)
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&^_.+-")
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
                throw ExteralessTLError(.malformed, "sendMedia.mimeType is invalid")
            }
        }
        if mediaKind == .photo, self.mimeType != nil || self.fileName != nil {
            throw ExteralessTLError(.unsupported, "sendMedia.photo uses native JPEG metadata; send as document to preserve a file")
        }
        self.caption = try object["caption"].map { try PluginTLModel.string($0, name: "caption", maximum: 16_384) } ?? ""
        if mediaKind == .text, !allowEmptyText, self.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ExteralessTLError(.malformed, "sendMedia.text requires a nonempty caption/text")
        }
        guard let rawEntities = (object["entities"] ?? [Any]()) as? [Any], rawEntities.count <= 100 else {
            throw ExteralessTLError(.malformed, "sendMedia.entities must be an array of at most 100 TL MessageEntity values")
        }
        self.entities = try rawEntities.map(ExteralessTLValue.init(jsonObject:))
        if deferEntityTextValidation {
            _ = try ExteralessTLTransformCodec.mediaEntityBodies(self.entities, caption: nil)
        } else {
            try exteralessTLValidateMediaEntities(self.entities, caption: self.caption)
        }
        self.silent = try PluginTLModel.bool(object["silent"], name: "silent", default: false)
        self.spoiler = try PluginTLModel.bool(object["spoiler"], name: "spoiler", default: false)
        if let raw = object["ttlSeconds"], !(raw is NSNull) {
            let value = try PluginTLModel.integer(raw, name: "ttlSeconds")
            guard value > 0, let seconds = Int32(exactly: value) else { throw ExteralessTLError(.malformed, "ttlSeconds must be positive Int32") }
            self.ttlSeconds = seconds
        } else { self.ttlSeconds = nil }
        self.disableLinkPreviews = try PluginTLModel.bool(object["disableLinkPreviews"], name: "disableLinkPreviews", default: false)
        guard mediaKind == .text || !self.disableLinkPreviews else {
            throw ExteralessTLError(.unsupported, "disableLinkPreviews is a text-only option")
        }
        if let value = object["scheduleTime"], !(value is NSNull) {
            let time = try PluginTLModel.integer(value, name: "scheduleTime")
            guard time > 0, let intTime = Int32(exactly: time) else {
                throw ExteralessTLError(.malformed, "scheduleTime must be a positive Int32 Unix timestamp")
            }
            self.scheduleTime = intTime
        } else {
            self.scheduleTime = nil
        }
        if let value = object["replyTo"], !(value is NSNull) {
            let reply = try PluginTLModel.object(value, name: "replyTo", keys: ["id", "namespace"])
            let id = try PluginTLModel.integer(reply["id"], name: "replyTo.id")
            guard id > 0, let replyId = Int32(exactly: id) else { throw ExteralessTLError(.malformed, "replyTo.id must be a positive Int32") }
            self.replyToId = replyId
            if let raw = reply["namespace"] {
                guard let namespace = Int32(exactly: try PluginTLModel.integer(raw, name: "replyTo.namespace")), [0, 1, 2].contains(namespace) else {
                    throw ExteralessTLError(.malformed, "replyTo.namespace must be Cloud(0), Local(1), or SecretIncoming(2)")
                }
                self.replyToNamespace = namespace
            } else { self.replyToNamespace = nil }
        } else {
            self.replyToId = nil
            self.replyToNamespace = nil
        }
        if let value = object["threadId"], !(value is NSNull) {
            let id = try PluginTLModel.integer(value, name: "threadId")
            guard id > 0, id <= Int64(Int32.max) else { throw ExteralessTLError(.malformed, "threadId must be a positive cloud forum topic id") }
            self.threadId = id
        } else {
            self.threadId = nil
        }
        if mediaKind == .album {
            guard self.caption.isEmpty, self.entities.isEmpty, !self.spoiler, self.ttlSeconds == nil,
                  let items = object["items"] as? [Any], items.count >= 2, items.count <= 10 else {
                throw ExteralessTLError(.malformed, "Album requires 2...10 items; captions/entities/spoiler/TTL belong to items")
            }
            self.items = try items.map { item in
                var fields = try PluginTLModel.object(item, name: "album item", keys: ["kind", "path", "fileName", "mimeType", "caption", "entities", "spoiler", "ttlSeconds"])
                guard let kind = fields["kind"] as? String, ["photo", "video", "audio", "document"].contains(kind) else {
                    throw ExteralessTLError(.malformed, "Album item must be photo, video, audio or document")
                }
                fields["schemaVersion"] = object["schemaVersion"]
                fields["account"] = object["account"]
                fields["peer"] = object["peer"]
                return try PluginTLMediaModel(fields)
            }
        } else {
            guard object["items"] == nil else { throw ExteralessTLError(.malformed, "Only albums have items") }
            self.items = []
        }
        if self.peer.kind == .secret {
            guard self.threadId == nil, self.scheduleTime == nil,
                  self.replyToId == nil || self.replyToNamespace != nil else {
                throw ExteralessTLError(.malformed, "Secret sends require explicit reply namespace and have no thread/schedule")
            }
        }
    }
}

struct PluginTLEditMediaModel: Sendable {
    let content: PluginTLMediaModel
    let messageId: Int32
    let namespace: Int32
    let caption: String?
    let entities: [ExteralessTLValue]?
    let spoiler: Bool?

    init(_ value: Any) throws {
        var object = try PluginTLModel.object(value, name: "editMedia", keys: ["schemaVersion", "account", "peer", "timeoutMs", "message", "kind", "path",
            "fileName", "mimeType", "caption", "entities", "spoiler", "disableLinkPreviews", "scheduleTime"])
        guard let message = object.removeValue(forKey: "message") else { throw ExteralessTLError(.malformed, "editMedia.message is required") }
        let target = try PluginTLModel.object(message, name: "editMedia.message", keys: ["id", "namespace"])
        let id = try PluginTLModel.integer(target["id"], name: "message.id")
        guard id > 0, let messageId = Int32(exactly: id) else { throw ExteralessTLError(.malformed, "message.id must be positive Int32") }
        self.messageId = messageId
        let namespace = try target["namespace"].map { try PluginTLModel.integer($0, name: "message.namespace") } ?? 0
        guard namespace == 0 || namespace == 3 else { throw ExteralessTLError(.unsupported, "editMedia supports Cloud(0) and ScheduledCloud(3) messages") }
        self.namespace = Int32(namespace)
        self.content = try PluginTLMediaModel(object, allowEmptyText: true, deferEntityTextValidation: object["caption"] == nil)
        guard self.content.kind != .album, self.content.peer.kind != .secret else {
            throw ExteralessTLError(.unsupported, "Edit one cloud message; secret-chat edit has no native protocol path")
        }
        guard self.namespace == 3 || self.content.scheduleTime == nil else {
            throw ExteralessTLError(.unsupported, "Only an existing ScheduledCloud message can be rescheduled by editMedia")
        }
        self.caption = object["caption"] == nil ? nil : self.content.caption
        self.entities = object["entities"] == nil ? nil : self.content.entities
        self.spoiler = object["spoiler"] == nil ? nil : self.content.spoiler
    }
}
