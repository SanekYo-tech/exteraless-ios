import AccountContext
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

/// Composition adapter for the AccountContext factory seam in the coordinator hunk.
/// The settings action remains owned by ExteralessChatIntegration; it is not registered twice.
@MainActor
public final class ExteralessFeedIntegration {
    public static let presentationChanged = Notification.Name("Exteraless.FeedPresentationChanged")

    private final class ScreenReference {
        weak var screen: ExteralessFeedController?
        init(_ screen: ExteralessFeedController) { self.screen = screen }
    }

    private var context: AccountContext?
    private var registry: ExteralessFeedChannelRegistry?
    private var reads: ExteralessFeedReadState?
    private var screens: [ScreenReference] = []
    private var badgeValue = Promise<(count: Int, isPartial: Bool)>((0, true))
    private var settings: ClientSettingsObservation?
    private let foreground = MetaDisposable()
    private var isForeground = false

    public init() {
        self.settings = ClientSettings.shared.observe { [weak self] keys in
            guard keys.isEmpty || !keys.isDisjoint(with: ExteralessFeedSettings.fields) || keys.contains("appearance.showFeedTab") || keys.contains("appearance.showFeedUnreadCounter") else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateMembership()
                NotificationCenter.default.post(name: Self.presentationChanged, object: nil)
            }
        }
    }

    public var isTabVisible: Bool { ClientSettings.shared.bool("appearance.showFeedTab", default: false) }

    public func update(context: AccountContext) {
        if self.context === context { return }
        self.clearContext()
        self.context = context
        // A subscriber to the retired account keeps the retired promise, never this new one.
        self.badgeValue = Promise((0, true))
        let registry = ExteralessFeedChannelRegistry(engine: context.engine)
        let reads = ExteralessFeedReadState(context: context)
        self.registry = registry
        self.reads = reads
        registry.updated = { [weak self, weak context] _ in
            MainActor.assumeIsolated {
                guard let self, let context, self.context === context else { return }
                self.updateMembership()
            }
        }
        reads.updated = { [weak self, weak context] in
            MainActor.assumeIsolated {
                guard let self, let context, self.context === context else { return }
                self.publishBadge()
            }
        }
        self.foreground.set((context.sharedContext.applicationBindings.applicationInForeground |> deliverOnMainQueue).start(next: { [weak self, weak context] value in
            MainActor.assumeIsolated {
                guard let self, let context, self.context === context else { return }
                self.isForeground = value
                if value { self.registry?.start(); self.updateMembership() }
                else { self.registry?.stop(); self.reads?.pause() }
            }
        }))
    }

    public func clearContext() {
        self.foreground.set(nil)
        self.registry?.stop()
        self.reads?.invalidate()
        self.registry = nil
        self.reads = nil
        self.isForeground = false
        for reference in self.screens { reference.screen?.invalidateAccount() }
        self.screens.removeAll()
        self.badgeValue.set(.single((0, false)))
        self.context = nil
    }

    /// Fail closed for an obsolete tab/menu callback instead of switching this integration
    /// back to its caller's retired account.
    public func makeController(context: AccountContext) -> ViewController? {
        guard self.context === context else { return nil }
        let screen = ExteralessFeedController(context: context)
        screen.tabBarItem = UITabBarItem(title: "Feed", image: UIImage(systemName: "rectangle.stack"), selectedImage: UIImage(systemName: "rectangle.stack.fill"))
        self.screens.removeAll { $0.screen == nil }
        self.screens.append(ScreenReference(screen))
        return screen
    }

    public func unreadBadge(context: AccountContext) -> Signal<(count: Int, isPartial: Bool), NoError> {
        guard self.context === context else { return .single((0, true)) }
        return self.badgeValue.get()
    }

    private func updateMembership() {
        guard let context, let registry, self.isForeground else { self.publishBadge(); return }
        self.reads?.update(channels: registry.state.channels, configuration: ExteralessFeedSettings.read(account: String(context.account.id.int64)))
        self.publishBadge()
    }

    private func publishBadge() {
        let enabled = ClientSettings.shared.bool("appearance.showFeedUnreadCounter", default: true)
        let count = enabled ? (self.reads?.tracker.unreadCount ?? 0) : 0
        self.badgeValue.set(.single((count, enabled && !(self.registry?.state.isComplete ?? false))))
    }
}

/// Call before the Appearance owner's root-tab filters. Retain `feed` in the root controller;
/// a preference change must not reconstruct the feed, lose its scroll anchor or redirect reads.
public func exteralessReplaceContactsWithFeed(_ controllers: [ViewController], contacts: ViewController, feed: ViewController?, enabled: Bool) -> [ViewController] {
    var result = controllers.filter { controller in feed == nil || controller !== feed }
    if enabled, let feed {
        let index = result.firstIndex(where: { $0 === contacts }) ?? 0
        result.removeAll { $0 === contacts }
        result.insert(feed, at: min(index, result.count))
    }
    return result
}
