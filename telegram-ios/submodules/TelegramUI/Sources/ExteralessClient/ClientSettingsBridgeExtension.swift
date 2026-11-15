import ExteralessCore
import Foundation
import PluginHost

/// Global client preferences share the actual native feature store. Per-plugin
/// settings continue to use BridgeServices' separate Runtime get/setSetting API.
final class ClientSettingsBridgeExtension: PluginBridgeExtension {
    private struct Route: Decodable {
        let fqcn: String?
        let member: String?
    }
    let exportedMethods: [String: Set<String>] = [
        "exteraless.ios.Runtime": ["getClientSetting", "setClientSetting", "setClientSettings", "getClientSettingMetadata"],
    ]
    private let settings: ClientSettings
    private let permits: @Sendable (String, PluginPermission) -> Bool

    init(settings: ClientSettings = .shared,
         permits: @escaping @Sendable (String, PluginPermission) -> Bool) {
        self.settings = settings
        self.permits = permits
    }

    func dispatch(requestJSON: String, pluginId: String) throws -> String? {
        let data = Data(requestJSON.utf8)
        // Read only routing strings to avoid claiming other providers' payloads.
        // Arguments remain in the original bytes for the strict settings codec.
        guard let route = try? JSONDecoder().decode(Route.self, from: data),
              route.fqcn == "exteraless.ios.Runtime", let member = route.member,
              ["getClientSetting", "setClientSetting", "setClientSettings", "getClientSettingMetadata"].contains(member) else { return nil }
        guard data.count <= 1_048_576 else { throw BridgeFailure.malformed("Client settings request exceeds 1 MiB") }
        let object: [String: ClientSettingValue]
        do {
            guard case let .object(root) = try ClientSettingValue.decodeJSON(data) else {
                throw ClientSettingsError.invalidJSON
            }
            object = root
        } catch {
            throw BridgeFailure.malformed("Invalid client settings JSON")
        }
        guard object["op"] == .string("call"), case let .array(args) = object["args"] else {
            throw BridgeFailure.malformed("Invalid \(member) arguments")
        }
        guard permits(pluginId, .settings) else {
            throw BridgeFailure.permission("\(member) requires settings permission")
        }
        if member == "setClientSettings" {
            guard args.count == 1, case let .string(json) = args[0] else { throw BridgeFailure.malformed("setClientSettings requires one opaque JSON string") }
            guard json.utf8.count <= ExteraConfigCompatibility.maximumBatchBytes,
                  case let .object(values) = try ClientSettingValue.decodeJSON(json) else {
                throw BridgeFailure.malformed("Invalid client settings batch")
            }
            guard !values.keys.contains(where: { ClientAPIFeatures.requiresNativeEditor($0) || $0 == "cloud.includeApiKeys" }) else {
                throw BridgeFailure.permission("This setting is managed by the native settings screen")
            }
            do { try ExteraConfigCompatibility.applyPublicJSON(json, to: settings) }
            catch ClientSettingsError.secretAccessDenied { throw BridgeFailure.permission("Client credentials are managed by native credential services") }
            return try PluginBridgeJSON.success(.null)
        }
        guard (member == "getClientSetting" ? (1...2).contains(args.count) : args.count == (member == "getClientSettingMetadata" ? 1 : 2)),
              case let .string(key) = args.first, !key.isEmpty else { throw BridgeFailure.malformed("Invalid \(member) arguments") }
        if member == "getClientSettingMetadata" {
            let metadata: ClientSettingValue
            do { metadata = try ExteraConfigCompatibility.publicMetadata(for: key, in: settings) }
            catch ClientSettingsError.secretAccessDenied { throw BridgeFailure.permission("Client credentials are managed by native credential services") }
            guard metadata != .null else { return try PluginBridgeJSON.success(.null) }
            let encoded = try JSONEncoder().encode(metadata)
            guard encoded.count <= ExteraConfigCompatibility.maximumBatchBytes else { throw BridgeFailure.unavailable("Client setting metadata exceeds the bounded projection") }
            // Opaque JSON preserves literal __handle__/__bytes__ keys in defaults.
            return try PluginBridgeJSON.success(.string(String(decoding: encoded, as: UTF8.self)))
        }
        let snapshot = settings.readSnapshot()
        let definition = snapshot.definitions.first(where: { $0.key == key })
        guard definition?.isSecret != true, !snapshot.secretKeys.contains(key) else {
            throw BridgeFailure.permission("Client credentials are managed by the native settings screen")
        }
        if member == "setClientSetting" {
            guard !ClientAPIFeatures.requiresNativeEditor(key), key != "cloud.includeApiKeys" else {
                throw BridgeFailure.permission("This setting is managed by the native settings screen")
            }
            guard definition != nil else { throw BridgeFailure.unimplemented("Unknown client setting: \(key)") }
            do {
                try ExteraConfigCompatibility.validatePublicValue(args[1], for: key)
                try settings.setPublic(args[1], for: key)
            } catch ClientSettingsError.secretAccessDenied {
                throw BridgeFailure.permission("Client credentials are managed by the native settings screen")
            }
            return try PluginBridgeJSON.success(.null)
        }
        let value: ClientSettingValue
        if definition != nil, let stored = snapshot.values[key] {
            try ExteraConfigCompatibility.validatePublicValue(stored, for: key)
            value = stored
        } else if args.count == 2 {
            value = args[1]
        } else {
            value = .null
        }
        return try PluginBridgeJSON.success(Self.bridgeValue(value))
    }

    private static func bridgeValue(_ value: ClientSettingValue) -> PluginJSONValue {
        switch value {
        case .null: return .null
        case let .bool(value): return .bool(value)
        case let .integer(value): return .integer(value)
        case let .number(value): return .number(value)
        case let .string(value): return .string(value)
        case let .array(values): return .array(values.map(Self.bridgeValue))
        case let .object(values): return .object(values.mapValues(Self.bridgeValue))
        }
    }
}
