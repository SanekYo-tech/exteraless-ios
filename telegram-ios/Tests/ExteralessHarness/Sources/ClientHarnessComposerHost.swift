import AccountContext
import AsyncDisplayKit
import ChatInputTextNode
import ChatPresentationInterfaceState
import ChatRichTextEditorComposer
import ChatTextInputPanelNode
import Display
import Foundation
import RichTextEngineEditor
import TelegramCore
import TelegramPresentationData
import TelegramUI
import UIKit

/// Scene/state adapter around the production panel producer. All editing, Date,
/// Mention, undo, parser and media drawing remain in the actual native components.
@available(iOS 18.4, *)
@MainActor
final class ClientHarnessComposerHost: ViewController {
    let context: AccountContext
    let journal: ClientHarnessJournal
    private(set) var panel: ChatTextInputPanelNode!
    private(set) var interfaceState: ChatPresentationInterfaceState
    var pendingDate: (text: NSAttributedString, apply: (Int32) -> Bool)?
    var inputLanguage: String?
    private(set) var parserCalls = 0
    private var layout: ContainerViewLayout?
    private var layingOut = false
    private let caption = UILabel()
    var stage: String = "Owned rich draft · native InputDec" { didSet { self.caption.text = self.stage } }

    static let peer = TelegramUser(id: EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(777001)),
        accessHash: nil, firstName: "Fixture", lastName: "Chat", username: nil, phone: nil, photo: [], botInfo: nil,
        restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil,
        backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)

    init(context: AccountContext, journal: ClientHarnessJournal) throws {
        self.context = context
        self.journal = journal
        let data = context.sharedContext.currentPresentationData.with { $0 }
        self.interfaceState = ChatPresentationInterfaceState(chatWallpaper: .builtin(WallpaperSettings()), theme: data.theme,
            preferredGlassType: .default, strings: data.strings, dateTimeFormat: data.dateTimeFormat,
            nameDisplayOrder: data.nameDisplayOrder, limitsConfiguration: context.currentLimitsConfiguration.with { $0 },
            fontSize: data.chatFontSize, bubbleCorners: data.chatBubbleCorners, accountPeerId: context.account.peerId,
            mode: .standard(.default), chatLocation: .peer(id: Self.peer.id), subject: nil, greetingData: nil,
            pendingUnpinnedAllMessages: false, activeGroupCallInfo: nil, hasActiveGroupCall: false, threadData: nil,
            isGeneralThreadClosed: nil, replyMessage: nil, accountPeerColor: nil, businessIntro: nil)
            .updatedPeer { _ in RenderedPeer(peer: Self.peer) }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: data))
        self.title = "Native Composer fixture"
        guard let panel = makeExteralessComposerPanel(context: context, state: self.interfaceState,
            interaction: clientHarnessComposerInteraction(self)) else {
            throw ClientHarnessFailure(description: "shipping Composer panel factory refused the isolated fixture")
        }
        self.panel = panel
        panel.view.accessibilityIdentifier = "client-harness.composer.panel"
        panel.updateHeight = { [weak self] _ in self?.requestPanelLayout() }
        panel.updateActivity = { [weak self] in self?.journal.record("composer-native-typing-activity") }
        panel.sendMessage = { fatalError("client-ui-harness: Composer.sendMessage is not provided") }
        panel.paste = { _ in fatalError("client-ui-harness: Composer.mediaPaste is not provided") }
        panel.displayAttachmentMenu = { fatalError("client-ui-harness: Composer.attachments is not provided") }
        guard let parser = panel.pastedMarkdownParser else { throw ClientHarnessFailure(description: "production Composer parser not installed") }
        panel.pastedMarkdownParser = { [weak self] context, text in
            self?.parserCalls += 1
            return parser(context, text)
        }
        _ = try self.nativeNode()
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.addSubnode(self.panel)
        self.caption.font = .systemFont(ofSize: 13)
        self.caption.numberOfLines = 2
        self.caption.text = self.stage
        self.displayNode.view.addSubview(self.caption)
        self.displayNodeDidLoad()
        self.updateAppearance()
    }

    func nativeNode() throws -> RichTextEditorChatInputNode {
        guard let node = self.panel.richTextInputNode as? RichTextEditorChatInputNode,
              node.usesNativeRichTextEngine, node.inputView is RichTextEngineEditorView else {
            throw ClientHarnessFailure(description: "Composer did not construct ChatRichTextEditorComposer → InputDec")
        }
        return node
    }

    func seed(_ content: ChatInputContent) {
        let state = ChatTextInputState(content: content, selectionRange: 0 ..< 0)
        self.interfaceState = self.interfaceState.updatedInterfaceState { $0.withUpdatedEffectiveInputState(state) }
        self.panel.updateInputTextState(state, keepSendButtonEnabled: false, extendedSearchLayout: false, accessoryItems: [], animated: false)
        self.requestPanelLayout()
    }

    func applyInput(_ transform: (ChatTextInputState, ChatInputMode) -> (ChatTextInputState, ChatInputMode)) {
        guard let node = self.panel?.richTextInputNode else { return }
        node.performUndoableInputChange {
            let old = self.interfaceState.interfaceState.effectiveInputState
            let (updated, mode) = transform(old, self.interfaceState.inputMode)
            self.interfaceState = self.interfaceState.updatedInterfaceState { $0.withUpdatedEffectiveInputState(updated) }
                .updatedInputMode { _ in mode }
            if old != updated {
                self.panel.updateInputTextState(updated, keepSendButtonEnabled: false,
                    extendedSearchLayout: false, accessoryItems: [], animated: false)
            }
        }
        self.requestPanelLayout()
    }

    func applyMode(_ transform: (ChatPresentationInterfaceState) -> (ChatInputMode, EngineMessage.Id?)) {
        let (mode, _) = transform(self.interfaceState)
        self.interfaceState = self.interfaceState.updatedInputMode { _ in mode }
        self.requestPanelLayout()
    }

    func captureDate() {
        self.pendingDate = self.panel.beginNativeDateEditing()
        self.journal.record("composer-format-date-request", ["selected": self.pendingDate?.text.string ?? "<refused>",
            "presentation": "held native picker completion; finite offline answer"])
    }

    func updateAppearance() {
        let data = self.context.sharedContext.currentPresentationData.with { $0 }
        self.interfaceState = self.interfaceState.updatedTheme(data.theme).updatedStrings(data.strings)
        if self.isNodeLoaded {
            self.displayNode.backgroundColor = data.theme.list.blocksBackgroundColor
            self.caption.textColor = data.theme.list.itemPrimaryTextColor
        }
        self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: data), transition: .immediate)
        self.requestPanelLayout()
    }

    func requestPanelLayout() { if self.isNodeLoaded { self.view.setNeedsLayout() } }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); self.layoutPanel(.immediate) }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.layout = layout
        self.layoutPanel(transition)
    }

    private func layoutPanel(_ transition: ContainedViewLayoutTransition) {
        guard !self.layingOut, let layout = self.layout, self.isNodeLoaded else { return }
        self.layingOut = true; defer { self.layingOut = false }
        let top = max(layout.safeInsets.top, self.navigationLayout(layout: layout).navigationFrame.maxY)
        let bottom = max(layout.inputHeight ?? 0, max(layout.safeInsets.bottom, layout.intrinsicInsets.bottom))
        let sides = layout.sideInsets(forBandFrom: top, to: layout.size.height - bottom)
        let height = self.panel.updateLayout(width: layout.size.width, leftInset: sides.left, rightInset: sides.right,
            bottomInset: 0, additionalSideInsets: .zero, maxHeight: max(60, layout.size.height - top - bottom - 46),
            maxOverlayHeight: 0, isSecondary: false, transition: transition, interfaceState: self.interfaceState,
            metrics: layout.metrics, deviceMetrics: layout.deviceMetrics, isMediaInputExpanded: false)
        transition.updateFrame(node: self.panel, frame: CGRect(x: 0, y: layout.size.height - bottom - height,
            width: layout.size.width, height: height))
        self.panel.updateAbsoluteRect(self.panel.frame, within: layout.size, transition: transition)
        self.caption.frame = CGRect(x: sides.left + 16, y: top + 4, width: layout.size.width - sides.left - sides.right - 32, height: 38)
    }

    func stop() {
        _ = self.panel.richTextInputNode?.resignInputFirstResponder()
        self.pendingDate = nil
        self.seed(ChatInputContent())
        self.panel.interfaceInteraction = nil
        self.panel.pastedMarkdownParser = nil
        self.panel.removeFromSupernode()
    }
}
