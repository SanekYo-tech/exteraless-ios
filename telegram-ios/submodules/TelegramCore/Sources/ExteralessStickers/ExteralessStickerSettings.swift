import ExteralessCore
import Foundation
import SwiftSignalKit

/// Invalidations carry no captured value. The snapshot read and its publication
/// share one serial queue, outside every ClientSettings/observer lock.
public func exteralessStickerPolicy(settings: ClientSettings = .shared) -> Signal<StickerPolicy, NoError> {
    return _internal_exteralessStickerPolicy(settings: settings)
}

/// `didRead` lets native fixtures pause a real snapshot between read/publication.
/// Production never supplies it. A queue is otherwise created per subscription.
func _internal_exteralessStickerPolicy(settings: ClientSettings, queue suppliedQueue: Queue? = nil, didRead: ((StickerPolicy) -> Void)? = nil) -> Signal<StickerPolicy, NoError> {
    return Signal { subscriber in
        let delivery = StickerPolicyDelivery(settings: settings, queue: suppliedQueue ?? Queue(name: "Exteraless.StickerPolicy"), subscriber: subscriber, didRead: didRead)
        let observation = settings.observe { keys in
            if keys.isEmpty || !keys.isDisjoint(with: StickerFeatures.keys) { delivery.invalidate() }
        }
        // Register before queuing the initial read. A racing invalidation joins
        // it; the queued work always reads the then-current coherent snapshot.
        delivery.invalidate()
        return ActionDisposable {
            delivery.dispose()
            observation.cancel()
        }
    }
    |> distinctUntilChanged
}

/// The store's Sendable invalidation captures this delivery object, not an
/// unprotected Subscriber/closure. Mutable admission flags are atomic; the read
/// hook and subscriber are used only on the subscription's serial queue.
private final class StickerPolicyDelivery: @unchecked Sendable {
    private let settings: ClientSettings
    private let queue: Queue
    private let subscriber: Subscriber<StickerPolicy, NoError>
    private let didRead: ((StickerPolicy) -> Void)?
    private let disposed = Atomic(value: false)
    private let pending = Atomic(value: false)

    init(settings: ClientSettings, queue: Queue, subscriber: Subscriber<StickerPolicy, NoError>, didRead: ((StickerPolicy) -> Void)?) {
        self.settings = settings
        self.queue = queue
        self.subscriber = subscriber
        self.didRead = didRead
    }

    func invalidate() {
        guard !self.disposed.with({ $0 }), !self.pending.swap(true) else { return }
        // Queue.async executes inline on its own queue. Always enqueue to prevent
        // subscriber-triggered settings writes from recursively publishing.
        self.queue.justDispatch {
            _ = self.pending.swap(false)
            guard !self.disposed.with({ $0 }) else { return }
            let value = StickerPolicy(settings: self.settings)
            self.didRead?(value)
            guard !self.disposed.with({ $0 }) else { return }
            self.subscriber.putNext(value)
        }
    }

    func dispose() { _ = self.disposed.swap(true) }
}
