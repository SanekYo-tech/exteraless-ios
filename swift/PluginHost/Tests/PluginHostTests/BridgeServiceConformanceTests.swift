import Foundation
import XCTest
@testable import PluginHost

/// The same JSON entry point used by NativeBridgeBinding, with value snapshots
/// and recording effects. No AccountContext, UIKit, Python, network or real send.
final class BridgeServiceConformanceTests: XCTestCase {
    private static let runtime = "exteraless.ios.Runtime"
    private static let utilities = "org.telegram.messenger.AndroidUtilities"
    private static let theme = "org.telegram.ui.ActionBar.Theme"
    private static let userConfig = "org.telegram.messenger.UserConfig"

    private final class Services: PluginMessagesService, PluginSettingsService, PluginUIService,
        PluginPlatformService, @unchecked Sendable {
        private let lock = NSLock()
        private var current = PluginPlatformSnapshot(
            displayScale: 3, themeColors: ["dialogTextBlack": Int32(bitPattern: 0xff12_3456)],
            strings: ["Cancel": "Отмена"], localeIdentifier: "ru_RU",
            accounts: [PluginServiceAccount(index: 4, recordId: 9_007_199_254_740_993, userId: 123456)],
            selectedAccountIndex: 4)
        let serviceStorage: PluginServiceStorage
        let serviceLogs = PluginServiceLogBuffer(capacity: 4, maximumMessageBytes: 32)
        let runtimeVersion = "fixture/1"
        let clipboards = Recorder<String>()
        let openedURLs = Recorder<URL>()
        let sends = Recorder<PluginTextMessageRequest>()
        let effectLeases = Recorder<PluginNativeCallLease>()
        let nativeMainWork = Recorder<Int>()

        init(root: URL) { serviceStorage = PluginServiceStorage(rootDirectory: root) }

        var platformSnapshot: PluginPlatformSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        func publish(_ value: PluginPlatformSnapshot) {
            lock.lock()
            current = value
            lock.unlock()
        }
        func selectedAccount() throws -> Int32 { try platformSnapshot.selectedAccount() }
        func instanceHandle(fqcn: String, account: Int32) throws -> Int64 {
            try platformSnapshot.account(at: account).recordId
        }
        func themeColor(forKey key: String) throws -> Int32 { try platformSnapshot.themeColor(forKey: key) }
        func themeKey(_ name: String) throws -> String { try platformSnapshot.themeKey(name) }
        func dp(_ value: Double) throws -> Double { try platformSnapshot.points(value, pixelAligned: true) }
        func runOnUIThread(delayMs: Int, work: @escaping @Sendable () -> Void) { nativeMainWork.append(delayMs) }
        func constructUI(fqcn: String, arguments: [Any]) throws -> Int64 {
            throw BridgeFailure.unimplemented("Unsupported UI: \(fqcn)")
        }
        func addToClipboard(_ text: String, pluginId: String, lease: PluginNativeCallLease) throws {
            try lease.check()
            effectLeases.append(lease)
            clipboards.append(text)
        }
        func openURL(_ url: URL, pluginId: String, lease: PluginNativeCallLease) throws {
            try lease.check()
            effectLeases.append(lease)
            openedURLs.append(url)
        }
        func sendMessage(_ request: PluginTextMessageRequest, lease: PluginNativeCallLease) throws -> String {
            try lease.check()
            effectLeases.append(lease)
            sends.append(request)
            return "recorded-request"
        }
    }

    private func fixture(permissions: PermissionsModel? = nil, reflection: SecurityGates? = nil) throws -> (Services, BridgeServices) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("service-json-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let services = Services(root: root)
        return (services, BridgeServices(messages: services, settings: services, ui: services,
                                         permissions: permissions, reflection: reflection))
    }

    private func request(_ bridge: BridgeServices, _ operation: String = "call", _ fqcn: String,
                         _ member: String, args: [Any] = [], instance: Any? = nil, value: Any? = nil,
                          pluginId: String? = "alpha", claimedPluginId: String? = nil, ownerToken: String? = nil) throws -> [String: Any] {
        var object: [String: Any] = ["op": operation, "fqcn": fqcn, "member": member, "args": args, "kwargs": [String: Any]()]
        if let instance { object["instance"] = instance }
        if let value { object["value"] = value }
        if let claimedPluginId { object["pluginId"] = claimedPluginId }
        if let ownerToken { object["ownerToken"] = ownerToken }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let response = bridge.dispatchJSON(json, pluginId: pluginId)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    private func value(_ response: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> Any {
        XCTAssertEqual(response["ok"] as? Bool, true, String(describing: response), file: file, line: line)
        return try XCTUnwrap(response["value"], file: file, line: line)
    }

    private func assertFailure(_ response: [String: Any], _ kind: String,
                               containing text: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response["ok"] as? Bool, false, file: file, line: line)
        let error = response["error"] as? [String: Any]
        XCTAssertEqual(error?["kind"] as? String, kind, String(describing: response), file: file, line: line)
        if let text {
            XCTAssertTrue((error?["message"] as? String)?.contains(text) == true,
                          String(describing: response), file: file, line: line)
        }
    }

    private func applicationContext(_ bridge: BridgeServices, pluginId: String = "alpha") throws -> [String: Any] {
        try XCTUnwrap(value(request(bridge, "get", "org.telegram.messenger.ApplicationLoader", "applicationContext",
                                   pluginId: pluginId)) as? [String: Any])
    }

    func testThemePointsAndLocaleUsePublishedValues() throws {
        let (services, bridge) = try fixture()
        XCTAssertEqual(try value(request(bridge, "get", Self.theme, "key_dialogTextBlack")) as? String, "dialogTextBlack")
        XCTAssertEqual((try value(request(bridge, "call", Self.theme, "getColor", args: ["dialogTextBlack"])) as? NSNumber)?.uint32Value, 0xff12_3456)
        XCTAssertEqual(try value(request(bridge, "get", Self.userConfig, "selectedAccount")) as? Int, 4)
        XCTAssertEqual((try value(request(bridge, "call", Self.utilities, "dp", args: [1.1])) as? NSNumber)?.doubleValue ?? 0,
                       4.0 / 3.0, accuracy: 0.000001)
        XCTAssertEqual((try value(request(bridge, "call", Self.utilities, "dpf2", args: [1.1])) as? NSNumber)?.doubleValue, 1.1)
        XCTAssertEqual(try value(request(bridge, "get", Self.utilities, "density")) as? Int, 3)
        let locale = "org.telegram.messenger.LocaleController"
        XCTAssertEqual(try value(request(bridge, "call", locale, "getString", args: ["Cancel"])) as? String, "Отмена")
        XCTAssertEqual(try value(request(bridge, "call", locale, "getString", args: ["MissingKey", 42])) as? String, "LOC_ERR:MissingKey")
        XCTAssertEqual(try value(request(bridge, "call", locale, "getLocaleStringIso639")) as? String, "ru-RU")

        services.publish(PluginPlatformSnapshot(displayScale: 2,
            themeColors: ["dialogTextBlack": Int32(bitPattern: 0xffee_ddcc)],
            strings: ["Cancel": "Cancel"], localeIdentifier: "en"))
        XCTAssertEqual((try value(request(bridge, "call", Self.utilities, "dp", args: [1.1])) as? NSNumber)?.doubleValue, 1.5)
        XCTAssertEqual((try value(request(bridge, "call", Self.theme, "getColor", args: ["key_dialogTextBlack"])) as? NSNumber)?.uint32Value, 0xffee_ddcc)
        XCTAssertEqual(try value(request(bridge, "call", locale, "getString", args: ["Cancel"])) as? String, "Cancel")
        assertFailure(try request(bridge, "get", Self.userConfig, "selectedAccount"), "ServiceUnavailable")
        assertFailure(try request(bridge, "get", Self.theme, "key_missing"), "JavaMemberError", containing: "UnsupportedThemeKey")
    }

    func testNativeEffectsRetainTheirOriginalEpochUntilExecution() throws {
        let (services, bridge) = try fixture()
        let lifetimes = PluginNativeEffectBudget()
        let active = try lifetimes.reserve(pluginId: "alpha", bytes: 0)
        bridge.ownerValidator = { id, token, _ in id == "alpha" && token == "epoch-one" }
        bridge.effectOwnerValidator = { id, token in id == "alpha" && token == "epoch-one" && active.isActive }
        _ = try value(request(bridge, "call", Self.runtime, "addToClipboard", args: ["first"], ownerToken: "epoch-one"))
        let lease = try XCTUnwrap(services.effectLeases.values.first)
        XCTAssertTrue(lease.isCurrent)
        active.finish()
        XCTAssertFalse(lease.isCurrent)
        assertFailure(try request(bridge, "call", Self.runtime, "addToClipboard", args: ["retired"], ownerToken: "epoch-one"), "InvalidHandle")
        bridge.effectOwnerValidator = { _, token in token == "epoch-two" }
        XCTAssertFalse(lease.isCurrent, "An old lease must not acquire the replacement owner's epoch")
        XCTAssertEqual(services.clipboards.values, ["first"])
    }

    func testEffectLeaseRechecksPermissionRevocation() throws {
        let permissions = PermissionsModel()
        let directory = tempDirectory("effect-permissions")
        let store = try PluginStore(directory: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        permissions.setGranted("alpha", [.intents], to: store)
        let (services, bridge) = try fixture(permissions: permissions)
        _ = try value(request(bridge, "call", Self.runtime, "openURL", args: ["https://example.invalid/test"]))
        let lease = try XCTUnwrap(services.effectLeases.values.first)
        XCTAssertTrue(lease.isCurrent)
        permissions.setGranted("alpha", [], to: store)
        XCTAssertFalse(lease.isCurrent)
    }

    func testOwnedRunnableCompletionAndRejectedAdmissionStayInTheirEpoch() throws {
        let (_, bridge) = try fixture()
        bridge.ownerValidator = { _, _, _ in true }
        bridge.onOwnedCallback = { _, token, _, _, _, _ in token != "rejected" }
        let marker: [String: Any] = ["__handle__": 17]
        assertFailure(try request(bridge, "call", Self.utilities, "runOnUIThread", args: [marker], ownerToken: "rejected"), "InvalidHandle")
        _ = try value(request(bridge, "call", Self.utilities, "runOnUIThread", args: [marker], ownerToken: "one"))
        _ = try value(request(bridge, "call", Self.utilities, "runOnUIThread", args: [marker], ownerToken: "two"))
        XCTAssertEqual(try value(request(bridge, "call", Self.runtime, "completeCallback", args: [17], ownerToken: "rejected")) as? Bool, false)
        XCTAssertEqual(try value(request(bridge, "call", Self.runtime, "completeCallback", args: [17], ownerToken: "one")) as? Bool, true)
        XCTAssertEqual(try value(request(bridge, "call", Self.runtime, "completeCallback", args: [17], ownerToken: "one")) as? Bool, false)
        XCTAssertEqual(try value(request(bridge, "call", Self.runtime, "completeCallback", args: [17], ownerToken: "two")) as? Bool, true)
    }

    func testOperationsCannotAliasOrTriggerEffects() throws {
        let (services, bridge) = try fixture()
        assertFailure(try request(bridge, "call", Self.userConfig, "selectedAccount"), "JavaMemberError")
        assertFailure(try request(bridge, "set", Self.userConfig, "selectedAccount", value: 0), "JavaMemberError")
        assertFailure(try request(bridge, "get", Self.theme, "getColor"), "JavaMemberError")
        assertFailure(try request(bridge, "call", Self.theme, "key_dialogTextBlack"), "JavaMemberError")
        assertFailure(try request(bridge, "get", Self.utilities, "addToClipboard"), "JavaMemberError")
        assertFailure(try request(bridge, "set", Self.utilities, "addToClipboard", value: "not an effect"), "JavaMemberError")
        assertFailure(try request(bridge, "get", Self.runtime, "setSetting"), "JavaMemberError")
        assertFailure(try request(bridge, "set", Self.runtime, "sendMessage", value: "not an effect"), "JavaMemberError")
        XCTAssertEqual(services.clipboards.count, 0)
        XCTAssertEqual(services.sends.count, 0)
        XCTAssertEqual(try value(request(bridge, "member_kind", Self.theme, "getColor")) as? String, "method")
        XCTAssertEqual(try value(request(bridge, "member_kind", Self.theme, "key_dialogTextBlack")) as? String, "field")
        XCTAssertEqual(try value(request(bridge, "member_kind", Self.theme, "bogus")) as? String, "unknown")
    }

    func testUnknownAndMissingServicesAreNamedFailures() throws {
        let (_, bridge) = try fixture()
        for fqcn in ["missing.Controller", "org.telegram.messenger.FileLoader", "org.telegram.ui.Components.UItem"] {
            XCTAssertEqual(try value(request(bridge, "class_exists", fqcn, "")) as? Bool, false)
            assertFailure(try request(bridge, "call", fqcn, "getInstance", args: [4]), "JavaMemberError", containing: fqcn)
        }
        for fqcn in ["org.telegram.ui.ActionBar.BottomSheet", "org.telegram.tgnet.TLRPC$TL_messages_sendMessage"] {
            assertFailure(try request(bridge, "construct", fqcn, ""), "Unimplemented", containing: fqcn)
        }
        let missing = BridgeServices()
        assertFailure(try request(missing, "call", Self.utilities, "dp", args: [16]), "ServiceUnavailable")
        assertFailure(try request(missing, "call", Self.theme, "getColor", args: ["dialogTextBlack"]), "ServiceUnavailable")
        assertFailure(try request(missing, "get", Self.userConfig, "selectedAccount"), "ServiceUnavailable")
        assertFailure(try request(bridge, "unknown-op", Self.utilities, "dp", args: [16]), "MalformedRequest")
        let invalidNumbers: [Any] = [true, "16", NSNull()]
        for argument in invalidNumbers {
            assertFailure(try request(bridge, "call", Self.utilities, "dp", args: [argument]), "MalformedRequest")
        }
        let invalidAccounts: [Any] = [true, 4.5, "4", NSNull()]
        for argument in invalidAccounts {
            assertFailure(try request(bridge, "call", Self.userConfig, "getInstance", args: [argument]), "MalformedRequest")
        }
    }

    func testMalformedEnvelopesDoNotDefaultToAValidCall() throws {
        let (services, bridge) = try fixture()
        let invalid = [
            "not json", "[]", "null",
            "{\"fqcn\":\"org.telegram.messenger.AndroidUtilities\",\"member\":\"addToClipboard\",\"args\":[\"wrong\"]}",
            "{\"op\":\"call\",\"fqcn\":\"org.telegram.messenger.AndroidUtilities\",\"member\":\"dp\",\"args\":16}",
            "{\"op\":\"call\",\"fqcn\":\"org.telegram.messenger.AndroidUtilities\",\"member\":\"dp\",\"args\":[16],\"kwargs\":[]}",
            "{\"op\":\"call_instance\",\"fqcn\":\"java.io.File\",\"member\":\"getPath\"}",
            "{\"op\":\"set\",\"fqcn\":\"org.telegram.messenger.UserConfig\",\"member\":\"selectedAccount\"}"
        ]
        for json in invalid {
            let reply = bridge.dispatchJSON(json, pluginId: "alpha")
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
            assertFailure(response, "MalformedRequest")
        }
        XCTAssertEqual(services.clipboards.count, 0)
        XCTAssertEqual(bridge.liveInstanceCount, 0)
    }

    func testHandlesAreNegativeTypedOwnedStableAndReleased() throws {
        let (_, bridge) = try fixture()
        let alpha = try applicationContext(bridge)
        let alphaId = try XCTUnwrap(alpha["__handle__"] as? NSNumber).int64Value
        XCTAssertLessThan(alphaId, 0)
        XCTAssertEqual(alpha["__fqcn__"] as? String, "android.content.Context")
        XCTAssertEqual(alpha["__fqcn"] as? String, "android.content.Context")
        XCTAssertEqual((try applicationContext(bridge)["__handle__"] as? NSNumber)?.int64Value, alphaId)
        let beta = try applicationContext(bridge, pluginId: "beta")
        XCTAssertNotEqual((beta["__handle__"] as? NSNumber)?.int64Value, alphaId)
        XCTAssertEqual(bridge.liveInstanceCount, 2)

        assertFailure(try request(bridge, "call_instance", "android.content.Context", "getFilesDir", instance: alphaId, pluginId: "beta"), "SecurityError")
        assertFailure(try request(bridge, "call_instance", "java.io.File", "getPath", instance: alphaId), "InvalidHandle")
        var conflicting = alpha
        conflicting["__fqcn"] = "java.io.File"
        assertFailure(try request(bridge, "call_instance", "android.content.Context", "getFilesDir", instance: conflicting), "InvalidHandle")
        var invalidType = alpha
        invalidType["__fqcn__"] = 42
        assertFailure(try request(bridge, "call_instance", "android.content.Context", "getFilesDir", instance: invalidType), "MalformedRequest")
        assertFailure(try request(bridge, "call_instance", "android.content.Context", "getFilesDir", instance: 100), "InvalidHandle")
        assertFailure(try request(bridge, "call", Self.runtime, "setSetting", args: ["stolen", [alpha]], pluginId: "beta"), "SecurityError")
        XCTAssertThrowsError(try bridge.releaseInstance(handle: alphaId, fqcn: "android.content.Context", pluginId: "beta"))
        XCTAssertEqual(bridge.liveInstanceCount, 2)

        try bridge.releaseInstance(handle: alphaId, fqcn: "android.content.Context", pluginId: "alpha")
        assertFailure(try request(bridge, "call_instance", "android.content.Context", "getFilesDir", instance: alphaId), "InvalidHandle")
        let replacement = try applicationContext(bridge)
        XCTAssertLessThan(try XCTUnwrap(replacement["__handle__"] as? NSNumber).int64Value, alphaId)
        bridge.releaseInstances(pluginId: "alpha")
        XCTAssertEqual(bridge.liveInstanceCount, 1)
        _ = try value(request(bridge, "call_instance", "android.content.Context", "getCacheDir", instance: beta, pluginId: "beta"))
    }

    func testAccountHandleDoesNotFollowAccountReplacement() throws {
        let (services, bridge) = try fixture()
        let instance = try value(request(bridge, "call", Self.userConfig, "getInstance", args: [4]))
        XCTAssertEqual(try value(request(bridge, "call_instance", Self.userConfig, "getClientUserId", instance: instance)) as? Int, 123456)
        assertFailure(try request(bridge, "call", Self.userConfig, "getInstance", args: [0]), "ServiceUnavailable")
        services.publish(PluginPlatformSnapshot(accounts: [PluginServiceAccount(index: 4, recordId: 222, userId: 999)], selectedAccountIndex: 4))
        assertFailure(try request(bridge, "call_instance", Self.userConfig, "getClientUserId", instance: instance), "InvalidHandle")
        assertFailure(try request(bridge, "get_instance", Self.userConfig, "currentAccount", instance: instance), "InvalidHandle")
    }

    func testRuntimeSettingsJSONAndFilesystemChainUseNativeIdentity() throws {
        let (services, bridge) = try fixture()
        let object: [String: Any] = ["unicode": "Привет 👋", "enabled": true, "disabled": false,
            "list": [NSNull(), NSNumber(value: Int64.max), NSNumber(value: UInt64.max), 2.5]]
        _ = try value(request(bridge, "call", Self.runtime, "setSetting", args: ["nested", object], claimedPluginId: "beta"))
        let stored = try value(request(bridge, "call", Self.runtime, "getSetting", args: ["nested", NSNull()]))
        XCTAssertEqual(try PluginJSONValue(jsonObject: stored), try PluginJSONValue(jsonObject: object))
        XCTAssertEqual(try value(request(bridge, "call", Self.runtime, "getSetting", args: ["nested", "default"], pluginId: "beta")) as? String, "default")
        _ = try value(request(bridge, "call", Self.runtime, "setSetting", args: ["null", NSNull()]))
        XCTAssertTrue(try value(request(bridge, "call", Self.runtime, "getSetting", args: ["null", "fallback"])) is NSNull)
        XCTAssertEqual(try value(request(bridge, "call", Self.runtime, "removeSetting", args: ["null"])) as? Bool, true)
        XCTAssertEqual(try value(request(bridge, "call", Self.runtime, "removeSetting", args: ["null"])) as? Bool, false)
        XCTAssertEqual(try value(request(bridge, "call", Self.runtime, "getSetting", args: ["null", "fallback"])) as? String, "fallback")
        assertFailure(try request(bridge, "call", Self.runtime, "getVersion", pluginId: nil, claimedPluginId: "alpha"), "SecurityError")
        assertFailure(try request(bridge, "call", Self.runtime, "getSetting", args: ["nested"]), "MalformedRequest")

        let context = try applicationContext(bridge)
        let file = try value(request(bridge, "call_instance", "android.content.Context", "getFilesDir", instance: context))
        let path = try value(request(bridge, "call_instance", "java.io.File", "getAbsolutePath", instance: file))
        XCTAssertEqual(path as? String, try services.serviceStorage.filesDirectory(pluginId: "alpha").path)
        XCTAssertEqual(try value(request(bridge, "call_instance", "java.io.File", "isDirectory", instance: file)) as? Bool, true)
        XCTAssertEqual(try value(request(bridge, "call", Self.runtime, "getFilesDir")) as? String, path as? String)
        XCTAssertEqual(try value(request(bridge, "call", Self.runtime, "getPluginsDir")) as? String, try services.serviceStorage.pluginsDirectory().path)
        assertFailure(try request(bridge, "call", Self.runtime, "getFilesDir", pluginId: "../escape"), "SecurityError")
        for index in 0..<6 {
            _ = try value(request(bridge, "call", Self.runtime, "log", args: ["line \(index)"], claimedPluginId: "beta"))
        }
        XCTAssertEqual(services.serviceLogs.entries.map(\.message), ["line 2", "line 3", "line 4", "line 5"])
        XCTAssertTrue(services.serviceLogs.entries.allSatisfy { $0.pluginId == "alpha" })
    }

    private struct CallbackRecord: Equatable, Sendable {
        let pluginId: String
        let handle: Int64
        let method: String
        let arguments: String
        let delay: Int
    }

    func testRunnableIsPassedToOwningSchedulerAndNeverToNativeMainWork() throws {
        let (services, bridge) = try fixture()
        let runnable: [String: Any] = ["__handle__": 77, "__fqcn__": NSNull()]
        assertFailure(try request(bridge, "call", Self.utilities, "runOnUIThread", args: [runnable]), "ServiceUnavailable")
        let callbacks = Recorder<CallbackRecord>()
        bridge.onCallback = { id, handle, method, args, delay in
            callbacks.append(CallbackRecord(pluginId: id, handle: handle, method: method, arguments: args, delay: delay))
        }
        _ = try value(request(bridge, "call", Self.utilities, "runOnUIThread", args: [runnable, 25], claimedPluginId: "beta"))
        XCTAssertEqual(callbacks.values, [CallbackRecord(pluginId: "alpha", handle: 77, method: "run", arguments: "[]", delay: 25)])
        XCTAssertEqual(services.nativeMainWork.count, 0)
        assertFailure(try request(bridge, "call", Self.utilities, "runOnUIThread", args: [runnable, -1]), "MalformedRequest")
        assertFailure(try request(bridge, "call", Self.utilities, "runOnUIThread", args: [runnable, true]), "MalformedRequest")
        assertFailure(try request(bridge, "call", Self.utilities, "runOnUIThread", args: [77]), "MalformedRequest")
        XCTAssertEqual(callbacks.count, 1)
    }

    private func enqueueCallback(_ bridge: BridgeServices, handle: Int64 = 77,
                                 pluginId: String = "alpha") throws -> [String: Any] {
        let runnable: [String: Any] = ["__handle__": NSNumber(value: handle), "__fqcn__": NSNull()]
        return try request(bridge, "call", Self.utilities, "runOnUIThread", args: [runnable, 60_000], pluginId: pluginId)
    }

    private func completeCallback(_ bridge: BridgeServices, handle: Int64 = 77,
                                  pluginId: String = "alpha") throws -> Bool {
        try XCTUnwrap(value(request(bridge, "call", Self.runtime, "completeCallback",
                                   args: [NSNumber(value: handle)], pluginId: pluginId)) as? Bool)
    }

    func testCallbackCompletionConsumesOneReferenceAndPreservesReusableHandles() throws {
        let bridge = BridgeServices()
        XCTAssertFalse(try completeCallback(bridge)) // A reusable native-probe handle has no reservation.
        XCTAssertEqual(try value(request(bridge, "class_exists", Self.runtime, "")) as? Bool, true)
        XCTAssertEqual(try value(request(bridge, "member_kind", Self.runtime, "completeCallback")) as? String, "method")
        let callbacks = Recorder<Int64>()
        bridge.onCallback = { _, handle, _, _, _ in callbacks.append(handle) }
        _ = try value(enqueueCallback(bridge))
        _ = try value(enqueueCallback(bridge))
        bridge.onCallback = nil // Completion remains available after scheduler detachment.

        assertFailure(try request(bridge, "get", Self.runtime, "completeCallback"), "JavaMemberError")
        assertFailure(try request(bridge, "set", Self.runtime, "completeCallback", value: 77), "JavaMemberError")
        XCTAssertFalse(try completeCallback(bridge))
        XCTAssertTrue(try completeCallback(bridge))
        XCTAssertFalse(try completeCallback(bridge))
        XCTAssertFalse(try completeCallback(bridge, handle: 999))
        XCTAssertEqual(callbacks.values, [77, 77])
    }

    func testCallbackBudgetCountsDuplicateReferencesAndRejectsBeforeEnqueue() throws {
        let bridge = BridgeServices()
        assertFailure(try enqueueCallback(bridge), "ServiceUnavailable", containing: "scheduler is not installed")
        XCTAssertFalse(try completeCallback(bridge))
        let callbacks = Recorder<Int64>()
        bridge.onCallback = { _, handle, _, _, _ in callbacks.append(handle) }
        for _ in 0..<256 { _ = try value(enqueueCallback(bridge)) }
        assertFailure(try enqueueCallback(bridge), "ServiceUnavailable", containing: "per-plugin pending callback limit")
        assertFailure(try enqueueCallback(bridge, handle: 88), "ServiceUnavailable", containing: "per-plugin pending callback limit")
        XCTAssertEqual(callbacks.count, 256)
        XCTAssertFalse(try completeCallback(bridge, handle: 88)) // Rejected admission created no reference.

        XCTAssertFalse(try completeCallback(bridge)) // One reference frees one slot, even before the last.
        _ = try value(enqueueCallback(bridge, handle: 88))
        XCTAssertEqual(callbacks.count, 257)
        for index in 0..<255 {
            XCTAssertEqual(try completeCallback(bridge), index == 254)
        }
        XCTAssertFalse(try completeCallback(bridge)) // Failed duplicate admission did not increment.
        XCTAssertTrue(try completeCallback(bridge, handle: 88))
    }

    func testGlobalCallbackBudgetIsSharedAcrossOwners() throws {
        let bridge = BridgeServices()
        let callbacks = Recorder<String>()
        bridge.onCallback = { id, _, _, _, _ in callbacks.append(id) }
        for owner in ["alpha", "beta", "gamma", "delta"] {
            for _ in 0..<256 { _ = try value(enqueueCallback(bridge, pluginId: owner)) }
        }
        assertFailure(try enqueueCallback(bridge, pluginId: "epsilon"), "ServiceUnavailable", containing: "global pending callback limit")
        XCTAssertEqual(callbacks.count, 1024)
        XCTAssertFalse(try completeCallback(bridge, pluginId: "epsilon"))
        assertFailure(try enqueueCallback(bridge, pluginId: "epsilon"), "ServiceUnavailable", containing: "global pending callback limit")

        XCTAssertFalse(try completeCallback(bridge, pluginId: "beta"))
        _ = try value(enqueueCallback(bridge, pluginId: "epsilon"))
        assertFailure(try enqueueCallback(bridge, handle: 88, pluginId: "epsilon"), "ServiceUnavailable", containing: "global pending callback limit")
        XCTAssertEqual(callbacks.count, 1025)
        XCTAssertTrue(try completeCallback(bridge, pluginId: "epsilon"))
        XCTAssertFalse(try completeCallback(bridge, pluginId: "epsilon"))
        _ = try value(enqueueCallback(bridge, pluginId: "zeta"))
        assertFailure(try enqueueCallback(bridge, handle: 88, pluginId: "zeta"), "ServiceUnavailable", containing: "global pending callback limit")
    }

    func testCallbackCompletionValidatesPositiveIntegerAndNativeOwner() throws {
        let bridge = BridgeServices()
        let callbacks = Recorder<String>()
        bridge.onCallback = { id, _, _, _, _ in callbacks.append(id) }
        _ = try value(enqueueCallback(bridge))
        _ = try value(enqueueCallback(bridge))
        _ = try value(enqueueCallback(bridge, pluginId: "beta")) // The same numeric id in another realm.
        XCTAssertEqual(try value(request(bridge, "call", Self.runtime, "completeCallback", args: [77],
                                         pluginId: "outsider", claimedPluginId: "alpha")) as? Bool, false)
        XCTAssertTrue(try completeCallback(bridge, pluginId: "beta"))
        XCTAssertFalse(try completeCallback(bridge, pluginId: "beta"))
        assertFailure(try request(bridge, "call", Self.runtime, "completeCallback", args: [77],
                                  pluginId: nil, claimedPluginId: "alpha"), "SecurityError")

        let malformed: [Any] = [true, "77", 77.5, NSNull(), NSNumber(value: UInt64.max)]
        for handle in malformed {
            assertFailure(try request(bridge, "call", Self.runtime, "completeCallback", args: [handle]), "MalformedRequest")
        }
        for handle in [0, -77] {
            assertFailure(try request(bridge, "call", Self.runtime, "completeCallback", args: [handle]), "InvalidHandle")
        }
        assertFailure(try request(bridge, "call", Self.runtime, "completeCallback"), "MalformedRequest")
        assertFailure(try request(bridge, "call", Self.runtime, "completeCallback", args: [77, 77]), "MalformedRequest")
        XCTAssertFalse(try completeCallback(bridge, handle: Int64.max))
        XCTAssertFalse(try completeCallback(bridge)) // Other realms and malformed calls preserved both references.
        XCTAssertTrue(try completeCallback(bridge))
        XCTAssertEqual(callbacks.values, ["alpha", "alpha", "beta"])
    }

    func testUnloadClearsOnlyOwnersCallbacksAndNativeHandles() throws {
        let (_, bridge) = try fixture()
        let alpha = try applicationContext(bridge)
        let beta = try applicationContext(bridge, pluginId: "beta")
        let callbacks = Recorder<String>()
        bridge.onCallback = { id, _, _, _, _ in callbacks.append(id) }
        for owner in ["alpha", "beta"] {
            _ = try value(enqueueCallback(bridge, pluginId: owner))
            _ = try value(enqueueCallback(bridge, pluginId: owner))
        }
        bridge.releaseInstances(pluginId: "alpha")
        XCTAssertEqual(bridge.liveInstanceCount, 1)
        XCTAssertFalse(try completeCallback(bridge))
        XCTAssertFalse(try completeCallback(bridge, pluginId: "beta"))
        XCTAssertTrue(try completeCallback(bridge, pluginId: "beta"))
        assertFailure(try request(bridge, "call_instance", "android.content.Context", "getFilesDir", instance: alpha), "InvalidHandle")
        _ = try value(request(bridge, "call_instance", "android.content.Context", "getFilesDir", instance: beta, pluginId: "beta"))
        _ = try value(enqueueCallback(bridge))
        XCTAssertTrue(try completeCallback(bridge))
        XCTAssertEqual(callbacks.count, 5)
    }

    func testUnloadRestoresExactlyItsShareOfGlobalCallbackBudget() throws {
        let bridge = BridgeServices()
        let callbacks = Recorder<String>()
        bridge.onCallback = { id, _, _, _, _ in callbacks.append(id) }
        for owner in ["alpha", "beta", "gamma", "delta"] {
            for _ in 0..<256 { _ = try value(enqueueCallback(bridge, pluginId: owner)) }
        }
        bridge.releaseInstances(pluginId: "alpha")
        bridge.releaseInstances(pluginId: "alpha") // Idempotent: cannot subtract the same quota twice.
        XCTAssertFalse(try completeCallback(bridge))
        for _ in 0..<256 { _ = try value(enqueueCallback(bridge, pluginId: "epsilon")) }
        assertFailure(try enqueueCallback(bridge, pluginId: "zeta"), "ServiceUnavailable", containing: "global pending callback limit")
        XCTAssertEqual(callbacks.count, 1280)
    }

    func testCallbackReservationIsVisibleBeforeSchedulerRuns() throws {
        let bridge = BridgeServices()
        let replies = Recorder<String>()
        bridge.onCallback = { [weak bridge] id, handle, _, _, _ in
            guard let bridge else { return }
            // Native JSON completion only: no Python reentry. This also verifies
            // that invoking the scheduler does not hold the accounting lock.
            let json = "{\"op\":\"call\",\"fqcn\":\"exteraless.ios.Runtime\",\"member\":\"completeCallback\",\"args\":[\(handle)]}"
            replies.append(bridge.dispatchJSON(json, pluginId: id))
        }
        _ = try value(enqueueCallback(bridge))
        let reply = try XCTUnwrap(replies.values.first)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        XCTAssertEqual(try value(response) as? Bool, true)
        XCTAssertFalse(try completeCallback(bridge))
    }

    func testConcurrentCallbackAdmissionHonorsGlobalBudget() throws {
        let bridge = BridgeServices()
        let callbacks = Recorder<String>()
        let results = Recorder<Bool>()
        let errors = Recorder<String>()
        bridge.onCallback = { id, _, _, _, _ in callbacks.append(id) }
        let json = "{\"op\":\"call\",\"fqcn\":\"org.telegram.messenger.AndroidUtilities\",\"member\":\"runOnUIThread\",\"args\":[{\"__handle__\":77,\"__fqcn__\":null},60000]}"
        DispatchQueue.concurrentPerform(iterations: 1152) { index in
            let reply = bridge.dispatchJSON(json, pluginId: "plugin\(index % 8)")
            do {
                guard let response = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
                      let ok = response["ok"] as? Bool else {
                    errors.append(reply)
                    return
                }
                if !ok, (response["error"] as? [String: Any])?["kind"] as? String != "ServiceUnavailable" {
                    errors.append(reply)
                }
                results.append(ok)
            } catch {
                errors.append(String(describing: error))
            }
        }
        XCTAssertTrue(errors.values.isEmpty, errors.values.joined(separator: "\n"))
        XCTAssertEqual(results.values.filter { $0 }.count, 1024)
        XCTAssertEqual(results.values.filter { !$0 }.count, 128)
        XCTAssertEqual(callbacks.count, 1024)
        let acceptedByOwner = Dictionary(grouping: callbacks.values, by: { $0 })
        for (owner, accepted) in acceptedByOwner {
            for index in accepted.indices {
                XCTAssertEqual(try completeCallback(bridge, pluginId: owner), index == accepted.count - 1)
            }
        }
    }

    func testClipboardBrowserAndPlainTextSubsetOnlyRecordAcceptedCalls() throws {
        let (services, bridge) = try fixture()
        _ = try value(request(bridge, "call", Self.utilities, "addToClipboard", args: ["hello"]))
        XCTAssertEqual(services.clipboards.values, ["hello"])
        let context = try applicationContext(bridge)
        _ = try value(request(bridge, "call", "org.telegram.messenger.browser.Browser", "openUrl", args: [context, "https://example.invalid/path"]))
        XCTAssertEqual(services.openedURLs.values.map(\.absoluteString), ["https://example.invalid/path"])
        assertFailure(try request(bridge, "call", Self.runtime, "openURL", args: ["file:///outside"]), "MalformedRequest")

        let response = try XCTUnwrap(value(request(bridge, "call", Self.runtime, "sendMessage",
            args: [["type": "group", "id": 42], "plain text", 4])) as? [String: Any])
        XCTAssertEqual(response["status"] as? String, "scheduled")
        XCTAssertEqual(response["requestId"] as? String, "recorded-request")
        let sent = try XCTUnwrap(services.sends.values.first)
        XCTAssertEqual(sent.pluginId, "alpha")
        XCTAssertEqual(sent.account.recordId, 9_007_199_254_740_993)
        XCTAssertEqual(sent.peerKind, .group)
        XCTAssertEqual(sent.peerId, 42)
        XCTAssertEqual(sent.text, "plain text")
        let helper = "org.telegram.messenger.SendMessagesHelper"
        let handle = try value(request(bridge, "call", helper, "getInstance", args: [4]))
        _ = try value(request(bridge, "call_instance", helper, "sendMessage", args: [123, "second"], instance: handle))
        XCTAssertEqual(services.sends.values.last?.peerKind, .user)
        assertFailure(try request(bridge, "call_instance", helper, "sendMessage", args: [["TLRPC": "params"]], instance: handle), "Unimplemented")
        assertFailure(try request(bridge, "call", Self.runtime, "sendMessage", args: [-42, "x", 4]), "MalformedRequest")
        assertFailure(try request(bridge, "call", Self.runtime, "sendMessage", args: [42, " ", 4]), "MalformedRequest")
        assertFailure(try request(bridge, "call", Self.runtime, "sendMessage", args: [["user_id": 42], "x", 4]), "Unimplemented")
        assertFailure(try request(bridge, "call", Self.runtime, "sendMessage", args: [42, "x", 0]), "ServiceUnavailable")
        XCTAssertEqual(services.sends.count, 2)
    }

    func testRuntimeClassAndSensitiveEffectsRespectInjectedGates() throws {
        let permissions = PermissionsModel()
        let gates = SecurityGates(permissions: permissions)
        let (services, bridge) = try fixture(reflection: gates)
        XCTAssertEqual(try value(request(bridge, "call", Self.runtime, "getVersion")) as? String, "fixture/1")
        XCTAssertEqual(try value(request(bridge, "class_exists", Self.runtime, "")) as? Bool, true)
        assertFailure(try request(bridge, "call", Self.runtime, "sendMessage", args: [42, "x", 4]), "SecurityError")
        assertFailure(try request(bridge, "call", Self.runtime, "openURL", args: ["https://example.invalid"]), "SecurityError")
        XCTAssertEqual(services.sends.count, 0)
        XCTAssertEqual(services.openedURLs.count, 0)
        permissions.unsafeMode = true
        _ = try value(request(bridge, "call", Self.runtime, "sendMessage", args: [42, "x", 4]))
        XCTAssertEqual(services.sends.count, 1)
    }
}
