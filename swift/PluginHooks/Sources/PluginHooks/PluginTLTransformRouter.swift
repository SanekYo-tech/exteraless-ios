import Foundation

public final class PluginTLTransformRegistration: @unchecked Sendable {
    fileprivate let entry: TLTransformEntry
    fileprivate init(_ entry: TLTransformEntry) { self.entry = entry }

    public func updateSubscriptions(_ kinds: Set<PluginTLTransformKind>) {
        self.entry.update(kinds)
        TLTransformDispatcher.shared.invalidateDisabled()
    }

    public func detach() {
        self.entry.update([])
        TLTransformDispatcher.shared.detach(self.entry)
    }

    deinit { self.detach() }
}

/// Independent additive contract; the existing atomic PluginHookRouter gate stays
/// the first test in Network/State call sites. Retain the returned registration.
public enum PluginTLTransformRouter {
    public typealias Handler = @Sendable (PluginTLTransformPayload, @escaping @Sendable (PluginTLTransformResult) -> Void) -> PluginHookCancellation?
    public typealias Diagnostic = @Sendable (_ code: String, _ name: String, _ accountRecordId: Int64) -> Void

    public static func attach(handler: @escaping Handler, subscriptions: Set<PluginTLTransformKind> = [],
                              diagnostic: @escaping Diagnostic = { code, name, _ in NSLog("PluginTL %@: %@", code, name) }) -> PluginTLTransformRegistration {
        return TLTransformDispatcher.shared.attach(handler, subscriptions: subscriptions, diagnostic: diagnostic)
    }

    public static func hasSubscribers(_ kind: PluginTLTransformKind) -> Bool {
        return TLTransformDispatcher.shared.snapshot(kind) != nil
    }

    /// FIFO per account and phase (update/container share one lane). Handler work
    /// is off the lane queue; a stuck handler cannot delay a deadline. Invalid
    /// replacements, timeout and detach explicitly fall back to the original.
    @discardableResult
    public static func intercept(_ payload: PluginTLTransformPayload, timeout: TimeInterval = 5,
                                 completion: @escaping @Sendable (PluginTLTransformResult) -> Void) -> PluginHookCancellation? {
        guard let entry = TLTransformDispatcher.shared.snapshot(payload.kind) else {
            completion(.keepOriginal)
            return nil
        }
        return TLTransformDispatcher.shared.enqueue(payload, entry: entry, timeout: timeout, completion: completion)
    }

    public static func report(_ code: String, payload: PluginTLTransformPayload) {
        TLTransformDispatcher.shared.snapshot(payload.kind)?.diagnostic(code, payload.name, payload.accountRecordId)
    }

    public static func report(_ code: String, kind: PluginTLTransformKind, name: String, accountRecordId: Int64) {
        TLTransformDispatcher.shared.snapshot(kind)?.diagnostic(code, name, accountRecordId)
    }
}

fileprivate final class TLTransformEntry: @unchecked Sendable {
    let handler: PluginTLTransformRouter.Handler
    let diagnostic: PluginTLTransformRouter.Diagnostic
    private let lock = NSLock()
    private var kinds: Set<PluginTLTransformKind>

    init(handler: @escaping PluginTLTransformRouter.Handler, kinds: Set<PluginTLTransformKind>, diagnostic: @escaping PluginTLTransformRouter.Diagnostic) {
        self.handler = handler
        self.kinds = kinds
        self.diagnostic = diagnostic
    }

    func allows(_ kind: PluginTLTransformKind) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.kinds.contains(kind)
    }

    func update(_ kinds: Set<PluginTLTransformKind>) {
        self.lock.lock(); self.kinds = kinds; self.lock.unlock()
    }
}

private final class TLTransformWork: @unchecked Sendable {
    let id = UUID()
    let payload: PluginTLTransformPayload
    let entry: TLTransformEntry
    let bytes: Int
    let completion: @Sendable (PluginTLTransformResult) -> Void
    let lock = NSLock()
    private var closed = false
    private var replyClaimed = false
    private var hostCancellation: PluginHookCancellation?
    // Dispatcher-queue only:
    var started = false
    var ready: PluginTLTransformResult?
    var timer: DispatchSourceTimer?

    init(payload: PluginTLTransformPayload, entry: TLTransformEntry, completion: @escaping @Sendable (PluginTLTransformResult) -> Void) {
        self.payload = payload
        self.entry = entry
        self.bytes = payload.valueJSON.utf8.count + payload.metadataJSON.utf8.count
        self.completion = completion
    }

    var isOpen: Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        return !self.closed
    }

    func claimReply() -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard !self.closed, !self.replyClaimed else { return false }
        self.replyClaimed = true
        return true
    }

    func install(_ cancellation: PluginHookCancellation?) {
        self.lock.lock()
        let closed = self.closed
        if !closed { self.hostCancellation = cancellation }
        self.lock.unlock()
        if closed { TLTransformDispatcher.cancelHost(cancellation) }
    }

    @discardableResult
    func close() -> Bool {
        self.lock.lock()
        guard !self.closed else { self.lock.unlock(); return false }
        self.closed = true
        let cancellation = self.hostCancellation
        self.hostCancellation = nil
        self.lock.unlock()
        TLTransformDispatcher.cancelHost(cancellation)
        return true
    }
}

private final class TLTransformDispatcher: @unchecked Sendable {
    static let shared = TLTransformDispatcher()
    private struct Lane: Hashable {
        let account: Int64
        let family: String
        init(_ payload: PluginTLTransformPayload) {
            self.account = payload.accountRecordId
            self.family = payload.kind == .update || payload.kind == .updates ? "state" : payload.kind.rawValue
        }
    }

    private let lock = NSLock()
    private var current: TLTransformEntry?
    private var count = 0
    private var bytes = 0
    private let queue = DispatchQueue(label: "PluginTLTransform.fifo", qos: .userInitiated)
    private let handlers = DispatchQueue(label: "PluginTLTransform.handlers", qos: .userInitiated, attributes: .concurrent)
    private static let cancellationQueue = DispatchQueue(label: "PluginTLTransform.cancel", qos: .utility, attributes: .concurrent)
    private var lanes: [Lane: [TLTransformWork]] = [:]

    static func cancelHost(_ cancellation: PluginHookCancellation?) {
        guard let cancellation else { return }
        cancellationQueue.async { cancellation.cancel() }
    }

    func attach(_ handler: @escaping PluginTLTransformRouter.Handler, subscriptions: Set<PluginTLTransformKind>, diagnostic: @escaping PluginTLTransformRouter.Diagnostic) -> PluginTLTransformRegistration {
        let entry = TLTransformEntry(handler: handler, kinds: subscriptions, diagnostic: diagnostic)
        self.lock.lock()
        let previous = self.current
        self.current = entry
        self.lock.unlock()
        previous?.update([])
        self.invalidateDisabled()
        return PluginTLTransformRegistration(entry)
    }

    func snapshot(_ kind: PluginTLTransformKind) -> TLTransformEntry? {
        self.lock.lock()
        let entry = self.current
        self.lock.unlock()
        return entry?.allows(kind) == true ? entry : nil
    }

    func detach(_ entry: TLTransformEntry) {
        self.lock.lock()
        if self.current === entry { self.current = nil }
        self.lock.unlock()
        self.invalidateDisabled()
    }

    func invalidateDisabled() {
        self.queue.async {
            for lane in Array(self.lanes.keys) {
                let values = self.lanes[lane] ?? []
                for value in values where !value.entry.allows(value.payload.kind) {
                    if value.ready == nil { value.ready = .keepOriginal }
                }
                self.pump(lane)
            }
        }
    }

    func enqueue(_ payload: PluginTLTransformPayload, entry: TLTransformEntry, timeout: TimeInterval,
                 completion: @escaping @Sendable (PluginTLTransformResult) -> Void) -> PluginHookCancellation? {
        let work = TLTransformWork(payload: payload, entry: entry, completion: completion)
        self.lock.lock()
        guard work.bytes <= 16 * 1024 * 1024, self.count < 256, work.bytes <= 32 * 1024 * 1024 - self.bytes else {
            self.lock.unlock()
            entry.diagnostic("TL_HOOK_QUEUE_FULL", payload.name, payload.accountRecordId)
            completion(.failure("TL_HOOK_QUEUE_FULL"))
            return nil
        }
        self.count += 1
        self.bytes += work.bytes
        self.lock.unlock()
        let deadline = DispatchTime.now() + (timeout.isFinite ? max(0.001, min(timeout, 5)) : 5)
        let lane = Lane(payload)
        self.queue.async {
            self.lanes[lane, default: []].append(work)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: deadline)
            timer.setEventHandler { [weak work, weak self] in
                guard let work, let self, work.isOpen, work.ready == nil else { return }
                work.entry.diagnostic("TL_HOOK_TIMEOUT", work.payload.name, work.payload.accountRecordId)
                work.ready = .keepOriginal
                self.pump(lane)
            }
            work.timer = timer
            timer.resume()
            self.pump(lane)
        }
        return PluginHookCancellation { [weak self, weak work] in
            guard let self, let work, work.close() else { return }
            self.queue.async { self.pump(lane) }
        }
    }

    private func pump(_ lane: Lane) {
        while let work = self.lanes[lane]?.first {
            if !work.isOpen {
                self.removeFirst(lane, work: work)
                continue
            }
            if !work.entry.allows(work.payload.kind), work.ready == nil { work.ready = .keepOriginal }
            if let ready = work.ready {
                let deliver = work.close()
                self.removeFirst(lane, work: work)
                if deliver { work.completion(ready) }
                continue
            }
            guard !work.started else { return }
            work.started = true
            self.handlers.async {
                guard work.isOpen, work.entry.allows(work.payload.kind) else { return }
                let cancellation = work.entry.handler(work.payload) { [weak self, weak work] result in
                    guard let self, let work, work.claimReply() else { return }
                    // The host can finish on main. Schema work always returns to
                    // the transform workers, never the host/UI/Core callback queue.
                    self.handlers.async {
                        guard work.isOpen else { return }
                        let validated: PluginTLTransformResult
                        do {
                            switch result {
                            case let .modify(value): validated = .modify(try work.payload.normalizedReplacement(value))
                            case let .modifyFinal(value): validated = .modifyFinal(try work.payload.normalizedReplacement(value))
                            case .cancel where !work.payload.canCancel:
                                work.entry.diagnostic("TL_HOOK_CANCEL_UNSUPPORTED", work.payload.name, work.payload.accountRecordId)
                                validated = .keepOriginal
                            default: validated = result
                            }
                        } catch {
                            work.entry.diagnostic("TL_HOOK_INVALID_REPLACEMENT", work.payload.name, work.payload.accountRecordId)
                            validated = .keepOriginal
                        }
                        self.queue.async {
                            guard work.isOpen, work.ready == nil else { return }
                            work.ready = validated
                            self.pump(lane)
                        }
                    }
                }
                work.install(cancellation)
            }
            return
        }
    }

    private func removeFirst(_ lane: Lane, work: TLTransformWork) {
        self.lanes[lane]?.removeFirst()
        if self.lanes[lane]?.isEmpty == true { self.lanes.removeValue(forKey: lane) }
        work.timer?.cancel()
        work.timer = nil
        self.lock.lock()
        self.count -= 1
        self.bytes -= work.bytes
        self.lock.unlock()
    }
}
