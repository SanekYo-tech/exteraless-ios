import AccountContext
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore

final class ExteralessInlineCurrencyController {
    private struct Cached {
        let value: String?
        let expires: TimeInterval
    }
    private let disposable = MetaDisposable()
    private var state = ChatCurrencyRequestState()
    private var accountKey: Int64?
    private var cache: [String: Cached] = [:]
    private var order: [String] = []
    private let updated: () -> Void

    init(updated: @escaping () -> Void) { self.updated = updated }
    deinit { self.disposable.dispose() }

    func cancelPending() {
        self.state.cancel()
        self.disposable.set(nil)
    }

    func suggestion(text: String, caret: Int, context: AccountContext) -> ChatMathExpression.Suggestion? {
        if self.accountKey != context.account.id.int64 {
            self.cancelPending()
            self.cache.removeAll()
            self.order.removeAll()
            self.accountKey = context.account.id.int64
        }
        guard ClientSettings.shared.bool("chats.inlineMathCurrency", default: true),
              let query = ChatCurrencyQuery.query(in: text, caret: caret) else { self.cancelPending(); return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = self.cache[query], cached.expires > now {
            if self.state.query != nil { self.cancelPending() }
            guard let value = cached.value else { return nil }
            let source = text as NSString
            let previous = caret >= 2 ? source.character(at: caret - 2) : 0
            let prefix = previous == 32 || previous == 9 || previous == 160 ? " " : ""
            return ChatMathExpression.Suggestion(insertionOffset: caret, insertionText: prefix + value, value: value)
        }
        guard let generation = self.state.begin(query: query) else { return nil }
        let accountKey = context.account.id.int64
        let result: Signal<String?, NoError> = context.engine.peers.resolvePeerByName(name: "calcmulabot", referrer: nil)
        |> filter { if case .result = $0 { return true }; return false }
        |> take(1)
        |> mapToSignal { resolved -> Signal<String?, NoError> in
            guard case let .result(peer) = resolved, let peer, case let .user(user) = peer,
                  user.botInfo != nil, peer.addressName?.lowercased() == "calcmulabot" else { return .single(nil) }
            return context.engine.messages.requestChatContextResults(botId: peer.id, peerId: context.account.peerId, query: query, offset: "")
            |> map { ChatCurrencyQuery.result(title: $0?.results.results.first?.title) }
            |> `catch` { _ -> Signal<String?, NoError> in .single(nil) }
        }
        self.disposable.set((result
        |> timeout(10, queue: .mainQueue(), alternate: .single(nil))
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self, self.accountKey == accountKey, self.state.complete(query: query, generation: generation) else { return }
            self.order.removeAll { $0 == query }
            self.order.append(query)
            self.cache[query] = Cached(value: value, expires: ProcessInfo.processInfo.systemUptime + (value == nil ? 30 : 300))
            while self.order.count > 64 { self.cache.removeValue(forKey: self.order.removeFirst()) }
            if ClientSettings.shared.bool("chats.inlineMathResult", default: true) && ClientSettings.shared.bool("chats.inlineMathCurrency", default: true) { self.updated() }
        }))
        return nil
    }
}
