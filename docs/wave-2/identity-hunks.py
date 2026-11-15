"""Exact, read-only shared insertions for the Identity owner.

python docs/wave-2/identity-hunks.py --check   # validate every anchor; <= 30 seconds
python docs/wave-2/identity-hunks.py          # emit a unified diff for coordinator

Never writes the working tree. Each replacement has an expected occurrence
count. A concurrent edit fails the affected anchor instead of overwriting it.
--scope allowed/remaining follows the user's application-wave reservations.
--tool-patch emits functions.patch syntax; this program never applies it.
"""
from __future__ import annotations

import argparse
import difflib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PREFIX = "telegram-ios/submodules/"

# Application-wave reservations. PeerInfo identity changes below do not edit
# story eligibility, story panes or story routing owned by Dialogs.
RESERVED_FILES = {
    PREFIX + "TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift",
    PREFIX + "TelegramUI/Sources/ChatController.swift",
    PREFIX + "ChatListUI/Sources/ChatListController.swift",
    PREFIX + "ChatListUI/Sources/Node/ChatListItem.swift",
    PREFIX + "AvatarNode/Sources/AvatarNode.swift",
    PREFIX + "AvatarNode/Sources/PeerAvatar.swift",
}

REGION_APPLIED_MARKERS = {
    "avatar.initials.colors": "let identity = peer.map { exteralessIdentityPresentation(account: account ?? genericContext.account, peer: $0) }",
    "avatar.complete.account": "identityPresentation: exteralessIdentityPresentation(account: account, peer: peer)",
    "avatar.complete.letters": "var displayLetters = identityPresentation?.letters ?? peer.displayLetters",
    "dates.clock.digits": "return dateTimeFormat.identityCalendar.digits(in:",
    "dates.header.initial.text": "let text = exteralessIdentityDateHeaderText(localTimestamp: localTimestamp, scheduled: scheduled, presentationData: presentationData)",
    "dates.header.live.refresh": "self.text = exteralessIdentityDateHeaderText(localTimestamp: self.localTimestamp, scheduled: self.scheduled, presentationData: presentationData)",
}


class Hunks:
    def __init__(self, scope="all", files=None):
        self.original: dict[str, str] = {}
        self.modified: dict[str, str] = {}
        self.anchors: list[dict] = []
        self.scope = scope
        self.files = set(files) if files else None

    def includes(self, path):
        if self.files is not None and path not in self.files:
            return False
        return self.scope == "all" or ((path in RESERVED_FILES) == (self.scope == "remaining"))

    def read(self, path):
        if path not in self.original:
            self.original[path] = (ROOT / path).read_text(encoding="utf-8")
            self.modified[path] = self.original[path]
        return self.modified[path]

    def edit(self, name, path, old, new, count=1):
        if not self.includes(path):
            return
        text = self.read(path)
        pieces = text.split(new) if new else [text]
        applied = len(pieces) - 1
        pending = sum(piece.count(old) for piece in pieces)
        removed = not new and old not in text and name == "dates.header.remove.static.timezone" and "let civil = Int64(timestamp) + Int64(offset)" in text
        if removed or (new and applied >= count and pending == 0):
            self.anchors.append({"id": name, "file": path, "occurrences": count, "status": "applied", "source_line": text[:text.index(new)].count("\n") + 1 if new else 1})
            return
        if applied + pending != count:
            raise AssertionError(f"{name}: {path}: expected {count} exact anchors, found {pending} pending + {applied} applied")
        # Protect already-applied blocks when `old` is a substring of `new`.
        self.modified[path] = new.join(piece.replace(old, new) for piece in pieces) if new else text.replace(old, new)
        self.anchors.append({"id": name, "file": path, "occurrences": count, "pending_occurrences": pending, "status": "pending", "source_line": text[:text.index(old)].count("\n") + 1})

    def add(self, name, path, source):
        if not self.includes(path):
            return
        if (ROOT / path).exists():
            text = self.read(path)
            if text != source:
                raise AssertionError(f"{name}: shared helper differs from prepared source: {path}")
            self.anchors.append({"id": name, "file": path, "occurrences": 1, "status": "applied", "source_line": 1})
            return
        self.original[path] = ""
        self.modified[path] = source
        self.anchors.append({"id": name, "file": path, "occurrences": 1, "status": "pending", "source_line": 1})

    def region(self, name, path, start, end, transform, after=None):
        if not self.includes(path):
            return
        text = self.read(path)
        marker = REGION_APPLIED_MARKERS.get(name)
        if marker and marker in text:
            self.anchors.append({"id": name, "file": path, "occurrences": 1, "status": "applied", "source_line": text[:text.index(marker)].count("\n") + 1})
            return
        if after is not None and text.count(after) != 1:
            raise AssertionError(f"{name}: non-unique containing declaration")
        if after is None and text.count(start) != 1:
            raise AssertionError(f"{name}: non-unique region start")
        begin = text.index(start, text.index(after) if after is not None else 0)
        finish = text.index(end, begin + len(start))
        old = text[begin:finish]
        if after is None:
            self.edit(name, path, old, transform(old))
        else:
            new = transform(old)
            assert old != new, name + ": empty region edit"
            self.modified[path] = text[:begin] + new + text[finish:]
            self.anchors.append({"id": name, "file": path, "occurrences": 1, "status": "pending", "containing_declaration": after, "source_line": text[:begin].count("\n") + 1})

    def diff(self):
        output = []
        for path, text in self.modified.items():
            original = self.original[path]
            if original == text:
                continue
            before, after = original.splitlines(True), text.splitlines(True)
            context = 3
            if original:
                matcher = difflib.SequenceMatcher(a=before, b=after)
                for context in [3, 6, 12, 24, 48, max(len(before), 1)]:
                    groups = list(matcher.get_grouped_opcodes(context))
                    if all(original.count("".join(before[group[0][1]:group[-1][2]])) == 1 for group in groups):
                        break
            output.append("".join(difflib.unified_diff(before, after, fromfile="a/" + path if original else "/dev/null", tofile="b/" + path, n=context)))
        return "".join(output)

    def tool_patch(self):
        output = ["*** Begin Patch"]
        for path, text in self.modified.items():
            old = self.original[path]
            if old == text:
                continue
            if not old:
                output += ["*** Add File: " + path] + ["+" + line for line in text.splitlines()]
            else:
                output.append("*** Update File: " + path)
                before, after = old.splitlines(), text.splitlines()
                for group in difflib.SequenceMatcher(a=before, b=after, autojunk=False).get_grouped_opcodes(4):
                    output.append("@@")
                    for tag, i1, i2, j1, j2 in group:
                        if tag == "equal": output += [" " + line for line in before[i1:i2]]
                        if tag in ("delete", "replace"): output += ["-" + line for line in before[i1:i2]]
                        if tag in ("insert", "replace"): output += ["+" + line for line in after[j1:j2]]
        output.append("*** End Patch")
        return "\n".join(output) + "\n"


def composition(h):
    p = PREFIX + "TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift"
    h.edit("composition.owner", p, "    private var tools: ExteralessToolsIntegration?", "    private var tools: ExteralessToolsIntegration?\n    private var identity: ExteralessIdentityIntegration?")
    h.edit("composition.definitions", p, "+ AIFeatures.definitions + ToolsFeatures.definitions", "+ AIFeatures.definitions + ToolsFeatures.definitions + IdentityFeatures.definitions")
    h.edit("composition.init", p, "        if tools == nil { tools = ExteralessToolsIntegration() }", "        if tools == nil { tools = ExteralessToolsIntegration() }\n        if identity == nil { identity = ExteralessIdentityIntegration() }")
    h.edit("composition.update", p, "        tools?.update(context: context)", "        tools?.update(context: context)\n        identity?.update(context: context)")
    h.edit("composition.clear", p, "        tools?.clearContext()", "        tools?.clearContext()\n        identity?.clearContext()")


def presentation(h):
    p = PREFIX + "TelegramPresentationData/Sources/PresentationData.swift"
    h.edit("presentation.fields", p, "    public let showSeconds: Bool", "    public let showSeconds: Bool\n    public let identityCalendar: IdentityDatePolicy\n    // Copied into native list/chat presentation values, including async caches.\n    public let identityRevision: UInt64")
    h.edit("presentation.default", p, "        self.showSeconds = false", "        self.showSeconds = false\n        self.identityCalendar = IdentityDatePolicy()\n        self.identityRevision = 0")
    h.edit("presentation.blank", p, "        self.identityRevision = 0\n    }\n    \n", "        self.identityRevision = 0\n    }\n\n")
    h.edit("presentation.init", p, "groupingSeparator: String, showSeconds: Bool = false) {", "groupingSeparator: String, showSeconds: Bool = false, identityCalendar: IdentityDatePolicy = IdentityDatePolicy(), identityRevision: UInt64 = 0) {")
    h.edit("presentation.assign", p, "        self.showSeconds = showSeconds", "        self.showSeconds = showSeconds\n        self.identityCalendar = identityCalendar\n        self.identityRevision = identityRevision")
    h.edit("presentation.snapshot.capture", p, '    let decimalSeparator = locale.decimalSeparator ?? "."', '    let identityFormatting = ExteralessIdentityPresentation.shared.formattingSnapshot\n    let decimalSeparator = locale.decimalSeparator ?? "."')
    h.edit("presentation.snapshot", p, 'showSeconds: ClientSettings.shared.bool("appearance.showSeconds"))', 'showSeconds: ClientSettings.shared.bool("appearance.showSeconds"), identityCalendar: identityFormatting.calendar, identityRevision: identityFormatting.revision)')
    p = PREFIX + "TelegramPresentationData/Sources/ExteralessAppearanceUpdates.swift"
    h.edit("presentation.signal", p, "        subscriber.putNext(())\n        return ActionDisposable {", "        let identity = NotificationCenter.default.addObserver(forName: IdentityFeatures.presentationChanged, object: nil, queue: .main) { _ in\n            subscriber.putNext(())\n        }\n        subscriber.putNext(())\n        return ActionDisposable {")
    h.edit("presentation.signal.dispose", p, "            NotificationCenter.default.removeObserver(resources)", "            NotificationCenter.default.removeObserver(resources)\n            NotificationCenter.default.removeObserver(identity)")
    # These native controllers otherwise ignore changes when theme/strings keep
    # object identity; new names/dates/statuses must actually rebuild their rows.
    for label, file in [
        ("chatList", "ChatListUI/Sources/ChatListController.swift"),
        ("contacts", "ContactListUI/Sources/ContactsController.swift"),
        ("profile", "TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift")
    ]:
        p = PREFIX + file
        h.edit(label + ".invalidation.capture", p, "                let previousStrings = strongSelf.presentationData.strings", "                let previousStrings = strongSelf.presentationData.strings\n                let previousDateTimeFormat = strongSelf.presentationData.dateTimeFormat")
        h.edit(label + ".invalidation.compare", p, "                if previousTheme !== presentationData.theme || previousStrings !== presentationData.strings {", "                if previousTheme !== presentationData.theme || previousStrings !== presentationData.strings || previousDateTimeFormat != presentationData.dateTimeFormat {")
    p = PREFIX + "TelegramUI/Sources/ChatController.swift"
    h.edit("chat.invalidation.capture", p, "                let previousChatWallpaper = strongSelf.presentationData.chatWallpaper", "                let previousChatWallpaper = strongSelf.presentationData.chatWallpaper\n                let previousDateTimeFormat = strongSelf.presentationData.dateTimeFormat")
    h.edit("chat.invalidation.compare", p, "if isFirstTime || previousTheme != presentationData.theme || previousStrings !== presentationData.strings || presentationData.chatWallpaper != previousChatWallpaper {", "if isFirstTime || previousTheme != presentationData.theme || previousStrings !== presentationData.strings || presentationData.chatWallpaper != previousChatWallpaper || previousDateTimeFormat != presentationData.dateTimeFormat {")


def names(h):
    p = PREFIX + "LocalizedPeerData/Sources/PeerTitle.swift"
    h.edit("names.explicit.account", p, "public extension EnginePeer {", """public extension EnginePeer {
    func exteralessDisplayTitle(account: Account, strings: PresentationStrings, displayOrder: PresentationPersonNameOrder) -> String {
        return exteralessIdentityPresentation(account: account, peer: self).name ?? self.displayTitle(strings: strings, displayOrder: displayOrder)
    }

    func exteralessCompactDisplayTitle(account: Account) -> String {
        return exteralessIdentityPresentation(account: account, peer: self).compactName ?? self.compactDisplayTitle
    }
""")
    files = [
        ("list.names", "ChatListUI/Sources/Node/ChatListItem.swift", "item.context", 12, 6),
        ("header.names", "TelegramUI/Components/ChatTitleView/Sources/ChatTitleView.swift", "self.context", 2, 3),
        ("nav.names", "TelegramUI/Components/ChatTitleView/Sources/ChatTitleComponent.swift", "component.context", 2, 3),
        ("profile.name", "TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift", "self.context", 1, 0),
        ("profile.items.names", "TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoProfileItems.swift", "context", 2, 4),
        ("reply.names", "TelegramUI/Components/Chat/ChatMessageReplyInfoNode/Sources/ChatMessageReplyInfoNode.swift", "arguments.context", 4, 0),
        ("forward.names", "TelegramUI/Components/Chat/ChatMessageForwardInfoNode/Sources/ChatMessageForwardInfoNode.swift", "context", 2, 0),
        ("bubble.names", "TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift", "item.context", 3, 2),
        ("animated.names", "TelegramUI/Components/Chat/ChatMessageAnimatedStickerItemNode/Sources/ChatMessageAnimatedStickerItemNode.swift", "item.context", 2, 0),
        ("sticker.names", "TelegramUI/Components/Chat/ChatMessageStickerItemNode/Sources/ChatMessageStickerItemNode.swift", "item.context", 2, 0)
    ]
    for name, file, context, full, compact in files:
        p = PREFIX + file
        if full:
            h.edit(name, p, ".displayTitle(strings:", f".exteralessDisplayTitle(account: {context}.account, strings:", full)
        if compact:
            h.edit(name + ".compact", p, ".compactDisplayTitle", f".exteralessCompactDisplayTitle(account: {context}.account)", compact)
    p = PREFIX + "TelegramUI/Components/Chat/ChatMessageWebpageBubbleContentNode/Sources/ChatMessageWebpageBubbleContentNode.swift"
    h.edit("webpage.peer.name", p, ".displayTitle(strings:", ".exteralessDisplayTitle(account: item.context.account, strings:")
    # Do not let the phone-number fallback hide an explicitly chosen local alias.
    for file, context in [("ChatTitleView.swift", "self"), ("ChatTitleComponent.swift", "component")]:
        p = PREFIX + "TelegramUI/Components/ChatTitleView/Sources/" + file
        needle = "if !peerView.isContact, let user = peer as? TelegramUser, !user.flags.contains(.isSupport), user.botInfo == nil, let phone = user.phone, !phone.isEmpty {"
        h.edit(file + ".alias.phone.precedence", p, needle,
            f"if !peerView.isContact, exteralessIdentityPeerKey(EnginePeer(peer)).flatMap({{ ExteralessIdentityPresentation.shared.state(account: {context}.context.account)?.alias(for: $0) }}) == nil, let user = peer as? TelegramUser, !user.flags.contains(.isSupport), user.botInfo == nil, let phone = user.phone, !phone.isEmpty {{")
    p = PREFIX + "ContactsPeerItem/Sources/ContactsPeerItem.swift"
    h.edit("contacts.projection", p, "            case let .peer(peer, chatPeer):\n                if let peer = peer {\n                    let textColor: UIColor", "            case let .peer(peer, chatPeer):\n                if let peer = peer {\n                    let identityPeer = exteralessIdentityPresentation(account: item.context.account, peer: peer)\n                    let identityDisplayOrder: PresentationPersonNameOrder = identityPeer.localNameOrder.map { $0.rawValue == 0 ? .lastFirst : .firstLast } ?? item.displayOrder\n                    let textColor: UIColor")
    h.edit("contacts.user.names", p, "                        } else if let firstName = user.firstName, let lastName = user.lastName, !firstName.isEmpty, !lastName.isEmpty {", "                        } else if let name = identityPeer.localAlias {\n                            titleAttributedString = NSAttributedString(string: name, font: titleBoldFont, textColor: textColor)\n                        } else if let firstName = user.firstName, let lastName = user.lastName, !firstName.isEmpty, !lastName.isEmpty {")
    h.edit("contacts.name.order", p, "                            switch item.displayOrder {", "                            switch identityDisplayOrder {")
    for kind in ["group", "channel", "community"]:
        h.edit("contacts." + kind + ".name", p, "string: " + kind + ".title, font: titleBoldFont", "string: identityPeer.localAlias ?? " + kind + ".title, font: titleBoldFont")


def profile(h):
    base = PREFIX + "TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/"
    p = base + "PeerInfoProfileItems.swift"
    h.edit("profile.id.dc", p, "    let bioContextAction: (ASDisplayNode, ContextGesture?, CGPoint?) -> Void =", """    if let peer = data.peer, let metadata = exteralessIdentityMetadata(account: context.account, peer: peer, cachedData: data.cachedData) {
        items[.peerInfo]!.append(PeerInfoScreenLabeledValueItem(
            id: "exteraless.identity.id", label: "ID", text: metadata.id,
            action: { _, _ in UIPasteboard.general.string = metadata.id },
            longTapAction: metadata.userLink.map { link in { _ in UIPasteboard.general.string = link } },
            requestLayout: { interaction.requestLayout($0) }
        ))
        if let dc = metadata.datacenterId {
            items[.peerInfo]!.append(PeerInfoScreenLabeledValueItem(
                id: "exteraless.identity.dc", label: metadata.datacenterSource ?? "DC", text: String(dc),
                action: { _, _ in UIPasteboard.general.string = String(dc) },
                requestLayout: { interaction.requestLayout($0) }
            ))
        }
    }

    let bioContextAction: (ASDisplayNode, ContextGesture?, CGPoint?) -> Void =""")
    for label, entities in [("user", "user.isPremium ? enabledPublicBioEntities : enabledPrivateBioEntities"), ("channel", "enabledEntities"), ("group", "enabledPrivateBioEntities")]:
        old = f"textBehavior: .multiLine(maxLines: 100, enabledEntities: {entities}), action: isMyProfile ?"
        new = f"textBehavior: .multiLine(maxLines: 100, enabledEntities: {entities}), expandedByDefault: ExteralessIdentityPresentation.shared.policy.showFullAbout, action: isMyProfile ?"
        h.edit("profile.about." + label, p, old, new)
    p = base + "ListItems/PeerInfoScreenLabeledValueItem.swift"
    h.edit("about.model", p, "    let textBehavior: PeerInfoScreenLabeledValueTextBehavior", "    let textBehavior: PeerInfoScreenLabeledValueTextBehavior\n    let expandedByDefault: Bool")
    h.edit("about.parameter", p, "        textBehavior: PeerInfoScreenLabeledValueTextBehavior = .singleLine,", "        textBehavior: PeerInfoScreenLabeledValueTextBehavior = .singleLine,\n        expandedByDefault: Bool = false,")
    h.edit("about.assign", p, "        self.textBehavior = textBehavior", "        self.textBehavior = textBehavior\n        self.expandedByDefault = expandedByDefault")
    h.edit("about.trim", p, "if !self.isExpanded {", "if !(self.isExpanded || item.expandedByDefault) {", 2)
    h.edit("about.lines", p, "maxNumberOfLines = self.isExpanded ? maxLines : collapsedNumberOfLines", "maxNumberOfLines = item.expandedByDefault ? 0 : (self.isExpanded ? maxLines : collapsedNumberOfLines)")
    p = base + "PeerInfoData.swift"
    h.edit("profile.common.groups", p, "                let peer = peerView.peers[userPeerId]", """                if var panes = availablePanes,
                   exteralessIdentityPreferCommonGroups(defaultIsGifts: panes.first == .gifts, hasCommonGroups: panes.contains(.groupsInCommon)) {
                    panes.removeAll(where: { $0 == .groupsInCommon })
                    panes.insert(.groupsInCommon, at: 0)
                    availablePanes = panes
                }

                let peer = peerView.peers[userPeerId]""")
    p = base + "PeerInfoHeaderNode.swift"
    h.edit("profile.project", p, "        self.state = state\n        self.peer = peer", "        let identityPresentation = peer.map { exteralessIdentityPresentation(account: self.context.account, peer: $0) }\n        self.state = state\n        self.peer = peer")
    h.edit("profile.status.optional", p, "peer?.emojiStatus", "identityPresentation?.emojiStatus", 3)
    h.edit("profile.status.badge", p, 'let emojiStatus = peer.emojiStatus {', 'let emojiStatus = identityPresentation?.emojiStatus {')
    h.edit("profile.premium.badge", p, '&& peer.isPremium && !premiumConfiguration.isPremiumDisabled', '&& identityPresentation?.premiumBadge == true && !premiumConfiguration.isPremiumDisabled')
    h.edit("profile.premium.measure", p, "            isPremium = peer.isPremium", "            isPremium = identityPresentation?.premiumBadge ?? peer.isPremium")
    h.edit("profile.colors.optional", p, "peer?.effectiveProfileColor", "identityPresentation?.profileColor", 5)
    h.edit("profile.cover", p, """        } else if let peer {
            backgroundCoverSubject = .peer(peer)
            if peer.effectiveProfileColor != nil {
                hasBackground = true
            }
        } else {""", """        } else if let peer {
            if let color = identityPresentation?.profileColor {
                let colors = self.context.peerNameColors.getProfile(color, dark: presentationData.theme.overallDarkAppearance)
                backgroundCoverSubject = .custom(colors.main, colors.secondary, nil, identityPresentation?.profileBackgroundEmojiId)
                hasBackground = true
            } else {
                backgroundCoverSubject = .peer(peer)
            }
        } else {""")


def premium(h):
    base = PREFIX + "TelegramUI/Components/Chat/"
    p = base + "ChatMessageReplyInfoNode/Sources/ChatMessageReplyInfoNode.swift"
    h.edit("reply.project", p, "            var giftEmojiFileId: Int64?\n            switch author?.nameColor {", "            let identityAuthor = author.map { exteralessIdentityPresentation(account: arguments.context.account, peer: EnginePeer($0), surface: .reply) }\n            var giftEmojiFileId: Int64?\n            switch identityAuthor?.nameColor {")
    h.edit("reply.emoji", p, "if let backgroundEmojiId = author?.backgroundEmojiId,", "if let backgroundEmojiId = identityAuthor?.backgroundEmojiId,")
    h.edit("reply.collectible.emoji", p, 'if !ClientSettings.shared.bool("chats.replyEmoji", default: true) {', 'if !ClientSettings.shared.bool("chats.replyEmoji", default: true) || !ExteralessIdentityPresentation.shared.policy.premiumItemEmojiInReplies {')
    p = base + "ChatMessageAttachedContentNode/Sources/ChatMessageAttachedContentNode.swift"
    h.edit("attached.project", p, "            let nameColors: PeerNameColors.Colors?\n            var giftEmojiFileId: Int64?\n            switch author?.nameColor {", "            let identityAuthor = author.map { exteralessIdentityPresentation(account: context.account, peer: EnginePeer($0), surface: .reply) }\n            let nameColors: PeerNameColors.Colors?\n            var giftEmojiFileId: Int64?\n            switch identityAuthor?.nameColor {")
    h.edit("attached.pattern", p, "let backgroundEmojiId = author?.backgroundEmojiId {", "let backgroundEmojiId = identityAuthor?.backgroundEmojiId {")
    h.edit("attached.gift.pattern", p, "if displayGiftIcon && displayLine && !isAd {", "if displayGiftIcon && displayLine && !isAd && ExteralessIdentityPresentation.shared.policy.premiumItemEmojiInReplies {")
    p = base + "ChatMessageContactBubbleContentNode/Sources/ChatMessageContactBubbleContentNode.swift"
    h.edit("contact.project", p, "            let nameColors: PeerNameColors.Colors?\n            switch contactPeer?.nameColor {", "            let identityContact = contactPeer.map { exteralessIdentityPresentation(account: item.context.account, peer: $0, surface: .reply) }\n            let nameColors: PeerNameColors.Colors?\n            switch identityContact?.nameColor {")
    h.edit("contact.pattern", p, "if let contactPeer, let backgroundEmojiId = contactPeer.backgroundEmojiId {", "if let backgroundEmojiId = identityContact?.backgroundEmojiId {")
    h.edit("contact.name", p, "                if displayName.isEmpty {\n                    displayName = item.presentationData.strings.Message_Contact", "                if let localName = exteralessIdentityContactName(account: item.context.account, peer: contactPeer, firstName: selectedContact.firstName, lastName: selectedContact.lastName) { displayName = localName }\n                if displayName.isEmpty {\n                    displayName = item.presentationData.strings.Message_Contact")
    p = base + "ChatMessageForwardInfoNode/Sources/ChatMessageForwardInfoNode.swift"
    h.edit("forward.color", p, "if let nameColor = peer?.nameColor {", "if let nameColor = peer.flatMap({ exteralessIdentityPresentation(account: context.account, peer: $0).nameColor }) {")
    p = base + "ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift"
    h.edit("author.name.colors", p, "switch effectiveAuthor.nameColor {", "switch exteralessIdentityPresentation(account: item.context.account, peer: EnginePeer(effectiveAuthor)).nameColor {", 2)
    h.edit("author.peer.colors", p, "switch peer.nameColor {", "switch exteralessIdentityPresentation(account: item.context.account, peer: EnginePeer(peer)).nameColor {", 2)
    h.edit("author.emoji.status", p, "let emojiStatus = effectiveAuthor.emojiStatus {", "let emojiStatus = exteralessIdentityPresentation(account: item.context.account, peer: EnginePeer(effectiveAuthor), surface: .messageAuthor).emojiStatus {", 2)
    h.edit("author.premium.badge", p, "} else if effectiveAuthor.isPremium {", "} else if exteralessIdentityPresentation(account: item.context.account, peer: EnginePeer(effectiveAuthor), surface: .messageAuthor).premiumBadge {")
    h.edit("boosts.measure", p, "                var boostCount: Int = 0\n                if incoming {", "                var boostCount: Int = 0\n                if incoming && ExteralessIdentityPresentation.shared.policy.premiumItemBoosts {")
    h.edit("boosts.apply", p, "            var boostCount: Int = 0\n            if incoming {", "            var boostCount: Int = 0\n            if incoming && ExteralessIdentityPresentation.shared.policy.premiumItemBoosts {")
    p = PREFIX + "ChatListUI/Sources/Node/ChatListItem.swift"
    h.edit("list.emoji.status", p, "let emojiStatus = peer.emojiStatus {", "let emojiStatus = exteralessIdentityPresentation(account: item.context.account, peer: peer).emojiStatus {", 2)
    h.edit("list.premium.badge", p, "peer.isPremium && !premiumConfiguration.isPremiumDisabled", "exteralessIdentityPresentation(account: item.context.account, peer: peer).premiumBadge && !premiumConfiguration.isPremiumDisabled", 2)
    h.edit("list.video.avatar", p, "if let photo = photo, item.context.sharedContext.energyUsageSettings.loopEmoji, (!photo.videoRepresentations.isEmpty || photo.emojiMarkup != nil) {", "if let photo = photo, item.context.sharedContext.energyUsageSettings.loopEmoji, ((!photo.videoRepresentations.isEmpty && ExteralessIdentityPresentation.shared.policy.premiumItemVideoAvatar) || photo.emojiMarkup != nil) {")
    for file, context in [("ChatTitleView.swift", "self.context"), ("ChatTitleComponent.swift", "component.context")]:
        p = PREFIX + "TelegramUI/Components/ChatTitleView/Sources/" + file
        h.edit(file + ".status", p, "let emojiStatus = peer.emojiStatus {", f"let emojiStatus = exteralessIdentityPresentation(account: {context}.account, peer: EnginePeer(peer)).emojiStatus {{")
        h.edit(file + ".badge", p, "peer.isPremium && !premiumConfiguration.isPremiumDisabled", f"exteralessIdentityPresentation(account: {context}.account, peer: EnginePeer(peer)).premiumBadge && !premiumConfiguration.isPremiumDisabled")
    p = base + "ChatAvatarNavigationNode/Sources/ChatAvatarNavigationNode.swift"
    h.edit("nav.video.avatar", p, "if let peer = peer, peer.isPremium {", "if let peer = peer, exteralessIdentityPresentation(account: context.account, peer: peer).premiumBadge {")
    h.edit("nav.video.eligibility", p, "if let photo = photo, !photo.videoRepresentations.isEmpty || photo.emojiMarkup != nil {", "if let photo = photo, (!photo.videoRepresentations.isEmpty && ExteralessIdentityPresentation.shared.policy.premiumItemVideoAvatar) || photo.emojiMarkup != nil {")
    p = PREFIX + "AvatarVideoNode/Sources/AvatarVideoNode.swift"
    h.edit("video.visibility", p, "    public func updateVisibility(_ isVisible: Bool) {\n        self.visibility = isVisible", "    public func updateVisibility(_ isVisible: Bool) {\n        self.visibility = isVisible\n        let showsVideo = isVisible && ExteralessIdentityPresentation.shared.policy.premiumItemVideoAvatar")
    h.edit("video.visibility.content", p, "if isVisible, let videoContent = self.videoContent,", "if showsVideo, let videoContent = self.videoContent,")
    h.edit("video.visibility.layer", p, "        self.videoItemLayer?.isVisibleForAnimations = isVisible", "        self.videoItemLayer?.isVisibleForAnimations = showsVideo\n        self.videoItemLayer?.isHidden = !showsVideo")
    p = PREFIX + "TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoAvatarTransformContainerNode.swift"
    h.edit("profile.video.avatar", p, "} else if threadInfo == nil, let video = videoRepresentations.last, let peerReference = PeerReference(peer) {", "} else if ExteralessIdentityPresentation.shared.policy.premiumItemVideoAvatar, threadInfo == nil, let video = videoRepresentations.last, let peerReference = PeerReference(peer) {")
    p = PREFIX + "TelegramUI/Sources/ChatController.swift"
    h.edit("wallpaper.presentation", p, "                chatWallpaper = exteralessOverrides.wallpaper", "                chatWallpaper = ExteralessIdentityPresentation.shared.policy.premiumItemCustomWallpaper ? exteralessOverrides.wallpaper : nil")
    p = base + "ChatMessageAnimatedStickerItemNode/Sources/ChatMessageAnimatedStickerItemNode.swift"
    h.edit("sticker.effects", p, "    func playPremiumStickerAnimation() {\n", "    func playPremiumStickerAnimation() {\n        guard ExteralessIdentityPresentation.shared.policy.premiumItemStickerEffects else { return }\n")
    h.edit("emoji.effects", p, "    public func playEffectAnimation(resource: TelegramMediaResource, isStickerEffect: Bool = false) {\n", "    public func playEffectAnimation(resource: TelegramMediaResource, isStickerEffect: Bool = false) {\n        guard ExteralessIdentityPresentation.shared.policy.premiumItemStickerEffects else { return }\n")
    h.edit("emoji.effects.tap", p, "let syncAnimations = item.message.id.peerId.namespace == Namespaces.Peer.CloudUser", "let syncAnimations = item.message.id.peerId.namespace == Namespaces.Peer.CloudUser && ExteralessIdentityPresentation.shared.policy.premiumItemStickerEffects")
    h.edit("emoji.effects.queued", p, "    private func commitEnqueuedAnimations() {\n", "    private func commitEnqueuedAnimations() {\n        guard ExteralessIdentityPresentation.shared.policy.premiumItemStickerEffects else {\n            self.enqueuedAdditionalAnimations.removeAll()\n            return\n        }\n")
    p = base + "ChatMessageItemView/Sources/ChatMessageItemView.swift"
    h.edit("message.effects", p, "    public func playMessageEffect(force: Bool) {\n", "    public func playMessageEffect(force: Bool) {\n        guard ExteralessIdentityPresentation.shared.policy.premiumItemStickerEffects else { return }\n")
    p = base + "ChatMessageDateAndStatusNode/Sources/ChatMessageDateAndStatusNode.swift"
    h.edit("paid.reactions.values", p, "            self.reactions = reactions", "            self.reactions = exteralessIdentityVisibleReactions(reactions)")
    h.edit("paid.reactions.add", p, "            self.areStarReactionsEnabled = areStarReactionsEnabled", "            self.areStarReactionsEnabled = areStarReactionsEnabled && ExteralessIdentityPresentation.shared.policy.premiumItemStarInReactions")
    p = base + "ChatMessageReactionsFooterContentNode/Sources/ChatMessageReactionsFooterContentNode.swift"
    h.edit("paid.footer.counts", p, "for reaction in reactions.reactions {", "for reaction in exteralessIdentityVisibleReactions(reactions.reactions) {")
    h.edit("paid.footer.values", p, "var mappedReactions = reactions.reactions.map { reaction in", "var mappedReactions = exteralessIdentityVisibleReactions(reactions.reactions).map { reaction in")
    p = PREFIX + "TelegramUI/Sources/Chat/ChatControllerOpenMessageContextMenu.swift"
    h.edit("paid.menu", p, "actions.reactionItems = topReactions.map { ReactionContextItem.reaction(item: $0, icon: .none) }", "actions.reactionItems = topReactions.filter { ExteralessIdentityPresentation.shared.policy.premiumItemStarInReactions || $0.reaction.rawValue != .stars }.map { ReactionContextItem.reaction(item: $0, icon: .none) }")
    p = PREFIX + "TelegramUI/Components/EntityKeyboard/Sources/EmojiPagerContentSignals.swift"
    h.edit("paid.emoji.pager", p, "                            case .stars:\n", "                            case .stars:\n                                guard ExteralessIdentityPresentation.shared.policy.premiumItemStarInReactions else { continue }\n", 3)


def avatar(h):
    p = PREFIX + "AvatarNode/Sources/AvatarNode.swift"
    def project(text):
        anchor = "            let clipStyle = clipStyle.withExteralessShape(size: displayDimensions)"
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + "\n            let identity = peer.map { exteralessIdentityPresentation(account: account ?? genericContext.account, peer: $0) }")
        text = text.replace("peer?.nameColor, peer?.displayLetters ?? []", "identity?.nameColor, identity?.letters ?? peer?.displayLetters ?? []")
        text = text.replace("nameColor: peer.nameColor", "nameColor: identity?.nameColor")
        text = text.replace("nameColor: peer?.nameColor", "nameColor: identity?.nameColor")
        text = text.replace("letters: peer.displayLetters", "letters: identity?.letters ?? peer.displayLetters")
        return text.replace("letters: peer?.displayLetters ?? []", "letters: identity?.letters ?? peer?.displayLetters ?? []")
    h.region("avatar.initials.colors", p, "        public func setPeer(\n            context genericContext: AccountContext,", "        public func setCustomLetters", project)
    p = PREFIX + "AvatarNode/Sources/PeerAvatar.swift"
    def complete(text):
        assert text.count("        blurred: blurred\n") == 1
        return text.replace("        blurred: blurred\n", "        blurred: blurred,\n        identityPresentation: exteralessIdentityPresentation(account: account, peer: peer)\n")
    h.region("avatar.complete.account", p, "public func peerAvatarCompleteImage(account: Account,", "public func peerAvatarCompleteImage(postbox: Postbox,", complete)
    def image(text):
        assert text.count("blurred: Bool = false)") == 1
        text = text.replace("blurred: Bool = false)", "blurred: Bool = false, identityPresentation: ExteralessPeerIdentityPresentation? = nil)")
        text = text.replace("var displayLetters = peer.displayLetters", "var displayLetters = identityPresentation?.letters ?? peer.displayLetters")
        return text.replace("nameColor: peer.nameColor)", "nameColor: identityPresentation?.nameColor ?? peer.nameColor)")
    h.region("avatar.complete.letters", p, "public func peerAvatarCompleteImage(postbox: Postbox,", "public func peerAvatarImage(account: Account,", image)


IDENTITY_DATE_HELPERS = r'''import ExteralessCore
import Foundation
import TelegramCore
import TelegramPresentationData
import TextFormat

public func exteralessIdentityForwardDate(timestamp: Int32, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, now: Date = Date()) -> String? {
    guard ExteralessIdentityPresentation.shared.policy.dateOfForwardedMsg, timestamp > 0 else { return nil }
    let date = Date(timeIntervalSince1970: Double(timestamp))
    let time = stringForMessageTimestamp(timestamp: timestamp, dateTimeFormat: dateTimeFormat)
    if IdentityDatePolicy.dayDistance(from: date, to: now, timeZone: .current) == 0 { return time }
    let calendar = dateTimeFormat.identityCalendar
    let day = calendar.persianText(for: date, style: .monthDay(includeYear: !calendar.sameYear(date, now)))
        ?? stringForDate(date: date, timeZone: .current, strings: strings)
    return strings.Time_AtPreciseDate(day, time).string
}

func exteralessIdentityListDate(timestamp: Int32, now: Int32, strings: PresentationStrings, format: PresentationDateTimeFormat, precise: Bool = false) -> String? {
    guard format.identityCalendar.usePersianCalendar else { return nil }
    let date = Date(timeIntervalSince1970: Double(timestamp))
    let current = Date(timeIntervalSince1970: Double(now))
    guard let days = IdentityDatePolicy.dayDistance(from: date, to: current, timeZone: .current) else { return nil }
    let time = stringForMessageTimestamp(timestamp: timestamp, dateTimeFormat: format)
    if days == 0 { return time }
    if !precise && (1...6).contains(days) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return shortStringForDayOfWeek(strings: strings, day: Int32(calendar.component(.weekday, from: date) - 1))
    }
    let text = format.identityCalendar.persianText(for: date, style: .monthDay(includeYear: !format.identityCalendar.sameYear(date, current)))
    if precise, let text { return strings.Time_AtPreciseDate(text, time).string }
    return text
}

func exteralessIdentityLastSeen(timestamp: Int32, now: Int32, strings: PresentationStrings, format: PresentationDateTimeFormat) -> String? {
    guard format.identityCalendar.usePersianCalendar, timestamp > 0 else { return nil }
    let date = Date(timeIntervalSince1970: Double(timestamp))
    let current = Date(timeIntervalSince1970: Double(now))
    let time = stringForMessageTimestamp(timestamp: timestamp, dateTimeFormat: format)
    switch IdentityDatePolicy.dayDistance(from: date, to: current, timeZone: .current) {
    case 0?: return strings.LastSeen_TodayAt(time).string
    case 1?: return strings.LastSeen_YesterdayAt(time).string
    default:
        guard let dateText = format.identityCalendar.persianText(for: date, style: .monthDay(includeYear: !format.identityCalendar.sameYear(date, current))) else { return nil }
        return strings.LastSeen_AtDate(strings.Time_AtPreciseDate(dateText, time).string).string
    }
}
'''


def dates(h):
    h.add("dates.semantic.helpers", PREFIX + "TelegramStringFormatting/Sources/ExteralessIdentityDateFormat.swift", IDENTITY_DATE_HELPERS)
    p = PREFIX + "TextFormat/Sources/DateFormat.swift"
    def clock(text):
        lines = text.splitlines(True)
        count = 0
        for index, line in enumerate(lines):
            if line.lstrip().startswith("return "):
                indentation = line[:len(line) - len(line.lstrip())]
                expression = line.strip()[7:]
                lines[index] = indentation + "return dateTimeFormat.identityCalendar.digits(in: " + expression + ")\n"
                count += 1
        assert count == 4, "Native clock return sites changed"
        return "".join(lines)
    h.region("dates.clock.digits", p, "public func stringForShortTimestamp(", "public func stringForMessageTimestamp(", clock)
    signature = "public func stringForShortDate(timestamp: Int32, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, withTime: Bool = true) -> String {"
    h.edit("dates.entity.numeric", p, signature, signature + "\n    if let text = dateTimeFormat.identityCalendar.persianText(for: Date(timeIntervalSince1970: Double(timestamp)), style: .numeric(dayFirst: dateTimeFormat.dateFormat == .dayFirst, separator: dateTimeFormat.dateSeparator, suffix: dateTimeFormat.dateSuffix, fullYear: dateTimeFormat.requiresFullYear)) { return text }")
    signature = "private func stringForFullDate(timestamp: Int32, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat) -> String {"
    h.edit("dates.entity.long", p, signature, signature + "\n    if let text = dateTimeFormat.identityCalendar.persianText(for: Date(timeIntervalSince1970: Double(timestamp)), style: .monthDay(includeYear: true)) { return text }")
    p = PREFIX + "TelegramStringFormatting/Sources/DateFormat.swift"
    h.edit("dates.import", p, "import Foundation\n", "import Foundation\nimport ExteralessCore\n")
    signature = "public func stringForMediumCompactDate(timestamp: Int32, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, withTime: Bool = true) -> String {"
    h.edit("dates.medium.compact", p, signature, signature + "\n    if let text = dateTimeFormat.identityCalendar.persianText(for: Date(timeIntervalSince1970: Double(timestamp)), style: .monthDay(includeYear: false)) {\n        return withTime ? strings.Time_MediumDate(text, stringForMessageTimestamp(timestamp: timestamp, dateTimeFormat: dateTimeFormat)).string : text\n    }")
    signature = "public func stringForMediumDate(timestamp: Int32, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, withTime: Bool = true) -> String {"
    h.edit("dates.medium", p, signature, signature + "\n    if let text = dateTimeFormat.identityCalendar.persianText(for: Date(timeIntervalSince1970: Double(timestamp)), style: .numeric(dayFirst: dateTimeFormat.dateFormat == .dayFirst, separator: dateTimeFormat.dateSeparator, suffix: dateTimeFormat.dateSuffix, fullYear: dateTimeFormat.requiresFullYear)) {\n        return withTime ? strings.Time_MediumDate(text, stringForMessageTimestamp(timestamp: timestamp, dateTimeFormat: dateTimeFormat)).string : text\n    }")
    signature = "public func stringForFullDate(timestamp: Int32, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat) -> String {"
    h.edit("dates.full", p, signature, signature + "\n    if let text = dateTimeFormat.identityCalendar.persianText(for: Date(timeIntervalSince1970: Double(timestamp)), style: .monthDay(includeYear: true)) {\n        return strings.Time_AtPreciseDate(text, stringForMessageTimestamp(timestamp: timestamp, dateTimeFormat: dateTimeFormat)).string\n    }")
    for label, signature, date, year in [
        ("dates.absolute.timestamp", "public func stringForDate(timestamp: Int32, timeZone: TimeZone? = TimeZone(secondsFromGMT: 0), strings: PresentationStrings) -> String {", "Date(timeIntervalSince1970: Double(timestamp))", True),
        ("dates.absolute.date", "public func stringForDate(date: Date, timeZone: TimeZone? = TimeZone(secondsFromGMT: 0), strings: PresentationStrings) -> String {", "date", True),
        ("dates.absolute.no.year", "public func stringForDateWithoutYear(date: Date, timeZone: TimeZone? = TimeZone(secondsFromGMT: 0), strings: PresentationStrings) -> String {", "date", False)
    ]:
        h.edit(label, p, signature, signature + f"\n    if let text = ExteralessIdentityPresentation.shared.policy.calendar.persianText(for: {date}, style: .monthDay(includeYear: {str(year).lower()}), timeZone: timeZone ?? .current) {{ return text }}")
    p = PREFIX + "TelegramStringFormatting/Sources/PresenceStrings.swift"
    signature = "public func stringForTimestamp(day: Int32, month: Int32, year: Int32, dateTimeFormat: PresentationDateTimeFormat) -> String {"
    h.edit("dates.civil.components", p, signature, signature + "\n    if dateTimeFormat.identityCalendar.usePersianCalendar,\n       let date = IdentityDatePolicy.gregorianDate(year: Int(year) + 1900, month: Int(month), day: Int(day), timeZone: .current),\n       let text = dateTimeFormat.identityCalendar.persianText(for: date, style: .numeric(dayFirst: dateTimeFormat.dateFormat == .dayFirst, separator: dateTimeFormat.dateSeparator, suffix: dateTimeFormat.dateSuffix, fullYear: dateTimeFormat.requiresFullYear)) { return text }")
    signature = "public func stringForMonth(strings: PresentationStrings, month: Int32, ofYear year: Int32) -> String {"
    h.edit("dates.month.interval", p, signature, signature + """
    if ExteralessIdentityPresentation.shared.policy.calendar.usePersianCalendar,
       let first = IdentityDatePolicy.gregorianDate(year: Int(year) + 1900, month: Int(month) + 1, day: 1, timeZone: .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        if let next = calendar.date(byAdding: .month, value: 1, to: first),
           let last = calendar.date(byAdding: .day, value: -1, to: next),
           let range = ExteralessIdentityPresentation.shared.policy.calendar.persianRange(from: first, through: last) { return range }
    }""")
    h.edit("dates.compact", p, '    return "\\(shortStringForDayOfWeek(strings: strings, day: timeinfo.tm_wday)) \\(timeinfo.tm_mday) \\(monthAtIndex(Int(timeinfo.tm_mon), strings: strings))"', '''    if let text = dateTimeFormat.identityCalendar.persianText(for: Date(timeIntervalSince1970: Double(timestamp)), style: .monthDay(includeYear: false)) {
        return "\\(shortStringForDayOfWeek(strings: strings, day: timeinfo.tm_wday)) \\(text)"
    }
    return "\\(shortStringForDayOfWeek(strings: strings, day: timeinfo.tm_wday)) \\(timeinfo.tm_mday) \\(monthAtIndex(Int(timeinfo.tm_mon), strings: strings))"''')
    for name, precise in [("stringForRelativeTimestamp", False), ("stringForPreciseRelativeTimestamp", True)]:
        signature = f"public func {name}(strings: PresentationStrings, relativeTimestamp: Int32, relativeTo timestamp: Int32, dateTimeFormat: PresentationDateTimeFormat) -> String {{"
        h.edit("dates." + name, p, signature, signature + f"\n    if let text = exteralessIdentityListDate(timestamp: relativeTimestamp, now: timestamp, strings: strings, format: dateTimeFormat, precise: {str(precise).lower()}) {{ return text }}")
    # Keep Appearance's relative-last-seen precedence, then convert the exact date.
    h.edit("dates.last.seen", p, "            } else {\n                var t: time_t = time_t(statusTimestamp)", "            } else {\n                if let text = exteralessIdentityLastSeen(timestamp: statusTimestamp, now: timestamp, strings: strings, format: dateTimeFormat) { return (text, false) }\n                var t: time_t = time_t(statusTimestamp)")
    p = PREFIX + "TelegramUI/Components/Chat/ChatMessageForwardInfoNode/Sources/ChatMessageForwardInfoNode.swift"
    h.edit("forward.date.import", p, "import TelegramPresentationData\n", "import TelegramPresentationData\nimport TelegramStringFormatting\n")
    h.edit("forward.date.input", p, "_ storyData: StoryData?, _ constrainedSize: CGSize", "_ storyData: StoryData?, _ originalTimestamp: Int32?, _ constrainedSize: CGSize")
    h.edit("forward.date.closure", p, "inlineBotName, psaType, storyData, constrainedSize in", "inlineBotName, psaType, storyData, originalTimestamp, constrainedSize in")
    h.edit("forward.date.mutable", p, "            let titleString: PresentationStrings.FormattedString", "            var titleString: PresentationStrings.FormattedString")
    h.edit("forward.date.suffix", p, "            var currentCredibilityIconImage: UIImage?", r'''            if storyData == nil, let originalTimestamp,
               let suffix = exteralessIdentityForwardDate(timestamp: originalTimestamp, strings: strings, dateTimeFormat: presentationData.dateTimeFormat) {
                if let value = authorString {
                    authorString = value + " · " + suffix
                } else {
                    titleString = PresentationStrings.FormattedString(string: titleString.string + " · " + suffix, ranges: titleString.ranges)
                }
            }
            var currentCredibilityIconImage: UIImage?''')
    h.edit("forward.utf16.ranges", p, "NSRange(location: leftPart.count, length: peerString.count)", "NSRange(location: leftPart.utf16.count, length: peerString.utf16.count)", 2)
    for folder in ["ChatMessageAnimatedStickerItemNode", "ChatMessageBubbleItemNode", "ChatMessageInteractiveInstantVideoNode", "ChatMessageInstantVideoItemNode", "ChatMessageStickerItemNode"]:
        p = PREFIX + f"TelegramUI/Components/Chat/{folder}/Sources/{folder}.swift"
        h.edit("forward.date." + folder, p, "forwardPsaType, nil, CGSize(width:", "forwardPsaType, nil, item.message.forwardInfo?.date, CGSize(width:")
        if folder == "ChatMessageBubbleItemNode":
            h.edit("forward.date.story.exclusion", p, "ChatMessageForwardInfoNode.StoryData(storyType: storyType), CGSize(width:", "ChatMessageForwardInfoNode.StoryData(storyType: storyType), nil, CGSize(width:")


def activity(h):
    h.add("activity.marker.image", PREFIX + "TelegramPresentationData/Sources/ExteralessIdentityActivity.swift", '''import ExteralessCore
import Foundation
import UIKit

/// Recolors only the existing native dot's interior, preserving the row's
/// highlighted/pinned outline and the Appearance-owned marker geometry.
public func exteralessIdentityActivityImage(_ image: UIImage?, band: IdentityActivityBand?) -> UIImage? {
    guard let image, let band else { return image }
    let color: UIColor
    switch band {
    case .online: return image
    case .within15Minutes: color = UIColor(red: 234.0 / 255.0, green: 234.0 / 255.0, blue: 30.0 / 255.0, alpha: 1)
    case .within30Minutes: color = UIColor(red: 234.0 / 255.0, green: 132.0 / 255.0, blue: 30.0 / 255.0, alpha: 1)
    case .withinHour: color = UIColor(red: 234.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0, alpha: 1)
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = image.scale
    return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
        image.draw(at: .zero)
        color.setFill()
        UIBezierPath(ovalIn: CGRect(origin: .zero, size: image.size).insetBy(dx: 2, dy: 2)).fill()
    }
}
''')
    p = PREFIX + "ChatListUI/Sources/Node/ChatListItem.swift"
    h.edit("activity.node.state", p, "    private var onlineIsVoiceChat: Bool = false", "    private var onlineIsVoiceChat: Bool = false\n    private var identityActivityBand: IdentityActivityBand?")
    h.edit("activity.measure.state", p, "            var onlineIsVoiceChat = false", "            var onlineIsVoiceChat = false\n            var identityActivityBand: IdentityActivityBand?")
    h.edit("activity.observed.presence", p, "                            let relativeStatus = relativeUserPresenceStatus(updatedPresence, relativeTo: timestamp)", "                            let relativeStatus = relativeUserPresenceStatus(updatedPresence, relativeTo: timestamp)\n                            identityActivityBand = exteralessIdentityActivityBand(account: item.context.account, peer: .user(peer), presence: updatedPresence, locallyOnline: presence.lastActivity > 0 && Int64(presence.lastActivity) + 30 >= Int64(timestamp), now: Int64(timestamp))")
    h.edit("activity.marker.visibility", p, "let (onlineLayout, onlineApply) = onlineLayout(online, onlineIsVoiceChat)", "let (onlineLayout, onlineApply) = onlineLayout(online || identityActivityBand != nil, onlineIsVoiceChat)")
    h.edit("activity.apply.state", p, "                    strongSelf.onlineIsVoiceChat = onlineIsVoiceChat", "                    strongSelf.onlineIsVoiceChat = onlineIsVoiceChat\n                    strongSelf.identityActivityBand = identityActivityBand")
    h.edit("activity.regular.image", p, "strongSelf.onlineNode.setImage(onlineIcon, color: item.presentationData.theme.list.itemCheckColors.foregroundColor, transition: .immediate)", "strongSelf.onlineNode.setImage(exteralessIdentityActivityImage(onlineIcon, band: identityActivityBand), color: item.presentationData.theme.list.itemCheckColors.foregroundColor, transition: .immediate)")
    h.edit("activity.highlight.image", p, "self.onlineNode.setImage(PresentationResourcesChatList.recentStatusOnlineIcon(item.presentationData.theme, state: .highlighted, voiceChat: self.onlineIsVoiceChat), color: nil, transition: transition)", "self.onlineNode.setImage(exteralessIdentityActivityImage(PresentationResourcesChatList.recentStatusOnlineIcon(item.presentationData.theme, state: .highlighted, voiceChat: self.onlineIsVoiceChat), band: self.identityActivityBand), color: nil, transition: transition)")
    h.edit("activity.unhighlight.image", p, "self.onlineNode.setImage(onlineIcon, color: nil, transition: transition)", "self.onlineNode.setImage(exteralessIdentityActivityImage(onlineIcon, band: self.identityActivityBand), color: nil, transition: transition)")
    h.edit("activity.autoremove.badge", p, "                    if online {", "                    if online || identityActivityBand != nil {")


DATE_HEADER_TEXT = r'''private func exteralessIdentityDateHeaderText(localTimestamp: Int32, scheduled: Bool, presentationData: ChatPresentationData) -> String {
    if scheduled && localTimestamp == scheduleWhenOnlineTimestamp { return presentationData.strings.ScheduledMessages_ScheduledOnline }
    let now = Date()
    // Header IDs are local civil days encoded as UTC. Do not shift them twice.
    let nowCivil = now.addingTimeInterval(Double(TimeZone.current.secondsFromGMT(for: now)))
    let date = Date(timeIntervalSince1970: Double(localTimestamp))
    let utc = TimeZone(secondsFromGMT: 0)!
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = utc
    let components = gregorian.dateComponents([.year, .month, .day], from: date)
    let today = gregorian.isDate(date, inSameDayAs: nowCivil)
    var text: String
    if today {
        text = presentationData.strings.Weekday_Today
    } else if let converted = presentationData.dateTimeFormat.identityCalendar.persianText(for: date,
        style: .monthDay(includeYear: !presentationData.dateTimeFormat.identityCalendar.sameYear(date, nowCivil, timeZone: utc)), timeZone: utc) {
        text = converted
    } else if gregorian.isDate(date, equalTo: nowCivil, toGranularity: .year) {
        text = presentationData.strings.Date_ChatDateHeader(monthAtIndex((components.month ?? 1) - 1, strings: presentationData.strings), String(components.day ?? 1)).string
    } else {
        text = presentationData.strings.Date_ChatDateHeaderYear(monthAtIndex((components.month ?? 1) - 1, strings: presentationData.strings), String(components.day ?? 1), String(components.year ?? 1970)).string
    }
    if scheduled { text = today ? presentationData.strings.ScheduledMessages_ScheduledToday : presentationData.strings.ScheduledMessages_ScheduledDate(text).string }
    return text
}

'''


def date_headers(h):
    p = PREFIX + "TelegramUI/Components/Chat/ChatMessageItemImpl/Sources/ChatMessageDateHeader.swift"
    h.edit("dates.header.formatter", p, "private final class ChatMessageDateContentNode: ASDisplayNode {", DATE_HEADER_TEXT + "private final class ChatMessageDateContentNode: ASDisplayNode {")
    h.edit("dates.header.state", p, "    private var text: String\n    \n    init(presentationData: ChatPresentationData, controllerInteraction: ChatControllerInteraction?, localTimestamp: Int32, scheduled: Bool)", "    private var text: String\n    private let localTimestamp: Int32\n    private let scheduled: Bool\n    \n    init(presentationData: ChatPresentationData, controllerInteraction: ChatControllerInteraction?, localTimestamp: Int32, scheduled: Bool)")
    h.edit("dates.header.init.state", p, "init(presentationData: ChatPresentationData, controllerInteraction: ChatControllerInteraction?, localTimestamp: Int32, scheduled: Bool) {\n        self.presentationData = presentationData", "init(presentationData: ChatPresentationData, controllerInteraction: ChatControllerInteraction?, localTimestamp: Int32, scheduled: Bool) {\n        self.localTimestamp = localTimestamp\n        self.scheduled = scheduled\n        self.presentationData = presentationData")
    start = "        let nowTimestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)\n        \n        var t: time_t = time_t(localTimestamp)"
    def text(_):
        return "        let text = exteralessIdentityDateHeaderText(localTimestamp: localTimestamp, scheduled: scheduled, presentationData: presentationData)\n"
    h.region("dates.header.initial.text", p, start, "        self.text = text", text)
    start = "    func updatePresentationData(_ presentationData: ChatPresentationData, context: AccountContext) {"
    def refresh(text):
        old = "        self.presentationData = presentationData"
        assert text.count(old) == 1
        text = text.replace(old, old + "\n        self.text = exteralessIdentityDateHeaderText(localTimestamp: self.localTimestamp, scheduled: self.scheduled, presentationData: presentationData)")
        return text.replace("if presentationData.fontSize != previousPresentationData.fontSize {", "if presentationData.fontSize != previousPresentationData.fontSize || presentationData.dateTimeFormat != previousPresentationData.dateTimeFormat {")
    h.region("dates.header.live.refresh", p, start, "    func updateBackgroundColor(", refresh, after="private final class ChatMessageDateContentNode: ASDisplayNode {")
    h.edit("dates.header.historical.timezone", p, "        return ((timestamp + timezoneOffset) / (granularity)) * (granularity)", "        let offset = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: Double(timestamp)))\n        let civil = Int64(timestamp) + Int64(offset)\n        return Int32(clamping: Int64(floor(Double(civil) / Double(granularity))) * Int64(granularity))")
    h.edit("dates.header.remove.static.timezone", p, """private let timezoneOffset: Int32 = {
    let nowTimestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
    var now: time_t = time_t(nowTimestamp)
    var timeinfoNow: tm = tm()
    localtime_r(&now, &timeinfoNow)
    return Int32(timeinfoNow.tm_gmtoff)
}()

""", "")


def build_hunks(scope="all", files=None):
    h = Hunks(scope=scope, files=files)
    composition(h)
    presentation(h)
    names(h)
    profile(h)
    premium(h)
    avatar(h)
    dates(h)
    activity(h)
    date_headers(h)
    return h


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--scope", choices=["all", "allowed", "remaining"], default="all")
    parser.add_argument("--file", action="append")
    parser.add_argument("--tool-patch", action="store_true")
    args = parser.parse_args()
    h = build_hunks(scope=args.scope, files=args.file)
    if args.check:
        print(json.dumps({"files": len(h.modified), "anchors": len(h.anchors), "working_tree_written": False, "insertions": h.anchors}, indent=2))
    elif args.tool_patch:
        print(h.tool_patch(), end="")
    else:
        print(h.diff(), end="")


if __name__ == "__main__":
    main()
