import AccountContext
import Display
import Foundation
import SwiftSignalKit
import TelegramCore

/// A lower-module entry point shared by chat, chat-list and peer-info menus.
/// ContextUI already depends on AccountContext; AccountContext does not depend
/// on ContextUI. The application installs the native plugin implementation.
public enum ExteralessPluginMenuEntry {
    public typealias Factory = @MainActor (AccountContext, String, EnginePeer?, EngineMessage?, ViewController) -> [ContextMenuItem]
    public static let didChange = Notification.Name("ExteralessNativePluginMenuItemsDidChange")
    @MainActor private static var factory: Factory?

    @MainActor public static func setFactory(_ factory: Factory?) {
        self.factory = factory
    }

    @MainActor public static func appending(to items: [ContextMenuItem], context: AccountContext,
        placement: String, peer: EnginePeer? = nil, message: EngineMessage? = nil,
        source: ViewController) -> [ContextMenuItem] {
        let extra = self.factory?(context, placement, peer, message, source) ?? []
        return extra.isEmpty ? items : items + (items.isEmpty ? [] : [.separator]) + extra
    }

    /// Registration changes rebuild the actual displayed menu. Copy the Items
    /// value so tips/reactions survive and repeated updates never duplicate rows.
    public static func updating(items: Signal<ContextController.Items, NoError>,
        context: AccountContext, placement: String, peer: EnginePeer? = nil,
        message: EngineMessage? = nil, source: ViewController) -> Signal<ContextController.Items, NoError> {
        let changes = Signal<Void, NoError> { subscriber in
            let observer = NotificationCenter.default.addObserver(forName: self.didChange, object: nil, queue: .main) { _ in
                subscriber.putNext(())
            }
            subscriber.putNext(())
            return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
        }
        return combineLatest(items, changes)
        |> deliverOnMainQueue
        |> map { original, _ in
            return MainActor.assumeIsolated {
                var result = original
                switch original.content {
                case let .list(rows):
                    result.content = .list(self.appending(to: rows, context: context, placement: placement, peer: peer, message: message, source: source))
                case let .twoLists(first, second):
                    result.content = .twoLists(first, self.appending(to: second, context: context, placement: placement, peer: peer, message: message, source: source))
                case .custom:
                    break
                }
                return result
            }
        }
    }
}
