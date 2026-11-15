import Foundation

public enum NativeServiceOpenDecision: Equatable, Sendable {
    case continueOpening
    case handled
    /// The native caller disappeared or its account was removed. Do not open a
    /// different account's screen, and do not issue after callbacks.
    case cancelled
}

public struct NativeServiceOpenStep<Owner: Hashable & Sendable>: Sendable {
    public let lease: NativeServiceCallbackLease<Owner>
    public let argumentsJSON: String

    public init(lease: NativeServiceCallbackLease<Owner>, context: PluginJSONValue) throws {
        self.lease = lease
        self.argumentsJSON = try NativeServiceWire.json(.array([context]))
    }
}

/// Nonblocking sequential before-handler barrier, also used for the file-open
/// callback's exception/fallback semantics. A successful file callback handles the
/// opening regardless of its returned dict/bool/null (FilesControllerJava:195-200).
public final class NativeServiceOpenBarrier<Owner: Hashable & Sendable>: @unchecked Sendable {
    public let id = UUID().uuidString
    private let queue: DispatchQueue
    private let fileCallback: Bool
    private let callbackTimeoutNanoseconds: UInt64
    private let deadline: UInt64
    private var steps: [NativeServiceOpenStep<Owner>]
    private var index = 0
    private var awaiting = false
    private var sequence: UInt64 = 0
    private var finished = false
    private var control: NativeServiceCallbackControl?
    private var timer: DispatchSourceTimer?
    private var completion: (@Sendable (NativeServiceOpenDecision) -> Void)?

    public init(steps: [NativeServiceOpenStep<Owner>], fileCallback: Bool,
                callbackTimeoutMs: Int = 300, totalTimeoutMs: Int = 2000,
                completion: @escaping @Sendable (NativeServiceOpenDecision) -> Void) {
        self.queue = DispatchQueue(label: "Exteraless.NativeOpenBarrier", qos: .userInitiated)
        self.steps = steps
        self.fileCallback = fileCallback
        self.callbackTimeoutNanoseconds = UInt64(max(1, min(2000, callbackTimeoutMs))) * 1_000_000
        self.deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(1, min(5000, totalTimeoutMs))) * 1_000_000
        self.completion = completion
    }

    public func start() { queue.async { [self] in advance() } }

    public func cancel() { queue.async { [self] in finish(.cancelled) } }

    /// Unregister/unload advances past the withdrawn current handler immediately;
    /// it never waits on that interpreter, nor admits a replacement generation.
    public func registrationsChanged() {
        queue.async { [self] in
            if !finished, awaiting, index > 0, index <= steps.count, !steps[index - 1].lease.isOpen {
                control?.cancel()
                sequence &+= 1
                awaiting = false
                timer?.cancel()
                timer = nil
                advance()
            }
        }
    }

    private func advance() {
        guard !finished, !awaiting else { return }
        while index < steps.count {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { finish(.continueOpening); return }
            let step = steps[index]
            index += 1
            guard step.lease.isOpen else { continue }
            sequence &+= 1
            let expected = sequence
            let control = NativeServiceCallbackControl(deadlineNanoseconds: min(deadline,
                DispatchTime.now().uptimeNanoseconds + callbackTimeoutNanoseconds))
            self.control = control
            awaiting = true
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: DispatchTime(uptimeNanoseconds: control.deadlineNanoseconds))
            timer.setEventHandler { [weak self] in
                self?.received(.failure(.unavailable("Native opening callback timed out")), expected: expected)
            }
            self.timer = timer
            timer.resume()
            let accepted = step.lease.request(argumentsJSON: step.argumentsJSON, control: control) { [weak self] result in
                guard let self else { return }
                self.queue.async { [self] in received(result, expected: expected) }
            }
            if !accepted {
                received(.failure(.unavailable("Native opening callback was not admitted")), expected: expected)
            }
            return
        }
        finish(.continueOpening)
    }

    private func received(_ result: NativeServiceCallbackResult, expected: UInt64) {
        guard !finished, awaiting, sequence == expected else { return }
        let wasActive = control?.isActive == true
        control?.cancel()
        control = nil
        timer?.cancel()
        timer = nil
        awaiting = false
        let stillRegistered = index > 0 && steps[index - 1].lease.isOpen
        if wasActive && stillRegistered, case let .success(value) = result {
            if fileCallback {
                finish(.handled)
                return
            }
            // The SDK _IntentCallback explicitly returns bool. An object or the
            // native admission Bool must never be mistaken for that result.
            if value == .bool(true) { finish(.handled); return }
        }
        advance()
    }

    private func finish(_ decision: NativeServiceOpenDecision) {
        guard !finished else { return }
        finished = true
        awaiting = false
        index = 0
        control?.cancel()
        control = nil
        timer?.cancel()
        timer = nil
        steps.removeAll()
        let completion = self.completion
        self.completion = nil
        completion?(decision)
    }

    deinit {
        control?.cancel()
        timer?.cancel()
    }
}

/// The registry owns registrations, the pool owns C leases, and each opening owns
/// a bounded barrier. After handlers are delivered only by completeOriginal(),
/// after the native opener returned, never on a cancelled/handled before path.
public final class NativeServiceInterceptions<Owner: Hashable & Sendable>: @unchecked Sendable {
    private struct FileEntry {
        let model: NativeServiceFileRegistration
        let lease: NativeServiceCallbackLease<Owner>
    }
    private struct IntentEntry {
        let model: NativeServiceIntentRegistration
        let lease: NativeServiceCallbackLease<Owner>
        let sequence: UInt64
    }
    public final class IntentAfter: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [NativeServiceOpenStep<Owner>]
        fileprivate init(_ steps: [NativeServiceOpenStep<Owner>]) { self.steps = steps }
        public func completeOriginal() {
            lock.lock()
            let steps = self.steps
            self.steps.removeAll()
            lock.unlock()
            for step in steps { step.lease.send(argumentsJSON: step.argumentsJSON) }
        }
    }

    private let lock = NSLock()
    private let sites: Set<NativeServiceInterceptionSite>
    private var files: [String: FileEntry] = [:]
    private var intents: [IntentEntry] = []
    private var sequence: UInt64 = 0
    private struct Opening {
        let barrier: NativeServiceOpenBarrier<Owner>
        let accountRecordId: Int64?
        let argumentBytes: Int
    }
    private var barriers: [String: Opening] = [:]
    private var pendingArgumentBytes = 0

    public init(sites: Set<NativeServiceInterceptionSite>) { self.sites = sites }

    public func supports(_ site: NativeServiceInterceptionSite) -> Bool { sites.contains(site) }

    public func canInterceptFile(fileName: String) -> Bool {
        lock.lock()
        let entry = files[(fileName as NSString).pathExtension.lowercased()]
        lock.unlock()
        return entry?.lease.isOpen == true && entry?.model.matches(fileName: fileName) == true
    }

    public func registerFile(_ model: NativeServiceFileRegistration, lease: NativeServiceCallbackLease<Owner>) throws -> String {
        guard sites.contains(.chatDocument), lease.supportsResults else {
            throw BridgeFailure.unimplemented("fileRegister requires OpenChatMessage.document and a result-bearing owner dispatcher")
        }
        lock.lock()
        files = files.filter {
            if $0.value.lease.isOpen { return true }
            $0.value.lease.close()
            return false
        }
        guard files.count < 1024 || files[model.fileExtension] != nil else {
            lock.unlock()
            throw BridgeFailure.unavailable("Native file registration budget exhausted")
        }
        if let old = files[model.fileExtension], old.lease.isOpen, old.lease.pluginId != lease.pluginId {
            lock.unlock()
            throw BridgeFailure.unavailable("ExtensionAlreadyRegistered")
        }
        let old = files.updateValue(FileEntry(model: model, lease: lease), forKey: model.fileExtension)
        lock.unlock()
        old?.lease.close()
        notifyBarriers()
        return lease.id
    }

    public func registerIntent(_ model: NativeServiceIntentRegistration, lease: NativeServiceCallbackLease<Owner>) throws -> String {
        guard !sites.isDisjoint(with: [.externalURL, .applicationURL]), lease.supportsResults else {
            throw BridgeFailure.unimplemented("intentRegister requires a native URL hook and a result-bearing owner dispatcher")
        }
        try model.validateNativeURLSites()
        lock.lock(); defer { lock.unlock() }
        intents.removeAll {
            if $0.lease.isOpen { return false }
            $0.lease.close()
            return true
        }
        guard intents.count < 1024 else { throw BridgeFailure.unavailable("Native intent registration budget exhausted") }
        sequence &+= 1
        intents.append(IntentEntry(model: model, lease: lease, sequence: sequence))
        intents.sort { $0.model.priority == $1.model.priority ? $0.sequence < $1.sequence : $0.model.priority > $1.model.priority }
        return lease.id
    }

    public func remove(id: String, owner: Owner, file: Bool) -> Bool {
        remove(id: id, file: file, accepting: { $0.owner == owner })
    }

    public func remove(id: String, cleanup: NativeServiceCleanupIdentity, file: Bool) -> Bool {
        remove(id: id, file: file, accepting: { $0.matchesCleanup(cleanup) })
    }

    private func remove(id: String, file: Bool, accepting: (NativeServiceCallbackLease<Owner>) -> Bool) -> Bool {
        lock.lock()
        let lease: NativeServiceCallbackLease<Owner>?
        if file {
            let key = files.first { $0.value.lease.id == id && accepting($0.value.lease) }?.key
            lease = key.flatMap { files.removeValue(forKey: $0)?.lease }
        } else if let index = intents.firstIndex(where: { $0.lease.id == id && accepting($0.lease) }) {
            lease = intents.remove(at: index).lease
        } else {
            lease = nil
        }
        lock.unlock()
        lease?.close()
        if lease != nil { notifyBarriers() }
        return lease != nil
    }

    public func releaseInstances(pluginId: String? = nil) {
        lock.lock()
        let selected = files.values.map(\.lease).filter { pluginId == nil || $0.pluginId == pluginId }
            + intents.map(\.lease).filter { pluginId == nil || $0.pluginId == pluginId }
        files = files.filter { pluginId != nil && $0.value.lease.pluginId != pluginId }
        intents.removeAll { pluginId == nil || $0.lease.pluginId == pluginId }
        lock.unlock()
        for lease in selected { lease.close() }
        notifyBarriers()
    }

    public func interceptFile(_ context: NativeServiceFileOpenContext, accountRecordId: Int64? = nil,
                              completion: @escaping @Sendable (NativeServiceOpenDecision) -> Void) -> NativeServiceOpenBarrier<Owner>? {
        lock.lock()
        let entry = files[(context.fileName as NSString).pathExtension.lowercased()]
        lock.unlock()
        guard let entry, entry.lease.isOpen, entry.model.matches(fileName: context.fileName),
              let step = try? NativeServiceOpenStep(lease: entry.lease, context: context.value) else { return nil }
        return begin(steps: [step], file: true, accountRecordId: accountRecordId,
            argumentBytes: step.argumentsJSON.utf8.count, completion: completion)
    }

    public func interceptIntent(_ context: NativeServiceIntentContext, accountRecordId: Int64? = nil,
                                completion: @escaping @Sendable (NativeServiceOpenDecision, IntentAfter) -> Void) -> NativeServiceOpenBarrier<Owner>? {
        lock.lock()
        let entries = intents
        lock.unlock()
        var before: [NativeServiceOpenStep<Owner>] = []
        var after: [NativeServiceOpenStep<Owner>] = []
        var argumentBytes = 0
        for entry in entries where entry.lease.isOpen {
            guard let value = entry.model.matchingContext(context), let step = try? NativeServiceOpenStep(lease: entry.lease, context: value) else { continue }
            argumentBytes += step.argumentsJSON.utf8.count
            guard argumentBytes <= 1_048_576 else { return nil }
            if entry.model.before { before.append(step) } else { after.append(step) }
        }
        guard !before.isEmpty || !after.isEmpty else { return nil }
        let afterDelivery = IntentAfter(after)
        return begin(steps: before, file: false, accountRecordId: accountRecordId, argumentBytes: argumentBytes) { decision in
            completion(decision, decision == .continueOpening ? afterDelivery : IntentAfter([]))
        }
    }

    private func begin(steps: [NativeServiceOpenStep<Owner>], file: Bool, accountRecordId: Int64?, argumentBytes: Int,
                       completion: @escaping @Sendable (NativeServiceOpenDecision) -> Void) -> NativeServiceOpenBarrier<Owner>? {
        lock.lock()
        guard barriers.count < 64, argumentBytes <= 1_048_576,
              pendingArgumentBytes + argumentBytes <= 8_388_608 else { lock.unlock(); return nil }
        // A separate id box avoids capturing a mutable local in an escaping Swift
        // callback; start happens only after its identity is published below.
        let identity = UUID().uuidString
        let barrier = NativeServiceOpenBarrier(steps: steps, fileCallback: file) { [weak self] decision in
            self?.forgetBarrier(identity)
            completion(decision)
        }
        barriers[identity] = Opening(barrier: barrier, accountRecordId: accountRecordId, argumentBytes: argumentBytes)
        pendingArgumentBytes += argumentBytes
        lock.unlock()
        barrier.start()
        return barrier
    }

    private func forgetBarrier(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        if let opening = barriers.removeValue(forKey: id) { pendingArgumentBytes -= opening.argumentBytes }
    }

    private func notifyBarriers() {
        lock.lock()
        let barriers = Array(barriers.values)
        lock.unlock()
        for opening in barriers { opening.barrier.registrationsChanged() }
    }

    public func cancelOpenings(accountRecordId: Int64? = nil) {
        lock.lock()
        let barriers = barriers.values.filter { accountRecordId == nil || $0.accountRecordId == accountRecordId }
        lock.unlock()
        for opening in barriers { opening.barrier.cancel() }
    }

    deinit {
        for entry in files.values { entry.lease.close() }
        for entry in intents { entry.lease.close() }
        for opening in barriers.values { opening.barrier.cancel() }
    }
}
