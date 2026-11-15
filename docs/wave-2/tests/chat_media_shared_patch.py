"""Read-only, fail-on-drift shared-owner patch generator for CMC-03/04/09/10.

It never writes shared files. stdout is an ordinary git patch for the coordinator.
The native Forward transformation wraps existing bodies, including other owners'
comment/sound fixes, instead of carrying an obsolete copy of that implementation.
"""
from __future__ import annotations

import argparse
import difflib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def replace(text: str, old: str, new: str, count: int = 1) -> str:
    actual = text.count(old)
    if actual != count:
        raise ValueError(f"shared source drift: wanted {count}, found {actual}: {old[:100]!r}")
    return text.replace(old, new)


def closing_brace(text: str, start: int) -> int:
    depth, i = 0, start
    while i < len(text):
        if text.startswith("//", i):
            i = text.index("\n", i)
        elif text.startswith("/*", i):
            i = text.index("*/", i + 2) + 2
        elif text[i] == '"':
            i += 1
            while i < len(text):
                if text[i] == "\\":
                    i += 2
                elif text[i] == '"':
                    i += 1
                    break
                else:
                    i += 1
        else:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    return i
            i += 1
    raise ValueError("unclosed Swift closure")


def wrap(text: str, needle: str, operation: str, extra: str = "") -> str:
    if text.count(needle) != 1:
        raise ValueError(f"shared closure drift: {needle!r}")
    at = text.index(needle)
    opening = text.index("{", at)
    first_line = text.index("\n", opening)
    end = closing_brace(text, opening)
    indent = text[text.rfind("\n", 0, at) + 1:at]
    body = text[first_line + 1:end].rstrip()
    body = "\n".join("    " + line.rstrip() if line.strip() else "" for line in body.splitlines())
    prefix = indent + f"    exteralessForwardAdmission(context: context, access: exportAccess, operation: .{operation}) {{\n"
    if extra:
        prefix += indent + "        " + extra + "\n"
    return text[:first_line + 1] + prefix + body + "\n" + indent + "    }\n" + indent + text[end:]


def gallery(text: str) -> str:
    text = replace(text, "    private var inheritedExportPermit: ExteralessContentExportPermit?\n", """    private var inheritedExportPermit: ExteralessContentExportPermit?
    private let exteralessActionLifetime = ExteralessGalleryActionLifetime()
    private var exteralessActionPeerProtected = false

    override func didExitHierarchy() {
        super.didExitHierarchy()
        self.exteralessActionLifetime.invalidate()
    }
""")
    text = replace(text, """        self.currentMessage = message
        self.mediaSubject = mediaSubject
""", """        let previousMedia = self.currentMessage.flatMap { selectedMediaForMessage(message: $0, mediaSubject: self.mediaSubject) }
        let selectedMedia = selectedMediaForMessage(message: message, mediaSubject: mediaSubject)
        if self.currentMessage?.stableId != message.stableId || self.currentMessage?.stableVersion != message.stableVersion || self.currentMessage?.id != message.id || self.mediaSubject != mediaSubject || self.exteralessActionPeerProtected != peerIsCopyProtected || previousMedia.flatMap({ old in selectedMedia.map { old.isEqual(to: $0) } }) != true {
            self.exteralessActionLifetime.invalidate()
        }
        self.exteralessActionPeerProtected = peerIsCopyProtected
        self.currentMessage = message
        self.mediaSubject = mediaSubject
""")
    text = replace(text, "    func setWebPage(_ webPage: TelegramMediaWebpage, media: EngineRawMedia) {\n", "    func setWebPage(_ webPage: TelegramMediaWebpage, media: EngineRawMedia) {\n        self.exteralessActionLifetime.invalidate()\n")
    start = text.index("    @objc func actionButtonPressed() {")
    end = text.index("    private func exteralessNativeSharePressed(", start)
    text = text[:start] + """    @objc func actionButtonPressed() {
        guard self.exportAllowed(.presentation) else { return }
        if let message = self.currentMessage, let interaction = self.controllerInteraction, self.buttonsState?.displayActionButton == true {
            let generation = self.exteralessActionLifetime.generation
            let subject = self.mediaSubject
            let item = interaction.currentItemNode()
            let playerIdentity = (item as? UniversalVideoGalleryItemNode)?.exteralessImageActionPlayerIdentity
            let selection = ExteralessGalleryMediaSelection(message: EngineMessage(message), subject: subject, itemGeneration: generation)
            let current: () -> Bool = { [weak self, weak item] in
                guard let self, let item else { return false }
                return self.exteralessActionLifetime.generation == generation && self.currentMessage?.id == message.id && self.currentMessage?.stableId == message.stableId && self.currentMessage?.stableVersion == message.stableVersion && self.mediaSubject == subject && interaction.currentItemNode() === item && (item as? UniversalVideoGalleryItemNode)?.exteralessImageActionPlayerIdentity == playerIdentity && self.view.window != nil && self.exportAllowed(.presentation)
            }
            let request = ExteralessGalleryMessageActionRequest(context: self.context, message: EngineMessage(message), selection: selection, itemGeneration: generation, playbackSample: { [weak item] in
                guard current() else { return nil }
                return (item as? UniversalVideoGalleryItemNode)?.exteralessImageActionPlaybackSample
            }, exportPermit: self.exportPermit, itemValidity: self.exteralessActionLifetime.validity(of: generation), interaction: interaction, isCurrent: current, nativeShare: { [weak self] permit, prepare in
                guard current() else { return }
                self?.exteralessNativeSharePressed(selection: selection, providedPermit: permit, prepareShare: prepare)
            }, setDisposable: { [weak self] in self?.messageContextDisposable.set($0) }, setInteracting: { [weak self] in self?.interacting?($0) })
            if MainActor.assumeIsolated({ ExteralessGalleryMessageActions.present?(request) ?? false }) { return }
        }
        self.exteralessNativeSharePressed()
    }

""" + text[end:]
    text = replace(text, """    private func exteralessNativeSharePressed(providedPermit: ExteralessContentExportPermit? = nil, prepareShare: ((ViewController) -> Bool)? = nil) {
        let inheritedPermit = self.exportPermit
        if let inheritedPermit, let providedPermit, inheritedPermit !== providedPermit { return }
        let permit = providedPermit ?? inheritedPermit
        let accountId = self.context.account.id.int64
        guard self.exportAllowed(.exportPreparation), permit?.allows(accountId: accountId, operation: .exportPreparation) ?? true else { return }
""", """    private func exteralessNativeSharePressed(selection: ExteralessGalleryMediaSelection? = nil, providedPermit: ExteralessContentExportPermit? = nil, prepareShare: ((ViewController) -> Bool)? = nil) {
        // CMC never replaces a nonnil FU-02 permit. Ordinary native calls retain
        // their existing group/share semantics; the CMC action names one medium.
        let inheritedPermit = self.exportPermit
        if let inheritedPermit, let providedPermit, inheritedPermit !== providedPermit { return }
        let permit = providedPermit ?? inheritedPermit
        let accountId = self.context.account.id.int64
        guard self.exportAllowed(.exportPreparation), permit?.allows(accountId: accountId, operation: .exportPreparation) ?? true else { return }
        if let selection {
            guard let permit, let id = self.currentMessage?.id, let prepareShare,
                  permit.allows(accountId: accountId, messageIds: [id], operation: .exportPreparation) else { return }
            let generation = selection.itemGeneration
            let _ = (permit.guardSignal(accountId: accountId, messageIds: [id], operation: .exportPreparation, {
                self.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: id))
            }) |> deliverOnMainQueue).startStandalone(next: { [weak self] current in
                guard let self, let current, self.exteralessActionLifetime.generation == generation,
                      let reference = selection.reference(in: current), permit.allows(accountId: accountId, messageIds: [id], operation: .exportPreparation) else { return }
                let controller = self.context.sharedContext.makeShareScreen(context: self.context, params: ShareControllerParams(subject: .media(reference, self.shareMediaParameters?()), preferredAction: .saveToCameraRoll, dismissed: { [weak self] _ in self?.interacting?(false) }))
                self.interacting?(true)
                self.presentRootShare(controller, permit: permit, prepareShare: prepareShare)
            })
            return
        }
""")
    return text


def forward(text: str) -> str:
    text = replace(text, "    func forwardMessages(messages: [EngineRawMessage], options: ChatInterfaceForwardOptionsState? = nil, resetCurrent: Bool) {\n", "    func forwardMessages(messages: [EngineRawMessage], options: ChatInterfaceForwardOptionsState? = nil, resetCurrent: Bool, exportAccess: ExteralessChatExportAccess? = nil) {\n        let context = self.context\n")
    text = replace(text, "enqueueMessages(account: strongSelf.context.account, peerId: peer.id, messages: peerMessages)", "exteralessForwardExportSignal(context: context, access: exportAccess, { enqueueMessages(account: strongSelf.context.account, peerId: peer.id, messages: peerMessages) })")
    text = replace(text, "enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: mappedMessages)", "exteralessForwardExportSignal(context: context, access: exportAccess, { enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: mappedMessages) })")
    text = replace(text, "strongSelf.presentScheduleTimePicker(completion:", "strongSelf.exteralessForwardSchedulePicker(access: exportAccess, completion:")
    text = replace(text, "strongSelf.present(controller, in: .window(.root))", "exteralessPresentForwardController(context: context, access: exportAccess, controller: controller, from: strongSelf)")
    text = replace(text, "self.effectiveNavigationController?.pushViewController(controller)", "exteralessPresentForwardController(context: context, access: exportAccess, controller: controller, from: self, push: true)")
    start = text.index("ChatInterfaceState.update(engine: strongSelf.context.engine, peerId: peerId, threadId: threadId, {")
    opening = text.index("{", start)
    end = closing_brace(text, opening) + 1
    assert text[end] == ")"
    original = text[start:end + 1]
    text = text[:start] + "exteralessForwardExportSignal(context: context, access: exportAccess, { " + original + " })" + text[end + 1:]
    text = wrap(text, "let proceed: (ChatController) -> Void = { chatController in", "presentation", "guard exportAccess?.handoff(to: chatController) ?? true else { return }")
    text = replace(text, """                                    if !isChatPinnedMessages {
                                        maybeChat.updateChatPresentationInterfaceState""", """                                    if !isChatPinnedMessages {
                                        guard exportAccess?.handoff(to: maybeChat) ?? true else { return }
                                        maybeChat.updateChatPresentationInterfaceState""")
    text = wrap(text, "let commit: ([EnqueueMessage]) -> Void = { result in", "exportEffect", "exportAccess?.commitSelection()")
    text = wrap(text, "let proceed = { [weak self, weak controller] in", "exportPreparation", "exportAccess?.expectCoverDismissal()")
    text = wrap(text, "controller.peerSelected = { [weak self, weak controller] peer, threadId in", "exportEffect", "exportAccess?.commitSelection()")
    text = wrap(text, "controller.multiplePeersSelected = { [weak self, weak controller] peers, peerMap, messageText, mode, forwardOptions, _ in", "exportPreparation")
    # This closure comes after the optional recording-discard confirmation.
    text = wrap(text, "let _ = self.presentVoiceMessageDiscardAlert(action: { [weak self] in", "exportPreparation")
    return text


def tests(text: str) -> str:
    if 'name = "ExteralessChatMediaTestsLib"' in text:
        raise ValueError("test target already integrated")
    return text.rstrip() + """

swift_library(
    name = "ExteralessChatMediaTestsLib",
    testonly = True,
    module_name = "ExteralessChatMediaTests",
    srcs = glob(["Tests/ChatMedia/*.swift"], allow_empty = False),
    copts = ["-swift-version", "6"],
    deps = [
        ":TelegramUI",
        "//submodules/AccountContext:AccountContext",
        "//submodules/Display:Display",
        "//submodules/GalleryUI:GalleryUI",
        "//submodules/MediaPlayer:MediaPlayer",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//third-party/exteraless:ExteralessCore",
    ],
)

ios_unit_test(
    name = "ExteralessChatMediaTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = "//Tests/Exteraless:Runner",
    test_host = "//Tests/Exteraless:NativeTestHost",
    linkopts = ["-framework", "MediaPlayer"],
    deps = [":ExteralessChatMediaTestsLib"],
    visibility = ["//visibility:public"],
)
"""


def test_suite(text: str) -> str:
    return replace(text, '        "//submodules/TelegramUI:ExteralessAINativeTests",\n', '        "//submodules/TelegramUI:ExteralessAINativeTests",\n        "//submodules/TelegramUI:ExteralessChatMediaTests",\n')


def test_manifest(text: str) -> str:
    value = json.loads(text)
    value["required_sources"]["submodules/TelegramUI/Tests/ChatMedia/ChatMediaRemediationNativeTests.swift"] = "//submodules/TelegramUI:ExteralessChatMediaTests"
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--part", choices=["gallery", "forward", "tests", "all"], default="all")
    parser.add_argument("--check", action="store_true", help="validate anchors and report sizes; emit no patch")
    parser.add_argument("--verify", action="store_true", help="also run git apply --check on generated bytes, without editing files")
    args = parser.parse_args()
    transforms = [
        ("gallery", "telegram-ios/submodules/GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift", gallery),
        ("forward", "telegram-ios/submodules/TelegramUI/Sources/ChatControllerForwardMessages.swift", forward),
        ("tests", "telegram-ios/submodules/TelegramUI/BUILD", tests),
        ("tests", "telegram-ios/Tests/Exteraless/BUILD", test_suite),
        ("tests", "telegram-ios/Tests/Exteraless/native-tests.json", test_manifest),
    ]
    patches = []
    for part, name, transform in transforms:
        if args.part not in (part, "all"):
            continue
        before = (ROOT / name).read_text(encoding="utf-8")
        after = transform(before)
        diff = "".join(difflib.unified_diff(before.splitlines(keepends=True), after.splitlines(keepends=True), fromfile="a/" + name, tofile="b/" + name))
        patches.append(diff)
        if args.check or args.verify:
            print(json.dumps({"part": part, "path": name, "before_lines": len(before.splitlines()), "after_lines": len(after.splitlines()), "patch_lines": len(diff.splitlines())}))
        else:
            print(diff, end="")
    if args.verify:
        subprocess.run(["git", "apply", "--check", "--whitespace=error", "-"], input="".join(patches).encode("utf-8"), cwd=ROOT, timeout=25, check=True)
        print("PASS: generated shared patch passes git apply --check; no shared file edited")


if __name__ == "__main__":
    main()
