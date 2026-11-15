import Foundation
import SwiftSignalKit

public enum ExteralessRetentionReadinessFailure: Error, Equatable, Sendable {
    case configurationUnavailable
    case archive(ExteralessRetentionError)
    case cancelled
    case timedOut
}

/// A revocable native startup result, scoped to this owner and this readiness attempt.
public struct ExteralessRetentionReadinessToken: Equatable, Sendable {
    public let configurationVersion: UInt64
    let owner: UUID
    let attempt: UUID
}

struct RetentionConfiguredWork {
    let configuration: ExteralessRetentionProcessConfiguration
    let version: UInt64
    let attempt: UUID
    let readinessRead: UInt64
    let work: RetentionOperationWork
}

/// Configuration, epoch invalidation and readiness are changed under one mutex. The
/// notification drain runs outside it; subscribers always read the current state, not a stale
/// success/failure payload left in a publisher by a reentrant or concurrent callback.
final class RetentionOwnerState {
    let operationScope = RetentionOperationScope()
    private let lock = NSLock()
    private let owner = UUID()
    private var version: UInt64
    private var configuration: ExteralessRetentionProcessConfiguration?
    private var identity: (role: ExteralessRetentionProcessRole, root: URL)?
    private var attempt = UUID()
    private var unavailableEpoch = UUID()
    private var closed = false
    private var outcome: Result<ExteralessRetentionReadinessToken, ExteralessRetentionReadinessFailure>?
    private var revision: UInt64 = 0
    private var readinessRead: UInt64 = 0
    private var draining = false
    private let changes = ValuePromise<UInt64>(0, ignoreRepeated: true)

    init(_ initial: ExteralessRetentionConfigurationState) {
        self.version = initial.version
        switch initial.availability {
        case let .available(value): self.configuration = value; self.identity = (value.role, value.durabilityRootURL)
        case .unavailable: self.outcome = .failure(.configurationUnavailable)
        }
    }

    var currentConfiguration: ExteralessRetentionProcessConfiguration? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.closed ? nil : self.configuration
    }

    @discardableResult
    func update(_ state: ExteralessRetentionConfigurationState) -> Bool {
        self.lock.lock()
        guard !self.closed, state.version > self.version else { self.lock.unlock(); return false }
        self.version = state.version
        self.configuration = nil
        if case let .available(value) = state.availability,
           self.identity == nil || (self.identity?.role == value.role && self.identity?.root == value.durabilityRootURL) {
            self.configuration = value
            if self.identity == nil { self.identity = (value.role, value.durabilityRootURL) }
        }
        self.operationScope.invalidate()
        self.attempt = UUID()
        if self.configuration == nil { self.unavailableEpoch = UUID() }
        self.outcome = self.configuration == nil ? .failure(.configurationUnavailable) : nil
        self.revision &+= 1
        self.lock.unlock()
        self.publish()
        return true
    }

    func captureWork(readiness: Bool = false) -> RetentionConfiguredWork? {
        self.lock.lock(); defer { self.lock.unlock() }
        guard !self.closed, let configuration = self.configuration else { return nil }
        if readiness { self.readinessRead &+= 1 }
        return RetentionConfiguredWork(configuration: configuration, version: self.version, attempt: self.attempt, readinessRead: self.readinessRead, work: self.operationScope.makeWork())
    }

    @discardableResult
    func beginAttempt() -> UUID? {
        self.lock.lock()
        guard !self.closed, self.configuration != nil else { self.lock.unlock(); return nil }
        self.operationScope.invalidate()
        self.attempt = UUID()
        let attempt = self.attempt
        self.outcome = nil
        self.revision &+= 1
        self.lock.unlock()
        self.publish()
        return attempt
    }

    func complete(_ admission: RetentionConfiguredWork, error: ExteralessRetentionError? = nil) {
        self.lock.lock()
        guard !self.closed, self.configuration != nil, admission.version == self.version,
              admission.attempt == self.attempt, admission.readinessRead == self.readinessRead, admission.work.isCurrent else { self.lock.unlock(); return }
        if let error { self.outcome = .failure(.archive(error)) }
        else { self.outcome = .success(ExteralessRetentionReadinessToken(configurationVersion: self.version, owner: self.owner, attempt: self.attempt)) }
        self.revision &+= 1
        self.lock.unlock()
        self.publish()
    }

    func isCurrent(_ token: ExteralessRetentionReadinessToken) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard !self.closed, self.configuration != nil, token.owner == self.owner,
              token.configurationVersion == self.version, token.attempt == self.attempt,
              case let .success(current)? = self.outcome else { return false }
        return current == token
    }

    func close() {
        self.lock.lock()
        if self.closed { self.lock.unlock(); return }
        self.closed = true
        self.configuration = nil
        self.operationScope.invalidate(close: true)
        self.attempt = UUID()
        self.outcome = .failure(.cancelled)
        self.revision &+= 1
        self.lock.unlock()
        self.publish()
    }

    private func currentOutcome(expectedAttempt: UUID?, unavailableEpoch: UUID) -> Result<ExteralessRetentionReadinessToken, ExteralessRetentionReadinessFailure>? {
        self.lock.lock(); defer { self.lock.unlock() }
        if self.closed { return .failure(.cancelled) }
        if self.configuration == nil || self.unavailableEpoch != unavailableEpoch { return .failure(.configurationUnavailable) }
        if let expectedAttempt, expectedAttempt != self.attempt { return .failure(.cancelled) }
        return self.outcome
    }

    func awaitReadiness(timeout: Double, expectedAttempt: UUID? = nil) -> Signal<Result<ExteralessRetentionReadinessToken, ExteralessRetentionReadinessFailure>, NoError> {
        let seconds = timeout.isFinite ? max(0.01, min(25, timeout)) : 5
        return Signal { subscriber in
            self.lock.lock()
            let unavailableEpoch = self.unavailableEpoch
            let initiallyUnavailable = self.configuration == nil && !self.closed
            self.lock.unlock()
            if initiallyUnavailable {
                subscriber.putNext(.failure(.configurationUnavailable)); subscriber.putCompletion(); return EmptyDisposable
            }
            let finished = Atomic<Bool>(value: false)
            let disposable = self.changes.get().start(next: { _ in
                guard let result = self.currentOutcome(expectedAttempt: expectedAttempt, unavailableEpoch: unavailableEpoch), !finished.swap(true) else { return }
                subscriber.putNext(result)
                subscriber.putCompletion()
            })
            return ActionDisposable { _ = finished.swap(true); disposable.dispose() }
        } |> SwiftSignalKit.timeout(seconds, queue: Queue.concurrentDefaultQueue(), alternate: .single(.failure(.timedOut)))
    }

    private func publish() {
        self.lock.lock()
        if self.draining { self.lock.unlock(); return }
        self.draining = true
        while true {
            let revision = self.revision
            self.lock.unlock()
            self.changes.set(revision)
            self.lock.lock()
            if self.revision == revision { self.draining = false; self.lock.unlock(); return }
        }
    }
}
