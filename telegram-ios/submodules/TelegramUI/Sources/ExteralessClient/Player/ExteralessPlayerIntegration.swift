import AccountContext
import AsyncDisplayKit
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

/// Retained by the application composition root. The mini player observes only
/// the primary account; teardown releases its UI, tasks and native observers.
@MainActor
public final class ExteralessPlayerIntegration {
    private var context: AccountContext?
    private var session: ExteralessPlayerSession?
    private weak var root: TelegramRootController?
    private var overlay: ExteralessMiniPlayerController?
    private let navigationDisposable = MetaDisposable()
    private let overlayDisposable = MetaDisposable()
    private let foregroundDisposable = MetaDisposable()
    private var foreground = false
    private var settingsObservation: ClientSettingsObservation?
    private var refreshing = false

    public init() {
        ExteralessSettingsUI.registerActions([
            ExteralessSettingsAction(id: "appearance.playerLibrary", title: "My Profile Music", section: "Player", action: { context, parent in
                ExteralessPlayerActions.openMyMusic(context: context, parent: parent)
            }),
            ExteralessSettingsAction(id: "appearance.playerDecoderInfo", title: "Native Media Decoders", section: "Player", action: { _, parent in
                let alert = UIAlertController(title: "Native media decoding", message: PlayerDecoderPolicy.explanation, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                parent.present(alert, animated: true)
            })
        ])
        settingsObservation = ClientSettings.shared.observe { [weak self] keys in
            guard keys.contains(where: PlayerFeatures.owns) else { return }
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    public func update(context: AccountContext) {
        if self.context === context { refresh(); return }
        clearContext()
        self.context = context
        let session = ExteralessPlayerSession(context: context)
        self.session = session
        session.updated = { [weak self] in self?.refresh() }
        session.invalidated = { [weak self] in self?.clearContext() }
        foregroundDisposable.set((context.sharedContext.applicationBindings.applicationIsActive |> deliverOnMainQueue).start(next: { [weak self] active in
            self?.foreground = active
            self?.refresh()
        }))
        session.start()
        refresh()
    }

    public func clearContext() {
        let account = context?.account.id.int64
        context = nil
        session?.updated = nil
        session?.invalidated = nil
        session?.stop()
        session = nil
        navigationDisposable.set(nil)
        overlayDisposable.set(nil)
        foregroundDisposable.set(nil)
        foreground = false
        removeOverlay()
        root = nil
        if let account { ExteralessPlayerServices.clear(account: account) }
    }

    private func removeOverlay() {
        let overlay = self.overlay
        self.overlay = nil
        overlay?.stop()
        overlay?.dismiss()
        PlayerMiniPresentation.setMounted(account: nil)
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        guard let context, let session, session.accountIsValid, session.active,
              let root = context.sharedContext.mainWindow?.viewController as? TelegramRootController else {
            removeOverlay()
            return
        }
        if self.root !== root {
            removeOverlay()
            self.root = root
            navigationDisposable.set((root.viewControllersSignal |> deliverOnMainQueue).start(next: { [weak self] _ in self?.refresh() }))
            overlayDisposable.set((root.overlayControllersSignal |> deliverOnMainQueue).start(next: { [weak self] _ in self?.refresh() }))
        }
        guard session.style.modernMiniPlayer, session.type == .music, session.state != nil else { removeOverlay(); return }
        if let location = session.state?.playlistLocation as? PeerMessagesPlaylistLocation, case let .custom(_, _, _, _, hidePanel) = location, hidePanel { removeOverlay(); return }
        let overlay: ExteralessMiniPlayerController
        if let current = self.overlay { overlay = current }
        else {
            overlay = ExteralessMiniPlayerController(session: session, root: root)
            self.overlay = overlay
            root.presentOverlay(controller: overlay, blockInteraction: false)
            PlayerMiniPresentation.setMounted(account: context.account.id.int64)
        }
        let onMainTabs = root.topViewController === root.rootTabController
        let hasOtherOverlay = root.overlayControllers.contains { $0 !== overlay }
        overlay.update(visible: foreground && onMainTabs && !hasOtherOverlay)
    }

    deinit {
        settingsObservation?.cancel()
        navigationDisposable.dispose(); overlayDisposable.dispose(); foregroundDisposable.dispose()
    }
}

private final class ExteralessMiniPlayerController: ViewController {
    private let session: ExteralessPlayerSession
    private weak var root: TelegramRootController?
    private let mini: ExteralessMiniPlayerView
    private let occlusions: ExteralessPlayerOcclusionPublisher
    private var visible = false
    private var occlusionVisible = false
    private var retired = false
    private var validLayout: ContainerViewLayout?

    init(session: ExteralessPlayerSession, root: TelegramRootController) {
        self.session = session
        self.root = root
        let mini = ExteralessMiniPlayerView(frame: .zero)
        self.mini = mini
        self.occlusions = ExteralessPlayerOcclusionPublisher(accountId: session.context.account.id.int64, view: mini)
        super.init(navigationBarPresentationData: nil)
        statusBar.statusBarStyle = .Ignore
        self.mini.openAction = { [weak self] in self?.open() }
        self.mini.geometryChanged = { [weak self] in
            guard let self else { return }
            self.occlusions.update(visible: !self.retired && self.occlusionVisible && self.session.accountIsValid && self.session.active)
        }
        self.ready.set(.single(true))
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadDisplayNode() {
        self.displayNode = SparseNode()
        self.displayNode.view.addSubview(mini)
        self.displayNodeDidLoad()
    }

    func update(visible: Bool) {
        guard !retired else { return }
        self.visible = visible
        if let layout = validLayout { containerLayoutUpdated(layout, transition: .immediate) }
    }

    func stop() {
        guard !retired else { return }
        retired = true
        occlusionVisible = false
        visible = false
        mini.isHidden = true
        occlusions.retire()
        mini.stop()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        guard !retired else { return }
        super.containerLayoutUpdated(layout, transition: transition)
        validLayout = layout
        let keyboardVisible = (layout.inputHeight ?? 0) > 0
        occlusionVisible = visible && !keyboardVisible && session.accountIsValid && session.active
        mini.isHidden = !occlusionVisible
        mini.update(session: session)
        let sides = layout.sideInsets(forBandFrom: 0, to: layout.size.height)
        let width = min(540, max(0, layout.size.width - sides.left - sides.right - 24))
        let height = mini.preferredHeight
        let x = sides.left + (layout.size.width - sides.left - sides.right - width) / 2
        var y: CGFloat
        if session.style.miniTop {
            let bar = root?.rootTabController?.currentController?.navigationBar
            let barBottom = bar.map { $0.view.convert($0.bounds, to: self.view).maxY } ?? (max(layout.safeInsets.top, layout.statusBarHeight ?? 0) + 44)
            y = max(layout.safeInsets.top, barBottom) + 6
        } else {
            var bottom = layout.size.height - max(layout.intrinsicInsets.bottom, layout.safeInsets.bottom)
            if let tabs = root?.rootTabController, tabs.verticalTabBarFrame(for: layout) == nil,
               !ClientSettings.shared.bool("appearance.hideBottomNavigationBar"), let current = tabs.currentController,
               let frame = tabs.frameForControllerTab(controller: current) {
                bottom = min(bottom, tabs.view.convert(frame, to: self.view).minY - 8)
            }
            y = bottom - height - 8
        }
        y = max(layout.safeInsets.top, min(y, layout.size.height - height - layout.safeInsets.bottom))
        let animationDuration: Double
        switch transition { case .immediate: animationDuration = 0; case let .animated(duration, _): animationDuration = duration }
        occlusions.update(visible: occlusionVisible, animationDuration: animationDuration)
        transition.updateFrame(view: mini, frame: CGRect(x: x, y: y, width: width, height: height))
        occlusions.update(visible: occlusionVisible)
    }

    private func open() {
        guard visible, session.accountIsValid, let state = session.state, let type = session.type,
              let parent = root?.rootTabController?.currentController else { return }
        if let player = ExteralessPlayerActions.nativePlayer(context: session.context, state: state, type: type, parent: parent, forceClassic: !session.style.modernPlayer) {
            parent.push(player)
        } else { parent.push(ExteralessPlayerController(context: session.context)) }
    }
}
