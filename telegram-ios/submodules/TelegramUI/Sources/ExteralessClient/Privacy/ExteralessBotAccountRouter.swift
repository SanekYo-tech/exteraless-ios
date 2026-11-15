import AccountContext
import Display
import ExteralessCore
import Foundation
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import UIKit

/// Main-thread identity routing. Each asynchronous decision owns the exact account
/// objects and preferences it inspected; a switch/logout/configuration change cancels it.
final class ExteralessBotAccountRouter {
    static let shared = ExteralessBotAccountRouter()
    typealias Choice = (context: AccountContext, peer: EnginePeer)
    private struct Pending {
        let disposable: MetaDisposable
        let completion: PrivacyCompletion<Choice?>
        var controller: ViewController? = nil
    }
    private var contexts: [AccountContext] = []
    private var currentAccountId: Int64?
    private var generation = 0
    private var pending: [UUID: Pending] = [:]
    private var navigationHandoffs = Set<ObjectIdentifier>()

    func update(context: AccountContext, accounts: [AccountContext]) {
        precondition(Thread.isMainThread)
        let changed = currentAccountId != context.account.id.int64 || accounts.count != contexts.count || zip(accounts, contexts).contains(where: { $0.account !== $1.account })
        contexts = accounts
        currentAccountId = context.account.id.int64
        if changed { invalidate() }
    }

    func clearContext() {
        precondition(Thread.isMainThread)
        contexts = []
        currentAccountId = nil
        invalidate()
    }

    func invalidate() {
        precondition(Thread.isMainThread)
        generation += 1
        navigationHandoffs.removeAll()
        ExteralessBotSendAuthorization.shared.clear()
        let pending = self.pending
        self.pending.removeAll()
        for value in pending.values { value.disposable.dispose(); value.controller?.dismiss(); value.completion.finish(nil) }
    }

    @discardableResult
    func resolve(context: AccountContext, bot: EnginePeer, explicit: Bool, presenter: ViewController, completion: @escaping (Choice?) -> Void) -> Disposable {
        precondition(Thread.isMainThread)
        let policy = PrivacyPolicy.current
        guard policy.botPrivacyEnabled || policy.botPrivacyAlwaysAsk, case let .user(user) = bot, user.botInfo != nil else {
            completion((context, bot))
            return EmptyDisposable
        }
        let accounts = contexts.filter {
            $0.account.testingEnvironment == context.account.testingEnvironment
                && !ExteralessHiddenAccounts.shared.isHidden(exteralessPrivacyExtrasIdentity($0.account))
        }
        guard accounts.contains(where: { $0.account === context.account }) else { completion(nil); return EmptyDisposable }
        let generation = self.generation
        let requestId = UUID()
        let disposable = MetaDisposable()
        pending[requestId] = Pending(disposable: disposable, completion: PrivacyCompletion(completion))
        let inspections = accounts.map { candidate in
            combineLatest(exteralessBotConversationEvidence(account: candidate.account, botId: bot.id, username: bot.addressName), candidate.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: candidate.account.peerId)))
        }
        disposable.set((combineLatest(inspections)
        |> take(1)
        |> timeout(15.0, queue: Queue.mainQueue(), alternate: .single(accounts.map { _ in (nil, nil) }))
        |> deliverOnMainQueue).start(next: { [weak self, weak presenter] values in
            guard let self, self.generation == generation, self.pending[requestId] != nil else { return }
            guard BotAccountPolicy.samePreferences(policy, PrivacyPolicy.current) else { self.finish(requestId, choice: nil); return }
            guard let presenter, presenter.viewIfLoaded?.window != nil else { self.finish(requestId, choice: nil); return }
            let established = zip(accounts, values).compactMap { account, value -> Int64? in value.0?.established == true ? account.account.id.int64 : nil }
            let configured = accounts.first(where: { $0.account.peerId.id._internalGetInt64Value() == policy.botPrivacyUserId })?.account.id.int64
            let decision = BotAccountPolicy.choose(useSelectedAccount: policy.botPrivacyEnabled, alwaysAsk: policy.botPrivacyAlwaysAsk, requested: context.account.id.int64, configured: configured, explicit: explicit, established: established, available: accounts.map { $0.account.id.int64 }, complete: !values.contains(where: { $0.0 == nil }))
            let choose: (Int64) -> Void = { [weak self] id in
                guard let self, self.generation == generation, BotAccountPolicy.samePreferences(policy, PrivacyPolicy.current), let index = accounts.firstIndex(where: { $0.account.id.int64 == id }), let evidence = values[index].0 else {
                    self?.finish(requestId, choice: nil)
                    return
                }
                self.finish(requestId, choice: (accounts[index], evidence.peer))
            }
            switch decision {
            case let .account(id): choose(id)
            case let .choose(ids):
                let presentation = context.sharedContext.currentPresentationData.with { $0 }
                var actions = ids.compactMap { id -> TextAlertAction? in
                    guard let index = accounts.firstIndex(where: { $0.account.id.int64 == id }) else { return nil }
                    let name = values[index].1?.displayTitle(strings: presentation.strings, displayOrder: presentation.nameDisplayOrder) ?? "Account \(index + 1)"
                    return TextAlertAction(type: .defaultAction, title: name, action: { choose(id) })
                }
                actions.append(TextAlertAction(type: .genericAction, title: presentation.strings.Common_Cancel, action: { [weak self] in self?.finish(requestId, choice: nil) }))
                let controller = textAlertController(sharedContext: context.sharedContext, title: "Bot account", text: "Choose the account for this bot.", actions: actions, actionLayout: .vertical, dismissOnOutsideTap: false)
                self.pending[requestId]?.controller = controller
                presenter.present(controller, in: .window(.root))
            case .unavailable, .unknown:
                self.finish(requestId, choice: nil)
                presenter.present(textAlertController(sharedContext: context.sharedContext, title: "Bot account", text: decision == .unavailable ? "The selected account is unavailable. Select a bot account in Exteraless privacy settings." : "Could not verify this bot's conversations in every account. Try again when the accounts are connected.", actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]), in: .window(.root))
            }
        }))
        // A sheet left on-screen still has a bounded decision lifetime.
        Queue.mainQueue().after(30.0, { [weak self] in self?.finish(requestId, choice: nil) })
        return ActionDisposable { [weak self] in
            Queue.mainQueue().async { self?.finish(requestId, choice: nil) }
        }
    }

    private func finish(_ id: UUID, choice: Choice?) {
        precondition(Thread.isMainThread)
        guard let pending = pending.removeValue(forKey: id) else { return }
        pending.disposable.dispose()
        pending.controller?.dismiss()
        pending.completion.finish(choice)
    }

    func guardSend(account: Account, peerId: EnginePeer.Id) -> Signal<Bool, NoError> {
        return Signal { [weak self] subscriber in
            let disposable = MetaDisposable()
            let lookup = MetaDisposable()
            let cancelled = Atomic(value: false)
            Queue.mainQueue().async {
                guard !cancelled.with({ $0 }) else { return }
                guard let self, let context = self.contexts.first(where: { $0.account === account }), let presenter = (context.sharedContext.mainWindow?.viewController as? NavigationController)?.topViewController as? ViewController else {
                    subscriber.putNext(false); subscriber.putCompletion(); return
                }
                lookup.set((context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)) |> deliverOnMainQueue).start(next: { [weak self, weak presenter] peer in
                    guard !cancelled.with({ $0 }) else { return }
                    guard let self, let presenter, let peer else { subscriber.putNext(false); subscriber.putCompletion(); return }
                    let expectedPolicy = PrivacyPolicy.current
                    disposable.set(self.resolve(context: context, bot: peer, explicit: true, presenter: presenter, completion: { choice in
                        let allowed = choice?.context.account === account && ExteralessBotSendAuthorization.shared.approve(account: account, peerId: peerId, expectedPolicy: expectedPolicy)
                        subscriber.putNext(allowed)
                        subscriber.putCompletion()
                    }))
                }))
            }
            return ActionDisposable {
                let _ = cancelled.swap(true)
                lookup.dispose()
                disposable.dispose()
            }
        }
    }

    func interceptNavigation(_ params: NavigateToChatControllerParams) -> Bool {
        precondition(Thread.isMainThread)
        if navigationHandoffs.remove(ObjectIdentifier(params)) != nil { return false }
        let policy = PrivacyPolicy.current
        guard policy.botPrivacyEnabled || policy.botPrivacyAlwaysAsk, params.attachBotStart == nil,
              case let .peer(peer) = params.chatLocation, case let .user(user) = peer, user.botInfo != nil,
              let presenter = params.navigationController.topViewController as? ViewController else { return false }
        let _ = resolve(context: params.context, bot: peer, explicit: params.botStart == nil && params.botAppStart == nil, presenter: presenter) { [weak self] choice in
            guard let self, let choice else { return }
            if choice.context.account === params.context.account {
                guard ExteralessBotSendAuthorization.shared.approve(account: choice.context.account, peerId: choice.peer.id, expectedPolicy: policy) else { return }
                self.navigationHandoffs.insert(ObjectIdentifier(params))
                navigateToChatControllerImpl(params)
                return
            }
            self.activate(choice: choice) { [weak self] context, navigation in
                guard let self else { return }
                let continueNavigation: (ChatControllerInitialBotAppStart?) -> Void = { start in
                    // Draft text/history holders are account-owned and are deliberately rebuilt.
                    let next = NavigateToChatControllerParams(navigationController: navigation, context: context, chatLocation: .peer(choice.peer), botStart: params.botStart, botAppStart: start, keepStack: .default, animated: params.animated, setupController: params.setupController, completion: params.completion, chatListCompletion: params.chatListCompletion, forceOpenChat: params.forceOpenChat)
                    guard ExteralessBotSendAuthorization.shared.approve(account: context.account, peerId: choice.peer.id, expectedPolicy: policy) else { return }
                    self.navigationHandoffs.insert(ObjectIdentifier(next))
                    navigateToChatControllerImpl(next)
                }
                if let start = params.botAppStart, let app = start.botApp {
                    let _ = (context.engine.messages.getBotApp(botId: choice.peer.id, shortName: app.shortName) |> deliverOnMainQueue).start(next: { app in
                        continueNavigation(ChatControllerInitialBotAppStart(botApp: app, payload: start.payload, justInstalled: false, mode: start.mode))
                    })
                } else { continueNavigation(params.botAppStart) }
            }
        }
        return true
    }

    func activate(choice: Choice, failed: @escaping () -> Void = {}, completion: @escaping (AccountContext, NavigationController) -> Void) {
        precondition(Thread.isMainThread)
        let shared = choice.context.sharedContext
        let policy = PrivacyPolicy.current
        if currentAccountId != choice.context.account.id.int64 { shared.switchToAccount(id: choice.context.account.id, fromSettingsController: nil, withChatListController: nil) }
        let _ = (shared.activeAccountContexts
        |> filter { $0.primary?.account === choice.context.account }
        |> take(1)
        |> map(Optional.init)
        |> timeout(5.0, queue: Queue.mainQueue(), alternate: .single(nil))
        |> deliverOnMainQueue).start(next: { state in
            guard let state, BotAccountPolicy.samePreferences(policy, PrivacyPolicy.current), let context = state.primary, let navigation = shared.mainWindow?.viewController as? NavigationController else { failed(); return }
            completion(context, navigation)
        })
    }
}
