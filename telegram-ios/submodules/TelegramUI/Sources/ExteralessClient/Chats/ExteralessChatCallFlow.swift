import Foundation
import SwiftSignalKit
import TelegramCore

enum ExteralessChatCallAttempt {
    case started
    case alreadyInProgress(EnginePeer.Id?)
    case unavailable
}

/// The production call producer, with controlled reads/presentations in fixtures.
/// One scope spans the initial confirmation, both peer reads and replacement OK.
final class ExteralessChatCallFlow<Peer> {
    enum Prompt: Equatable { case initial, replace, external }
    typealias Peers = (target: Peer?, current: Peer?)
    private let targetId: EnginePeer.Id
    private let ask: Bool
    private let scope: ExteralessChatOperationScope
    private let load: (EnginePeer.Id?) -> Signal<Peers, NoError>
    private let request: (Bool) -> ExteralessChatCallAttempt
    private let present: (Prompt, Peers, @escaping () -> Void, @escaping () -> Void) -> Disposable?
    private let completion: () -> Void
    private let navigate: () -> Void
    private let reading = MetaDisposable()
    private var presentation: Disposable?
    private var promptId: UUID?
    private var started = false
    private var finished = false
    private var lifetime: ExteralessChatCallFlow?

    init(targetId: EnginePeer.Id, ask: Bool, validity: Signal<Bool, NoError>, load: @escaping (EnginePeer.Id?) -> Signal<Peers, NoError>, request: @escaping (Bool) -> ExteralessChatCallAttempt, present: @escaping (Prompt, Peers, @escaping () -> Void, @escaping () -> Void) -> Disposable?, completion: @escaping () -> Void, navigate: @escaping () -> Void) {
        self.targetId = targetId; self.ask = ask; self.scope = ExteralessChatOperationScope(validity: validity)
        self.load = load; self.request = request; self.present = present
        self.completion = completion; self.navigate = navigate
    }
    func start() {
        guard !started else { return }
        started = true
        lifetime = self
        scope.invalidated = { [weak self] in self?.cancel() }
        let _ = scope.ready.start(next: { [weak self] active in
            guard let self, active, !self.finished else { return }
            if self.ask { self.readPeers(current: nil, prompt: .initial) }
            else { self.attempt(replace: false) }
        })
    }
    func cancel() { finish(completed: false) }
    private func readPeers(current: EnginePeer.Id?, prompt: Prompt) {
        guard scope.isCurrent, !finished else { return }
        let read = MetaDisposable()
        reading.set(read)
        read.set((load(current) |> take(1) |> deliverOnMainQueue).start(next: { [weak self] peers in
            guard let self, self.scope.isCurrent, !self.finished else { return }
            guard peers.target != nil else { self.cancel(); return }
            self.show(prompt == .replace && peers.current == nil ? .external : prompt, peers: peers)
        }))
    }
    private func show(_ prompt: Prompt, peers: Peers) {
        guard scope.isCurrent, !finished else { return }
        let id = UUID()
        promptId = id
        let controller = present(prompt, peers, { [weak self] in
            guard let self, !self.finished, self.scope.isCurrent, self.promptId == id else { return }
            self.promptId = nil
            let old = self.presentation; self.presentation = nil; old?.dispose()
            if prompt == .external { self.cancel() }
            else { self.attempt(replace: prompt == .replace) }
        }, { [weak self] in
            guard let self, self.promptId == id else { return }
            self.cancel()
        })
        // A synchronous fixture callback can already have opened another prompt.
        if promptId == id, !finished { presentation = controller; if controller == nil { cancel() } }
        else { controller?.dispose() }
    }
    private func attempt(replace: Bool) {
        guard scope.isCurrent, !finished else { return }
        switch request(replace) {
        case .started: finish(completed: true)
        case let .alreadyInProgress(current):
            if current == targetId { finish(completed: true, navigate: true) }
            else if replace { cancel() }
            else { readPeers(current: current, prompt: .replace) }
        case .unavailable: cancel()
        }
    }
    private func finish(completed: Bool, navigate: Bool = false) {
        guard !finished else { return }
        finished = true
        promptId = nil
        reading.dispose()
        presentation?.dispose(); presentation = nil
        scope.cancel()
        if completed { completion(); if navigate { self.navigate() } }
        lifetime = nil
    }
}
