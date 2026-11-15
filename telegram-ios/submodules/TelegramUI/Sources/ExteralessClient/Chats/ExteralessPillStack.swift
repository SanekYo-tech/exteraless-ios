import AccountContext
import Display
import ExteralessCore
import Foundation
import SettingsUI
import SwiftSignalKit
import TelegramCore
import UIKit

/// Compatibility factory used by the feed and the AccountContext chat-list header seam.
final class ExteralessPillHeaderView: UIView, ExteralessPillHeader {
    private let context: AccountContext
    private let runtime: ExteralessPillRuntime
    private let open: (ViewController) -> Void
    private let button = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let icon = UIImageView()
    private let ring = CAShapeLayer()
    private var accentColor = UIColor.systemBlue
    private var successColor = UIColor.systemGreen
    private let presentation = MetaDisposable()
    private var observation: ClientSettingsObservation?
    private var registryObservation: PillCancellation?
    private var registryReloadScheduled = false
    private var subscription: ExteralessPillSubscription?
    private var descriptors: [PillDescriptor] = []
    private var ids: [Int] = []
    private var selected: Int?
    private var renderedDescriptor: PillDescriptor?
    private var model: PillModel?
    private var configurationError = false
    private var running = false
    private var savingSelection = false
    private var invalidated = false
    private var inputSignature: [String: ClientSettingValue] = [:]
    var heightUpdated: (() -> Void)?
    var view: UIView { self }
    var preferredHeight: CGFloat {
        (self.ids.isEmpty && !self.configurationError) || self.invalidated ? 0 : max(52, ceil(self.button.titleLabel?.font.lineHeight ?? 20) + 16)
    }

    init(context: AccountContext, open: @escaping (ViewController) -> Void) {
        self.context = context; self.open = open
        self.runtime = ExteralessPillRuntimes.get(context: context)
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 38, bottom: 0, trailing: 16)
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline)
            return attributes
        }
        self.button.configuration = configuration
        self.button.titleLabel?.adjustsFontForContentSizeCategory = true
        self.button.titleLabel?.lineBreakMode = .byTruncatingTail
        self.button.layer.cornerRadius = 18
        self.button.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
        self.button.accessibilityIdentifier = "exteraless.pill.current"
        self.addSubview(self.button)
        self.icon.contentMode = .scaleAspectFit; self.icon.isUserInteractionEnabled = false
        self.button.addSubview(self.icon)
        self.spinner.hidesWhenStopped = true; self.spinner.isUserInteractionEnabled = false
        self.button.addSubview(self.spinner)
        self.ring.fillColor = UIColor.clear.cgColor; self.ring.lineWidth = 2; self.ring.lineCap = .round
        self.button.layer.addSublayer(self.ring)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right, .up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(self.swiped(_:)))
            swipe.direction = direction; self.button.addGestureRecognizer(swipe)
        }
        self.button.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(self.longPressed(_:))))
        self.isAccessibilityElement = true; self.accessibilityTraits = [.button, .adjustable]
        self.accessibilityHint = "Swipe up or down to change status. Double-tap to open or refresh. Long-press for settings."
        self.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Status pill settings", target: self, selector: #selector(self.openSettings))]
        self.button.isAccessibilityElement = false
        self.reloadSettings()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        self.presentation.dispose(); self.observation?.cancel(); self.registryObservation?.cancel()
    }
    func setVisible(_ visible: Bool) { if visible { self.start() } else { self.stop() } }
    func start() {
        guard self.runtime.lease.isValid else { self.invalidate(); return }
        guard !self.running, !self.invalidated else { return }
        self.running = true
        self.observation = ClientSettings.shared.observe { [weak self] keys in
            guard exteralessPillSettingsAffectView(keys) else { return }
            DispatchQueue.main.async { [weak self] in guard let self, self.running else { return }; self.reloadSettings() }
        }
        self.registryObservation = PillPluginRegistry.shared.observe { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, !self.registryReloadScheduled else { return }
                self.registryReloadScheduled = true
                if let selected = self.selected, selected >= 10_000, self.renderedDescriptor?.pair == nil {
                    self.subscription?.cancel()
                    self.subscription = nil
                    self.renderedDescriptor = nil
                    self.button.layer.removeAllAnimations()
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.registryReloadScheduled = false
                    guard self.running else { return }
                    // A replacement owner may retain identical metadata/native ID.
                    // Coalesce registration batches, then renew its provider lease.
                    if let selected = self.selected, selected >= 10_000, self.renderedDescriptor?.pair == nil {
                        self.renderedDescriptor = nil
                    }
                    self.reloadSettings()
                }
            }
        }
        self.presentation.set((self.context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] presentation in
            guard let self else { return }
            self.accentColor = presentation.theme.list.itemAccentColor
            self.successColor = presentation.theme.list.freeTextSuccessColor
            self.updateColors()
        }))
        self.reloadSettings()
    }
    func stop() {
        self.running = false
        self.subscription?.cancel(); self.subscription = nil; self.renderedDescriptor = nil
        self.spinner.stopAnimating()
        self.presentation.set(nil); self.observation?.cancel(); self.observation = nil
        self.registryObservation?.cancel(); self.registryObservation = nil
    }
    func invalidate() {
        let previousHeight = self.preferredHeight
        self.invalidated = true; self.stop(); self.ids = []; self.selected = nil
        self.button.isHidden = true; self.isAccessibilityElement = false
        if previousHeight != self.preferredHeight { self.heightUpdated?() }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); self.reconcileSubscription() }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        self.heightUpdated?(); self.setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        self.button.frame = CGRect(x: 8, y: 4, width: max(0, self.bounds.width - 16), height: max(44, self.bounds.height - 8))
        let leading = self.effectiveUserInterfaceLayoutDirection == .rightToLeft ? max(0, self.button.bounds.width - 32) : 12
        let frame = CGRect(x: leading, y: floor((self.button.bounds.height - 20) / 2), width: 20, height: 20)
        self.icon.frame = frame; self.spinner.frame = frame; self.ring.frame = frame
        self.ring.path = UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 16, height: 16)).cgPath
    }
    private func reloadSettings() {
        guard self.runtime.lease.isValid else { self.invalidate(); return }
        let previousHeight = self.preferredHeight
        let signature = ClientSettings.shared.snapshot().filter { exteralessPillSettingsAffectView([$0.key]) }
        if signature != self.inputSignature { self.inputSignature = signature; self.renderedDescriptor = nil }
        do {
            let configuration = try self.runtime.configuration()
            self.descriptors = try self.runtime.descriptors()
            self.ids = configuration.layout.visible(available: Set(self.descriptors.map(\.id)))
            self.selected = configuration.layout.selection(available: Set(self.descriptors.map(\.id)))
            self.configurationError = false
        } catch {
            self.configurationError = true; self.descriptors = []; self.ids = []; self.selected = nil
        }
        self.button.isHidden = self.ids.isEmpty && !self.configurationError
        self.isAccessibilityElement = !self.button.isHidden
        if self.model == nil, let descriptor = self.descriptors.first(where: { $0.id == self.selected }) {
            self.render(.init(id: descriptor.id, title: descriptor.title, value: "Waiting for reading", source: "Selected provider", phase: .idle), animated: false)
        }
        self.reconcileSubscription()
        if previousHeight != self.preferredHeight { self.heightUpdated?() }
    }
    private func reconcileSubscription() {
        guard self.running, self.window != nil, !self.invalidated else {
            self.subscription?.cancel(); self.subscription = nil; self.renderedDescriptor = nil; return
        }
        let descriptor = self.descriptors.first { $0.id == self.selected }
        if let descriptor, descriptor == self.renderedDescriptor { return }
        self.subscription?.cancel(); self.subscription = nil; self.renderedDescriptor = descriptor
        if let descriptor {
            self.render(.init(id: descriptor.id, title: descriptor.title, value: "Loading…", source: "Selected provider", phase: .loading), animated: false)
            self.subscription = self.runtime.subscribe(descriptor) { [weak self] model in
                guard let self else { return }
                guard self.runtime.lease.isValid else { self.invalidate(); return }
                guard self.running, self.selected == model.id else { return }
                self.render(model, animated: true)
            }
        } else if self.configurationError {
            self.render(.init(id: 1, title: "Status pills", value: "Check rate configuration", detail: "Saved rate pairs are invalid. Open Status Pills to inspect them.", source: "Pill settings", phase: .failed), animated: false)
        } else {
            self.model = nil; self.button.setTitle(nil, for: .normal); self.spinner.stopAnimating()
        }
    }
    private func render(_ model: PillModel, animated: Bool) {
        let changed = self.model?.displayText != model.displayText
        self.model = model
        self.updateColors()
        self.accessibilityLabel = model.displayText
        var value = model.source + ". " + model.detail
        if let date = model.updatedAt { value += ". Updated " + DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short) }
        self.accessibilityValue = value
        self.icon.image = UIImage(systemName: self.renderedDescriptor?.symbol ?? "exclamationmark.circle")
        self.icon.isHidden = model.phase == .loading || model.progress != nil
        self.ring.isHidden = model.progress == nil || model.phase == .loading
        CATransaction.begin(); CATransaction.setDisableActions(true); self.ring.strokeEnd = CGFloat(model.progress ?? 0); CATransaction.commit()
        if model.phase == .loading { self.spinner.startAnimating() } else { self.spinner.stopAnimating() }
        let updateTitle = {
            var configuration = self.button.configuration ?? .plain()
            configuration.title = model.displayText
            self.button.configuration = configuration
        }
        if changed && animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: self.button, duration: 0.16, options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction], animations: updateTitle)
        } else { updateTitle() }
    }
    private func cycle(forward: Bool) {
        guard self.running, !self.savingSelection, let configuration = try? self.runtime.configuration(),
              let next = configuration.layout.next(current: self.selected, available: Set(self.descriptors.map(\.id)), forward: forward), next != self.selected else { return }
        self.savingSelection = true
        let lease = self.runtime.lease
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let saved: Bool
            do {
                try lease.withCurrent { try ClientSettings.shared.applyPublic(["chats.lastActivePillId": .integer(Int64(next))], expected: ClientSettings.shared.readSnapshot()) }
                saved = true
            } catch { saved = false }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.savingSelection = false
                guard self.running, lease.isValid else { return }
                if saved { self.reloadSettings() }
                else { UIAccessibility.post(notification: .announcement, argument: "Couldn't save the selected status pill.") }
            }
        }
    }
    private func updateColors() {
        let color = self.model?.isHighlighted == true ? self.successColor : self.accentColor
        self.button.tintColor = color; self.icon.tintColor = color; self.spinner.color = color; self.ring.strokeColor = color.cgColor
        var configuration = self.button.configuration ?? .plain()
        configuration.baseForegroundColor = color
        self.button.configuration = configuration
        self.button.backgroundColor = color.withAlphaComponent(0.12)
    }
    @objc private func pressed() {
        guard self.running, self.runtime.lease.isValid else { return }
        if self.configurationError { self.open(ExteralessPillSettingsController(context: self.context)); return }
        switch self.selected {
        case 5: self.open(self.context.sharedContext.makeStorageManagementController(context: self.context))
        case 6: self.open(proxySettingsController(context: self.context))
        case 7:
            self.runtime.toggleGhost { error in UIAccessibility.post(notification: .announcement, argument: error ?? (PrivacyPolicy.current.ghostModeActive ? "Ghost mode enabled" : "Ghost mode disabled")) }
        case 8, 9, 10, 11, 15: self.subscription?.refresh(force: true)
        case let id? where id >= 10_000 && self.renderedDescriptor?.pair == nil:
            PillPluginRegistry.shared.perform(.tap, request: .init(id: id, scope: self.runtime.lease.scope), lease: self.runtime.lease)
        case let id?: self.open(ExteralessPillDetailController(context: self.context, id: id))
        default: break
        }
    }
    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        let forward = gesture.direction == .up || (self.effectiveUserInterfaceLayoutDirection == .rightToLeft ? gesture.direction == .right : gesture.direction == .left)
        self.cycle(forward: forward)
    }
    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, self.running else { return }
        if let id = self.selected, id >= 10_000, self.renderedDescriptor?.pair == nil {
            let scope = self.runtime.lease.scope
            if !PluginPillBridgeActions.longPress(id: id, scope: scope, completion: { [weak self] handled in
                MainActor.assumeIsolated {
                    guard let self, !handled, self.running, self.selected == id, self.runtime.lease.isValid, self.runtime.lease.scope == scope else { return }
                    _ = self.openSettings()
                }
            }) {
                PillPluginRegistry.shared.perform(.longPress, request: .init(id: id, scope: scope), lease: self.runtime.lease)
            }
        } else { _ = self.openSettings() }
    }
    @objc private func openSettings() -> Bool {
        guard self.running, self.runtime.lease.isValid else { return false }
        self.open(ExteralessPillSettingsController(context: self.context)); return true
    }
    override func accessibilityIncrement() { self.cycle(forward: true) }
    override func accessibilityDecrement() { self.cycle(forward: false) }
    override func accessibilityActivate() -> Bool { self.pressed(); return self.running && (self.selected != nil || self.configurationError) }
}
