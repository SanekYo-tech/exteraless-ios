import Foundation
import SwiftSignalKit
import TelegramCore

/// Injected in offline fixtures. Production supplies the fresh, single-transaction Engine
/// projection. Admission and the caller's account/scope predicate are checked after delivery.
@MainActor
final class ExteralessFeedFreshActions {
    private let fetch: (Set<EngineMessage.Id>) -> Signal<[EngineMessage.Id: ExteralessFeedMessageProjection], NoError>
    private let disposable = MetaDisposable()
    private var generation: UInt64 = 0
    private var invalidated = false

    init(fetch: @escaping (Set<EngineMessage.Id>) -> Signal<[EngineMessage.Id: ExteralessFeedMessageProjection], NoError>) { self.fetch = fetch }
    deinit { self.disposable.dispose() }

    func perform(ids: Set<EngineMessage.Id>, current: @escaping () -> Bool, allowed: @escaping ([ExteralessFeedMessageProjection]) -> Bool, rejected: @escaping () -> Void, action: @escaping ([ExteralessFeedMessageProjection]) -> Void) {
        guard !self.invalidated, !ids.isEmpty, ids.count <= 500, current() else { return }
        self.cancel()
        let generation = self.generation
        self.disposable.set((self.fetch(ids) |> take(1)
        |> timeout(10, queue: .mainQueue(), alternate: .single([:]))
        |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self, !self.invalidated, self.generation == generation, current() else { return }
            let values = ids.sorted().compactMap { result[$0] }
            guard values.count == ids.count, Set(values.map { $0.message.id }) == ids, allowed(values) else { rejected(); return }
            action(values)
        }))
    }

    func cancel() { self.generation &+= 1; self.disposable.set(nil) }
    func invalidate() { self.invalidated = true; self.cancel() }
}
