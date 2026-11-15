import Foundation
import PluginHost
import TelegramCore

struct NativeServiceAccountModel: Sendable {
    let account: Int32
    let peer: ExteralessTLPeerReference?
    let currentUser: Bool
    let cachedChatId: Int64?
    let messageId: Int32?
    let fileId: Int64?
    let offset: Int
    let limit: Int
    let timeoutMs: Int
    let event: NativeServiceNotification?

    init(member: String, value: PluginJSONValue) throws {
        var keys: Set<String> = ["account"]
        let peerMethods: Set<String> = ["nativeGetChat", "nativeObservePeer", "nativePeerInfo", "nativeNotificationSettings",
            "nativeMessageMedia", "nativeResourceStatus", "nativeObserveResource", "nativeDownload"]
        let mediaMethods: Set<String> = ["nativeMessageMedia", "nativeResourceStatus", "nativeObserveResource", "nativeDownload"]
        let resourceMethods: Set<String> = ["nativeResourceStatus", "nativeObserveResource", "nativeDownload"]
        if peerMethods.contains(member) { keys.insert("peer") }
        if mediaMethods.contains(member) { keys.insert("messageId") }
        if resourceMethods.contains(member) { keys.insert("fileId") }
        if member == "nativeGetUser" || member == "nativeGetChat" { keys.insert("id") }
        if member == "nativeGetContacts" { keys.formUnion(["offset", "limit"]) }
        if member == "notificationSubscribe" { keys.insert("event") }
        if !["nativeObservePeer", "nativeObserveResource", "notificationSubscribe"].contains(member) { keys.insert("timeoutMs") }
        let model = try NativeServiceWire.object(value, name: member + ".model", keys: keys)
        account = Int32(try NativeServiceWire.integer(model["account"], name: "account", range: 0...Int64(Int32.max)))
        if member == "nativeGetUser" {
            let id = try NativeServiceWire.integer(model["id"], name: "id", range: 0...0x00ff_ffff_ffff_ffff)
            currentUser = id == 0
            cachedChatId = nil
            if id == 0 { peer = nil } else { peer = try ExteralessTLPeerReference(kind: .user, id: id) }
        } else if member == "nativeGetChat", let id = model["id"] {
            guard model["peer"] == nil else { throw BridgeFailure.malformed("nativeGetChat accepts id or typed peer, not both") }
            cachedChatId = try NativeServiceWire.integer(id, name: "id", range: 1...0x00ff_ffff_ffff_ffff)
            currentUser = false
            peer = nil
        } else if peerMethods.contains(member) {
            currentUser = false
            cachedChatId = nil
            let value = try NativeServiceWire.object(model["peer"] ?? .null, name: "peer", keys: ["type", "id"])
            let name = try NativeServiceWire.string(value["type"], name: "peer.type", maximum: 16)
            guard let kind = ExteralessTLPeerReference.Kind(rawValue: name), kind != .secret,
                  member != "nativeGetChat" || kind != .user else {
                throw BridgeFailure.malformed("peer.type must explicitly identify a cloud user, group or channel; nativeGetChat requires group/channel")
            }
            peer = try ExteralessTLPeerReference(kind: kind,
                id: NativeServiceWire.integer(value["id"], name: "peer.id", range: 1...0x00ff_ffff_ffff_ffff))
        } else {
            peer = nil
            currentUser = false
            cachedChatId = nil
        }
        messageId = mediaMethods.contains(member) ? Int32(try NativeServiceWire.integer(model["messageId"], name: "messageId", range: 1...Int64(Int32.max))) : nil
        if resourceMethods.contains(member) { fileId = try NativeServiceWire.integer(model["fileId"], name: "fileId") } else { fileId = nil }
        offset = Int(try NativeServiceWire.integer(model["offset"] ?? .integer(0), name: "offset", range: 0...1_000_000))
        limit = Int(try NativeServiceWire.integer(model["limit"] ?? .integer(100), name: "limit", range: 1...500))
        timeoutMs = Int(try NativeServiceWire.integer(model["timeoutMs"] ?? .integer(member == "nativeDownload" ? 300_000 : 30_000), name: "timeoutMs", range: 100...600_000))
        if member == "notificationSubscribe" {
            let selected: NativeServiceNotification?
            if case let .string(name)? = model["event"] {
                selected = NativeServiceNotification.allCases.first { $0.name == name }
            } else {
                let id = try NativeServiceWire.integer(model["event"], name: "event", range: 1...Int64(Int32.max))
                selected = NativeServiceNotification(rawValue: Int32(id))
            }
            guard let selected else { throw BridgeFailure.unimplemented("UnsupportedNotificationEvent: no native publisher for this Android id") }
            event = selected
        } else {
            event = nil
        }
    }

    var engineMessageId: EngineMessage.Id? {
        guard let peer, let messageId else { return nil }
        let namespace: EnginePeer.Id.Namespace
        switch peer.kind {
        case .user: namespace = Namespaces.Peer.CloudUser
        case .group: namespace = Namespaces.Peer.CloudGroup
        case .channel: namespace = Namespaces.Peer.CloudChannel
        case .secret: return nil
        }
        return EngineMessage.Id(peerId: EnginePeer.Id(namespace: namespace, id: ._internalFromInt64Value(peer.id)),
            namespace: Namespaces.Message.Cloud, id: messageId)
    }
}
