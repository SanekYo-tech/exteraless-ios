import ExteralessCore
import Foundation
import SwiftSignalKit

public typealias ExteralessNotificationPresentationEffect = FilteringNotificationEffect
public typealias ExteralessNotificationRevision = FilteringNotificationRevision

private final class ExteralessNotificationRevisionSource: @unchecked Sendable {
    private weak var account: Account?
    init(account: Account) { self.account = account }

    func read() -> ExteralessNotificationRevision? {
        guard let account else { return nil }
        let filtering = ExteralessFilteringRuntime.shared.revision
        guard let hidden = ExteralessHiddenAccounts.shared.mainNotificationRevision(account: account),
              filtering == ExteralessFilteringRuntime.shared.revision else { return nil }
        return ExteralessNotificationRevision(filtering: filtering, hidden: hidden)
    }
}

public final class ExteralessNotificationAdmission: @unchecked Sendable {
    public let batchId: UUID
    public let accountIdentity: PrivacyExtrasAccountIdentity
    public let revision: ExteralessNotificationRevision
    // Internal for fixtures; public callers receive only account-bound methods.
    let state: FilteringNotificationAdmission

    init(state: FilteringNotificationAdmission) {
        self.state = state
        self.batchId = state.batchId
        self.accountIdentity = state.accountIdentity
        self.revision = state.revision
    }

    static func capture(account: Account, batchId: UUID) -> ExteralessNotificationAdmission? {
        let source = ExteralessNotificationRevisionSource(account: account)
        guard let revision = source.read() else { return nil }
        return ExteralessNotificationAdmission(state: FilteringNotificationAdmission(batchId: batchId,
            accountIdentity: exteralessPrivacyExtrasIdentity(account), accountObject: ObjectIdentifier(account),
            revision: revision, currentRevision: { source.read() }))
    }

    public func isCurrent(account: Account) -> Bool {
        state.isCurrent(accountIdentity: exteralessPrivacyExtrasIdentity(account), accountObject: ObjectIdentifier(account))
    }

    @discardableResult
    public func performIfCurrent(account: Account, effect: ExteralessNotificationPresentationEffect, _ action: () -> Void) -> Bool {
        state.performIfCurrent(accountIdentity: exteralessPrivacyExtrasIdentity(account), accountObject: ObjectIdentifier(account), effect: effect, action)
    }

    public func cancel() { state.cancel() }
}

public struct ExteralessAdmittedNotificationBatch {
    public let messages: ExteralessNotificationMessageBatch
    public let admission: ExteralessNotificationAdmission
}

private final class ExteralessNotificationStreamLifetime {
    private let lock = NSLock()
    private var disposed = false
    private var batchId: UUID?
    private var admission: ExteralessNotificationAdmission?

    func begin() -> UUID? {
        lock.lock()
        guard !disposed else { lock.unlock(); return nil }
        let old = admission
        admission = nil
        let id = UUID()
        batchId = id
        lock.unlock()
        old?.cancel()
        return id
    }

    func accept(_ delivery: ExteralessAdmittedNotificationBatch) -> Bool {
        lock.lock()
        let alreadyAccepted = admission
        let current = !disposed && batchId == delivery.admission.batchId && alreadyAccepted == nil
        if current { admission = delivery.admission }
        lock.unlock()
        if !current && alreadyAccepted !== delivery.admission { delivery.admission.cancel() }
        return current
    }

    func cancel() {
        lock.lock()
        disposed = true; batchId = nil
        let old = admission
        admission = nil
        lock.unlock()
        old?.cancel()
    }
}

/// The same stream/lifetime adapter is used by production Postbox preparation and
/// controlled native signal fixtures. Completion of one transaction does not
/// prematurely revoke its delivered token; outer disposal/supersession does.
func exteralessAdmittedNotificationStream(
    source: Signal<ExteralessNotificationMessageBatch, NoError>,
    prepare: @escaping (ExteralessNotificationMessageBatch, UUID) -> Signal<ExteralessAdmittedNotificationBatch?, NoError>
) -> Signal<ExteralessAdmittedNotificationBatch, NoError> {
    return Signal { subscriber in
        let lifetime = ExteralessNotificationStreamLifetime()
        let disposable = (source |> mapToSignal { batch -> Signal<ExteralessAdmittedNotificationBatch?, NoError> in
            guard let id = lifetime.begin() else { return .complete() }
            return prepare(batch, id)
        }).start(next: { delivery in
            guard let delivery else { return }
            if lifetime.accept(delivery) { subscriber.putNext(delivery) }
        }, completed: {
            lifetime.cancel()
            subscriber.putCompletion()
        })
        return ActionDisposable {
            lifetime.cancel()
            disposable.dispose()
        }
    }
}
