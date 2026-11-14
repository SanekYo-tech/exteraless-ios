import AccountContext
import Foundation
import PluginHost
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

/// One application-owned object is passed to PluginHost.BridgeServiceSet in all three
/// roles. init() needs no account; update(context:) must be called on the UI thread.
/// The C worker sees only immutable, lock-published value snapshots. AccountContext,
/// PresentationData and UIKit objects below are accessed exclusively on main.
public final class TelegramPluginServices: PluginMessagesService, PluginSettingsService,
    PluginUIService, PluginPlatformService, @unchecked Sendable {
    public let serviceStorage: PluginServiceStorage
    public let serviceLogs: PluginServiceLogBuffer
    public let runtimeVersion: String

    private let snapshotLock = NSLock()
    private var snapshot = PluginPlatformSnapshot()

    // Main-thread state. Slot ids survive reordering/account switches and are
    // never recycled for a different record during this service's lifetime.
    private var sharedContext: SharedAccountContext?
    private var accountContexts: [Int64: AccountContext] = [:]
    private var accountSlots: [Int64: Int32] = [:]
    private var nextAccountSlot: Int64 = 0
    private var primaryRecordId: Int64?
    private var presentationData: PresentationData?
    private var accountsDisposable: Disposable?
    private var presentationDisposable: Disposable?

    public init(storage: PluginServiceStorage = PluginServiceStorage(),
                logs: PluginServiceLogBuffer = PluginServiceLogBuffer()) {
        self.serviceStorage = storage
        self.serviceLogs = logs
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        self.runtimeVersion = "exteraless-ios/1 (Telegram \(version ?? "unversioned"), build \(build ?? "unavailable"))"
    }

    deinit {
        self.accountsDisposable?.dispose()
        self.presentationDisposable?.dispose()
    }

    public var platformSnapshot: PluginPlatformSnapshot {
        self.snapshotLock.lock()
        defer { self.snapshotLock.unlock() }
        return self.snapshot
    }

    /// Coordinator/UI can read logs without entering a plugin's interpreter.
    public var logEntries: [PluginServiceLogEntry] { self.serviceLogs.entries }

    /// Keep observing both presentation and active accounts after the initial
    /// publication: theme/language/account changes need no interpreter restart.
    public func update(context: AccountContext) {
        precondition(Thread.isMainThread, "TelegramPluginServices.update(context:) must run on main")
        let shared = context.sharedContext
        self.presentationData = shared.currentPresentationData.with { $0 }
        if self.sharedContext === shared {
            self.seedActiveContext(context)
            self.publishSnapshot()
            return
        }

        self.accountsDisposable?.dispose()
        self.presentationDisposable?.dispose()
        self.sharedContext = shared
        self.accountContexts.removeAll()
        self.primaryRecordId = nil
        self.seedActiveContext(context)
        self.publishSnapshot()

        self.accountsDisposable = (shared.activeAccountContexts
        |> deliverOnMainQueue).start(next: { [weak self] primary, accounts, _ in
            guard let self else { return }
            var contexts: [Int64: AccountContext] = [:]
            for (recordId, accountContext, _) in accounts {
                let id = recordId.int64
                guard self.allocateSlot(recordId: id) != nil else { continue }
                contexts[id] = accountContext
            }
            self.accountContexts = contexts
            self.primaryRecordId = primary?.account.id.int64
            self.publishSnapshot()
        })

        self.presentationDisposable = (shared.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            self.presentationData = data
            self.publishSnapshot()
        })
    }

    /// Mapping for the coordinator's AccountRecordId -> hook account adapter.
    public func accountIndex(recordId: Int64) -> Int32? {
        self.platformSnapshot.accounts.first(where: { $0.recordId == recordId })?.index
    }

    public func clearContext() {
        precondition(Thread.isMainThread)
        self.accountsDisposable?.dispose()
        self.presentationDisposable?.dispose()
        self.accountsDisposable = nil
        self.presentationDisposable = nil
        self.sharedContext = nil
        self.accountContexts.removeAll()
        self.primaryRecordId = nil
        self.presentationData = nil
        self.snapshotLock.lock()
        self.snapshot = PluginPlatformSnapshot()
        self.snapshotLock.unlock()
    }

    private func allocateSlot(recordId: Int64) -> Int32? {
        if let slot = self.accountSlots[recordId] { return slot }
        guard let slot = Int32(exactly: self.nextAccountSlot) else {
            self.serviceLogs.append(pluginId: "host", level: .error, message: "Account slot space exhausted")
            return nil
        }
        self.accountSlots[recordId] = slot
        self.nextAccountSlot += 1
        return slot
    }

    private func seedActiveContext(_ context: AccountContext) {
        // update's argument is the coordinator's active context. Publish that real
        // record immediately, even if the full activeAccountContexts signal has
        // not emitted yet; subsequent emissions provide the authoritative set.
        let id = context.account.id.int64
        guard self.allocateSlot(recordId: id) != nil else { return }
        self.accountContexts[id] = context
        self.primaryRecordId = id
    }

    private func publishSnapshot() {
        precondition(Thread.isMainThread)
        guard let data = self.presentationData else { return }
        let window = self.sharedContext?.applicationBindings.getTopWindow()
        let scale = Double(window?.screen.scale ?? UIScreen.main.scale)
        let traits = window?.traitCollection ?? UITraitCollection.current
        var accounts: [PluginServiceAccount] = []
        for (recordId, context) in self.accountContexts {
            guard let index = self.accountSlots[recordId] else { continue }
            accounts.append(PluginServiceAccount(index: index, recordId: recordId,
                userId: context.account.peerId.id._internalGetInt64Value()))
        }
        accounts.sort { $0.index < $1.index }
        let selected = self.primaryRecordId.flatMap { id in
            accounts.first(where: { $0.recordId == id })?.index
        }
        let snapshot = PluginPlatformSnapshot(displayScale: scale,
            themeColors: Self.themeColors(data.theme, traits: traits),
            strings: Self.localizedStrings(data.strings), localeIdentifier: data.strings.primaryComponent.languageCode,
            accounts: accounts, selectedAccountIndex: selected)
        self.snapshotLock.lock()
        self.snapshot = snapshot
        self.snapshotLock.unlock()
    }

    // MARK: Legacy service roles (throwing instead of invented defaults)

    public func selectedAccount() throws -> Int32 {
        try self.platformSnapshot.selectedAccount()
    }

    public func instanceHandle(fqcn: String, account: Int32) throws -> Int64 {
        guard BridgeServices.accountClassNames.contains(fqcn) else {
            throw BridgeFailure.unimplemented("Unsupported account service: \(fqcn)")
        }
        return try self.platformSnapshot.account(at: account).recordId
    }

    public func themeColor(forKey key: String) throws -> Int32 {
        try self.platformSnapshot.themeColor(forKey: key)
    }

    public func themeKey(_ name: String) throws -> String {
        try self.platformSnapshot.themeKey(name)
    }

    public func dp(_ value: Double) throws -> Double {
        try self.platformSnapshot.points(value, pixelAligned: true)
    }

    public func runOnUIThread(delayMs: Int, work: @escaping @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(0, delayMs)), execute: work)
    }

    public func constructUI(fqcn: String, arguments: [Any]) throws -> Int64 {
        throw BridgeFailure.unimplemented("Unsupported native UI constructor: \(fqcn); use portable ui.settings rows")
    }

    // MARK: Native effects

    public func addToClipboard(_ text: String, pluginId: String) throws {
        DispatchQueue.main.async {
            UIPasteboard.general.string = text
        }
    }

    public func openURL(_ url: URL, pluginId: String) throws {
        let logs = self.serviceLogs
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:], completionHandler: { opened in
                if !opened {
                    logs.append(pluginId: pluginId, level: .error, message: "Browser.openUrl: iOS could not open the URL")
                }
            })
        }
    }

    /// Scheduling succeeds synchronously; the bounded log records the native
    /// enqueue result. This does not claim network delivery or fabricate a TL id.
    public func sendMessage(_ request: PluginTextMessageRequest) throws -> String {
        let current = try self.platformSnapshot.account(at: request.account.index)
        guard current.recordId == request.account.recordId else {
            throw BridgeFailure.invalidHandle("sendMessage: account record has changed")
        }
        guard request.peerId > 0, request.peerId <= 0x00ff_ffff_ffff_ffff,
              !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.text.utf16.count <= 4096 else {
            throw BridgeFailure.malformed("sendMessage: invalid plain-text request")
        }
        let requestId = UUID().uuidString
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.enqueueMessage(request, requestId: requestId)
        }
        return requestId
    }

    @MainActor
    private func enqueueMessage(_ request: PluginTextMessageRequest, requestId: String) async {
        do {
            guard let context = self.accountContexts[request.account.recordId],
                  self.accountSlots[request.account.recordId] == request.account.index else {
                throw BridgeFailure.unavailable("sendMessage: account is no longer active")
            }
            let peerId: EnginePeer.Id
            switch request.peerKind {
            case .user:
                peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(request.peerId))
            case .group:
                peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(request.peerId))
            case .channel:
                peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(request.peerId))
            }

            // EngineData reads the local peer cache. No username resolution or TL
            // request is invented for a peer the account does not already know.
            let peerData = await (context.engine.data.get(
                TelegramEngine.EngineData.Item.Peer.Peer(id: peerId),
                TelegramEngine.EngineData.Item.Peer.SendPaidMessageStars(id: peerId),
                TelegramEngine.EngineData.Item.Peer.CachedData(id: peerId)
            ) |> take(1) |> last).get()
            guard let (maybePeer, advertisedPrice, cachedData) = peerData, let peer = maybePeer else {
                throw BridgeFailure.unavailable("sendMessage: peer is not present in the active account")
            }
            guard canSendMessagesToPeer(peer) else {
                throw BridgeFailure.permission("sendMessage: this peer does not allow messages")
            }
            var paidStars = advertisedPrice
            if case .channel(let channel) = peer {
                if channel.flags.contains(.isCreator) || channel.adminRights != nil {
                    paidStars = nil
                } else {
                    // Match the chat's effective per-account price, including
                    // an explicit zero exemption in the cached channel data.
                    paidStars = (cachedData as? CachedChannelData)?.sendPaidMessageStars ?? channel.sendPaidMessageStars
                }
            }
            if let paidStars, paidStars > .zero {
                throw BridgeFailure.unimplemented("sendMessage: paid-message parameters are unsupported")
            }
            switch peer {
            case .user:
                break
            case .legacyGroup(let group):
                guard !group.hasBannedPermission(.banSendText) else {
                    throw BridgeFailure.permission("sendMessage: text is restricted in this group")
                }
            case .channel(let channel):
                guard !channel.flags.contains(.isForum), !channel.flags.contains(.isMonoforum) else {
                    throw BridgeFailure.unimplemented("sendMessage: forum/monoforum thread parameters are unsupported")
                }
                guard channel.hasPermission(.sendText) else {
                    throw BridgeFailure.permission("sendMessage: text is restricted in this channel")
                }
            default:
                throw BridgeFailure.unimplemented("sendMessage: only cloud users, groups and channels are supported")
            }

            // A suspension may have crossed logout/account replacement. Never
            // redirect an accepted request to whichever account is now selected.
            guard self.accountContexts[request.account.recordId] === context else {
                throw BridgeFailure.unavailable("sendMessage: account was removed while preparing the message")
            }
            // Plugin-origin effects must not recursively re-enter the same send
            // hook. Core retains its original media/Postbox enqueue pipeline.
            let message = EnqueueMessage.message(text: request.text, attributes: [], inlineStickers: [:],
                mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil,
                localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
            let result = await (enqueueMessagesFromPlugin(account: context.account, peerId: peerId, messages: [message])
                |> take(1) |> last).get()
            // `last` emits nil even if the native signal completes without a
            // value, so an empty result is reported instead of a stuck Task.
            let ids = result?.compactMap { $0 } ?? []
            guard !ids.isEmpty else {
                throw BridgeFailure.unavailable("sendMessage: native enqueue produced no message")
            }
            self.serviceLogs.append(pluginId: request.pluginId,
                message: "sendMessage \(requestId): enqueued local message ids \(ids.map { String($0.id) }.joined(separator: ","))")
        } catch let failure as BridgeFailure {
            self.serviceLogs.append(pluginId: request.pluginId, level: .error,
                message: "sendMessage \(requestId): \(failure.kind): \(failure.description)")
        } catch {
            self.serviceLogs.append(pluginId: request.pluginId, level: .error,
                message: "sendMessage \(requestId): \(error.localizedDescription)")
        }
    }

    // MARK: Presentation snapshot adapters

    /// Android semantic keys map to the current native palette. In particular,
    /// featured-sticker buttons use native check/accent colors; premiumGradient1
    /// is the native accent endpoint, not a fabricated Android gradient drawable.
    private static func themeColors(_ theme: PresentationTheme, traits: UITraitCollection) -> [String: Int32] {
        let colors: [String: UIColor] = [
            "dialogBackground": theme.actionSheet.opaqueItemBackgroundColor,
            "dialogTextBlack": theme.actionSheet.primaryTextColor,
            "dialogTextBlue": theme.actionSheet.standardActionTextColor,
            "dialogTextLink": theme.actionSheet.standardActionTextColor,
            "dialogTextGray": theme.actionSheet.secondaryTextColor,
            "dialogTextGray3": theme.actionSheet.disabledActionTextColor,
            "dialogTextHint": theme.actionSheet.inputPlaceholderColor,
            "dialogRoundCheckBox": theme.actionSheet.controlAccentColor,
            "dialogRoundCheckBoxCheck": theme.actionSheet.checkContentColor,
            "windowBackgroundWhite": theme.list.itemBlocksBackgroundColor,
            "windowBackgroundGray": theme.list.blocksBackgroundColor,
            "windowBackgroundWhiteBlackText": theme.list.itemPrimaryTextColor,
            "windowBackgroundWhiteGrayText": theme.list.itemSecondaryTextColor,
            "windowBackgroundWhiteGrayText2": theme.list.itemSecondaryTextColor,
            "windowBackgroundWhiteBlueText": theme.list.itemAccentColor,
            "windowBackgroundWhiteBlueHeader": theme.list.sectionHeaderTextColor,
            "windowBackgroundWhiteLinkText": theme.list.itemAccentColor,
            "windowBackgroundWhiteHintText": theme.list.itemPlaceholderTextColor,
            "divider": theme.list.itemBlocksSeparatorColor,
            "listSelector": theme.list.itemHighlightedBackgroundColor,
            "text_RedRegular": theme.list.itemDestructiveColor,
            "checkbox": theme.list.itemCheckColors.fillColor,
            "checkboxCheck": theme.list.itemCheckColors.foregroundColor,
            "checkboxDisabled": theme.list.itemDisabledTextColor,
            "chat_inLoader": theme.chat.message.incoming.mediaActiveControlColor,
            "chat_messagePanelSend": theme.chat.inputPanel.panelControlAccentColor,
            "featuredStickers_addButton": theme.list.itemCheckColors.fillColor,
            "featuredStickers_addButtonPressed": theme.list.itemHighlightedColor,
            "featuredStickers_buttonText": theme.list.itemCheckColors.foregroundColor,
            "premiumGradient1": theme.list.itemAccentColor
        ]
        var result: [String: Int32] = [:]
        for (key, color) in colors {
            let resolved = color.resolvedColor(with: traits)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                // Unsupported colors are absent, not silently converted to black.
                continue
            }
            func byte(_ value: CGFloat) -> UInt32 {
                UInt32((min(1, max(0, value)) * 255).rounded())
            }
            result[key] = Int32(bitPattern: (byte(alpha) << 24) | (byte(red) << 16) | (byte(green) << 8) | byte(blue))
        }
        return result
    }

    private static func localizedStrings(_ strings: PresentationStrings) -> [String: String] {
        let values: [(String, String, String)] = [
            ("OK", "Common.OK", strings.Common_OK),
            ("Cancel", "Common.Cancel", strings.Common_Cancel),
            ("Done", "Common.Done", strings.Common_Done),
            ("Save", "Common.Save", strings.Common_Save),
            ("Delete", "Common.Delete", strings.Common_Delete),
            ("Close", "Common.Close", strings.Common_Close),
            ("Back", "Common.Back", strings.Common_Back),
            ("Edit", "Common.Edit", strings.Common_Edit),
            ("Search", "Common.Search", strings.Common_Search),
            ("Yes", "Common.Yes", strings.Common_Yes),
            ("No", "Common.No", strings.Common_No),
            ("Copy", "Conversation.ContextMenuCopy", strings.Conversation_ContextMenuCopy),
            ("Send", "MediaPicker.Send", strings.MediaPicker_Send),
            ("Settings", "Settings.Title", strings.Settings_Title),
            ("SavedMessages", "DialogList.SavedMessages", strings.DialogList_SavedMessages)
        ]
        var result: [String: String] = [:]
        for (androidKey, nativeKey, value) in values {
            result[androidKey] = value
            result[nativeKey] = value
        }
        return result
    }
}
