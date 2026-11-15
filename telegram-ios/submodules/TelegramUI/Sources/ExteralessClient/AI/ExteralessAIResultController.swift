import AccountContext
import AsyncDisplayKit
import Display
import ExteralessCore
import Foundation
import Pasteboard
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TextFormat
import UIKit

struct ExteralessAIResultContent {
    let text: AIFormattedText
    let note: String
    var entities: [MessageTextEntity]? = nil
}

/// Explicit idle/running/completed/failed/cancelled states. Partial output is
/// selectable but cannot be inserted as though it were a completed response.
@MainActor
final class ExteralessAIResultController: ViewController {
    typealias Operation = @MainActor (@escaping @Sendable (AIGenerationEvent) async -> Void) async throws -> ExteralessAIResultContent
    private enum State { case idle, running, completed, failed, cancelled, invalidated }
    private let context: AccountContext
    private let settings: AISettings
    private let speech: ExteralessSpeechService
    private let operation: Operation
    private let access: ExteralessAIResultAccess?
    private let original: String
    private let sourceEntities: [MessageTextEntity]
    private let asQuote: Bool
    private var applyResult: ((ExteralessAIInsertion) -> Bool)?
    private var state = State.idle
    private var requestId = UUID()
    private var task: Task<Void, Never>?
    private var presentationDisposable: Disposable?
    private var presentationData: PresentationData
    private var text = ""
    private var reasoning = ""
    private var resultEntities: [MessageTextEntity] = []
    private var status = ""
    private var showReasoning = false
    private var formatted = false
    private var paused = false
    private var layout: ContainerViewLayout?
    var speakOnCompletion = false
    var onComplete: ((ExteralessAIResultContent) -> Void)?
    var onInvalidated: (() -> Void)?
    var allowsCopy: Bool { state != .invalidated && (access?.allowsCopy ?? true) }
    var resultScope: ExteralessAIScope? { access?.scope }

    private let sourceLabel = UILabel()
    private let statusLabel = UILabel()
    private let textView = ExteralessAIResultTextView()
    private let reasoningButton = UIButton(type: .system)
    private let runButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)
    private let speakButton = UIButton(type: .system)
    private let pauseButton = UIButton(type: .system)
    private let formatButton = UIButton(type: .system)
    private let actions = UIStackView()
    private let speechActions = UIStackView()

    init(context: AccountContext, title: String, source: String, sourceEntities: [MessageTextEntity], settings: AISettings, speech: ExteralessSpeechService, asQuote: Bool, applyResult: ((ExteralessAIInsertion) -> Bool)?, access: ExteralessAIResultAccess? = nil, operation: @escaping Operation) {
        self.context = context
        self.settings = settings
        self.speech = speech
        self.operation = operation
        self.access = access
        self.original = source
        self.sourceEntities = sourceEntities
        self.asQuote = asQuote
        self.applyResult = applyResult
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData))
        self.title = title
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: presentationData.strings.Common_Close, style: .done, target: self, action: #selector(closePressed))
        access?.onInvalidated = { [weak self] in self?.invalidate(reason: "The source or its protection changed. Open the action again.") }
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadDisplayNode() {
        displayNode = ASDisplayNode()
        for view in [sourceLabel, statusLabel, textView, reasoningButton, actions, speechActions] { displayNode.view.addSubview(view) }
        sourceLabel.numberOfLines = 3
        sourceLabel.lineBreakMode = .byTruncatingTail
        statusLabel.numberOfLines = 0
        textView.isEditable = false
        textView.isSelectable = allowsCopy
        textView.copySelection = { [weak self] in self?.copySelection() }
        textView.alwaysBounceVertical = true
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 16, right: 6)
        textView.accessibilityIdentifier = "Exteraless.AI.Result"
        statusLabel.accessibilityIdentifier = "Exteraless.AI.Status"
        for stack in [actions, speechActions] {
            stack.axis = .horizontal
            stack.distribution = .fillEqually
            stack.spacing = 8
        }
        for button in [runButton, copyButton, insertButton] { actions.addArrangedSubview(button) }
        for button in [speakButton, pauseButton, formatButton] { speechActions.addArrangedSubview(button) }
        for button in [runButton, copyButton, insertButton, speakButton, pauseButton, formatButton, reasoningButton] {
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.textAlignment = .center
        }
        reasoningButton.addTarget(self, action: #selector(reasoningPressed), for: .touchUpInside)
        runButton.addTarget(self, action: #selector(runPressed), for: .touchUpInside)
        copyButton.addTarget(self, action: #selector(copyPressed), for: .touchUpInside)
        insertButton.addTarget(self, action: #selector(insertPressed), for: .touchUpInside)
        speakButton.addTarget(self, action: #selector(speakPressed), for: .touchUpInside)
        pauseButton.addTarget(self, action: #selector(pausePressed), for: .touchUpInside)
        formatButton.addTarget(self, action: #selector(formatPressed), for: .touchUpInside)
        presentationDisposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self else { return }
            self.presentationData = value
            self.updatePresentation()
        })
        updatePresentation()
        displayNodeDidLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if state == .idle { start() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        if state == .running { cancel() }
        speech.stopSpeaking()
        super.viewWillDisappear(animated)
    }

    func invalidate(reason: String = "Account changed. Open the action again in the current account.") {
        cancel()
        state = .invalidated
        applyResult = nil
        text = ""
        reasoning = ""
        resultEntities = []
        status = reason
        onInvalidated?()
        if isNodeLoaded { sourceLabel.text = ""; render() }
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.layout = layout
        let sides = layout.sideInsets(forBandFrom: 0, to: layout.size.height)
        let insets = layout.insets(options: [.input])
        let x = sides.left + 16
        let width = max(0, layout.size.width - sides.left - sides.right - 32)
        var y = max(insets.top, navigationLayout(layout: layout).navigationFrame.maxY) + 8
        let sourceHeight: CGFloat = sourceLabel.isHidden ? 0 : min(92, sourceLabel.sizeThatFits(CGSize(width: width, height: 92)).height)
        transition.updateFrame(view: sourceLabel, frame: CGRect(x: x, y: y, width: width, height: sourceHeight))
        y += sourceHeight + (sourceHeight > 0 ? 8 : 0)
        let statusHeight = min(140, max(24, statusLabel.sizeThatFits(CGSize(width: width, height: 140)).height))
        transition.updateFrame(view: statusLabel, frame: CGRect(x: x, y: y, width: width, height: statusHeight))
        y += statusHeight + 4
        let reasonHeight: CGFloat = reasoning.isEmpty ? 0 : 44
        transition.updateFrame(view: reasoningButton, frame: CGRect(x: x, y: y, width: width, height: reasonHeight))
        y += reasonHeight
        let buttonHeight = max(44, UIFont.preferredFont(forTextStyle: .footnote).lineHeight * 2 + 12)
        let bottom = layout.size.height - insets.bottom - 8
        transition.updateFrame(view: speechActions, frame: CGRect(x: x, y: bottom - buttonHeight, width: width, height: buttonHeight))
        transition.updateFrame(view: actions, frame: CGRect(x: x, y: bottom - buttonHeight * 2 - 4, width: width, height: buttonHeight))
        transition.updateFrame(view: textView, frame: CGRect(x: sides.left + 8, y: y, width: max(0, layout.size.width - sides.left - sides.right - 16), height: max(0, bottom - buttonHeight * 2 - 12 - y)))
    }

    private func updatePresentation() {
        let theme = presentationData.theme
        overrideUserInterfaceStyle = theme.overallDarkAppearance ? .dark : .light
        displayNode.backgroundColor = theme.list.blocksBackgroundColor
        textView.backgroundColor = theme.list.itemBlocksBackgroundColor
        textView.textColor = theme.list.itemPrimaryTextColor
        textView.tintColor = theme.list.itemAccentColor
        sourceLabel.textColor = theme.list.itemSecondaryTextColor
        sourceLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        statusLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        sourceLabel.isHidden = original.isEmpty || settings.store.bool("ai.showResponseOnly") || state == .invalidated
        sourceLabel.text = sourceLabel.isHidden ? "" : "Selected text\n" + original
        statusBar.statusBarStyle = theme.rootController.statusBarStyle.style
        navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: presentationData), transition: .immediate)
        for button in [runButton, copyButton, insertButton, speakButton, pauseButton, formatButton, reasoningButton] {
            button.tintColor = theme.list.itemAccentColor
            button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .footnote)
        }
        render()
    }

    private func start() {
        guard state != .running && state != .invalidated else { return }
        task?.cancel()
        access?.begin()
        speech.stopSpeaking()
        state = .running
        text = ""
        reasoning = ""
        resultEntities = []
        showReasoning = false
        formatted = false
        status = "Working…"
        let id = UUID()
        requestId = id
        let operation = self.operation
        render()
        task = Task { @MainActor [weak self] in
            do {
                let content = try await operation { [weak self] event in
                    await MainActor.run {
                        guard let self, self.requestId == id, self.state == .running else { return }
                        self.receive(event)
                    }
                }
                if let access = self?.access { try await access.validate() }
                guard !Task.isCancelled, let self, self.requestId == id, self.state == .running else { return }
                if let access = self.access, !access.finish() { return }
                self.task = nil
                self.state = .completed
                self.text = content.text.text
                self.resultEntities = content.entities ?? exteralessAIRestoredEntities(content.text, originals: self.sourceEntities)
                self.status = "Complete · " + content.note
                self.render()
                self.onComplete?(ExteralessAIResultContent(text: AIFormattedText(text: content.text.text), note: content.note, entities: self.resultEntities))
                UIAccessibility.post(notification: .announcement, argument: "AI response complete")
                if self.speakOnCompletion { self.speakPressed() }
            } catch {
                guard !Task.isCancelled, let self, self.requestId == id, self.state == .running else { return }
                self.task = nil
                self.state = .failed
                if let error = error as? ExteralessSpeechError { self.status = error.errorDescription ?? "Speech failed." }
                else if let error = error as? ExteralessAITranscriptionError { self.status = error.errorDescription ?? "Transcription failed." }
                else if let error = error as? ExteralessAIUIError { self.status = error.text }
                else { self.status = AIError.sanitized(error).description }
                self.render()
                UIAccessibility.post(notification: .announcement, argument: self.status)
            }
        }
    }

    private func receive(_ event: AIGenerationEvent) {
        switch event {
        case let .text(value): text += value
        case let .replaceText(value): text = value
        case let .reasoning(value): reasoning += value
        case .thinking: status = "Thinking…"
        case let .tool(name): status = "Using tool: " + name
        }
        render()
    }

    private func cancel() {
        requestId = UUID()
        // Synchronous, before cancelling the async bridge: queued Postbox
        // closures see the revoked lease even before main processes disposal.
        access?.cancel()
        task?.cancel()
        task = nil
        speech.cancelAll()
        if state == .running { state = .cancelled; status = "Cancelled · partial output" }
        if isNodeLoaded { render() }
    }

    private func render() {
        guard isNodeLoaded else { return }
        statusLabel.text = status
        statusLabel.textColor = state == .failed ? presentationData.theme.list.itemDestructiveColor : presentationData.theme.list.itemSecondaryTextColor
        reasoningButton.isHidden = reasoning.isEmpty
        reasoningButton.setTitle(showReasoning ? "Show answer" : "Show model reasoning", for: .normal)
        runButton.setTitle(state == .running ? "Cancel" : "Retry", for: .normal)
        runButton.isEnabled = state != .invalidated
        copyButton.setTitle("Copy", for: .normal)
        copyButton.isEnabled = allowsCopy && !(showReasoning ? reasoning : text).isEmpty
        textView.copyAllowed = allowsCopy
        textView.isSelectable = allowsCopy
        insertButton.setTitle(asQuote ? "Insert quote" : "Insert", for: .normal)
        insertButton.isEnabled = allowsCopy && state == .completed && applyResult != nil
        insertButton.isHidden = applyResult == nil
        speakButton.setTitle(speech.isSpeaking ? "Stop speaking" : "Read aloud", for: .normal)
        speakButton.isEnabled = state == .completed && !text.isEmpty
        pauseButton.setTitle(paused ? "Resume" : "Pause", for: .normal)
        pauseButton.isEnabled = speech.isSpeaking
        formatButton.setTitle(formatted ? "Markdown source" : "Formatted", for: .normal)
        formatButton.isEnabled = state == .completed && !showReasoning
        let previousSelection = textView.selectedRange
        let previousOffset = textView.contentOffset
        let atEnd = textView.contentOffset.y + textView.bounds.height >= textView.contentSize.height - 44
        let visible = showReasoning ? reasoning : text
        if formatted && !showReasoning {
            let attributed = resultEntities.isEmpty ? convertMarkdownToAttributes(NSAttributedString(string: visible)) : chatInputStateStringWithAppliedEntities(visible, entities: resultEntities)
            let entities = generateChatInputTextEntities(attributed)
            let size = max(17, UIFont.preferredFont(forTextStyle: .body).pointSize)
            textView.attributedText = stringWithAppliedEntities(attributed.string, entities: entities, baseColor: presentationData.theme.list.itemPrimaryTextColor, linkColor: presentationData.theme.list.itemAccentColor, baseFont: Font.regular(size), linkFont: Font.regular(size), boldFont: Font.semibold(size), italicFont: Font.italic(size), boldItalicFont: Font.semiboldItalic(size), fixedFont: Font.monospace(size), blockQuoteFont: Font.regular(size), message: nil)
        } else {
            textView.attributedText = NSAttributedString(string: visible, attributes: [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: presentationData.theme.list.itemPrimaryTextColor])
        }
        if previousSelection.location + previousSelection.length <= textView.attributedText.length { textView.selectedRange = previousSelection }
        if atEnd && previousSelection.length == 0 && !textView.isDragging && !textView.isDecelerating {
            if textView.attributedText.length > 0 { textView.scrollRangeToVisible(NSRange(location: textView.attributedText.length - 1, length: 1)) }
        } else { textView.setContentOffset(previousOffset, animated: false) }
        if let layout { containerLayoutUpdated(layout, transition: .immediate) }
    }

    @objc private func runPressed() { if state == .running { cancel() } else { start() } }
    @objc private func closePressed() { cancel(); dismiss(animated: true) }
    @objc private func reasoningPressed() { showReasoning.toggle(); formatted = false; render() }
    @objc private func formatPressed() { formatted.toggle(); render() }

    @objc private func copyPressed() {
        withCurrentAccess { [weak self] in
            guard let self, self.allowsCopy else { return }
            let value = self.showReasoning ? self.reasoning : self.text
            if self.showReasoning { UIPasteboard.general.string = value }
            else { storeMessageTextInPasteboard(value, entities: self.state == .completed ? self.resultEntities : nil) }
            UIAccessibility.post(notification: .announcement, argument: "Copied")
        }
    }

    private func copySelection() {
        let range = textView.selectedRange
        let snapshot = textView.attributedText
        guard let snapshot, range.length > 0, range.location >= 0, NSMaxRange(range) <= snapshot.length else { return }
        withCurrentAccess { [weak self] in
            guard let self, self.allowsCopy, self.textView.attributedText == snapshot, self.textView.selectedRange == range else { return }
            storeAttributedTextInPasteboard(snapshot.attributedSubstring(from: range))
        }
    }

    private func withCurrentAccess(_ body: @escaping @MainActor () -> Void) {
        let id = requestId
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let access = self.access { try await access.validate() }
                guard self.requestId == id, self.state != .invalidated else { return }
                body()
            } catch {
                self.invalidate(reason: "The source or its protection changed. Open the action again.")
            }
        }
    }

    @objc private func insertPressed() {
        withCurrentAccess { [weak self] in
            guard let self, self.allowsCopy, self.state == .completed, let applyResult = self.applyResult else { return }
            if applyResult(ExteralessAIInsertion(text: self.text, entities: self.resultEntities, asQuote: self.asQuote)) { self.dismiss(animated: true) }
            else {
                self.status = "The draft changed while the request was running. Copy the result or reopen the action with the new selection."
                self.render()
            }
        }
    }

    @objc private func speakPressed() {
        if speech.isSpeaking { speech.stopSpeaking(); paused = false; render(); return }
        do {
            try speech.speak(text, language: settings.store.string("ai.OEVoskLanguage"), voiceIdentifier: settings.store.string("ai.speechVoiceIdentifier"), rate: Float(settings.store.double("ai.speechRate", default: 0.5))) { [weak self] _ in
                self?.paused = false
                self?.render()
            }
            render()
        } catch {
            status = (error as? ExteralessSpeechError)?.errorDescription ?? AIError.sanitized(error).description
            render()
        }
    }

    @objc private func pausePressed() {
        if paused { speech.resumeSpeaking() } else { speech.pauseSpeaking() }
        paused.toggle()
        render()
    }

    deinit { task?.cancel(); presentationDisposable?.dispose() }
}

/// System selection Copy goes through the same asynchronous source recheck as
/// the explicit button. UIKit's Share/Look Up routes cannot bypass that check.
final class ExteralessAIResultTextView: UITextView {
    var copyAllowed = false
    var copySelection: (() -> Void)?
    override func copy(_ sender: Any?) { if copyAllowed { copySelection?() } }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard copyAllowed else { return false }
        if action == #selector(copy(_:)) || action == #selector(select(_:)) || action == #selector(selectAll(_:)) {
            return super.canPerformAction(action, withSender: sender)
        }
        return false
    }
}
