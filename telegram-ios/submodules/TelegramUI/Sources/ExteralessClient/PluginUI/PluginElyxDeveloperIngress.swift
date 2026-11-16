import Foundation
import PluginHost

/// Entered only after PluginDeveloperProtocol authenticated the native socket
/// request. Plans retain native owners and consent, never the auth token.
@MainActor
enum PluginElyxDeveloperIngress {
    struct Plan {
        let request: PluginElyxDeveloperRequest
        let targets: [PluginElyxDeveloperTarget]
        let account: Int32
        let host: PluginHost
        let publication: PluginElyxDeveloperPublicationState?
    }

    static func capture(_ request: [String: PluginUIJSON], host: PluginHost, account: Int32,
                        targets: (PluginElyxDeveloperRequest) throws -> [PluginElyxDeveloperTarget]) throws -> Plan {
        var data = request
        data.removeValue(forKey: "token")
        data.removeValue(forKey: "#")
        let command = try PluginElyxDeveloperRequest(json: PluginUIJSON.object(data).encoded())
        return Plan(request: command, targets: try targets(command), account: account, host: host,
                    publication: command.kind == .changes ? PluginElyxDeveloperPublicationState(pluginId: command.pluginId) : nil)
    }

    static func run(_ plan: Plan, session: PluginDeveloperSession,
                    files: (any PluginElyxDeveloperFileAuthority)?,
                    nativeCurrent: @escaping @Sendable () -> Bool,
                    execute: @Sendable (PluginElyxDeveloperInvocation) async throws -> [String: PluginJSONValue],
                    actorCurrent: () -> Bool) async -> [String: PluginUIJSON] {
        do {
            guard session.isActive, actorCurrent() else { throw PluginElyxDeveloperError.stale("developer account/session retired before admission") }
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            let current: @Sendable () -> Bool = {
                session.isActive && nativeCurrent() && ProcessInfo.processInfo.systemUptime < deadline
            }
            let value = try await execute(PluginElyxDeveloperInvocation(request: plan.request, targets: plan.targets,
                account: plan.account, files: files, deadline: deadline, isCurrent: current, publication: plan.publication))
            plan.publication?.recordReply(value)
            guard current(), actorCurrent() else { throw PluginElyxDeveloperError.stale("developer account/session retired before delivery") }
            return try convert(value)
        } catch {
            return failure(error, request: plan.request, publication: plan.publication)
        }
    }

    static func failure(_ error: Error, request: PluginElyxDeveloperRequest? = nil,
                        publication: PluginElyxDeveloperPublicationState? = nil) -> [String: PluginUIJSON] {
        let nativeError: Error
        if let failure = error as? PluginUIFailure { nativeError = PluginElyxDeveloperError(kind: failure.kind, message: failure.message) }
        else { nativeError = error }
        let value = PluginElyxDeveloperError.response(nativeError, request: request, publication: publication)
        if let converted = try? convert(value) { return converted }
        // Error.response already bounds/sanitizes these scalar fields. Even a
        // conversion failure must keep its original error and commit knowledge.
        var fallback: [String: PluginUIJSON] = [:]
        for (key, field) in value {
            switch field {
            case let .string(text): fallback[key] = .string(text)
            case let .bool(flag): fallback[key] = .bool(flag)
            case .null: fallback[key] = .null
            case let .array(items):
                fallback[key] = .array(items.compactMap { if case let .string(text) = $0 { return .string(text) }; return nil })
            default: break
            }
        }
        return fallback
    }

    private static func convert(_ value: [String: PluginJSONValue]) throws -> [String: PluginUIJSON] {
        let data = try JSONEncoder().encode(PluginJSONValue.object(value))
        guard let result = try PluginUIJSON.decode(String(decoding: data, as: UTF8.self)).object else {
            throw PluginElyxDeveloperError.malformed("native Elyx reply must be an object")
        }
        return result
    }
}
