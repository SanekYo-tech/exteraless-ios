import CoreFoundation
import Foundation

/// JSON values persisted by the native settings service. Int64/UInt64 are kept
/// as integers, rather than passing through Double (account ids can exceed 2^53).
public indirect enum PluginJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case string(String)
    case array([PluginJSONValue])
    case object([String: PluginJSONValue])

    public init(jsonObject: Any) throws {
        try self.init(jsonObject: jsonObject, depth: 0)
    }

    private init(jsonObject: Any, depth: Int) throws {
        guard depth <= 64 else {
            throw BridgeFailure.malformed("JSON nesting exceeds 64 levels")
        }
        if jsonObject is NSNull {
            self = .null
        } else if let number = jsonObject as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if let value = Int64(number.stringValue) {
                self = .integer(value)
            } else if let value = UInt64(number.stringValue) {
                self = .unsignedInteger(value)
            } else {
                guard number.doubleValue.isFinite else {
                    throw BridgeFailure.malformed("JSON numbers must be finite")
                }
                self = .number(number.doubleValue)
            }
        } else if let string = jsonObject as? String {
            self = .string(string)
        } else if let array = jsonObject as? [Any] {
            self = .array(try array.map { try PluginJSONValue(jsonObject: $0, depth: depth + 1) })
        } else if let object = jsonObject as? [String: Any] {
            self = .object(try object.mapValues { try PluginJSONValue(jsonObject: $0, depth: depth + 1) })
        } else {
            throw BridgeFailure.malformed("Expected a JSON value, received \(type(of: jsonObject))")
        }
    }

    public var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .integer(let value): return NSNumber(value: value)
        case .unsignedInteger(let value): return NSNumber(value: value)
        case .number(let value): return NSNumber(value: value)
        case .string(let value): return value
        case .array(let value): return value.map(\.jsonObject)
        case .object(let value): return value.mapValues(\.jsonObject)
        }
    }

    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= 64 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Settings JSON nesting exceeds 64 levels"))
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self), value.isFinite {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PluginJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: PluginJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsignedInteger(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// A bridge account slot is pinned to an AccountRecordId, never a mutable sort
/// order. The application publishes these mappings for the host's event adapter.
public struct PluginServiceAccount: Hashable, Sendable {
    public let index: Int32
    public let recordId: Int64
    public let userId: Int64

    public init(index: Int32, recordId: Int64, userId: Int64) {
        self.index = index
        self.recordId = recordId
        self.userId = userId
    }
}

/// UIKit/AccountContext objects never cross the synchronous C callback boundary.
/// This value is built on the UI thread and replaced atomically by the app service.
public struct PluginPlatformSnapshot: Sendable {
    public let displayScale: Double?
    public let themeColors: [String: Int32]
    public let strings: [String: String]
    public let localeIdentifier: String?
    public let accounts: [PluginServiceAccount]
    public let selectedAccountIndex: Int32?

    public init(displayScale: Double? = nil, themeColors: [String: Int32] = [:],
                strings: [String: String] = [:], localeIdentifier: String? = nil,
                accounts: [PluginServiceAccount] = [], selectedAccountIndex: Int32? = nil) {
        self.displayScale = displayScale
        self.themeColors = themeColors
        self.strings = strings
        self.localeIdentifier = localeIdentifier
        self.accounts = accounts
        self.selectedAccountIndex = selectedAccountIndex
    }

    public func selectedAccount() throws -> Int32 {
        guard let index = selectedAccountIndex else {
            throw BridgeFailure.unavailable("UserConfig.selectedAccount: no active account snapshot")
        }
        _ = try account(at: index)
        return index
    }

    public func account(at index: Int32) throws -> PluginServiceAccount {
        guard let account = accounts.first(where: { $0.index == index }) else {
            throw BridgeFailure.unavailable("Account slot \(index) is not active")
        }
        return account
    }

    public func themeKey(_ name: String) throws -> String {
        let key = name.hasPrefix("key_") ? String(name.dropFirst(4)) : name
        guard themeColors[key] != nil else {
            if themeColors.isEmpty {
                throw BridgeFailure.unavailable("Theme: no presentation snapshot")
            }
            throw BridgeFailure.memberError("UnsupportedThemeKey: \(name)")
        }
        return key
    }

    public func themeColor(forKey name: String) throws -> Int32 {
        let key = try themeKey(name)
        guard let color = themeColors[key] else {
            throw BridgeFailure.memberError("UnsupportedThemeKey: \(name)")
        }
        return color
    }

    /// Android logical dp becomes UIKit *points*. dp snaps up to a physical-pixel
    /// boundary, ceil(points * screen.scale) / screen.scale; dpf2 keeps fractional
    /// points. Returning physical pixels here would double-scale UIKit layouts.
    public func points(_ value: Double, pixelAligned: Bool) throws -> Double {
        guard value.isFinite else { throw BridgeFailure.malformed("dp: expected a finite number") }
        guard let scale = displayScale, scale.isFinite, scale > 0 else {
            throw BridgeFailure.unavailable("AndroidUtilities.dp: no display-scale snapshot")
        }
        guard (value * scale).isFinite else {
            throw BridgeFailure.malformed("dp: scaled value overflows")
        }
        return pixelAligned ? (value * scale).rounded(.up) / scale : value
    }

    /// Named fallback matches Android LocaleController's missing-key convention.
    /// An unknown resource never becomes 0, an empty string, or a made-up translation.
    public func localizedString(_ key: String) throws -> String {
        guard localeIdentifier != nil else {
            throw BridgeFailure.unavailable("LocaleController: no presentation snapshot")
        }
        return strings[key] ?? "LOC_ERR:\(key)"
    }

    public func localeStringIso639() throws -> String {
        guard let locale = localeIdentifier, !locale.isEmpty else {
            throw BridgeFailure.unavailable("LocaleController: no locale snapshot")
        }
        return locale.replacingOccurrences(of: "_", with: "-")
    }
}

/// Portable text-only send contract. The JSON peerId is {"type":"user" |
/// "group" | "channel", "id":positive Int64}; a positive scalar is a user id.
/// Android negative dialog ids, TLRPC objects, rich text, topics and media are not
/// inferred. The account record is pinned when the native request is accepted.
public struct PluginTextMessageRequest: Sendable {
    public enum PeerKind: String, Sendable { case user, group, channel }
    public let pluginId: String
    public let account: PluginServiceAccount
    public let peerKind: PeerKind
    public let peerId: Int64
    public let text: String

    public init(pluginId: String, account: PluginServiceAccount, peerKind: PeerKind,
                peerId: Int64, text: String) {
        self.pluginId = pluginId
        self.account = account
        self.peerKind = peerKind
        self.peerId = peerId
        self.text = text
    }
}

/// Optional extension surface, discovered as `ui as? PluginPlatformService`.
/// Synchronous methods read value snapshots or enqueue native effects; none may
/// wait for the main queue or execute Python. A send returns a request id, not a
/// delivered Telegram message id; its eventual enqueue/failure goes to serviceLogs.
public protocol PluginPlatformService: AnyObject {
    var platformSnapshot: PluginPlatformSnapshot { get }
    var serviceStorage: PluginServiceStorage { get }
    var serviceLogs: PluginServiceLogBuffer { get }
    var runtimeVersion: String { get }
    func addToClipboard(_ text: String, pluginId: String) throws
    func openURL(_ url: URL, pluginId: String) throws
    func sendMessage(_ request: PluginTextMessageRequest) throws -> String
}

public extension PluginPlatformService {
    func addToClipboard(_ text: String, pluginId: String) throws {
        throw BridgeFailure.unimplemented("AndroidUtilities.addToClipboard: no platform implementation")
    }
    func openURL(_ url: URL, pluginId: String) throws {
        throw BridgeFailure.unimplemented("Browser.openUrl: no platform implementation")
    }
    func sendMessage(_ request: PluginTextMessageRequest) throws -> String {
        throw BridgeFailure.unimplemented("Runtime.sendMessage: no platform implementation")
    }
}

/// Strict argument readers shared by service routes. In particular, Bool is not
/// an integer, and neither fractional values nor out-of-range ids are truncated.
enum PluginServiceArgument {
    static func integer(_ value: Any, name: String) throws -> Int64 {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let result = Int64(number.stringValue) else {
            throw BridgeFailure.malformed("\(name): expected an Int64 integer")
        }
        return result
    }

    static func number(_ value: Any, name: String) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            throw BridgeFailure.malformed("\(name): expected a finite number")
        }
        return number.doubleValue
    }

    static func string(_ value: Any, name: String) throws -> String {
        guard let result = value as? String else {
            throw BridgeFailure.malformed("\(name): expected a string")
        }
        return result
    }
}
