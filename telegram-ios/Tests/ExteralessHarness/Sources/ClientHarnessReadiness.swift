import ClientHarnessAccount
import Foundation
import SwiftSignalKit
import TelegramCore

/// Composer's shared NoError constructor predates AccountResult.retentionRecovery.
/// Observe the public, real pre-Account recovery owner before either open starts.
/// This fresh process has exactly one fixture factory and no other account producer.
/// A typed failure terminates this run and disposes that owner; only the native
/// factory's authorized result can succeed. No retry, archive reset or gate bypass.
func clientHarnessAccountWithReadiness() -> Signal<HarnessAccount, ExteralessRetentionReadinessFailure> {
    Signal { subscriber in
        let finished = Atomic(value: false)
        let account = MetaDisposable()
        let recovery = MetaDisposable()
        func fail(_ error: ExteralessRetentionReadinessFailure) {
            guard !finished.swap(true) else { return }
            subscriber.putError(error)
            account.dispose()
            recovery.dispose()
        }
        recovery.set(ExteralessAccountRecoveryCenter.shared.pending.start(next: { entries in
            for entry in entries where !entry.recovery.isDisposed {
                // Read current status, not an older queued snapshot after recovery.
                if case let .failed(error) = entry.recovery.currentStatus {
                    entry.recovery.dispose()
                    fail(error)
                    break
                }
            }
        }))
        if ExteralessAccountRetentionEnvironment.shared.current.configuration == nil {
            fail(.configurationUnavailable)
        } else if !finished.with({ $0 }) {
            account.set(HarnessAccount.make().start(next: { value in
                guard ExteralessAccountRetentionEnvironment.shared.current.configuration != nil else {
                    fail(.configurationUnavailable)
                    return
                }
                guard !finished.swap(true) else { return }
                subscriber.putNext(value)
                subscriber.putCompletion()
                recovery.dispose()
            }))
        }
        return ActionDisposable {
            _ = finished.swap(true)
            account.dispose()
            recovery.dispose()
        }
    }
}
