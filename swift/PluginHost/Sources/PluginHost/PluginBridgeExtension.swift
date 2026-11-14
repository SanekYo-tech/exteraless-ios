import Foundation

/// Additive native services. Calls arrive synchronously on a Python owner worker;
/// implementations may enqueue native work but must never re-enter Python inline.
public protocol PluginBridgeExtension: AnyObject, Sendable {
    /// Exact callable surface provided by this installed native implementation.
    /// Discovery is side-effect free and does not create presentation/task leases.
    var exportedMethods: [String: Set<String>] { get }
    /// nil means this provider does not own the operation. A handled operation
    /// returns the complete native {ok,value}/{ok:false,error} JSON envelope.
    func dispatch(requestJSON: String, pluginId: String) throws -> String?
    /// Called after the interpreter lifetime is retired. Cancel native resources;
    /// do not invoke Python callbacks during this cleanup.
    func releaseInstances(pluginId: String)
}

public extension PluginBridgeExtension {
    var exportedMethods: [String: Set<String>] { [:] }
    func releaseInstances(pluginId: String) {}
}

/// Immutable provider order; each in-flight dispatch retains its own snapshot.
public final class CompositePluginBridgeExtension: PluginBridgeExtension {
    private let providers: [any PluginBridgeExtension]
    public let exportedMethods: [String: Set<String>]

    public init(_ providers: [any PluginBridgeExtension]) {
        self.providers = providers
        self.exportedMethods = providers.reduce(into: [:]) { result, provider in
            for (fqcn, members) in provider.exportedMethods where !fqcn.isEmpty {
                result[fqcn, default: []].formUnion(members.filter { !$0.isEmpty })
            }
        }
    }

    public func dispatch(requestJSON: String, pluginId: String) throws -> String? {
        for provider in providers {
            if let result = try provider.dispatch(requestJSON: requestJSON, pluginId: pluginId) {
                return result
            }
        }
        return nil
    }

    public func releaseInstances(pluginId: String) {
        for provider in providers { provider.releaseInstances(pluginId: pluginId) }
    }
}

/// Shared envelope helpers for extension providers; scalar/null values are valid.
public enum PluginBridgeJSON {
    public static func success(_ value: PluginJSONValue) throws -> String {
        let body: PluginJSONValue = .object(["ok": .bool(true), "value": value])
        return String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
    }

    public static func failure(kind: String, message: String) throws -> String {
        let body: PluginJSONValue = .object([
            "ok": .bool(false), "error": .object(["kind": .string(kind), "message": .string(message)]),
        ])
        return String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
    }
}
