import AccountContext
import AsyncDisplayKit
import Display
import Foundation
import SwiftSignalKit
import TelegramPresentationData
import UIKit

/// Telegram's Display presentation/layout host with real UIKit value controls.
/// All event closures only enqueue native owner work; none enters Python.
final class PluginUIContentController: ViewController {
    private let context: AccountContext
    private var model: PluginUIModel
    private var revision: Int64
    private var presentationData: PresentationData
    private var presentationDisposable: Disposable?
    private let root = PluginUIPassthroughView()
    private let dim = UIControl()
    private let panel = UIView()
    private let backdropBlur = UIVisualEffectView(effect: nil)
    private let panelBlur = UIVisualEffectView(effect: nil)
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var layout: ContainerViewLayout?
    private var timer: DispatchWorkItem?
    private var hasAnimatedIn = false
    private(set) var isClosing = false
    private var currentValues: [String: PluginUIJSON] = [:]
    private var pagePath: [String] = []
    private var selector: UIAlertController?
    private var inlineError: String?

    let event: (Int64, String, [String: PluginUIJSON], String?) -> Bool
    let canAct: (Int64) -> Bool
    let visibilityChanged: (Bool) -> Void
    let closed: () -> Void
    let timedOut: () -> Void
    let openLink: (Int64, URL) throws -> Void
    let failed: (PluginUIFailure) -> Void

    init(context: AccountContext, model: PluginUIModel, revision: Int64,
         event: @escaping (Int64, String, [String: PluginUIJSON], String?) -> Bool,
         canAct: @escaping (Int64) -> Bool, visibilityChanged: @escaping (Bool) -> Void,
          closed: @escaping () -> Void, timedOut: @escaping () -> Void,
          openLink: @escaping (Int64, URL) throws -> Void, failed: @escaping (PluginUIFailure) -> Void) {
        self.context = context
        self.model = model
        self.pagePath = model.pagePath
        self.revision = revision
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.event = event
        self.canAct = canAct
        self.visibilityChanged = visibilityChanged
        self.closed = closed
        self.timedOut = timedOut
        self.openLink = openLink
        self.failed = failed
        super.init(navigationBarPresentationData: model.kind.isPage ? NavigationBarPresentationData(presentationData: self.presentationData) : nil)
        self.statusBar.statusBarStyle = model.kind.isPage ? self.presentationData.theme.rootController.statusBarStyle.style : .Ignore
        self.attemptNavigation = { [weak self] _ in
            guard let self else { return true }
            if !self.pagePath.isEmpty && self.canAct(self.revision) {
                self.pagePath.removeLast()
                self.rebuild()
                return false
            }
            return self.model.cancelable
        }
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        self.timer?.cancel()
        self.presentationDisposable?.dispose()
        NotificationCenter.default.removeObserver(self)
    }

    override func loadDisplayNode() {
        let root = self.root
        self.displayNode = ASDisplayNode(viewBlock: { root }, didLoad: nil)
        root.content = self.panel
        root.passthrough = self.model.kind.isTransient
        root.accessibilityViewIsModal = !self.model.kind.isTransient
        root.addSubview(self.backdropBlur)
        self.backdropBlur.isUserInteractionEnabled = false
        root.addSubview(self.dim)
        root.addSubview(self.panel)
        self.dim.addTarget(self, action: #selector(self.dimPressed), for: .touchUpInside)
        self.dim.isAccessibilityElement = false
        self.panel.clipsToBounds = true
        self.panel.addSubview(self.panelBlur)
        self.panelBlur.isUserInteractionEnabled = false
        self.panel.addSubview(self.scrollView)
        self.scrollView.keyboardDismissMode = .interactive
        self.scrollView.alwaysBounceVertical = self.model.kind.isPage
        self.scrollView.contentInsetAdjustmentBehavior = .never
        self.stack.axis = .vertical
        self.stack.spacing = 8.0
        self.stack.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.addSubview(self.stack)
        NSLayoutConstraint.activate([
            self.stack.leadingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.leadingAnchor, constant: 12.0),
            self.stack.trailingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.trailingAnchor, constant: -12.0),
            self.stack.topAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.topAnchor, constant: 16.0),
            self.stack.bottomAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.bottomAnchor, constant: -16.0),
            self.stack.widthAnchor.constraint(equalTo: self.scrollView.frameLayoutGuide.widthAnchor, constant: -24.0)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(self.textSizeChanged), name: UIContentSizeCategory.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.textSizeChanged), name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        self.rebuild()
        self.presentationDisposable = (self.context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            let changed = data.theme !== self.presentationData.theme || data.strings !== self.presentationData.strings || data.listsFontSize != self.presentationData.listsFontSize
            self.presentationData = data
            if changed { self.rebuild() }
        })
        self.displayNodeDidLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !self.isClosing else { return }
        self.visibilityChanged(self.view.window != nil)
        if !self.hasAnimatedIn && !self.model.kind.isPage {
            self.hasAnimatedIn = true
            if !UIAccessibility.isReduceMotionEnabled {
                self.dim.alpha = 0
                self.panel.alpha = 0
                self.panel.transform = self.model.kind == .alert ? CGAffineTransform(scaleX: 0.97, y: 0.97) : CGAffineTransform(translationX: 0, y: 24)
                UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: {
                    self.dim.alpha = 1
                    self.panel.alpha = 1
                    self.panel.transform = .identity
                })
            }
            if !self.model.kind.isTransient { UIAccessibility.post(notification: .screenChanged, argument: self.panel) }
            else { UIAccessibility.post(notification: .announcement, argument: [self.model.title, self.model.text, self.model.subtitle].compactMap { $0 }.joined(separator: ". ")) }
        }
        self.armTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.visibilityChanged(false)
        self.timer?.cancel()
        self.timer = nil
        super.viewWillDisappear(animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A page underneath another native page remains leased but invisible.
        // A page actually removed from the stack, or an overlay removed by its
        // presentation context, retires its lease.
        let retainedByNavigation = (self.navigationController as? NavigationController)?.viewControllers.contains(where: { $0 === self }) == true
        if self.isClosing || (!retainedByNavigation && self.presentedViewController == nil) { self.closed() }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard self.model.cancelable, !self.isClosing else { return false }
        if !self.pagePath.isEmpty && self.canAct(self.revision) {
            self.pagePath.removeLast()
            self.rebuild()
            return true
        }
        return self.event(self.revision, "cancel", ["source": .string("back")], "back")
    }

    func apply(model: PluginUIModel, revision: Int64) {
        guard !self.isClosing else { return }
        self.captureInputValues()
        // A deliberate value update wins; a title/progress/theme refresh keeps
        // the user's draft and first responder intact.
        var previous: [String: PluginUIJSON] = [:]
        self.walk(self.model.widgets + self.model.rows) { previous[$0.key] = $0.value }
        self.walk(model.widgets + model.rows) { widget in
            if previous[widget.key] != widget.value { self.currentValues.removeValue(forKey: widget.key) }
        }
        let validKeys = Set(model.valueDefaults.keys)
        self.currentValues = self.currentValues.filter { validKeys.contains($0.key) }
        if model.pagePath != self.model.pagePath { self.pagePath = model.pagePath }
        self.model = model
        self.revision = revision
        if self.isNodeLoaded { self.rebuild(captureValues: false) }
        if self.viewIfLoaded?.window != nil { self.armTimer() }
    }

    func dismissOwned(animated: Bool) {
        guard !self.isClosing else { return }
        self.isClosing = true
        self.visibilityChanged(false)
        self.timer?.cancel()
        self.timer = nil
        self.selector?.dismiss(animated: false, completion: nil)
        self.selector = nil
        self.viewIfLoaded?.endEditing(true)
        if self.model.kind.isPage {
            if let navigation = self.navigationController as? NavigationController {
                navigation.filterController(self, animated: animated)
            } else {
                self.presentingViewController?.dismiss(animated: animated, completion: nil)
            }
            // Pending pushes can be removed before UIKit sends appearance events.
            if self.viewIfLoaded?.window == nil { self.closed() }
            return
        }
        let remove = { [weak self] in
            guard let self else { return }
            if let presenter = self.presentingViewController {
                presenter.dismiss(animated: false, completion: { [weak self] in self?.closed() })
            } else { self.closed() }
        }
        if animated && self.isNodeLoaded && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .curveEaseIn], animations: {
                self.dim.alpha = 0
                self.panel.alpha = 0
                if self.model.kind != .alert { self.panel.transform = CGAffineTransform(translationX: 0, y: 20) }
            }, completion: { _ in remove() })
        } else { remove() }
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.layout = layout
        self.layoutContent(layout, transition: transition)
    }

    private func layoutContent(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        guard self.isNodeLoaded else { return }
        let insets = layout.insets(options: [.input])
        let sides = layout.sideInsets(forBandFrom: 0.0, to: layout.size.height)
        let top = max(insets.top, self.model.kind.isPage ? self.navigationLayout(layout: layout).navigationFrame.maxY : 12.0)
        let availableHeight = max(0, layout.size.height - top - insets.bottom - (self.model.kind.isPage ? 0 : 24))
        let margin: CGFloat = self.model.kind.isPage ? 0 : 12.0
        let availableWidth = max(0, layout.size.width - sides.left - sides.right - 2 * margin)
        let width = min(availableWidth, self.model.kind == .alert ? 420.0 : (self.model.kind.isPage ? availableWidth : 560.0))
        guard width > 24 else { return }
        // The fitting pass must see the chosen width, not the previous frame's
        // width (zero on first appearance). Otherwise multiline labels measure
        // against conflicting required scroll-view constraints.
        self.scrollView.frame = CGRect(x: 0, y: 0, width: width, height: availableHeight)
        for case let widget as PluginUIWidgetContainer in self.stack.arrangedSubviews { widget.constrain(to: width - 24.0, height: availableHeight) }
        let measured = self.stack.systemLayoutSizeFitting(CGSize(width: max(0, width - 24), height: UIView.layoutFittingCompressedSize.height), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height + 32.0
        let height = self.model.kind.isPage ? availableHeight : min(availableHeight, max(56, measured))
        let originY: CGFloat
        if self.model.kind.isPage || (self.model.kind.isTransient && self.model.position == "top") { originY = top + (self.model.kind.isPage ? 0 : 12) }
        else if self.model.kind == .alert { originY = top + max(0, (availableHeight - height) * 0.5) }
        else { originY = max(top, layout.size.height - insets.bottom - height - 12) }
        transition.updateFrame(view: self.dim, frame: CGRect(origin: .zero, size: layout.size))
        transition.updateFrame(view: self.backdropBlur, frame: CGRect(origin: .zero, size: layout.size))
        transition.updateFrame(view: self.panel, frame: CGRect(x: sides.left + margin + (availableWidth - width) * 0.5, y: originY, width: width, height: height))
        transition.updateFrame(view: self.scrollView, frame: CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        transition.updateFrame(view: self.panelBlur, frame: CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        self.scrollView.layoutIfNeeded()
        self.revealInput()
    }

    private func page() -> (title: String?, rows: [PluginUIWidget]) {
        var rows = self.model.rows
        var title = self.model.title
        var validPath: [String] = []
        for id in self.pagePath {
            guard let item = PluginUIWidget.find(id, in: rows), let subpage = item.subpage else { break }
            validPath.append(id)
            rows = subpage
            title = item.text
        }
        self.pagePath = validPath
        return (title, rows)
    }

    private func rebuild(captureValues: Bool = true) {
        guard self.isNodeLoaded, !self.isClosing else { return }
        do { try self.rebuildContent(captureValues: captureValues) }
        catch let failure as PluginUIFailure {
            DispatchQueue.main.async { [weak self] in self?.failed(failure) }
        } catch {
            DispatchQueue.main.async { [weak self] in self?.failed(.unavailable("Native text or resource rendering failed")) }
        }
    }

    private func rebuildContent(captureValues: Bool) throws {
        if captureValues { self.captureInputValues() }
        let focused = self.widgetViews().first(where: { $0.inputIsFirstResponder }).map { ($0.model.id, $0.inputSelection) }
        for view in self.stack.arrangedSubviews { self.stack.removeArrangedSubview(view); view.removeFromSuperview() }
        let data = self.presentationData
        let theme = data.theme
        self.overrideUserInterfaceStyle = theme.overallDarkAppearance ? .dark : .light
        self.statusBar.statusBarStyle = self.model.kind.isPage ? theme.rootController.statusBarStyle.style : .Ignore
        self.root.backgroundColor = self.model.kind.isPage ? theme.list.blocksBackgroundColor : .clear
        self.dim.backgroundColor = self.model.dimEnabled && !self.model.kind.isPage ? UIColor.black.withAlphaComponent(0.4) : .clear
        self.dim.isHidden = self.model.kind.isTransient || self.model.kind.isPage
        let blurred = self.model.blurredBackground && !UIAccessibility.isReduceTransparencyEnabled
        let blurStyle: UIBlurEffect.Style = theme.overallDarkAppearance ? .systemMaterialDark : .systemMaterialLight
        self.panelBlur.isHidden = !blurred
        self.panelBlur.effect = blurred ? UIBlurEffect(style: blurStyle) : nil
        self.backdropBlur.isHidden = !blurred || !self.model.blurBehind
        self.backdropBlur.effect = blurred && self.model.blurBehind ? UIBlurEffect(style: blurStyle) : nil
        self.panel.backgroundColor = blurred ? .clear : (self.model.kind.isPage ? theme.list.blocksBackgroundColor : theme.actionSheet.opaqueItemBackgroundColor)
        self.panel.layer.cornerRadius = self.model.kind.isPage ? 0 : 16
        self.scrollView.indicatorStyle = theme.overallDarkAppearance ? .white : .black
        let revision = self.revision
        let page = self.page()
        self.title = page.title
        if self.model.kind.isPage {
            self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: data), transition: .immediate)
            self.navigationItem.rightBarButtonItem = self.model.cancelable ? UIBarButtonItem(title: data.strings.Common_Close, style: .plain, target: self, action: #selector(self.closePressed)) : nil
            self.navigationItem.leftBarButtonItem = self.pagePath.isEmpty ? nil : UIBarButtonItem(title: data.strings.Common_Back, style: .plain, target: self, action: #selector(self.subpageBackPressed))
        } else if let title = self.model.title, !title.isEmpty { self.addLabel(title, semibold: true) }
        if self.model.kind.isTransient {
            do {
                let icon = try pluginUIIcon(self.model.icon, style: self.model.style)
                let image = UIImageView(image: icon)
                image.contentMode = .scaleAspectFit
                image.tintColor = self.model.style == "error" ? theme.list.itemDestructiveColor : theme.list.itemAccentColor
                image.heightAnchor.constraint(equalToConstant: 28).isActive = true
                image.isAccessibilityElement = false
                self.stack.addArrangedSubview(image)
            }
        } else if let iconName = self.model.icon {
            let icon = try pluginUIIcon(iconName)
            let image = UIImageView(image: icon)
            image.contentMode = .scaleAspectFit
            image.tintColor = theme.list.itemAccentColor
            image.heightAnchor.constraint(equalToConstant: 44).isActive = true
            self.stack.addArrangedSubview(image)
        }
        if !self.model.text.isEmpty {
            if self.model.messageClickable {
                let text = try PluginUILinkTextView(text: self.model.text, data: data, centered: self.model.kind == .alert, activate: { [weak self] url in
                    guard let self else { return }
                    do { try self.openLink(revision, url) }
                    catch let failure as PluginUIFailure { self.inlineError = "\(failure.kind): \(failure.message)"; self.rebuild() }
                    catch { self.inlineError = pluginText("Error.Title", "Operation failed"); self.rebuild() }
                })
                self.stack.addArrangedSubview(text)
            } else { self.addLabel(self.model.text) }
        }
        if let subtitle = self.model.subtitle, !subtitle.isEmpty { self.addLabel(subtitle, small: true) }
        if self.model.kind == .alert && self.model.style != "message" {
            if self.model.style == "spinner" {
                let spinner = UIActivityIndicatorView(style: .large)
                spinner.color = theme.list.itemAccentColor
                spinner.startAnimating()
                spinner.accessibilityLabel = pluginText("Settings.Loading", "Loading…")
                self.stack.addArrangedSubview(spinner)
            } else {
                let progress = UIProgressView(progressViewStyle: .default)
                progress.progressTintColor = theme.list.itemAccentColor
                progress.trackTintColor = theme.list.controlSecondaryColor
                progress.setProgress(Float(self.model.progress / 100), animated: false)
                progress.accessibilityValue = "\(Int(self.model.progress))%"
                self.stack.addArrangedSubview(progress)
                self.addLabel("\(Int(self.model.progress))%", small: true)
            }
        }
        for widget in self.model.widgets + (self.model.kind.isPage ? page.rows : []) {
            let view = try PluginUIWidgetView(model: widget, data: data, values: self.currentValues, change: { [weak self] widget, value in
                guard let self, self.event(revision, widget.callback ?? "change", ["key": .string(widget.key), "value": value, "rowId": .string(widget.id)], nil) else { return false }
                self.currentValues[widget.key] = value
                return true
            }, select: { [weak self] widget, source in self?.select(widget, source: source, revision: revision) }, activated: { [weak self] widget, long in
                guard let self else { return }
                let name = long ? (widget.longCallback ?? "action") : (widget.callback ?? "action")
                guard self.event(revision, name, ["key": .string(widget.key), "rowId": .string(widget.id), "longPress": .bool(long)], nil) else { return }
                if !long && widget.subpage != nil && self.canAct(revision) {
                    self.pagePath.append(widget.id)
                    self.rebuild(captureValues: false)
                    self.scrollView.setContentOffset(.zero, animated: false)
                }
            }, layoutChanged: { [weak self] in self?.revealInput() })
            self.stack.addArrangedSubview(PluginUIWidgetContainer(widget: view))
        }
        for (index, item) in self.model.items.enumerated() {
            let image: UIImage?
            if let icon = item.icon { image = try pluginUIIcon(icon) } else { image = nil }
            let control = PluginUIActionControl(text: item.text, detail: item.subtext, image: image, checked: item.checked || self.model.selectedIndex == index, destructive: item.destructive, accent: false, enabled: item.enabled, data: data)
            control.action = { [weak self] in
                guard let self else { return }
                let _ = self.event(revision, "item", ["which": .integer(Int64(index)), "key": .string(item.id)], item.dismiss ? "item" : nil)
            }
            self.stack.addArrangedSubview(control)
        }
        for button in self.model.buttons {
            let control = PluginUIActionControl(text: button.text, destructive: button.destructive, enabled: button.enabled, color: button.color, data: data)
            control.action = { [weak self] in
                guard let self else { return }
                self.view.endEditing(true)
                self.captureInputValues()
                let _ = self.event(revision, button.callback, ["which": .integer(Int64(button.which)), "values": .object(self.currentValues)], button.dismiss ? "button" : nil)
            }
            self.stack.addArrangedSubview(control)
        }
        if self.model.kind.isTransient, let text = self.model.buttonText ?? (self.model.style == "undo" ? pluginText("Undo", "Undo") : nil) {
            let control = PluginUIActionControl(text: text, data: data)
            control.action = { [weak self] in
                guard let self else { return }
                let _ = self.event(revision, self.model.style == "undo" ? "undo" : "action", [:], self.model.style == "undo" ? "undo" : "action")
            }
            self.stack.addArrangedSubview(control)
        } else if !self.model.kind.isPage && !self.model.kind.isTransient && self.model.cancelable && !self.model.buttons.contains(where: { $0.which == -2 }) {
            let cancel = PluginUIActionControl(text: data.strings.Common_Cancel, data: data)
            cancel.action = { [weak self] in
                guard let self else { return }
                let _ = self.event(revision, "cancel", ["source": .string("button")], "cancel")
            }
            self.stack.addArrangedSubview(cancel)
        }
        if let error = self.inlineError { self.addLabel(error, small: true) }
        if let layout = self.layout { self.layoutContent(layout, transition: .immediate) }
        if let (id, selection) = focused { self.widgetViews().first(where: { $0.model.id == id })?.focusInput(selection: selection) }
    }

    private func addLabel(_ text: String, small: Bool = false, semibold: Bool = false) {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.font = pluginUIFont(self.presentationData, style: small ? .footnote : .body, semibold: semibold)
        label.textColor = small ? self.presentationData.theme.list.itemSecondaryTextColor : self.presentationData.theme.list.itemPrimaryTextColor
        label.textAlignment = self.model.kind == .alert ? .center : .natural
        if semibold { label.accessibilityTraits = .header }
        self.stack.addArrangedSubview(label)
    }

    private func select(_ widget: PluginUIWidget, source: UIView, revision: Int64) {
        guard self.canAct(revision), self.selector == nil else { return }
        let selector = UIAlertController(title: widget.text, message: widget.subtext, preferredStyle: .actionSheet)
        selector.overrideUserInterfaceStyle = self.presentationData.theme.overallDarkAppearance ? .dark : .light
        selector.view.tintColor = self.presentationData.theme.list.itemAccentColor
        for (index, text) in widget.choices.enumerated() {
            selector.addAction(UIAlertAction(title: text, style: .default, handler: { [weak self] _ in
                guard let self else { return }
                self.selector = nil
                let value = PluginUIJSON.integer(Int64(index))
                if self.event(revision, widget.callback ?? "change", ["key": .string(widget.key), "rowId": .string(widget.id), "value": value], nil) && self.canAct(revision) {
                    self.currentValues[widget.key] = value
                    self.rebuild(captureValues: false)
                }
            }))
        }
        selector.addAction(UIAlertAction(title: self.presentationData.strings.Common_Cancel, style: .cancel, handler: { [weak self] _ in self?.selector = nil }))
        selector.popoverPresentationController?.sourceView = source
        selector.popoverPresentationController?.sourceRect = source.bounds
        self.selector = selector
        self.present(selector, animated: true, completion: nil)
    }

    private func widgetViews() -> [PluginUIWidgetView] {
        var result: [PluginUIWidgetView] = []
        func visit(_ view: UIView) {
            if let widget = view as? PluginUIWidgetView { result.append(widget) }
            for child in view.subviews { visit(child) }
        }
        visit(self.stack)
        return result
    }

    private func captureInputValues() {
        for view in self.widgetViews() {
            switch view.model.kind {
            case .input, .toggle, .slider, .selector: self.currentValues[view.model.key] = view.value
            default: break
            }
        }
    }

    private func walk(_ widgets: [PluginUIWidget], _ body: (PluginUIWidget) -> Void) {
        for widget in widgets {
            body(widget)
            self.walk(widget.children, body)
            if let page = widget.subpage { self.walk(page, body) }
        }
    }

    private func revealInput() {
        guard let input = self.widgetViews().first(where: { $0.inputIsFirstResponder }) else { return }
        self.scrollView.scrollRectToVisible(input.convert(input.bounds, to: self.scrollView).insetBy(dx: 0, dy: -12), animated: false)
    }

    private func armTimer() {
        self.timer?.cancel()
        self.timer = nil
        guard self.model.kind.isTransient, !self.isClosing else { return }
        let work = DispatchWorkItem { [weak self] in self?.timedOut() }
        self.timer = work
        let duration = UIAccessibility.isVoiceOverRunning ? max(8000, self.model.durationMs) : self.model.durationMs
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(duration), execute: work)
    }

    @objc private func dimPressed() {
        guard self.model.cancelable, self.model.cancelOnTouchOutside else { return }
        let _ = self.event(self.revision, "cancel", ["source": .string("outside")], "cancel")
    }
    @objc private func closePressed() { let _ = self.event(self.revision, "cancel", ["source": .string("close")], "cancel") }
    @objc private func subpageBackPressed() {
        guard self.canAct(self.revision), !self.pagePath.isEmpty else { return }
        self.pagePath.removeLast()
        self.rebuild()
    }
    @objc private func textSizeChanged() { self.rebuild() }
}
