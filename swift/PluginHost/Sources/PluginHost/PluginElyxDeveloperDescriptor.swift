import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// C/native integration uses a context obtained from its actual interpreter
/// invocation. This type is neither Codable nor constructible from Python JSON.
public struct PluginElyxDeveloperInspectionContext: Hashable, Sendable {
    fileprivate let registry: UUID
    fileprivate let invocation: UUID
}

public enum PluginElyxDeveloperDescriptorPurpose: String, Codable, Sendable {
    case inspect, load, manifest
}

public enum PluginElyxDeveloperDescriptorConsumer: Equatable, Sendable {
    case inspection(PluginElyxDeveloperInspectionContext)
    case owner(PluginHost.CallbackOwner)
}

/// Installed by Host on the actual native owner/inspector worker, and cleared
/// by its execution-finished callback. The C verifier reads this native TLS;
/// no Python request can select or register a consumer context.
public enum PluginElyxDeveloperDescriptorExecution {
    private static let key = "exteraless.native.elyx.descriptor.consumer"
    private final class Box {
        let value: PluginElyxDeveloperDescriptorConsumer
        let valid: @Sendable () -> Bool
        var cleanup: [() -> Void] = []
        init(_ value: PluginElyxDeveloperDescriptorConsumer, valid: @escaping @Sendable () -> Bool) { self.value = value; self.valid = valid }
        deinit { for body in cleanup { body() } }
    }
    public static func install(_ value: PluginElyxDeveloperDescriptorConsumer?, isCurrent: @escaping @Sendable () -> Bool = { true }) {
        if let value { Thread.current.threadDictionary[key] = Box(value, valid: isCurrent) }
        else { Thread.current.threadDictionary.removeObject(forKey: key) }
    }
    public static var current: PluginElyxDeveloperDescriptorConsumer? {
        (Thread.current.threadDictionary[key] as? Box)?.value
    }
    static func checkCurrent() throws {
        guard let box = Thread.current.threadDictionary[key] as? Box, box.valid() else {
            throw PluginElyxDeveloperError.stale("native Elyx invocation/session expired")
        }
    }
    static func onFinish(_ body: @escaping () -> Void) throws {
        guard let box = Thread.current.threadDictionary[key] as? Box else { throw PluginElyxDeveloperError.stale("no native Elyx invocation") }
        box.cleanup.append(body)
    }
}

public struct PluginElyxDeveloperDescriptorClaims: Sendable {
    public let purpose: PluginElyxDeveloperDescriptorPurpose
    public let pluginId: String
    public let format: PluginFileFormat
    public let owner: PluginHost.CallbackOwner?
    public let namespace: String
    public let version: String
    public let sha256: String
    public let byteCount: Int
}

/// Created only by native file custody, never from a client-supplied fd/path/hash.
struct ElyxDescriptorBacking: Sendable {
    let descriptor: Int32
    let claims: PluginElyxDeveloperDescriptorClaims
    let check: @Sendable () throws -> Void
    let verify: @Sendable () throws -> Void
}

protocol ElyxManifestSource: AnyObject, Sendable {
    var manifestOwner: PluginHost.CallbackOwner { get }
    var manifestDigest: String { get }
    func manifestBacking() throws -> ElyxDescriptorBacking
}

func elyxNativeNonce() -> String {
    (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
}

/// Separate issuance registry. The wire value is only an unguessable lookup key;
/// the fd, claims, issuer, purpose and native consumer live in this registry.
/// Do not expose issue/bind/context creation as generic Python registrations.
public final class PluginElyxDeveloperDescriptorRegistry: @unchecked Sendable {
    public static let abi = 1
    public static let sourceABI = "exteraless.elyx.source.v1"
    public let identifier = UUID()
    private let lock = NSLock()
    private let maximumOutstanding: Int
    private var entries: [String: Entry] = [:]
    private var readers: [String: PluginElyxDeveloperResolvedDescriptor] = [:]
    private final class WeakSource {
        weak var value: (any ElyxManifestSource)?
        init(_ value: any ElyxManifestSource) { self.value = value }
    }
    private var sources: [String: WeakSource] = [:]
    private var accepting = true
    private var challenges: [String: PluginElyxDeveloperReadinessChallenge] = [:]
    private var operationCounts: [String: Int] = [:]
    private var readBytes = 0
    private var challengeCount = 0

    fileprivate final class Entry: @unchecked Sendable {
        let backing: ElyxDescriptorBacking
        let descriptor: PluginJSONValue
        private let lock = NSLock()
        private var inspection: PluginElyxDeveloperInspectionContext?
        private var consumed = false
        private var active = true

        init(_ backing: ElyxDescriptorBacking, descriptor: PluginJSONValue) { self.backing = backing; self.descriptor = descriptor }

        func bind(_ context: PluginElyxDeveloperInspectionContext) throws {
            lock.lock(); defer { lock.unlock() }
            guard active, !consumed, backing.claims.purpose == .inspect,
                  inspection == nil || inspection == context else {
                throw PluginElyxDeveloperError.stale("inspection descriptor cannot be rebound")
            }
            inspection = context
        }

        func check() throws {
            lock.lock(); let valid = active; lock.unlock()
            guard valid else { throw PluginElyxDeveloperError.stale("native descriptor lease expired") }
            try backing.check()
        }

        func consume(purpose: PluginElyxDeveloperDescriptorPurpose, caller: PluginElyxDeveloperDescriptorConsumer) throws {
            try check()
            lock.lock(); defer { lock.unlock() }
            guard active, !consumed, purpose == backing.claims.purpose else {
                throw PluginElyxDeveloperError.stale("native descriptor is expired, consumed or has a different purpose")
            }
            switch (purpose, caller) {
            case let (.inspect, .inspection(context)):
                guard inspection == context else { throw PluginElyxDeveloperError.stale("descriptor belongs to another inspection invocation") }
            case let (.load, .owner(owner)), let (.manifest, .owner(owner)):
                guard backing.claims.owner == owner else { throw PluginElyxDeveloperError.stale("descriptor belongs to another native callback owner") }
            default: throw PluginElyxDeveloperError.stale("wrong native descriptor consumer kind")
            }
            consumed = true
        }

        func requireConsumed() throws {
            try check()
            lock.lock(); let value = consumed; lock.unlock()
            guard value else { throw PluginElyxDeveloperError.unavailable("inspector did not consume the native-issued descriptor") }
        }

        func retire() { lock.lock(); active = false; lock.unlock() }
    }

    private static let descriptorKeys: Set<String> = ["abi", "schema", "capability", "purpose", "plugin_id", "owner_token", "format",
        "source_sha256", "byte_length", "source_namespace", "source_nonce"]

    public init(maximumOutstanding: Int = 64) {
        self.maximumOutstanding = min(256, max(1, maximumOutstanding))
    }

    /// Revoke future authority without releasing fd backing which an admitted
    /// native invocation still retains. Its actual completion performs cleanup.
    public func invalidate() {
        lock.lock()
        accepting = false
        let pending = Array(challenges.values)
        let issued = Array(entries.values)
        challenges.removeAll()
        sources.removeAll()
        lock.unlock()
        // Mark retained backings unusable without releasing their FDs. Existing
        // readers also fail their final check; actual invocation finish reclaims.
        for entry in issued { entry.retire() }
        for challenge in pending { challenge.invalidate() }
    }
    private func requireAccepting() throws {
        lock.lock(); let value = accepting; lock.unlock()
        guard value else { throw PluginElyxDeveloperError.stale("native Elyx registry binding retired") }
    }
    func beginReadinessChallenge() throws -> PluginElyxDeveloperReadinessChallenge {
        let challenge = PluginElyxDeveloperReadinessChallenge(registry: self)
        lock.lock(); defer { lock.unlock() }
        guard accepting, challenges.count < 8 else { throw PluginElyxDeveloperError.unavailable("native readiness challenge admission closed") }
        challenges[challenge.nonce] = challenge
        return challenge
    }
    func finishReadinessChallenge(_ nonce: String) {
        lock.lock(); let retired = challenges.removeValue(forKey: nonce); lock.unlock()
        withExtendedLifetime(retired) {}
    }
    private func observeReadinessChallenge(_ nonce: String, pluginId: String, ownerToken: String?) throws {
        lock.lock(); let challenge = challenges[nonce]; lock.unlock()
        guard let challenge else { return }
        try PluginElyxDeveloperDescriptorExecution.checkCurrent()
        guard pluginId == "@elyx-inspection", ownerToken == nil,
              PluginElyxDeveloperDescriptorExecution.current == .inspection(challenge.context) else { return }
        challenge.observe()
        lock.lock(); challengeCount += 1; lock.unlock()
    }
    public var metrics: PluginElyxDeveloperRegistryMetrics {
        lock.lock()
        let values = (operationCounts, readBytes, challengeCount, entries.count, readers.count, accepting)
        let observed = Array(sources.values)
        lock.unlock()
        return .init(operations: values.0, bytesRead: values.1, challengesObserved: values.2,
                     capabilities: values.3, readTickets: values.4, sourceReceipts: observed.compactMap(\.value).count, accepting: values.5)
    }

    /// Called by Host after it has reserved the actual metadata-inspector job.
    /// The native bridge stores this value in that job's native execution scope.
    public func makeInspectionContext() -> PluginElyxDeveloperInspectionContext {
        .init(registry: identifier, invocation: UUID())
    }

    public func bindInspection(_ descriptor: PluginElyxDeveloperDescriptor,
                               to context: PluginElyxDeveloperInspectionContext) throws {
        guard descriptor.registry === self, context.registry == identifier else {
            throw PluginElyxDeveloperError.stale("inspection context has a different native issuer")
        }
        try entry(descriptor.ticket).bind(context)
    }

    func issue(_ backing: ElyxDescriptorBacking) throws -> PluginElyxDeveloperDescriptor {
        try requireAccepting()
        try backing.verify()
        guard backing.descriptor >= 0, backing.claims.byteCount > 0,
              backing.claims.byteCount <= PluginElyxArchiveCandidate.maximumBytes,
              backing.claims.format.isArchive, Plugin.isValidID(backing.claims.pluginId, format: backing.claims.format),
              Self.hex(backing.claims.sha256), Self.hex(backing.claims.namespace), Self.hex(backing.claims.version),
              (backing.claims.purpose != .inspect) == (backing.claims.owner != nil) else {
            throw PluginElyxDeveloperError.malformed("invalid native descriptor issuance")
        }
        let ticket = elyxNativeNonce()
        let claims = backing.claims
        let descriptor: PluginJSONValue = .object([
            "abi": .string(Self.sourceABI), "schema": .integer(1), "capability": .string(ticket), "purpose": .string(claims.purpose.rawValue),
            "plugin_id": .string(claims.pluginId), "owner_token": claims.owner.map { .string($0.wireToken) } ?? .null,
            "format": .string(claims.format.rawValue), "source_sha256": .string(claims.sha256), "byte_length": .integer(Int64(claims.byteCount)),
            "source_namespace": .string(claims.namespace), "source_nonce": .string(claims.version)])
        let wire = try NativeServiceWire.json(descriptor)
        lock.lock()
        guard accepting, entries.count < maximumOutstanding else {
            lock.unlock()
            throw PluginElyxDeveloperError.unavailable("native descriptor capacity exhausted")
        }
        entries[ticket] = Entry(backing, descriptor: descriptor)
        lock.unlock()
        return PluginElyxDeveloperDescriptor(registry: self, ticket: ticket, json: wire)
    }

    /// The bridge supplies purpose and caller from native invocation context,
    /// never from request fields or a Python-selected plugin/inspector id.
    public func resolve(_ descriptorJSON: String, purpose: PluginElyxDeveloperDescriptorPurpose,
                         caller: PluginElyxDeveloperDescriptorConsumer) throws -> PluginElyxDeveloperResolvedDescriptor {
        try requireAccepting()
        let (raw, value) = try Self.payload(descriptorJSON, keys: Self.descriptorKeys)
        guard let ticket = raw["capability"] as? String, Self.hex(ticket) else { throw PluginElyxDeveloperError.malformed("invalid native capability") }
        let captured = try entry(ticket)
        guard value == captured.descriptor else { throw PluginElyxDeveloperError.stale("descriptor differs from its native-issued eleven-field proof") }
        try captured.backing.verify()
        let reader = try PluginElyxDeveloperResolvedDescriptor(captured, caller: caller, capability: ticket)
        try captured.consume(purpose: purpose, caller: caller)
        return reader
    }

    /// Entry used by the concrete C/native verification callback. In particular,
    /// never reconstruct `caller` from JSON owner/inspector fields.
    public func resolveCurrent(_ descriptorJSON: String, purpose: PluginElyxDeveloperDescriptorPurpose) throws -> PluginElyxDeveloperResolvedDescriptor {
        guard let caller = PluginElyxDeveloperDescriptorExecution.current else {
            throw PluginElyxDeveloperError.stale("descriptor verification has no native invocation context")
        }
        return try resolve(descriptorJSON, purpose: purpose, caller: caller)
    }

    /// C verifier entry: the last two values MUST come from immutable C module
    /// state, never Python request arguments. Inspector authentication is its
    /// native invocation context, not the spelling of a reserved plugin id.
    public func resolveFromBridge(_ descriptorJSON: String, purpose: PluginElyxDeveloperDescriptorPurpose,
                                  pluginId: String?, ownerToken: String?) throws -> PluginElyxDeveloperResolvedDescriptor {
        guard let caller = PluginElyxDeveloperDescriptorExecution.current else {
            throw PluginElyxDeveloperError.stale("descriptor verifier has no native execution context")
        }
        switch caller {
        case let .owner(owner):
            guard pluginId == owner.pluginId, ownerToken == owner.wireToken else {
                throw PluginElyxDeveloperError.stale("C interpreter identity does not match the issued native owner")
            }
        case .inspection:
            guard pluginId == "@elyx-inspection", ownerToken == nil else {
                throw PluginElyxDeveloperError.stale("plugin interpreter cannot impersonate an unbound native inspector")
            }
        }
        return try resolve(descriptorJSON, purpose: purpose, caller: caller)
    }

    func registerSource(_ source: any ElyxManifestSource) throws -> String {
        lock.lock(); let observed = sources; lock.unlock()
        // Weak loads may temporarily retain the last Source reference and run its
        // deinit/unregister. Never dereference them while holding the registry lock.
        let gone = observed.filter { $0.value.value == nil }
        lock.lock(); defer { lock.unlock() }
        for (id, value) in gone where sources[id] === value { sources.removeValue(forKey: id) }
        guard accepting, sources.count < 64 else { throw PluginElyxDeveloperError.unavailable("native source receipt capacity exhausted or retired") }
        let id = elyxNativeNonce()
        sources[id] = WeakSource(source)
        return id
    }
    func unregisterSource(_ id: String) { lock.lock(); sources.removeValue(forKey: id); lock.unlock() }

    /// Exact native-only hook for BridgeServices.elyxSourceDispatcher. The result
    /// contains only v1 JSON values/bytes; raw fds never cross this interface.
    public func dispatch(requestJSON: String, immutablePluginId: String, immutableOwnerToken: String?) -> String {
        do {
            guard requestJSON.utf8.count <= 32768,
                  let header = try JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any],
                  Set(header.keys) == Set(["op", "operation", "payload", "pluginId", "ownerToken"]), header["op"] as? String == "elyx_source",
                  header["pluginId"] as? String == immutablePluginId,
                  (header["ownerToken"] as? String) == immutableOwnerToken,
                  header["ownerToken"] is NSNull || header["ownerToken"] is String,
                  let operation = header["operation"] as? String, let text = header["payload"] as? String else {
                throw PluginElyxDeveloperError.malformed("invalid immutable-context Elyx source envelope")
            }
            lock.lock(); operationCounts[operation, default: 0] += 1; lock.unlock()
            if operation != "release" { try requireAccepting() }
            let value = try perform(operation, text: text, pluginId: immutablePluginId, ownerToken: immutableOwnerToken)
            return try PluginBridgeJSON.success(value)
        } catch let error as PluginElyxDeveloperError {
            return (try? PluginBridgeJSON.failure(kind: error.kind, message: error.message)) ?? "{\"ok\":false,\"error\":{\"kind\":\"RuntimeError\",\"message\":\"Elyx source failure\"}}"
        } catch {
            return (try? PluginBridgeJSON.failure(kind: "RuntimeError", message: String(describing: error))) ?? "{\"ok\":false,\"error\":{\"kind\":\"RuntimeError\",\"message\":\"Elyx source failure\"}}"
        }
    }

    private func perform(_ operation: String, text: String, pluginId: String, ownerToken: String?) throws -> PluginJSONValue {
        if operation == "claim" {
            let (raw, _) = try Self.payload(text, keys: Self.descriptorKeys)
            guard let name = raw["purpose"] as? String, let purpose = PluginElyxDeveloperDescriptorPurpose(rawValue: name), purpose != .manifest else {
                throw PluginElyxDeveloperError.malformed("claim requires inspect or load purpose")
            }
            try PluginElyxDeveloperDescriptorExecution.checkCurrent()
            let reader = try resolveFromBridge(text, purpose: purpose, pluginId: pluginId, ownerToken: ownerToken)
            return try registerReader(reader)
        }
        if operation == "manifest" {
            let (raw, _) = try Self.payload(text, keys: ["abi", "expected_source_sha256"])
            guard raw["abi"] as? String == Self.sourceABI, let digest = raw["expected_source_sha256"] as? String, Self.hex(digest),
                  case let .owner(owner)? = PluginElyxDeveloperDescriptorExecution.current,
                  owner.pluginId == pluginId, owner.wireToken == ownerToken else {
                throw PluginElyxDeveloperError.stale("manifest requires the C-bound active native owner")
            }
            try PluginElyxDeveloperDescriptorExecution.checkCurrent()
            lock.lock()
            let observed = Array(sources.values)
            lock.unlock()
            let candidates = observed.compactMap(\.value).filter { $0.manifestOwner == owner && $0.manifestDigest == digest }
            guard candidates.count == 1 else { throw PluginElyxDeveloperError.stale("manifest needs exactly one active native Source.open receipt; missing or ambiguous") }
            let issued = try issue(candidates[0].manifestBacking())
            let reader = try resolveFromBridge(issued.descriptorJSON, purpose: .manifest, pluginId: pluginId, ownerToken: ownerToken)
            return try registerReader(reader, retained: issued)
        }
        let keys: Set<String> = operation == "read" ? ["abi", "read_id", "offset", "count"] : ["abi", "read_id"]
        guard ["read", "check", "release"].contains(operation) else { throw PluginElyxDeveloperError.malformed("unknown native source operation") }
        let (raw, _) = try Self.payload(text, keys: keys)
        guard raw["abi"] as? String == Self.sourceABI, let id = raw["read_id"] as? String, Self.hex(id) else { throw PluginElyxDeveloperError.malformed("invalid native read ticket") }
        lock.lock(); let reader = readers[id]; lock.unlock()
        if operation == "check", reader == nil { try observeReadinessChallenge(id, pluginId: pluginId, ownerToken: ownerToken) }
        if operation == "release", reader == nil { return .object(["released": .bool(false)]) }
        guard let reader else { throw PluginElyxDeveloperError.stale("native read ticket is unknown or released") }
        try reader.authorize(pluginId: pluginId, ownerToken: ownerToken, releasing: operation == "release")
        if operation == "release" { removeReader(id); return .object(["released": .bool(true)]) }
        try PluginElyxDeveloperDescriptorExecution.checkCurrent()
        if operation == "check" {
            try reader.checkCurrent()
            return .object(["read_id": .string(id), "descriptor": reader.descriptor, "current": .bool(true)])
        }
        let offset = try Self.integer(raw["offset"], range: 0...reader.claims.byteCount)
        let count = try Self.integer(raw["count"], range: 1...65536)
        let data = try reader.read(offset: offset, count: count)
        lock.lock(); readBytes += data.count; lock.unlock()
        return .object(["offset": .integer(Int64(offset)), "data_base64": .string(data.base64EncodedString())])
    }

    private func registerReader(_ reader: PluginElyxDeveloperResolvedDescriptor,
                                retained: PluginElyxDeveloperDescriptor? = nil) throws -> PluginJSONValue {
        let id = elyxNativeNonce()
        lock.lock()
        guard accepting, readers.count < maximumOutstanding else { lock.unlock(); throw PluginElyxDeveloperError.unavailable("native read-ticket capacity exhausted or retired") }
        readers[id] = reader
        lock.unlock()
        do {
            try PluginElyxDeveloperDescriptorExecution.onFinish { [self, retained] in
                removeReader(id)
                withExtendedLifetime(retained) {}
            }
        } catch { removeReader(id); throw error }
        return .object(["abi": .string(Self.sourceABI), "read_id": .string(id), "descriptor": reader.descriptor,
                        "read_only": .bool(true), "load_reader_abi": .integer(1)])
    }
    private func removeReader(_ id: String) {
        lock.lock(); let value = readers.removeValue(forKey: id); lock.unlock()
        value?.retire()
    }
    private static func payload(_ text: String, keys: Set<String>) throws -> ([String: Any], PluginJSONValue) {
        guard !text.isEmpty, text.utf8.count <= 4096,
              let raw = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], Set(raw.keys) == keys else {
            throw PluginElyxDeveloperError.malformed("invalid native source payload keys or 4096-byte bound")
        }
        return (raw, try PluginJSONValue(jsonObject: raw))
    }
    private static func hex(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func integer(_ value: Any?, range: ClosedRange<Int>) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)), let parsed = Int(number.stringValue), range.contains(parsed) else {
            throw PluginElyxDeveloperError.malformed("native read offset/count must be bounded integers")
        }
        return parsed
    }

    fileprivate func entry(_ ticket: String) throws -> Entry {
        lock.lock(); let result = accepting ? entries[ticket] : nil; lock.unlock()
        guard let result else { throw PluginElyxDeveloperError.stale("native descriptor ticket is unknown or expired") }
        return result
    }

    fileprivate func retire(_ ticket: String) {
        lock.lock()
        let value = entries.removeValue(forKey: ticket)
        let ids = readers.filter { $0.value.capability == ticket }.map(\.key)
        let dropped = ids.compactMap { readers.removeValue(forKey: $0) }
        lock.unlock()
        for reader in dropped { reader.retire() }
        value?.retire()
    }

    public var outstandingCount: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    public var outstandingReadCount: Int { lock.lock(); defer { lock.unlock() }; return readers.count }
}

/// Held by the *actual invocation completion*, not merely its async waiter.
/// Revocation removes issuance; any in-flight resolved object still retains its
/// read-only fd backing, so early cancellation cannot recycle a descriptor number.
public final class PluginElyxDeveloperDescriptor: PluginElyxDeveloperDescriptorLease, @unchecked Sendable {
    fileprivate let registry: PluginElyxDeveloperDescriptorRegistry
    fileprivate let ticket: String
    public let descriptorJSON: String

    fileprivate init(registry: PluginElyxDeveloperDescriptorRegistry, ticket: String, json: String) {
        self.registry = registry; self.ticket = ticket; descriptorJSON = json
    }
    deinit { registry.retire(ticket) }
    public func checkCurrent() throws { try registry.entry(ticket).check() }
    func requireConsumed() throws { try registry.entry(ticket).requireConsumed() }

    /// Native Host calls this after reserving the inspector, before its queue
    /// hop. Only that invocation receives the returned non-serializable context.
    public func bindNativeInspection() throws -> PluginElyxDeveloperDescriptorConsumer {
        let context = registry.makeInspectionContext()
        try registry.bindInspection(self, to: context)
        return .inspection(context)
    }

    public func nativeLoadConsumer() throws -> PluginElyxDeveloperDescriptorConsumer {
        let entry = try registry.entry(ticket)
        try entry.check()
        guard entry.backing.claims.purpose == .load, let owner = entry.backing.claims.owner else {
            throw PluginElyxDeveloperError.stale("descriptor is not a native owner-bound load")
        }
        return .owner(owner)
    }
}

public final class PluginElyxDeveloperResolvedDescriptor: @unchecked Sendable {
    private let entry: PluginElyxDeveloperDescriptorRegistry.Entry
    fileprivate let capability: String
    private let caller: PluginElyxDeveloperDescriptorConsumer
    private let lock = NSLock()
    private var active = true
    private let fd: Int32
    fileprivate init(_ entry: PluginElyxDeveloperDescriptorRegistry.Entry, caller: PluginElyxDeveloperDescriptorConsumer, capability: String) throws {
        self.entry = entry; self.caller = caller; self.capability = capability
        #if canImport(Darwin) || canImport(Glibc)
        let copied = fcntl(entry.backing.descriptor, F_DUPFD_CLOEXEC, 0)
        guard copied >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        fd = copied
        #else
        throw PluginElyxDeveloperError.unavailable("native source read tickets require POSIX read-only descriptors")
        #endif
    }
    deinit {
        #if canImport(Darwin) || canImport(Glibc)
        _ = close(fd)
        #endif
    }
    public var claims: PluginElyxDeveloperDescriptorClaims { entry.backing.claims }
    fileprivate var descriptor: PluginJSONValue { entry.descriptor }
    var nativeDescriptorForTesting: Int32 { fd } // never serialized or exposed to Python
    fileprivate func authorize(pluginId: String, ownerToken: String?, releasing: Bool) throws {
        switch caller {
        case let .owner(owner):
            guard owner.pluginId == pluginId, owner.wireToken == ownerToken else { throw PluginElyxDeveloperError.stale("read ticket belongs to another C owner") }
            if !releasing, PluginElyxDeveloperDescriptorExecution.current != caller { throw PluginElyxDeveloperError.stale("read ticket has a different native invocation owner") }
        case .inspection:
            guard pluginId == "@elyx-inspection", ownerToken == nil, PluginElyxDeveloperDescriptorExecution.current == caller else {
                throw PluginElyxDeveloperError.stale("read ticket belongs to another native inspector")
            }
        }
    }
    fileprivate func retire() { lock.lock(); active = false; lock.unlock() }
    private func checkLocked() throws {
        guard active else { throw PluginElyxDeveloperError.stale("native read ticket is closed") }
        try entry.check()
        #if canImport(Darwin) || canImport(Glibc)
        var original = stat(), copied = stat()
        guard fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY, fstat(fd, &copied) == 0,
              fstat(entry.backing.descriptor, &original) == 0, copied.st_dev == original.st_dev, copied.st_ino == original.st_ino,
              copied.st_size == original.st_size, copied.st_size == claims.byteCount,
              UInt32(copied.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG) else { throw PluginElyxDeveloperError.stale("native read fd custody changed") }
        #endif
    }
    public func checkCurrent() throws { lock.lock(); defer { lock.unlock() }; try checkLocked() }
    public func read(offset: Int, count: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard offset >= 0, offset <= claims.byteCount, (1...65536).contains(count) else { throw PluginElyxDeveloperError.malformed("invalid native read range") }
        try checkLocked()
        #if canImport(Darwin) || canImport(Glibc)
        var data = Data(count: min(count, claims.byteCount - offset))
        var done = 0
        while done < data.count {
            let readCount = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: done), $0.count - done, off_t(offset + done)) }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            done += readCount
        }
        try checkLocked()
        return data
        #else
        throw PluginElyxDeveloperError.unavailable("native source read requires POSIX")
        #endif
    }
}

/// Native registration receipt, supplied by the concrete bridge composition.
/// A new bridge/hook registration gets a new epoch; an ABA replacement cannot
/// validate an older prepared candidate merely by exposing the same names.
public struct PluginElyxDeveloperBridgeReadiness: Equatable, Sendable {
    public enum Hook: String, CaseIterable, Sendable { case manifest, inspect, verifiedLoad }
    public let abi: Int
    public let registry: UUID
    public let epoch: UUID
    public let hooks: Set<Hook>
    public init(abi: Int, registry: UUID, epoch: UUID, hooks: Set<Hook>) {
        self.abi = abi; self.registry = registry; self.epoch = epoch; self.hooks = hooks
    }
}

public struct PluginElyxDeveloperInspection: Sendable {
    public let descriptor: PluginElyxDeveloperDescriptor
    public let format: PluginFileFormat
    public let isCurrent: @Sendable () -> Bool
}

/// Mandatory native integration points, not default success callbacks. Root
/// supplies the actual registered C verifier / three Python hooks / Host inspector.
public struct PluginElyxDeveloperDescriptorBridge: Sendable {
    let readiness: @Sendable () throws -> PluginElyxDeveloperBridgeReadiness
    let inspect: @Sendable (PluginElyxDeveloperInspection) async throws -> Plugin
    let currentOwner: @Sendable (PluginHost.CallbackOwner) -> Bool

    public init(readiness: @escaping @Sendable () throws -> PluginElyxDeveloperBridgeReadiness,
                inspect: @escaping @Sendable (PluginElyxDeveloperInspection) async throws -> Plugin,
                currentOwner: @escaping @Sendable (PluginHost.CallbackOwner) -> Bool) {
        self.readiness = readiness; self.inspect = inspect; self.currentOwner = currentOwner
    }

    func requireReady(_ registry: PluginElyxDeveloperDescriptorRegistry,
                      expected: PluginElyxDeveloperBridgeReadiness? = nil) throws -> PluginElyxDeveloperBridgeReadiness {
        let value = try readiness()
        guard value.abi == PluginElyxDeveloperDescriptorRegistry.abi, value.registry == registry.identifier,
              value.hooks == Set(PluginElyxDeveloperBridgeReadiness.Hook.allCases), expected == nil || expected == value else {
            throw PluginElyxDeveloperError.unavailable("native descriptor verifier / FD hooks are unavailable or replaced")
        }
        return value
    }
}

/// Same SHA-256 primitive as Core's ToolsSHA256: CryptoKit in Apple builds,
/// standard bounded portable implementation for offline Linux fixtures. No UIKit
/// or Core package dependency is introduced into PluginHost.
enum ElyxNativeSHA256 {
    static func hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        var bytes = [UInt8](data)
        let bits = UInt64(bytes.count) * 8
        bytes.append(128)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: bits >> shift)) }
        var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        func rotate(_ value: UInt32, _ bits: UInt32) -> UInt32 { (value >> bits) | (value << (32 - bits)) }
        for start in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let n = start + i * 4
                words[i] = UInt32(bytes[n]) << 24 | UInt32(bytes[n + 1]) << 16 | UInt32(bytes[n + 2]) << 8 | UInt32(bytes[n + 3])
            }
            for i in 16..<64 {
                let x = words[i - 15], y = words[i - 2]
                words[i] = words[i - 16] &+ (rotate(x, 7) ^ rotate(x, 18) ^ (x >> 3)) &+ words[i - 7]
                    &+ (rotate(y, 17) ^ rotate(y, 19) ^ (y >> 10))
            }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for i in 0..<64 {
                let first = h &+ (rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)) &+ ((e & f) ^ (~e & g)) &+ constants[i] &+ words[i]
                let second = (rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                h = g; g = f; f = e; e = d &+ first; d = c; c = b; b = a; a = first &+ second
            }
            for (i, value) in [a, b, c, d, e, f, g, h].enumerated() { state[i] = state[i] &+ value }
        }
        return state.map { String(format: "%08x", $0) }.joined()
        #endif
    }

    #if !canImport(CryptoKit)
    private static let constants: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
    #endif
}
