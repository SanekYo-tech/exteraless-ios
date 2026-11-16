import Foundation

/// Captured synchronously at authenticated ingress, before the first await.
/// The permission revision prevents an A -> B -> A consent edit reviving work.
public struct PluginElyxDeveloperTarget: Sendable {
    public let plugin: Plugin
    public let owner: PluginHost.CallbackOwner
    public let consent: PluginPermissionSnapshot
    private let model: Data

    init(plugin: Plugin, owner: PluginHost.CallbackOwner, consent: PluginPermissionSnapshot) throws {
        self.plugin = plugin; self.owner = owner; self.consent = consent
        model = try Self.model(plugin)
    }

    public func matches(_ current: Plugin) -> Bool { (try? Self.model(current)) == model }

    public static func sameInstallation(_ left: Plugin, _ right: Plugin) -> Bool {
        guard let first = try? model(left), let second = try? model(right) else { return false }
        return first == second
    }

    private static func model(_ plugin: Plugin) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let value = try encoder.encode(plugin) // persisted metadata/path/format/enabled, not transient flags
        guard value.count <= 1024 * 1024 else { throw PluginElyxDeveloperError.malformed("plugin metadata exceeds 1 MiB") }
        return value
    }
}

/// Handoff to the archive owner's new FD/source-byte authority. There is
/// intentionally no URL-only fallback to the superseded cache/path helpers.
/// Implementations are native-only; none of these capabilities is a bridge export.
public protocol PluginElyxDeveloperFileAuthority: Sendable {
    /// Anchor the native installation namespace and source descriptor, reject
    /// redirection, and retain the exact byte/version identity until release.
    func open(_ target: PluginElyxDeveloperTarget) throws -> any PluginElyxDeveloperSource
}

public protocol PluginElyxDeveloperSource: AnyObject, Sendable {
    var archiveBytes: Data { get }
    var sha256: String { get }
    /// Must detect namespace replacement, source edits (including ABA), and a
    /// changed FD/native source capability. Never resolve a mutable cache path.
    /// This checks file custody, not callbackOwner(): Host intentionally retires
    /// the old worker while retaining its per-ID mutation/source reservation.
    func checkCurrent() throws
    /// Private bounded staging, full static FD inspection and load-provider
    /// admission. On error, unlink only this staging lease via its directory FD.
    /// No installed bytes, extraction or model may be changed by prepare.
    func prepare(_ candidate: Data, shouldExecute: @escaping @Sendable () -> Bool) async throws -> any PluginElyxDeveloperPrepared
}

public protocol PluginElyxDeveloperPrepared: AnyObject, Sendable {
    var metadata: Plugin { get }
    var sha256: String { get }
    /// Includes ready FD inspection/verified-load ABI, exact candidate bytes,
    /// source version, safe mappings and all aggregate archive/wheel limits.
    func checkBeforePublication() throws
    /// Atomic native replacement under Host's per-ID mutation reservation.
    /// The final predicate and source/version CAS must precede the rename.
    func publish(shouldExecute: @escaping @Sendable () -> Bool) throws
    func checkPublished() throws
    /// A distinct retained descriptor for the NEW worker. Lifetime is held by
    /// the actual interpreter invocation, including cancellation/abandon tails.
    func loadSource(owner: PluginHost.CallbackOwner) throws -> any PluginElyxDeveloperDescriptorLease
}

public protocol PluginElyxDeveloperDescriptorLease: AnyObject, Sendable {
    /// Bounded data-only descriptor envelope for _elyx_developer.load_verified_json.
    /// It is not the listener token and grants no manager/other-owner authority.
    var descriptorJSON: String { get }
    func checkCurrent() throws
}

public struct PluginElyxDeveloperInstalled: Sendable {
    public let plugin: Plugin
    public let owner: PluginHost.CallbackOwner?
    public init(plugin: Plugin, owner: PluginHost.CallbackOwner?) { self.plugin = plugin; self.owner = owner }
}

/// A native-only invocation envelope; the listener token is never a field.
public struct PluginElyxDeveloperInvocation: Sendable {
    public let request: PluginElyxDeveloperRequest
    public let targets: [PluginElyxDeveloperTarget]
    public let account: Int32
    public let files: (any PluginElyxDeveloperFileAuthority)?
    public let deadline: TimeInterval
    public let isCurrent: @Sendable () -> Bool
    public let publication: PluginElyxDeveloperPublicationState?

    public init(request: PluginElyxDeveloperRequest, targets: [PluginElyxDeveloperTarget], account: Int32,
                files: (any PluginElyxDeveloperFileAuthority)?, deadline: TimeInterval, isCurrent: @escaping @Sendable () -> Bool,
                publication: PluginElyxDeveloperPublicationState? = nil) {
        self.request = request; self.targets = targets; self.account = account
        self.files = files; self.deadline = deadline; self.isCurrent = isCurrent
        self.publication = publication ?? (request.kind == .changes ? PluginElyxDeveloperPublicationState(pluginId: request.pluginId) : nil)
    }
}

/// Pure native command orchestration. Host supplies ONLY its captured-worker
/// read, metadata ping and native replacement APIs; there is no Python reload.
public enum PluginElyxDeveloperTransaction {
    public typealias Read = @Sendable (PluginElyxDeveloperTarget, String?) async throws -> String
    public typealias Publish = @Sendable (PluginElyxDeveloperTarget, any PluginElyxDeveloperSource, any PluginElyxDeveloperPrepared) async throws -> PluginElyxDeveloperInstalled

    public static func run(_ request: PluginElyxDeveloperRequest, targets: [PluginElyxDeveloperTarget],
                           files: (any PluginElyxDeveloperFileAuthority)?,
                           current: @escaping @Sendable (PluginElyxDeveloperTarget) -> Bool,
                           installedCurrent: @Sendable (PluginElyxDeveloperInstalled, PluginPermissionSnapshot) -> Bool,
                           session: @escaping @Sendable () -> Bool,
                           read: Read, ping: @Sendable () async throws -> String, publish: Publish,
                           publication: PluginElyxDeveloperPublicationState? = nil) async throws -> [String: PluginJSONValue] {
        let publication = publication ?? (request.kind == .changes ? PluginElyxDeveloperPublicationState(pluginId: request.pluginId) : nil)
        do {
            try checkSession(session)
            guard targets.count <= 64, Set(targets.map { $0.plugin.id }).count == targets.count,
                  targets.allSatisfy({ $0.plugin.fileFormat.isArchive && $0.plugin.loaded && $0.plugin.isEnabled && current($0) }) else {
                throw PluginElyxDeveloperError.stale("Elyx target set is stale, duplicated or exceeds 64 owners")
            }
            if let id = request.pluginId {
                guard targets.count == 1, targets[0].plugin.id == id else { throw PluginElyxDeveloperError.stale("selected Elyx plugin is not loaded") }
            }
            switch request.kind {
            case .ping:
                let result: [String: PluginJSONValue]
                if let target = targets.first {
                    let value = try decode(await read(target, nil))
                    guard current(target), case let .string(version)? = value["version"] else { throw PluginElyxDeveloperError.stale("Elyx ping owner/version changed") }
                    result = ["ok": .bool(true), "elyx": .bool(true), "version": .string(version)]
                } else {
                    result = try decode(await ping())
                    guard result["elyx"] == .bool(true), case .string? = result["version"] else { throw PluginElyxDeveloperError.malformed("invalid Original Elyx ping result") }
                }
                try checkSession(session)
                return try bounded(result)
            case .list:
                var plugins: [PluginJSONValue] = []
                for target in targets {
                    try checkSession(session)
                    guard current(target) else { throw PluginElyxDeveloperError.stale("Elyx list owner retired before read") }
                    let value = try decode(await read(target, nil))
                    guard current(target), case let .object(plugin)? = value["plugin"], plugin["id"] == .string(target.plugin.id) else {
                        throw PluginElyxDeveloperError.stale("Elyx list returned a retired/different owner")
                    }
                    plugins.append(.object(plugin))
                    _ = try bounded(["plugins": .array(plugins)])
                }
                try checkSession(session)
                guard targets.allSatisfy(current) else { throw PluginElyxDeveloperError.stale("Elyx list snapshot changed before delivery") }
                return ["ok": .bool(true), "plugins": .array(plugins)]
            case .compare, .changes:
                let target = targets[0]
                guard let files else { throw PluginElyxDeveloperError.unavailable("FD-backed Elyx developer file authority is not installed") }
                let source = try files.open(target)
                guard PluginElyxDeveloperRequest.isDigest(source.sha256), source.archiveBytes.count <= PluginElyxArchiveCandidate.maximumBytes else {
                    throw PluginElyxDeveloperError.malformed("invalid native Elyx source lease")
                }
                try source.checkCurrent()
                let value = try decode(await read(target, source.sha256))
                try checkSession(session)
                guard current(target), value["source_digest"] == .string(source.sha256), case let .object(raw)? = value["files"], raw.count <= 2048 else {
                    throw PluginElyxDeveloperError.stale("verified Elyx manifest does not match the captured source/owner")
                }
                var hashes: [String: String] = [:]
                for (path, value) in raw {
                    guard try PluginElyxDeveloperRequest.path(path) == path, case let .string(hash) = value, PluginElyxDeveloperRequest.isDigest(hash) else {
                        throw PluginElyxDeveloperError.malformed("invalid verified Elyx file manifest")
                    }
                    hashes[path] = hash
                }
                try source.checkCurrent()
                if request.kind == .compare {
                    let changed = request.hashes.keys.filter { hashes[$0] != request.hashes[$0] }.sorted()
                    let deleted = hashes.keys.filter { request.hashes[$0] == nil }.sorted()
                    try checkSession(session)
                    guard current(target) else { throw PluginElyxDeveloperError.stale("Elyx compare owner retired") }
                    try source.checkCurrent()
                    return try bounded(["ok": .bool(true), "plugin_id": .string(target.plugin.id),
                                        "created_or_modified": .array(changed.map(PluginJSONValue.string)),
                                        "deleted": .array(deleted.map(PluginJSONValue.string))])
                }
                // This transforms authoritative archive bytes, never extracted files.
                let candidate = try PluginElyxArchiveCandidate.applying(request.changes, to: source.archiveBytes)
                let valid: @Sendable () -> Bool = { session() && current(target) && (try? source.checkCurrent()) != nil }
                guard valid() else { throw PluginElyxDeveloperError.stale("Elyx source/owner retired before staging") }
                let prepared = try await source.prepare(candidate, shouldExecute: valid)
                try prepared.checkBeforePublication()
                guard valid(), prepared.metadata.id == target.plugin.id, prepared.metadata.fileFormat == target.plugin.fileFormat else {
                    throw PluginElyxDeveloperError.stale("Elyx candidate changed identity/format or its source retired")
                }
                let installed = try await publish(target, source, prepared)
                publication?.record(.committed)
                try checkSession(session)
                try prepared.checkPublished()
                guard installedCurrent(installed, target.consent) else { throw PluginElyxDeveloperError.stale("replacement owner/consent retired before delivery") }
                let plugin = installed.plugin
                guard plugin.id == target.plugin.id, plugin.fileFormat == target.plugin.fileFormat,
                      plugin.path == target.plugin.path, plugin.enabled == target.plugin.enabled else {
                    throw PluginElyxDeveloperError.stale("Elyx replacement receipt has different native installation state")
                }
                let reloaded = plugin.loaded && plugin.loadError == nil && installed.owner != nil && installed.owner != target.owner
                if !reloaded {
                    return PluginElyxDeveloperError.response(PluginHostError.runtimeFailure(plugin.loadError ?? "native archive replacement did not load a new owner"),
                        request: request, publication: publication)
                }
                return ["ok": .bool(true), "plugin_id": .string(plugin.id), "reloaded": .bool(true),
                        "errors": .array([]), "publication_outcome": .string("committed"), "source_changed": .bool(true)]
            }
        } catch {
            if let publication { throw publication.failure(error) }
            throw error
        }
    }

    private static func checkSession(_ current: () -> Bool) throws {
        try Task.checkCancellation()
        guard current() else { throw PluginElyxDeveloperError.stale("native developer session/account/deadline retired") }
    }

    private static func decode(_ text: String) throws -> [String: PluginJSONValue] {
        guard text.utf8.count <= 2 * 1024 * 1024,
              case let .object(value) = try PluginJSONValue(jsonObject: JSONSerialization.jsonObject(with: Data(text.utf8))),
              value["ok"] == .bool(true) else { throw PluginElyxDeveloperError.malformed("failed or oversized Elyx worker reply") }
        return value
    }

    private static func bounded(_ value: [String: PluginJSONValue]) throws -> [String: PluginJSONValue] {
        let encoded = try JSONEncoder().encode(PluginJSONValue.object(value))
        guard encoded.count <= PluginElyxDeveloperRequest.maximumRequestBytes - 2048 else { throw PluginElyxDeveloperError.malformed("Elyx response exceeds the native line budget") }
        return value
    }
}
