import CPluginHookShims
import Foundation

/// A thread-safe, idempotent cancellation action. Cancellation is explicit, not tied to deinit.
public final class PluginHookCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?

    public init(_ action: @escaping () -> Void) {
        self.action = action
    }

    public func cancel() {
        self.lock.lock()
        let action = self.action
        self.action = nil
        self.lock.unlock()
        action?()
    }
}

/// Injected by the UI host. Closures must be thread-safe and hand off work without blocking.
/// The router never imports the host, Telegram, SwiftSignalKit, UIKit or an interpreter.
public struct PluginHookHandlers: Sendable {
    public typealias SendMessage = @Sendable (PluginSendPayload, @escaping @Sendable (PluginSendResult) -> Void) -> PluginHookCancellation?
    public typealias Observe = @Sendable (PluginHookObservation) -> Void
    public typealias Diagnostic = @Sendable (PluginHookDiagnostic) -> Void

    public let sendMessage: SendMessage?
    public let observe: Observe?
    public let diagnostic: Diagnostic

    public init(sendMessage: SendMessage? = nil, observe: Observe? = nil, diagnostic: @escaping Diagnostic = { value in
        NSLog("PluginHooks [%@]: %@", value.code.rawValue, value.detail)
    }) {
        self.sendMessage = sendMessage
        self.observe = observe
        self.diagnostic = diagnostic
    }
}

/// Retain for the host lifetime. An old registration cannot disable a newer one.
public final class PluginHookRegistration: @unchecked Sendable {
    private let entry: HookRegistrationEntry

    fileprivate init(entry: HookRegistrationEntry) {
        self.entry = entry
    }

    /// Publish the kinds with live subscribers, after load/unload/enable/watchdog changes.
    public func updateSubscriptions(_ kinds: Set<PluginHookKind>) {
        HookRegistry.shared.update(self.entry, kinds: kinds)
    }

    /// Stops new callbacks; pending sends fail open. Already-running callbacks cannot be retracted.
    public func detach() {
        HookRegistry.shared.detach(self.entry)
    }

    deinit {
        self.detach()
    }
}

/// One process-wide adapter, with plugin fanout owned by the injected host.
public enum PluginHookRouter {
    private static let sendExecutionKey = "PluginHooks.native-send-execution"

    /// Capture synchronously inside SendMessage, before its Task hop. Unlike an
    /// isPending query this stays valid after a successful result, but is revoked
    /// synchronously before timeout/detach/cancellation publishes its fallback.
    public static func currentSendExecutionPredicate() -> @Sendable () -> Bool {
        let scope = Thread.current.threadDictionary[sendExecutionKey] as? PluginHookSendExecution
        return { scope?.isPermitted ?? false }
    }

    public static var ingressSnapshot: PluginHookIngressSnapshot { PluginHookIngressBudget.shared.snapshot }
    /// A C atomic load only: even the Swift registry/queues are lazy until attach or enabled work.
    public static func hasSubscribers(_ kind: PluginHookKind) -> Bool {
        return xthooks_subscriber_mask_load() & kind.rawValue != 0
    }

    public static func attach(_ handlers: PluginHookHandlers, subscriptions: Set<PluginHookKind> = [],
                              ingressLimits: PluginHookIngressLimits = PluginHookIngressLimits()) -> PluginHookRegistration {
        PluginHookIngressBudget.shared.configure(ingressLimits)
        return HookRegistry.shared.attach(handlers, kinds: subscriptions)
    }

    /// Fire-and-forget. The factory (including TL serialization) runs on a private serial queue.
    /// Shared count/byte credits follow factories and retained handoffs across
    /// registrations; overload drops newest observations, never Core work.
    public static func observe(_ kind: PluginHookKind, makeEvent: @escaping () -> PluginHookObservation) {
        guard hasSubscribers(kind), kind != .sendMessage,
              let entry = HookRegistry.shared.snapshot(kind),
              let credit = PluginHookIngressBudget.shared.reserve() else {
            return
        }
        let work = HookObservationWork(makeEvent)
        HookQueues.observations.async {
            defer { withExtendedLifetime(credit) {} }
            guard entry.allows(kind) else {
                return
            }
            guard let event = work.makeEvent().retaining(credit) else { return }
            guard event.kind == kind else {
                entry.report(PluginHookDiagnostic(code: .observationKindMismatch, detail: "Observation factory returned the wrong kind"))
                return
            }
            guard entry.allows(kind) else {
                return
            }
            entry.handlers.observe?(event)
        }
    }

    /// One result at most. No subscriber => synchronous keepOriginal, without an operation object.
    /// Enabled handlers run asynchronously. Timeout (maximum 5 s) / detach => keepOriginal;
    /// cancel() suppresses delivery and cancels host work. Late/duplicate replies are ignored.
    @discardableResult
    public static func interceptSend(_ payload: PluginSendPayload, timeout: TimeInterval = 5.0, completion: @escaping (PluginSendResult) -> Void) -> PluginHookCancellation? {
        guard hasSubscribers(.sendMessage), let entry = HookRegistry.shared.snapshot(.sendMessage) else {
            completion(.keepOriginal)
            return nil
        }
        var bytes = 256 + (payload.text?.utf8.count ?? 0)
        for name in payload.attributeTypes {
            guard name.utf8.count + 32 <= 16 * 1024 * 1024 - bytes else { completion(.keepOriginal); return nil }
            bytes += name.utf8.count + 32
        }
        guard let credit = PluginHookIngressBudget.shared.reserve(bytes: bytes) else {
            completion(.keepOriginal)
            return nil
        }
        var stagedPayload = payload
        stagedPayload.ingressLifetime.credit = credit
        let retainedPayload = stagedPayload
        let operation = HookSendOperation(payload: retainedPayload, entry: entry, completion: completion)
        guard entry.add(operation) else {
            completion(.keepOriginal)
            return nil
        }
        operation.startTimeout(timeout.isFinite ? max(0.001, min(timeout, 5.0)) : 5.0)
        HookQueues.sends.async {
            guard entry.allows(.sendMessage), operation.isPending, let handler = entry.handlers.sendMessage else {
                operation.finish(.keepOriginal, cancelHost: true)
                return
            }
            Thread.current.threadDictionary[sendExecutionKey] = operation.execution
            defer { Thread.current.threadDictionary.removeObject(forKey: sendExecutionKey) }
            let cancellation = handler(retainedPayload, { [weak operation] result in
                operation?.resolve(result)
            })
            operation.installHostCancellation(cancellation)
        }
        return PluginHookCancellation {
            operation.cancel()
        }
    }

    public static func reportDiagnostic(_ diagnostic: PluginHookDiagnostic) {
        guard xthooks_subscriber_mask_load() != 0 else {
            return
        }
        HookRegistry.shared.currentEntry()?.report(diagnostic)
    }
}

private enum HookQueues {
    static let observations = DispatchQueue(label: "PluginHooks.observations", qos: .utility)
    static let sends = DispatchQueue(label: "PluginHooks.sends", qos: .userInitiated, attributes: .concurrent)
    // Independent of handlers/serialization: a stuck handler cannot hold up a send's deadline.
    static let completions = DispatchQueue(label: "PluginHooks.completions", qos: .userInitiated, attributes: .concurrent)
}

private final class HookObservationWork: @unchecked Sendable {
    // Core owns immutability of values captured by this factory. It is invoked once, off Core queues.
    let makeEvent: () -> PluginHookObservation

    init(_ makeEvent: @escaping () -> PluginHookObservation) {
        self.makeEvent = makeEvent
    }
}

private final class HookRegistry: @unchecked Sendable {
    static let shared = HookRegistry()
    private let lock = NSLock()
    private var current: HookRegistrationEntry?

    func attach(_ handlers: PluginHookHandlers, kinds: Set<PluginHookKind>) -> PluginHookRegistration {
        let entry = HookRegistrationEntry(handlers: handlers, kinds: kinds)
        self.lock.lock()
        let previous = self.current
        self.current = entry
        xthooks_subscriber_mask_store(entry.mask)
        self.lock.unlock()
        previous?.deactivate()
        return PluginHookRegistration(entry: entry)
    }

    func update(_ entry: HookRegistrationEntry, kinds: Set<PluginHookKind>) {
        self.lock.lock()
        guard self.current === entry else {
            self.lock.unlock()
            return
        }
        let pending = entry.update(kinds)
        xthooks_subscriber_mask_store(entry.mask)
        self.lock.unlock()
        for operation in pending {
            operation.handlerDetached()
        }
    }

    func detach(_ entry: HookRegistrationEntry) {
        self.lock.lock()
        if self.current === entry {
            xthooks_subscriber_mask_store(0)
            self.current = nil
        }
        self.lock.unlock()
        entry.deactivate()
    }

    func snapshot(_ kind: PluginHookKind) -> HookRegistrationEntry? {
        self.lock.lock()
        let entry = self.current
        self.lock.unlock()
        return entry?.allows(kind) == true ? entry : nil
    }

    func currentEntry() -> HookRegistrationEntry? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.current
    }
}

private final class HookRegistrationEntry: @unchecked Sendable {
    let handlers: PluginHookHandlers
    private let lock = NSLock()
    private var active = true
    private var subscriptions: UInt32
    private var pending: [ObjectIdentifier: HookSendOperation] = [:]

    init(handlers: PluginHookHandlers, kinds: Set<PluginHookKind>) {
        self.handlers = handlers
        self.subscriptions = Self.supportedMask(kinds, handlers: handlers)
    }

    private static func supportedMask(_ kinds: Set<PluginHookKind>, handlers: PluginHookHandlers) -> UInt32 {
        return kinds.reduce(UInt32(0), { mask, kind in
            let supported = kind == .sendMessage ? handlers.sendMessage != nil : handlers.observe != nil
            return supported ? mask | kind.rawValue : mask
        })
    }

    var mask: UInt32 {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.active ? self.subscriptions : 0
    }

    func allows(_ kind: PluginHookKind) -> Bool {
        return self.mask & kind.rawValue != 0
    }

    func update(_ kinds: Set<PluginHookKind>) -> [HookSendOperation] {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.subscriptions = Self.supportedMask(kinds, handlers: self.handlers)
        return self.subscriptions & PluginHookKind.sendMessage.rawValue == 0 ? Array(self.pending.values) : []
    }

    func deactivate() {
        self.lock.lock()
        self.active = false
        self.subscriptions = 0
        let pending = Array(self.pending.values)
        self.lock.unlock()
        for operation in pending {
            operation.handlerDetached()
        }
    }

    func add(_ operation: HookSendOperation) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.active, self.subscriptions & PluginHookKind.sendMessage.rawValue != 0 else {
            return false
        }
        self.pending[ObjectIdentifier(operation)] = operation
        return true
    }

    func remove(_ operation: HookSendOperation) {
        self.lock.lock()
        self.pending.removeValue(forKey: ObjectIdentifier(operation))
        self.lock.unlock()
    }

    func report(_ diagnostic: PluginHookDiagnostic) {
        DispatchQueue.global(qos: .utility).async {
            self.handlers.diagnostic(diagnostic)
        }
    }
}

private final class HookSendOperation: @unchecked Sendable {
    let execution = PluginHookSendExecution()
    private let lock = NSLock()
    private let payload: PluginSendPayload
    private weak var entry: HookRegistrationEntry?
    private var completion: ((PluginSendResult) -> Void)?
    private var finished = false
    private var cancelHost = false
    private var hostCancellation: PluginHookCancellation?
    private var timeout: DispatchWorkItem?

    init(payload: PluginSendPayload, entry: HookRegistrationEntry, completion: @escaping (PluginSendResult) -> Void) {
        self.payload = payload
        self.entry = entry
        self.completion = completion
    }

    var isPending: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return !self.finished
    }

    func startTimeout(_ interval: TimeInterval) {
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.finish(.keepOriginal, cancelHost: true, diagnostic: PluginHookDiagnostic(
                code: .sendTimedOut, detail: "Send hook exceeded its deadline; original message kept", accountRecordId: self.payload.accountRecordId
            ))
        }
        self.lock.lock()
        if self.finished {
            self.lock.unlock()
            return
        }
        self.timeout = timeout
        self.lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + interval, execute: timeout)
    }

    func installHostCancellation(_ cancellation: PluginHookCancellation?) {
        self.lock.lock()
        let cancel = self.cancelHost
        if !self.finished {
            self.hostCancellation = cancellation
        }
        self.lock.unlock()
        if cancel {
            Self.cancelOffCallerQueue(cancellation)
        }
    }

    func resolve(_ result: PluginSendResult) {
        guard self.isPending else { return }
        do {
            switch result {
            case let .modify(patch), let .modifyFinal(patch):
                try PluginSendResultCodec.validate(patch, original: self.payload)
            case .keepOriginal, .cancel:
                break
            }
            self.finish(result, cancelHost: false)
        } catch {
            self.finish(.keepOriginal, cancelHost: false, diagnostic: PluginHookDiagnostic(
                code: .unsupportedSendModification,
                detail: (error as? PluginSendCodecError)?.description ?? "Unsupported send modification",
                accountRecordId: self.payload.accountRecordId
            ))
        }
    }

    func handlerDetached() {
        self.finish(.keepOriginal, cancelHost: true, diagnostic: PluginHookDiagnostic(
            code: .sendHandlerDetached, detail: "Send handler detached; original message kept", accountRecordId: self.payload.accountRecordId
        ))
    }

    func finish(_ result: PluginSendResult, cancelHost: Bool, diagnostic: PluginHookDiagnostic? = nil) {
        self.lock.lock()
        guard !self.finished else {
            self.lock.unlock()
            return
        }
        self.finished = true
        self.cancelHost = cancelHost
        if cancelHost { execution.revoke() }
        let cancellation = self.hostCancellation
        self.hostCancellation = nil
        let timeout = self.timeout
        self.timeout = nil
        self.lock.unlock()
        timeout?.cancel()
        self.entry?.remove(self)
        if let diagnostic = diagnostic {
            self.entry?.report(diagnostic)
        }
        if cancelHost {
            Self.cancelOffCallerQueue(cancellation)
        }
        HookQueues.completions.async {
            self.lock.lock()
            let completion = self.completion
            self.completion = nil
            self.lock.unlock()
            completion?(result)
        }
    }

    func cancel() {
        self.lock.lock()
        guard self.completion != nil else {
            self.lock.unlock()
            return
        }
        self.finished = true
        self.completion = nil
        self.cancelHost = true
        execution.revoke()
        let cancellation = self.hostCancellation
        self.hostCancellation = nil
        let timeout = self.timeout
        self.timeout = nil
        self.lock.unlock()
        timeout?.cancel()
        self.entry?.remove(self)
        Self.cancelOffCallerQueue(cancellation)
    }

    private static func cancelOffCallerQueue(_ cancellation: PluginHookCancellation?) {
        guard let cancellation = cancellation else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            cancellation.cancel()
        }
    }
}
