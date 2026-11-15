import Display
import ExteralessCore
import Foundation
import UIKit
import UniformTypeIdentifiers

private final class ExteralessGallerySubtitleLabel: UILabel {
    var windowUpdated: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        windowUpdated?()
    }
}

/// Playback-independent adapter for the normal Telegram Gallery. The gallery
/// supplies MediaPlayerStatus-derived samples; it never creates a second player.
@MainActor public final class ExteralessGallerySubtitleAdapter: NSObject, UIDocumentPickerDelegate {
    private let identity: String
    private let store: ToolsSubtitleStore
    private let label = ExteralessGallerySubtitleLabel()
    private weak var presenter: UIViewController?
    private var picker: UIDocumentPickerViewController?
    private weak var errorAlert: UIAlertController?
    private var track: ToolsSubtitleTrack?
    private var sample: ToolsSubtitlePlaybackSample?
    private var timer: Foundation.Timer?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var visible = false
    private var closed = false
    private var applicationActive = UIApplication.shared.applicationState == .active
    private var layoutRect: CGRect = .zero
    private var labelHasRoom = false
    private var loadError: String?
    public private(set) var hasSubtitles = false

    public init(identity: String, container: UIView, store: ToolsSubtitleStore) {
        self.identity = identity
        self.store = store
        super.init()
        label.numberOfLines = 3
        label.lineBreakMode = .byTruncatingTail
        label.accessibilityIdentifier = "exteraless.gallery.subtitles"
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.textAlignment = .center
        label.backgroundColor = UIColor(white: 0, alpha: 0.75)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.isUserInteractionEnabled = false
        label.isHidden = true
        label.windowUpdated = { [weak self] in self?.updateTimer() }
        container.addSubview(label)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(contentSizeCategoryChanged), name: UIContentSizeCategory.didChangeNotification, object: nil)
    }

    deinit {
        operation?.cancel()
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func load() {
        let id = cancelOperation(), store = store, identity = identity
        operation = Task { @MainActor [weak self] in
            do {
                let track = try await store.load(identity: identity)
                guard let self, self.isCurrent(id) else { return }
                self.operation = nil
                self.track = track
                self.hasSubtitles = track != nil
                self.loadError = nil
                self.updateTimer()
            } catch {
                guard let self, self.isCurrent(id) else { return }
                self.operation = nil
                // Expose corrupt sidecars when the user opens the picker/menu;
                // never turn them into an empty successful import.
                self.loadError = pluginErrorText(error)
            }
        }
    }

    public func update(sample: ToolsSubtitlePlaybackSample?) {
        guard !closed else { return }
        self.sample = sample
        updateTimer()
    }

    public func setVisible(_ visible: Bool) {
        guard !closed else { return }
        if self.visible != visible {
            self.visible = visible
            if visible {
                load()
            } else {
                // Album swipes and PiP transfers revoke pending picker/import work.
                // A return reloads the same immutable media identity from the store.
                cancelOperation()
                dismissOwnedControllers()
                track = nil
                hasSubtitles = false
            }
        }
        updateTimer()
    }

    public func updateLayout(in bounds: CGRect, bottomInset: CGFloat, transition: ContainedViewLayoutTransition = .immediate) {
        guard !closed else { return }
        layoutRect = CGRect(x: bounds.minX + 16, y: bounds.minY, width: max(0, bounds.width - 32),
                            height: max(0, bounds.height - max(0, bottomInset) - 16))
        layoutLabel(transition: transition)
        render()
    }

    public func select(from presenter: UIViewController) {
        guard !closed, visible, label.window != nil, picker == nil,
              presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { return }
        self.presenter = presenter
        if let error = loadError { loadError = nil; showError(error); return }
        cancelOperation()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.modalPresentationStyle = .formSheet
        picker.delegate = self
        self.picker = picker
        presenter.present(picker, animated: true)
    }

    public func clear(from presenter: UIViewController) {
        guard !closed, visible, label.window != nil else { return }
        self.presenter = presenter
        dismissOwnedControllers()
        let id = cancelOperation(), store = store, identity = identity
        operation = Task { @MainActor [weak self] in
            do {
                try await store.clear(identity: identity)
                guard let self, self.isCurrent(id) else { return }
                self.operation = nil
                self.track = nil
                self.hasSubtitles = false
                self.loadError = nil
                self.updateTimer()
            } catch {
                guard let self, self.isCurrent(id) else { return }
                self.operation = nil
                self.showError(pluginErrorText(error))
            }
        }
    }

    public func dispose() {
        guard !closed else { return }
        closed = true
        visible = false
        cancelOperation()
        dismissOwnedControllers()
        timer?.invalidate()
        timer = nil
        track = nil
        sample = nil
        hasSubtitles = false
        loadError = nil
        presenter = nil
        label.windowUpdated = nil
        NotificationCenter.default.removeObserver(self)
        label.removeFromSuperview()
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !closed, visible, controller === picker else { return }
        picker = nil
        controller.delegate = nil
        let id = generation
        let complete = { [weak self] in
            guard let self, self.isCurrent(id) else { return }
            guard urls.count == 1, let url = urls.first, ["srt", "vtt"].contains(url.pathExtension.lowercased()) else {
                self.load()
                self.showError("Choose one .srt or .vtt subtitle file.")
                return
            }
            self.importSubtitle(url)
        }
        if controller.presentingViewController != nil {
            controller.dismiss(animated: true, completion: complete)
        } else {
            complete()
        }
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard !closed, visible, controller === picker else { return }
        picker = nil
        controller.delegate = nil
        load()
    }

    private func importSubtitle(_ url: URL) {
        let id = cancelOperation(), store = store, identity = identity
        operation = Task { @MainActor [weak self] in
            do {
                let reader = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try exteralessToolsReadPickedFile(url, maximumBytes: ToolsSubtitleTrack.maximumBytes)
                }
                let data = try await withTaskCancellationHandler(operation: { try await reader.value }, onCancel: { reader.cancel() })
                try Task.checkCancellation()
                guard let self, self.isCurrent(id) else { return }
                let track = try await store.save(data, identity: identity)
                guard self.isCurrent(id) else { return }
                self.operation = nil
                self.track = track
                self.hasSubtitles = true
                self.loadError = nil
                self.updateTimer()
            } catch {
                guard let self, self.isCurrent(id) else { return }
                self.operation = nil
                self.showError(pluginErrorText(error))
            }
        }
    }

    @discardableResult private func cancelOperation() -> UUID {
        generation = UUID()
        operation?.cancel()
        operation = nil
        return generation
    }

    private func isCurrent(_ id: UUID) -> Bool {
        return !closed && visible && generation == id && !Task.isCancelled
    }

    private func dismissOwnedControllers() {
        let picker = self.picker
        self.picker = nil
        picker?.delegate = nil
        if picker?.presentingViewController != nil { picker?.dismiss(animated: false) }
        let alert = errorAlert
        errorAlert = nil
        if alert?.presentingViewController != nil { alert?.dismiss(animated: false) }
    }

    @objc private func applicationWillResignActive() {
        applicationActive = false
        updateTimer()
    }

    @objc private func applicationDidBecomeActive() {
        applicationActive = true
        updateTimer()
    }

    @objc private func contentSizeCategoryChanged() {
        label.font = UIFont.preferredFont(forTextStyle: .body)
        layoutLabel()
        render()
    }

    private func updateTimer() {
        let running = !closed && visible && label.window != nil && track != nil && sample?.playing == true && applicationActive
        if running && timer == nil {
            let timer = Foundation.Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if !running { timer?.invalidate(); timer = nil }
        render()
    }

    private func render() {
        let time = sample?.time(at: CACurrentMediaTime())
        let text = !closed && visible && applicationActive && label.window != nil ? time.flatMap { track?.text(at: $0) } : nil
        if label.text != text { label.text = text; layoutLabel() }
        label.isHidden = text == nil || !labelHasRoom
    }

    private func layoutLabel(transition: ContainedViewLayoutTransition = .immediate) {
        let lineCount = Int(min(3, max(0, floor((layoutRect.height - 12) / label.font.lineHeight))))
        labelHasRoom = !layoutRect.isEmpty && lineCount > 0
        guard labelHasRoom else {
            label.frame = CGRect(origin: layoutRect.origin, size: .zero)
            return
        }
        label.numberOfLines = lineCount
        let height = min(layoutRect.height, ceil(label.sizeThatFits(CGSize(width: layoutRect.width, height: .greatestFiniteMagnitude)).height) + 12)
        let frame = CGRect(x: layoutRect.minX, y: layoutRect.maxY - height, width: layoutRect.width, height: height)
        transition.updateFrame(view: label, frame: frame, beginWithCurrentState: true)
    }

    private func showError(_ message: String) {
        guard !closed, visible else { return }
        guard let presenter, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { loadError = message; return }
        let alert = UIAlertController(title: "Subtitles", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        errorAlert = alert
        presenter.present(alert, animated: true)
    }
}
