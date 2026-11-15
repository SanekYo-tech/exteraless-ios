import AccountContext
import Foundation
import PluginHost
import SwiftSignalKit
import TelegramCore

/// Concrete callsite adapter for the coordinator's OpenChatMessage/OpenUrl hunks.
/// It does not install swizzles. Composition enables only the sites it actually
/// patched and retains the provider; registrations fail when those sites are absent.
@MainActor public final class NativeServiceOpenHooks {
    public static let shared = NativeServiceOpenHooks()
    private weak var provider: PluginNativeServicesBridgeExtension?
    private struct Preparation {
        let accountRecordId: Int64
        let disposable: MetaDisposable
    }
    private var preparing: [UUID: Preparation] = [:]

    public init() {}

    public func install(provider: PluginNativeServicesBridgeExtension) {
        if self.provider !== provider {
            for value in preparing.values { value.disposable.dispose() }
            preparing.removeAll()
            self.provider?.interceptions.cancelOpenings()
        }
        self.provider = provider
    }

    /// true means opening was deferred. The caller must not run original a second
    /// time. False means no matching active handler/site (run original normally).
    @discardableResult
    public func interceptURL(context: AccountContext, url: URL, fromIntent: Bool = false,
                             original: @escaping @MainActor () -> Void) -> Bool {
        guard let provider, provider.interceptions.supports(fromIntent ? .applicationURL : .externalURL),
              let account = provider.accountIndex(recordId: context.account.id.int64),
              let event = try? NativeServiceIntentContext(url: url, account: account, fromIntent: fromIntent) else { return false }
        let continuation = NativeServiceMainOpen(context: context, provider: provider, original: original)
        let barrier = provider.interceptions.interceptIntent(event, accountRecordId: context.account.id.int64) { decision, after in
            DispatchQueue.main.async {
                guard decision == .continueOpening, continuation.resume() else { return }
                after.completeOriginal()
            }
        }
        return barrier != nil
    }

    /// The document hook calls this after its native SVG confirmation and before
    /// constructing BrowserScreen/QuickLook. Resource lookup is cache-only and
    /// asynchronous, with at most 64 preparations and a one-second fallback.
    @discardableResult
    public func interceptFile(context: AccountContext, file: TelegramMediaFile, messageId: EngineMessage.Id?,
                              place: String, exportAllowed: Bool, original: @escaping @MainActor () -> Void) -> Bool {
        guard let provider, provider.interceptions.supports(.chatDocument), exportAllowed,
              let name = file.fileName, provider.interceptions.canInterceptFile(fileName: name),
              let account = provider.accountIndex(recordId: context.account.id.int64), preparing.count < 64 else { return false }
        let id = UUID()
        let disposable = MetaDisposable()
        preparing[id] = Preparation(accountRecordId: context.account.id.int64, disposable: disposable)
        let continuation = NativeServiceMainOpen(context: context, provider: provider, original: original)
        let message = messageId.map(Self.messageValue)
        disposable.set((nativeServiceLocalFile(account: context.account, file: file)
        |> timeout(1.0, queue: Queue.mainQueue(), alternate: .single(nil))
        |> deliverOnMainQueue).start(next: { [weak self, weak provider] path in
            guard let self, let preparation = self.preparing.removeValue(forKey: id) else { return }
            preparation.disposable.dispose()
            guard let provider, let path,
                  let event = try? NativeServiceFileOpenContext(fileName: name, path: path, mime: file.mimeType,
                    account: account, place: place, message: message) else {
                _ = continuation.resume()
                return
            }
            let barrier = provider.interceptions.interceptFile(event, accountRecordId: preparation.accountRecordId) { decision in
                DispatchQueue.main.async {
                    if decision == .continueOpening { _ = continuation.resume() }
                }
            }
            if barrier == nil { _ = continuation.resume() }
        }, completed: { [weak self] in
            guard let self, let preparation = self.preparing.removeValue(forKey: id) else { return }
            preparation.disposable.dispose()
            _ = continuation.resume()
        }))
        return true
    }

    public func cancelPreparations(provider: PluginNativeServicesBridgeExtension, accountRecordId: Int64? = nil) {
        guard self.provider === provider else { return }
        for (id, preparation) in Array(preparing) where accountRecordId == nil || preparation.accountRecordId == accountRecordId {
            preparing.removeValue(forKey: id)
            preparation.disposable.dispose()
        }
    }

    private static func messageValue(_ id: EngineMessage.Id) -> PluginJSONValue {
        let type: String
        switch id.peerId.namespace {
        case Namespaces.Peer.CloudUser: type = "user"
        case Namespaces.Peer.CloudGroup: type = "group"
        case Namespaces.Peer.CloudChannel: type = "channel"
        default: type = "unsupported"
        }
        return .object(["partial": .bool(true), "id": .integer(Int64(id.id)),
            "namespace": .integer(Int64(id.namespace)),
            "peer": .object(["type": .string(type), "id": .integer(id.peerId.id._internalGetInt64Value())])])
    }
}

/// Main-isolated native continuation with a single resume and pinned account.
/// Sendability allows a barrier completion to schedule it on main, not to run its
/// UIKit closure on a worker. A removed/replaced AccountContext cannot be reopened.
private final class NativeServiceMainOpen: @unchecked Sendable {
    private weak var context: AccountContext?
    private weak var provider: PluginNativeServicesBridgeExtension?
    private var original: (@MainActor () -> Void)?

    @MainActor init(context: AccountContext, provider: PluginNativeServicesBridgeExtension, original: @escaping @MainActor () -> Void) {
        self.context = context
        self.provider = provider
        self.original = original
    }

    @MainActor func resume() -> Bool {
        let original = self.original
        self.original = nil
        guard let original, let context, let provider,
              provider.currentAccount(recordId: context.account.id.int64) === context else { return false }
        original()
        return true
    }
}
