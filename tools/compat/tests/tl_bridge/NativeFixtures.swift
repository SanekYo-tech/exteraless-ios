import Foundation

private enum FixtureFailure: Error { case assertion(String) }

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw FixtureFailure.assertion(message) }
}

private func rejects(_ label: String, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch is ExteralessTLError {
        return
    }
    throw FixtureFailure.assertion("accepted malformed fixture: \(label)")
}

private func bytes(_ hex: String) -> Data {
    let chars = Array(hex.utf8)
    return Data(stride(from: 0, to: chars.count, by: 2).map {
        UInt8(String(decoding: chars[$0 ..< $0 + 2], as: UTF8.self), radix: 16)!
    })
}

private func object(_ name: String, _ fields: [String: ExteralessTLValue] = [:]) -> ExteralessTLValue {
    var result = fields
    result["_"] = .string(name)
    return .object(result)
}

private final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { self.lock.lock(); defer { self.lock.unlock() }; return self.stored }
    func add() { self.lock.lock(); self.stored += 1; self.lock.unlock() }
}

private final class ExecutionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var value: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.active }
    func revoke() { self.lock.lock(); self.active = false; self.lock.unlock() }
}

@main
private struct NativeFixtures {
    static func main() throws {
        let codec = ExteralessTLCodec.shared
        try expect(codec.androidHookName("users.getUsers") == "TL_users_getUsers", "actual Android request hook name")
        try expect(codec.androidHookName("native.onlyUnknown") == "native.onlyUnknown", "no invented Android hook alias")
        // Independent pre-engine TelegramApi goldens. Do not regenerate these
        // expected bytes using the implementation being tested.
        let goldens: [(String, ExteralessTLValue, String)] = [
            ("InputGeoPoint", object("inputGeoPoint", ["flags": .integer(1), "lat": .double(55.75), "long": .double(37.62), "accuracy_radius": .integer(25)]),
             "af2f2248010000000000000000e04b408fc2f5285ccf424019000000"),
            ("InputDocument", object("inputDocument", ["id": .integer(42), "access_hash": .integer(-3), "file_reference": .bytes(Data([0, 255, 16]))]),
             "75b5bf1a2a00000000000000fdffffffffffffff0300ff10"),
            ("MessagePeerVote", object("messagePeerVoteMultiple", ["peer": object("peerUser", ["user_id": .integer(5)]), "options": .array([.bytes(Data([1])), .bytes(Data([2, 3]))]), "date": .integer(100)]),
             "e6f6284622175159050000000000000015c4b51c02000000010100000202030064000000"),
            ("MessageAction", object("messageActionTodoCompletions", ["completed": .array([.integer(1), .integer(2), .integer(-3)]), "incompleted": .array([])]),
             "895c7ccc15c4b51c030000000100000002000000fdffffff15c4b51c00000000"),
            ("MessageAction", object("messageActionChatCreate", ["title": .string("Group"), "users": .array([.integer(1), .integer(Int64.max)])]),
             "adcb47bd0547726f7570000015c4b51c020000000100000000000000ffffffffffffff7f"),
            ("MessageAction", object("messageActionNoForwardsToggle", ["prev_value": object("boolFalse"), "new_value": object("boolTrue")]),
             "72657dbf379779bcb5757299"),
            ("BotCommand", object("botCommand", ["flags": .integer(0), "command": .string("start"), "description": .string("Start the bot")]),
             "d2d652980000000005737461727400000d53746172742074686520626f740000"),
            ("AiComposeTone", object("aiComposeTone", ["flags": .integer(6), "id": .integer(0), "access_hash": .integer(0), "slug": .string("s"), "title": .string("t"), "emoji_id": .integer(0), "installs_count": .integer(0)]),
             "a93ef6cf06000000000000000000000000000000000000000173000001740000000000000000000000000000"),
            ("Updates", object("updateShortMessage", [
                "flags": .integer(128), "id": .integer(1), "user_id": .integer(2), "message": .string("secret text"),
                "pts": .integer(3), "pts_count": .integer(1), "date": .integer(4),
                "entities": .array([object("messageEntityBold", ["offset": .integer(0), "length": .integer(6)])])]),
             "f8c73b31800000000100000002000000000000000b736563726574207465787403000000010000000400000015c4b51c01000000c90b61bd0000000006000000")
        ]
        for (type, value, golden) in goldens {
            let encoded = try codec.encode(value, as: type)
            try expect(encoded == bytes(golden), "pre-engine golden \(type)")
            let decoded = try codec.decode(encoded, as: type)
            try expect(try codec.encode(decoded, as: type) == encoded, "roundtrip \(type)")
            for end in 0 ..< encoded.count {
                try rejects("truncation \(type) at \(end)") { _ = try codec.decode(encoded.prefix(end), as: type) }
            }
        }
        let request = object("users.getUsers", ["id": .array([object("inputUserSelf")])])
        let packed = try codec.encodeRequest(request)
        try expect(packed.body == bytes("48a5910d15c4b51c010000003fb1c1f7"), "method header and vector")
        try expect(packed.methodName == "users.getUsers" && packed.resultType == "Vector<User>", "native method result type")
        try expect(try codec.decodeRequest(packed.body) == request, "request model roundtrip")
        let response = bytes("15c4b51c010000007a4bbcd3ffffffffffffff7f")
        try expect(try codec.decodeMethodResponse(response, methodName: "users.getUsers") == .array([object("userEmpty", ["id": .integer(Int64.max)])]), "full-width vector response")
        try expect(try codec.decodeBoxedObject(bytes("b5757299")) == object("boolTrue"), "boxed Bool response")

        let inferred = object("inputGeoPoint", ["lat": .double(0), "long": .double(0), "accuracy_radius": .integer(0)])
        let normalized = try codec.normalize(inferred, as: "InputGeoPoint")
        try expect(normalized["flags"] == .integer(1) && normalized["accuracy_radius"] == .integer(0), "present zero sets optional bit")
        let user = object("user", ["id": .integer(Int64.min), "first_name": .string("привет 👋"), "close_friend": .bool(true)])
        let userRoundtrip = try codec.normalize(user, as: "User")
        try expect(userRoundtrip["flags2"] == .integer(4) && userRoundtrip["close_friend"] == .bool(true), "second flags word")
        try expect(userRoundtrip["id"] == .integer(Int64.min) && userRoundtrip["first_name"] == user["first_name"], "signed Int64 and UTF-8")

        try rejects("request constructor instead of method") { _ = try codec.encodeRequest(object("inputUserSelf")) }
        try rejects("generic transport request") { _ = try codec.encodeRequest(object("invokeWithLayer", ["layer": .integer(232), "query": request])) }
        try rejects("unrecognized method") { _ = try codec.encodeRequest(object("invented.method")) }
        try rejects("unknown flags") { _ = try codec.encode(object("inputGeoPoint", ["flags": .integer(2), "lat": .double(0), "long": .double(0)]), as: "InputGeoPoint") }
        try rejects("mask excludes supplied field") { _ = try codec.encode(object("inputGeoPoint", ["flags": .integer(0), "lat": .double(0), "long": .double(0), "accuracy_radius": .integer(0)]), as: "InputGeoPoint") }
        try rejects("shared flag bit requires its companion") { _ = try codec.encode(object("user", ["id": .integer(1), "bot": .bool(true)]), as: "User") }
        try rejects("boolean flag disagrees with provided mask") { _ = try codec.encode(object("user", ["id": .integer(1), "flags2": .integer(4), "close_friend": .bool(false)]), as: "User") }
        try rejects("foreign constructor type") { _ = try codec.encode(object("inputUserSelf"), as: "InputPeer") }
        try rejects("runtime-only field") { _ = try codec.encode(object("inputUserSelf", ["networkType": .integer(1)]), as: "InputUser") }
        try rejects("Int32 overflow") { _ = try codec.encode(.integer(Int64(Int32.max) + 1), as: "int") }
        try rejects("float as int") { _ = try codec.encode(.double(1), as: "int") }
        try rejects("Bool as int") { _ = try codec.encode(.bool(true), as: "int") }
        try rejects("nonfinite double") { _ = try codec.encode(.double(.infinity), as: "double") }
        try rejects("True constructor is not Bool") { _ = try codec.decode(bytes("39d3ed3f"), as: "Bool") }
        try rejects("vector signature") { _ = try codec.decode(bytes("0000000000000000"), as: "Vector<int>") }
        try rejects("negative vector length") { _ = try codec.decode(bytes("15c4b51cffffffff"), as: "Vector<int>") }
        try rejects("invalid UTF-8") { _ = try codec.decode(bytes("01ff0000"), as: "string") }
        try rejects("invalid padding") { _ = try codec.decode(bytes("01610001"), as: "string") }
        try rejects("invalid byte prefix") { _ = try codec.decode(bytes("ff000000"), as: "bytes") }
        try rejects("noncanonical long prefix") { _ = try codec.decode(bytes("fe01000061000000"), as: "bytes") }
        try rejects("trailing bytes") { _ = try codec.decode(bytes("b575729900000000"), as: "Bool") }
        try rejects("noncanonical base64") { _ = try ExteralessTLValue(jsonObject: ["__bytes__": "AQ"]) }
        try rejects("oversized vector") { _ = try codec.encode(.array(Array(repeating: .integer(0), count: 100_001)), as: "Vector<int>") }
        // ?true fields consume zero bytes but expand into many JSON Booleans.
        // A small, valid binary vector must still obey the total-value budget.
        var expandedUsers = bytes("15c4b51c10270000") // Vector<User>, 10,000 entries
        let emptyUser = bytes("83ccb8b100000000000000000100000000000000")
        for _ in 0 ..< 10_000 { expandedUsers.append(emptyUser) }
        try rejects("zero-byte flag expansion budget") { _ = try codec.decode(expandedUsers, as: "Vector<User>") }

        let longBytes = Data(repeating: 0x81, count: 254)
        let encodedLongBytes = try codec.encode(.bytes(longBytes), as: "bytes")
        try expect(encodedLongBytes.prefix(4) == Data([254, 254, 0, 0]), "24-bit length boundary")
        try expect(encodedLongBytes.count == 260 && encodedLongBytes.suffix(2) == Data([0, 0]), "long byte padding")
        try expect(try codec.decode(encodedLongBytes, as: "bytes") == .bytes(longBytes), "long byte value")
        let wide = Data((0 ..< 32).map(UInt8.init))
        try expect(try codec.encode(.bytes(wide), as: "int256") == wide, "int256 is fixed wire-order bytes")
        try expect(try codec.decode(wide, as: "int256") == .bytes(wide), "int256 parse")
        try rejects("short int256") { _ = try codec.encode(.bytes(Data(repeating: 0, count: 31)), as: "int256") }
        var nested = object("jsonNull")
        for _ in 0 ..< 70 { nested = object("jsonArray", ["value": .array([nested])]) }
        try rejects("recursion limit") { _ = try codec.encode(nested, as: "JSONValue") }

        try self.lifetimes()
        try self.transformations()
        try self.reviewRegressions()
        try self.enqueueCommitOwnership()
        try self.executionGuardOwnership()
        print("TL native fixtures: 9 pre-engine goldens, truncation/flags/primitive bounds, request/response roundtrips and owner/cancel/deadline races passed")
    }

    private static func transformations() throws {
        let codec = ExteralessTLCodec.shared
        let metadata: ExteralessTLValue = .object(["accountRecordId": .integer(Int64.max), "requestId": .string("fixture")])
        let original = try codec.encodeRequest(object("messages.sendMessage", ["peer": object("inputPeerSelf"), "message": .string("before"), "random_id": .integer(9)]))
        let changed = object("messages.sendMessage", ["peer": object("inputPeerChat", ["chat_id": .integer(123)]), "message": .string("after"), "random_id": .integer(9)])
        let request = try ExteralessTLTransformCodec.request(changed.jsonString(), original: original, metadata: metadata)
        try expect(try codec.decodeRequest(request.body)["peer"]?["chat_id"] == .integer(123), "pre replacement uses final peer")
        try rejects("pre cannot change method") {
            _ = try ExteralessTLTransformCodec.request(object("users.getUsers", ["id": .array([])]).jsonString(), original: original, metadata: metadata)
        }
        try rejects("hook cannot change account metadata") {
            let value = ExteralessTLValue.object(["tl": changed, "metadata": .object(["accountRecordId": .integer(0)])])
            _ = try ExteralessTLTransformCodec.request(value.jsonString(), original: original, metadata: metadata)
        }
        let update = object("updateDeleteChannelMessages", ["channel_id": .integer(5), "messages": .array([.integer(44)]), "pts": .integer(12), "pts_count": .integer(2)])
        var ledger: [Int64: Int32] = [5: 10]
        try expect(ExteralessTLUpdatePolicy.acceptChannel(update, ledger: &ledger) && ledger[5] == 12, "channel continuity accepted")
        try expect(!ExteralessTLUpdatePolicy.acceptChannel(update, ledger: &ledger), "duplicate channel update does not enter mutable hook")
        let cancelled = try ExteralessTLUpdatePolicy.cancelledValue(update)!
        try expect(cancelled["messages"] == .array([]) && cancelled["pts"] == .integer(12) && cancelled["pts_count"] == .integer(2), "cancel removes semantic deletion, not pts")
        try expect(ExteralessTLUpdatePolicy.isCounterOnly(cancelled), "counter carrier cannot trigger another mutable hook")
        try rejects("cannot mutate pts") {
            let bad = object("updateDeleteChannelMessages", ["channel_id": .integer(5), "messages": .array([]), "pts": .integer(99), "pts_count": .integer(2)])
            _ = try ExteralessTLTransformCodec.update(bad.jsonString(), original: update, metadata: metadata)
        }
        let container = object("updates", ["updates": .array([]), "users": .array([]), "chats": .array([]), "date": .integer(7), "seq": .integer(3)])
        try rejects("post cannot insert a seq_start via another Updates constructor") {
            let changed = object("updatesCombined", ["updates": .array([]), "users": .array([]), "chats": .array([]), "date": .integer(7), "seq": .integer(3), "seq_start": .integer(1)])
            _ = try ExteralessTLTransformCodec.response(changed.jsonString(), original: container, type: "Updates", metadata: metadata)
        }
        try rejects("post cannot introduce an unaccepted counter-bearing update") {
            let changed = object("updates", ["updates": .array([update]), "users": .array([]), "chats": .array([]), "date": .integer(7), "seq": .integer(3)])
            _ = try ExteralessTLTransformCodec.response(changed.jsonString(), original: container, type: "Updates", metadata: metadata)
        }
        try rejects("post peer object cannot overflow native PeerId conversion") {
            _ = try ExteralessTLTransformCodec.response(object("userEmpty", ["id": .integer(Int64.max)]).jsonString(),
                original: object("userEmpty", ["id": .integer(1)]), type: "User", metadata: metadata)
        }
        try rejects("cannot consume encrypted sequence by cancellation") {
            _ = try ExteralessTLUpdatePolicy.cancelledValue(object("updateNewEncryptedMessage"))
        }
        let global = object("updateDeleteMessages", ["messages": .array([.integer(1)]), "pts": .integer(15), "pts_count": .integer(1)])
        try expect(try ExteralessTLUpdatePolicy.cancelledValue(global) == nil, "accepted global semantic cancellation uses already-advanced ledger")
        let subset = try ExteralessTLUpdatePolicy.matchMembers(original: [global, update], changed: [update])
        try expect(subset.count == 1 && subset[1] == update, "container subsequence retains original identity")
        let nativeMessage: [String: ExteralessTLValue] = ["_": .string("message"), "flags": .integer(0), "flags2": .integer(0),
            "id": .integer(1), "from_id": object("peerUser", ["user_id": .integer(9)]), "peer_id": object("peerUser", ["user_id": .integer(10)]),
            "date": .integer(1), "message": .string("synthesized")]
        let repaired = try codec.reconcileNativePresence(nativeMessage)
        try expect(try codec.normalize(repaired, as: "Message")["from_id"] == nativeMessage["from_id"], "native short-message sender survives mutation roundtrip")
        let gate = PluginTLSubmissionGate()
        gate.stop()
        var sent = false
        try expect(!gate.submit { sent = true; return nil } && !sent, "no add after disposed async prefix")
        let decision = try PluginTLTransformResultCodec.decode("{\"strategy\":\"MODIFY_FINAL\",\"request\":{\"_\":\"fixture\"}}", kind: .preRequest)
        if case .modifyFinal = decision {} else { throw FixtureFailure.assertion("MODIFY_FINAL lost") }
    }

    private static func lifetimes() throws {
        let registry = ExteralessTLRequestRegistry<Int>(maximumPerPlugin: 2, maximumTotal: 3)
        let cancellations = Count()
        let ticket = try registry.reserve(pluginId: "one", owner: 11, callbackHandle: 7, accountRecordId: Int64.max, timeoutMs: 1000) { _ in }
        registry.bindCancellation(ticket) { cancellations.add() }
        try expect(ticket.accountRecordId == Int64.max, "record id is never truncated to account index")
        try expect(registry.take(id: ticket.id, pluginId: "two", owner: 11) == nil, "foreign plugin cannot cancel")
        try expect(registry.take(id: ticket.id, pluginId: "one", owner: 12) == nil, "replacement owner cannot cancel")
        try rejects("callback wrapper reused by another request") {
            _ = try registry.reserve(pluginId: "one", owner: 11, callbackHandle: 7, accountRecordId: 0, timeoutMs: 1000) { _ in }
        }
        let second = try registry.reserve(pluginId: "one", owner: 11, callbackHandle: 8, accountRecordId: 0, timeoutMs: 1000) { _ in }
        try rejects("per-plugin cap") {
            _ = try registry.reserve(pluginId: "one", owner: 11, callbackHandle: 9, accountRecordId: 0, timeoutMs: 1000) { _ in }
        }
        let third = try registry.reserve(pluginId: "two", owner: 22, callbackHandle: 7, accountRecordId: 0, timeoutMs: 1000) { _ in }
        try rejects("global cap") {
            _ = try registry.reserve(pluginId: "three", owner: 33, callbackHandle: 7, accountRecordId: 0, timeoutMs: 1000) { _ in }
        }
        let winners = Count()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if registry.take(ticket) != nil { winners.add() }
        }
        try expect(winners.value == 1 && cancellations.value == 1, "one terminal winner/cancellation under races")
        registry.bindCancellation(ticket) { cancellations.add() }
        try expect(cancellations.value == 2, "finish before cancellation install disposes late native work")
        try expect(registry.take(second) != nil && registry.take(third) != nil, "remaining tickets can finish")
        try expect(registry.count == 0 && registry.take(ticket) == nil, "no request handles remain")

        let completed = try registry.reserve(pluginId: "one", owner: 11, callbackHandle: 9, accountRecordId: 0, timeoutMs: 1000) { _ in }
        registry.bindCancellation(completed) { cancellations.add() }
        try expect(registry.complete(completed) == completed, "completion wins its terminal lease")
        try expect(!registry.contains(completed) && registry.completionPending(completed) && registry.count == 1,
                   "callback awaiting admission retains its bounded slot, not native work")
        try expect(registry.take(completed) == nil && registry.complete(completed) == nil, "cancel/duplicate completion cannot win twice")
        try expect(cancellations.value == 3, "native resources disposed at completion")
        registry.bindCancellation(completed) { cancellations.add() }
        try expect(cancellations.value == 4, "late native cancellation install after completion is immediately disposed")
        try expect(registry.releaseCompletion(completed) == completed && registry.releaseCompletion(completed) == nil,
                   "owner callback lease releases exactly once")
        try expect(registry.count == 0 && cancellations.value == 4, "completion release does not dispose native work twice")

        let cancelled = try registry.reserve(pluginId: "one", owner: 11, callbackHandle: 12, accountRecordId: 0, timeoutMs: 1000) { _ in }
        try expect(registry.cancelRetainingLease(id: cancelled.id, pluginId: "one", owner: 11) == cancelled,
                   "cancel wins a control-release lease")
        try expect(registry.count == 1 && !registry.contains(cancelled) && registry.complete(cancelled) == nil,
                   "control-queue pressure retains quota without reviving native work")
        try expect(registry.releaseCompletion(cancelled) == cancelled && registry.count == 0, "control release retires cancelled handle")

        let old = try registry.reserve(pluginId: "one", owner: 11, callbackHandle: 1, accountRecordId: 0, timeoutMs: 1000) { _ in }
        try expect(registry.takeAll(pluginId: "one") == [old], "unload retires the old owner")
        let reloaded = try registry.reserve(pluginId: "one", owner: 12, callbackHandle: 1, accountRecordId: 0, timeoutMs: 1000) { _ in }
        try expect(registry.take(old) == nil && registry.contains(reloaded), "late completion cannot enter reloaded owner")
        _ = registry.takeAll()

        let expired = Count()
        let deadline = DispatchSemaphore(value: 0)
        _ = try registry.reserve(pluginId: "timer", owner: 44, callbackHandle: 1, accountRecordId: 0, timeoutMs: 100) { ticket in
            if registry.take(ticket) != nil { expired.add() }
            deadline.signal()
        }
        try expect(deadline.wait(timeout: .now() + 1) == .success, "bounded request timer fires")
        try expect(expired.value == 1 && registry.count == 0, "timeout releases its registered request")
    }

    private static func reviewRegressions() throws {
        let codec = ExteralessTLCodec.shared
        let context = ExteralessTLValue.object(["requestId": .string("review-fixture")])
        let encrypted = object("encryptedMessageService", ["random_id": .integer(7), "chat_id": .integer(9), "date": .integer(100), "bytes": .bytes(Data([0]))])
        let changedCiphertext = object("encryptedMessageService", ["random_id": .integer(7), "chat_id": .integer(9), "date": .integer(100), "bytes": .bytes(Data([1]))])
        let state = object("updates.state", ["pts": .integer(10), "qts": .integer(11), "date": .integer(100), "seq": .integer(1), "unread_count": .integer(0)])
        func difference(_ secret: [ExteralessTLValue]) -> ExteralessTLValue {
            object("updates.difference", ["new_messages": .array([]), "new_encrypted_messages": .array(secret), "other_updates": .array([]), "chats": .array([]), "users": .array([]), "state": state])
        }
        let original = try codec.normalize(difference([encrypted]), as: "updates.Difference")
        for candidate in [difference([]), difference([changedCiphertext]), difference([encrypted, encrypted])] {
            try rejects("post must preserve encrypted operations with qts") {
                _ = try ExteralessTLTransformCodec.response(candidate.jsonString(), original: original, type: "updates.Difference", metadata: context)
            }
        }
        try expect(try codec.decode(ExteralessTLTransformCodec.response(original.jsonString(), original: original, type: "updates.Difference", metadata: context), as: "updates.Difference") == original,
                   "unchanged encrypted payload survives post validation")
        let update = object("updateNewEncryptedMessage", ["message": encrypted, "qts": .integer(11)])
        let changed = object("updateNewEncryptedMessage", ["message": changedCiphertext, "qts": .integer(11)])
        try rejects("nested encrypted update ciphertext is read-only") {
            _ = try ExteralessTLTransformCodec.response(changed.jsonString(), original: update, type: "Update", metadata: context)
        }
        try expect(!ExteralessTLTransformCodec.canCancelResponse(object("messages.sentEncryptedMessage", ["date": .integer(100)])), "protocol result without numeric counters still cannot be cancelled")
        try rejects("protocol updates cannot be introduced into a semantic vector") {
            _ = try ExteralessTLUpdatePolicy.matchMembers(original: [object("updateUser", ["user_id": .integer(2)])], changed: [update])
        }

        let participant = object("updateChatParticipantAdd", ["chat_id": .integer(1), "user_id": .integer(2), "inviter_id": .integer(3), "date": .integer(100), "version": .integer(1)])
        for id in [Int64(4), Int64.max, Int64.min] {
            let candidate = object("updateChatParticipantAdd", ["chat_id": .integer(1), "user_id": .integer(2), "inviter_id": .integer(id), "date": .integer(100), "version": .integer(1)])
            try rejects("inviter role cannot overflow or retarget") {
                _ = try ExteralessTLTransformCodec.update(candidate.jsonString(), original: participant, metadata: context)
            }
        }
        func service(_ users: [Int64]) -> ExteralessTLValue {
            object("updateNewMessage", ["pts": .integer(11), "pts_count": .integer(1), "message": object("messageService", ["id": .integer(1), "peer_id": object("peerChat", ["chat_id": .integer(1)]), "date": .integer(100), "action": object("messageActionChatAddUser", ["users": .array(users.map(ExteralessTLValue.integer))])])])
        }
        let originalService = try codec.normalize(service([2]), as: "Update")
        let peerVectors: [[Int64]] = [[3], [Int64.max], [2, 3], []]
        for ids in peerVectors {
            try rejects("service-message peer vector cannot overflow/retarget") {
                _ = try ExteralessTLTransformCodec.update(service(ids).jsonString(), original: originalService, metadata: context)
            }
        }
        try ExteralessTLTransformCodec.validateNativeValues(object("documentEmpty", ["id": .integer(Int64.max)]))
        let wideMedia = object("inputMediaDocument", ["id": object("inputDocument", ["id": .integer(Int64.max), "access_hash": .integer(Int64.min), "file_reference": .bytes(Data([0]))])])
        try ExteralessTLTransformCodec.validateNativeValues(codec.normalize(object("inputSingleMedia", ["random_id": .integer(Int64.min), "media": wideMedia, "message": .string("fixture")]), as: "InputSingleMedia"))
        try ExteralessTLTransformCodec.validateNativeValues(codec.normalize(object("inputAppEvent", ["time": .double(0), "type": .string("fixture"), "peer": .integer(Int64.min), "data": object("jsonNull")]), as: "InputAppEvent"))
        try rejects("negative PeerId magnitude must fit the native 55-bit branch") {
            try ExteralessTLTransformCodec.validateNativeValues(object("messageActionChatAddUser", ["users": .array([.integer(-0x0080_0000_0000_0000)])]))
        }
        let bold = object("messageEntityBold", ["offset": .integer(0), "length": .integer(1)])
        try expect(try ExteralessTLTransformCodec.mediaEntityBodies([bold], caption: nil).count == 1, "omitted edit caption defers text-dependent checks")
        try expect(try ExteralessTLTransformCodec.mediaEntityBodies([bold], caption: "ab").count == 1, "entities-only edit validates cached caption")
        try rejects("explicit empty edit caption is not an omitted caption") {
            _ = try ExteralessTLTransformCodec.mediaEntityBodies([bold], caption: "")
        }
        try rejects("cached caption rejects out-of-range entities") {
            _ = try ExteralessTLTransformCodec.mediaEntityBodies([object("messageEntityBold", ["offset": .integer(1), "length": .integer(2)])], caption: "ab")
        }
        try expect(try ExteralessTLTransformCodec.mediaEntityBodies([], caption: "").isEmpty, "explicit empty caption with empty entities preserves presence")
    }

    private static func enqueueCommitOwnership() throws {
        let provisionalReleased = Count()
        let disposed = Count()
        let waiting = ExteralessTLEnqueueCommit(canCommit: { true }, cancelProvisional: { provisionalReleased.add() })
        waiting.bindCancellation { disposed.add() }
        waiting.cancelSubscriber()
        waiting.cancelSubscriber()
        try expect(provisionalReleased.value == 1 && disposed.value == 1 && !waiting.beginCommit(), "cancelled authorization wait releases one provisional lease and cannot write")
        try expect(waiting.complete { _ in preconditionFailure("cancelled provisional delivered") } == nil, "late precommit completion is ignored")

        let committedReleased = Count()
        let tracked = Count()
        let nativeStopped = Count()
        let commit = ExteralessTLEnqueueCommit(canCommit: { true }, cancelProvisional: { committedReleased.add() })
        commit.bindCancellation { nativeStopped.add() }
        try expect(commit.beginCommit(), "real native write claims ownership")
        commit.cancelSubscriber()
        try expect(committedReleased.value == 0 && nativeStopped.value == 0, "subscriber disposal does not tear down a claimed commit")
        let delivered = commit.complete { claimed in
            if claimed { tracked.add() }
        }
        try expect(delivered == false && tracked.value == 1 && nativeStopped.value == 1, "commit installs tracking even when its subscriber is gone")
        try expect(commit.complete { _ in tracked.add() } == nil && tracked.value == 1, "commit tracking is exactly once")
        let revoked = ExteralessTLEnqueueCommit(canCommit: { false }, cancelProvisional: {})
        try expect(!revoked.allowsContinuation() && !revoked.beginCommit(), "revoked permit rejects continuation and transaction even without dispose")
    }

    private static func executionGuardOwnership() throws {
        let registry = ExteralessTLRequestRegistry<Int>()
        let parent = ExecutionFlag()
        let evaluated = Count()
        let cleaned = Count()
        let ticket = try registry.reserve(pluginId: "alpha", owner: 1, callbackHandle: 1, accountRecordId: 1,
            timeoutMs: 1000, executionIsCurrent: {
                _ = registry.count // deliberately re-enters the registry
                evaluated.add()
                return parent.value
            }, expired: { _ in })
        registry.bindCancellation(ticket) { cleaned.add() }
        try expect(registry.contains(ticket) && evaluated.value == 0, "ownership lookup must not call execution predicates under lock")
        try expect(ticket.permitsExecution, "normal parent execution remains valid")
        parent.revoke()
        try expect(!ticket.permitsExecution && registry.contains(ticket) && registry.count == 1,
                   "parent revocation cannot prematurely release an owned request")
        try expect(registry.complete(ticket) != nil && cleaned.value == 1, "revoked request still performs ownership cleanup")
        try expect(registry.completionPending(ticket) && registry.count == 1, "revoked completion keeps control-release quota")
        try expect(registry.releaseCompletion(ticket) != nil && registry.count == 0, "release accounting is independent of parent execution")
    }
}
