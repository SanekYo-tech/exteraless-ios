@preconcurrency import AccountContext
import Display
import ExteralessCore
import Foundation
@preconcurrency import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
@preconcurrency import TelegramUIPreferences

private final class ExteralessMonetActionToken: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.valid
    }

    func invalidate() {
        self.lock.lock()
        self.valid = false
        self.lock.unlock()
    }
}

enum ExteralessMonetThemeActionError: Error, LocalizedError {
    case retiredContext, changedTheme, storage

    var errorDescription: String? {
        switch self {
        case .retiredContext: return "The account context changed. Open Monet Themes again."
        case .changedTheme: return "The selected native theme changed. Choose Monet again to apply it."
        case .storage: return "The native Monet theme could not be saved."
        }
    }
}

/// Attached/retired by ExteralessAppearanceIntegration with the ready account.
/// A pending writer can finish its resource write, but a retired account or
/// disposed controller cannot admit a later native preference transaction.
@MainActor
final class ExteralessMonetThemeActions {
    static let shared = ExteralessMonetThemeActions()

    private var context: AccountContext?
    private var contextToken: ExteralessMonetActionToken?
    private let queue = DispatchQueue(label: "Exteraless.Appearance.Monet", qos: .userInitiated)

    func attach(context: AccountContext) {
        if self.context === context { return }
        self.detach()
        self.context = context
        self.contextToken = ExteralessMonetActionToken()
    }

    func detach() {
        self.contextToken?.invalidate()
        self.contextToken = nil
        self.context = nil
    }

    func select(context: AccountContext, mode: AppearanceMonetMode, seedRGB: UInt32, slot: ExteralessMonetThemeSlot, expected: PresentationThemeReference) -> Signal<Result<Void, ExteralessMonetThemeActionError>, NoError> {
        guard self.context === context, let contextToken = self.contextToken else { return .single(.failure(.retiredContext)) }
        let style = AppearanceMonetStyle(setting: ClientSettings.shared.integer(AppearanceMonetPolicy.settingKey))
        let descriptor = AppearanceMonetDescriptor(mode: mode, seedRGB: seedRGB, renderedStyle: style)
        let queue = self.queue
        return Signal { subscriber in
            let operation = ExteralessMonetActionToken()
            let disposable = MetaDisposable()
            queue.async {
                guard contextToken.isValid, operation.isValid else { return }
                let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max))
                let resourceId = EngineMediaResource.Id(resource.id)
                let reference = PresentationThemeReference.local(PresentationLocalTheme(title: mode.title, resource: resource, resolvedWallpaper: nil))
                let theme = makeExteralessMonetPresentationTheme(descriptor: descriptor, index: reference.index)
                guard let encoded = encodePresentationTheme(theme), let data = encoded.data(using: .utf8), data.count <= 256 * 1024 else {
                    subscriber.putNext(.failure(.storage))
                    subscriber.putCompletion()
                    return
                }
                // Both are the normal native local-theme media stores. Complete
                // the bounded atomic writes before referencing the resource.
                context.engine.resources.storeResourceData(id: resourceId, data: data, synchronous: true)
                context.sharedContext.accountManager.resources.storeResourceData(id: resourceId, data: data, synchronous: true)
                guard let sharedPath = context.sharedContext.accountManager.resources.completedResourcePath(id: resourceId),
                      let accountPath = context.engine.resources.completedResourcePath(id: resourceId),
                      (try? Data(contentsOf: URL(fileURLWithPath: sharedPath))) == data,
                      (try? Data(contentsOf: URL(fileURLWithPath: accountPath))) == data else {
                    subscriber.putNext(.failure(.storage))
                    subscriber.putCompletion()
                    return
                }
                guard contextToken.isValid, operation.isValid else { return }
                disposable.set(context.sharedContext.accountManager.transaction { transaction -> Result<Void, ExteralessMonetThemeActionError> in
                    guard contextToken.isValid, operation.isValid else { return .failure(.retiredContext) }
                    let current = transaction.getSharedData(ApplicationSpecificSharedDataKeys.presentationThemeSettings)?.get(PresentationThemeSettings.self) ?? .defaultSettings
                    guard let updated = exteralessMonetReplacingTheme(in: current, slot: slot, expected: expected, replacement: reference) else { return .failure(.changedTheme) }
                    transaction.updateSharedData(ApplicationSpecificSharedDataKeys.presentationThemeSettings, { _ in EnginePreferencesEntry(updated) })
                    // The same cloud-theme tracking update as applyTheme(nil),
                    // admitted atomically with this local selection. Preparing an
                    // inactive night/day slot must not retire the active cloud theme.
                    let activeSlot: ExteralessMonetThemeSlot = context.sharedContext.currentPresentationData.with { $0.autoNightModeTriggered ? .night : .day }
                    if activeSlot == slot {
                        transaction.updateSharedData(SharedDataKeys.themeSettings, { _ in EnginePreferencesEntry(ThemeSettings(currentTheme: nil)) })
                    }
                    return .success(())
                }.start(next: { result in
                    guard contextToken.isValid, operation.isValid else { return }
                    subscriber.putNext(result)
                }, completed: {
                    subscriber.putCompletion()
                }))
            }
            return ActionDisposable {
                operation.invalidate()
                disposable.dispose()
            }
        }
    }
}

/// No account is captured at registration, matching the other appearance routes.
func exteralessMonetSettingsActions() -> [ExteralessSettingsAction] {
    return [ExteralessSettingsAction(id: "appearance.monetThemes", title: "Monet Themes · Light, Dark and AMOLED", section: "Appearance · Themes", action: { context, controller in
        controller.push(ExteralessMonetSettingsController(context: context))
    })]
}
