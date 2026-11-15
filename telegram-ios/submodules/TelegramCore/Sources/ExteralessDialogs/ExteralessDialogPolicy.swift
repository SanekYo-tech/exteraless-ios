import ExteralessCore
import Foundation
import SwiftSignalKit

public func exteralessDialogPolicy() -> DialogPolicy { .current }

/// Serialized invalidations, subscribed before the first snapshot. Re-reading on
/// the serial queue prevents an older concurrent settings callback from winning.
public func exteralessDialogPolicyUpdates() -> Signal<DialogPolicy, NoError> {
    return Signal { subscriber in
        let queue = Queue()
        let observation = ClientSettings.shared.observe { keys in
            if keys.isEmpty || !keys.isDisjoint(with: DialogFeatures.keys) {
                queue.async { subscriber.putNext(DialogPolicy.current) }
            }
        }
        queue.async { subscriber.putNext(DialogPolicy.current) }
        return ActionDisposable { observation.cancel() }
    }
    |> distinctUntilChanged
}

public func exteralessDialogStoriesEnabled() -> Bool { !DialogPolicy.current.disableStories }

/// A real provider is subscribed only while enabled. Disabling cancels its
/// current work and publishes the native empty *presentation*, never a mutation
/// of server story subscriptions or read state.
public func exteralessDialogStorySource<T>(_ disabled: @escaping () -> T, source: @escaping () -> Signal<T, NoError>) -> Signal<T, NoError> {
    return exteralessDialogPolicyUpdates()
    |> map { !$0.disableStories }
    |> distinctUntilChanged
    |> mapToSignal { enabled in enabled ? source() : .single(disabled()) }
}
