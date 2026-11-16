"""Explicit Avatar/Composer evidence; no renderer, simulator launch or model substitute."""

import hashlib
import math
from pathlib import Path
import re
import shutil
import struct
from client_ui_control_frames import MATH_PROBES, validate_control_probes

VISUAL_SCENARIOS = ("avatar-render", "composer-render")
BUILD_SELECTION = {"bundle": "org.exteraless.ClientUIHarness", "target": "//Telegram:ClientUIHarness",
                   "host": "same-client-ui-app"}
AVATAR_STEPS = ("legacy", "v2-pending", "v2", "bubble-60", "bubble-38", "bubble-100", "letters", "blank",
                "override", "active-fade-reset", "v2-return") + tuple(
                    f"forum-{corners}-{radius}" for corners in (0, 14, 28) for radius in ("native", "unified"))
PROBES = {
    "avatar-render": ["home"] + [f"avatar-{palette}-{step}" for palette in ("light", "dark") for step in AVATAR_STEPS] + ["avatar-cleanup"],
    "composer-render": ["home", *MATH_PROBES, "composer-rich-light", "composer-date-selected", "composer-date-added",
                        "composer-date-add-undone", "composer-date-removed", "composer-date-remove-undone",
                        "composer-cell-selected", "composer-cell-mentioned", "composer-cell-undone",
                        "composer-code-pasted", "composer-code-undone", "composer-rich-dark", "composer-cleanup"],
}
COMMON_SOURCES = (
    "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessReadiness.swift",
    "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessLocalImages.swift",
    "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessVisualArtifacts.swift",
    "telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/RetentionReadiness.swift",
)
VISUAL_SOURCES = {
    "avatar-render": (
        "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessAvatar.swift",
        "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessAvatarInputs.swift",
        "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessAvatarCrossfade.swift",
        "telegram-ios/submodules/AvatarNode/Sources/AvatarNode.swift",
        "telegram-ios/submodules/AvatarNode/Sources/PeerAvatar.swift",
        "telegram-ios/submodules/AvatarNode/Sources/ExteralessAvatarShape.swift",
        "telegram-ios/submodules/DirectMediaImageCache/Sources/DirectMediaImageCache.swift",
        "telegram-ios/submodules/Display/Source/ImageNode.swift",
        "telegram-ios/submodules/Display/Source/DisplayLinkDispatcher.swift",
        "swift/ExteralessCore/Sources/ExteralessCore/AppearancePolicy.swift",
        "swift/ExteralessCore/Sources/ExteralessCore/AppearanceFeatures.swift",
    ),
    "composer-render": (
        "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessConfigurationControls.swift",
        "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessComposer.swift",
        "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessComposerHost.swift",
        "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessComposerInteraction.swift",
        "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessComposerVisualFactory.swift",
        "telegram-ios/submodules/TelegramUI/Sources/ChatInterfaceStateInputPanels.swift",
        "telegram-ios/submodules/TelegramUI/Sources/PastedMarkdownConversion.swift",
        "telegram-ios/submodules/TelegramCore/Sources/ChatInputContent/ChatInputContentModel.swift",
        "telegram-ios/submodules/ChatPresentationInterfaceState/Sources/ChatPanelInterfaceInteraction.swift",
        "telegram-ios/submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift",
        "telegram-ios/submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ExteralessChatInputHelpers.swift",
        "telegram-ios/submodules/TelegramUI/Components/Chat/ChatRichTextEditorComposer/Sources/RichTextEditorChatInputNode.swift",
        "telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView.swift",
        "telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView+Clipboard.swift",
        "telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView+Selection.swift",
        "telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView+GlobalPositions.swift",
        "telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView+UndoStack.swift",
        "telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEngineEditorView+SurfaceGate.swift",
        "telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEngineEditor/RichTextEditorProtocol.swift",
        "telegram-ios/submodules/TelegramUI/Components/RichTextEditor/Sources/RichTextEditorCore/Model/DocumentFragment.swift",
        "telegram-ios/submodules/TelegramUI/Components/RichTextEditorMediaView/Sources/MediaItemNodeView.swift",
        "telegram-ios/submodules/TelegramUI/Components/RichTextEditorMediaView/Sources/RichTextMediaContentComponent.swift",
    ),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_visual_sources(manifest, scenarios):
    files = manifest.get("files", {})
    for scenario in scenarios:
        if scenario in VISUAL_SCENARIOS:
            missing = set(COMMON_SOURCES + VISUAL_SOURCES[scenario]) - set(files)
            require(not missing, "Missing compiled visual-family source inputs: " + ", ".join(sorted(missing)))


def artifact_entries(state):
    entries = state.get("facts", {}).get("visualArtifacts", [])
    require(isinstance(entries, list) and 0 < len(entries) <= 96, "Missing/excessive native visual artifacts")
    paths = set()
    for entry in entries:
        path = entry.get("path", "")
        require(isinstance(path, str) and re.fullmatch(r"native/[a-z0-9-]+\.png", path) and path not in paths,
                "Invalid/duplicate native artifact handle")
        paths.add(path)
        require(isinstance(entry.get("sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]), "Invalid native artifact SHA")
        require(0 < entry.get("bytes", 0) <= 4 * 1024 * 1024 and entry.get("width", 0) > 0 and entry.get("height", 0) > 0,
                "Invalid native artifact dimensions/size")
    return entries


def copy_visual_artifacts(state, source, destination):
    """Copy only reported PNG handles, never an account directory or other app data."""
    for entry in artifact_entries(state):
        path = Path(source) / entry["path"]
        require(not path.is_symlink() and not path.parent.is_symlink() and path.is_file(), "Native PNG missing or indirect")
        require(path.stat().st_size == entry["bytes"], "Native PNG size changed")
        data = path.read_bytes()
        require(data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24, "Native artifact is not a PNG")
        require(struct.unpack(">II", data[16:24]) == (entry["width"], entry["height"]), "Native PNG dimensions changed")
        require(hashlib.sha256(data).hexdigest() == entry["sha256"], "Native PNG fingerprint mismatch")
        target = Path(destination) / entry["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)


def validate_visual(state, scenario):
    require([probe.get("name") for probe in state.get("probes", [])] == PROBES[scenario], "Missing/reordered final visual probes")
    facts = state.get("facts", {})
    require(state.get("pythonRequested") is False, "Final visual scenarios must use native local input")
    check_visual_sources(facts.get("domainSources", {}), (scenario,))
    require(all(facts.get("buildSelection", {}).get(key) == value for key, value in BUILD_SELECTION.items()),
            "Avatar/Composer evidence belongs to a different app/build host")
    readiness = facts.get("readiness", {})
    require(readiness.get("authorizedAfterNativeBarrier") is True and readiness.get("retryCount") == 0
            and readiness.get("configurationVersion", 0) > 0
            and readiness.get("failureRoute") == "ExteralessAccountRecoveryCenter.pending/currentStatus",
            "PFR typed native readiness/failure route was not installed")
    family = facts.get("visualFamily", {})
    require(family.get("name") == scenario and family.get("realNativeRenderer") is True and family.get("cleanup") is True,
            "Native visual family did not finish cleanup")
    artifacts = {entry["path"] for entry in artifact_entries(state)}
    probes = {probe["name"]: probe for probe in state["probes"]}
    for name in PROBES[scenario][1:-1]:
        require(probes[name].get("semantic", {}).get("nativeViewImage") in artifacts, "Probe has no actual native-view PNG: " + name)
    if scenario == "avatar-render":
        validate_avatar(probes, family, artifacts)
    else:
        validate_composer(probes, family)
        validate_control_probes(state['probes'], scenario)


def validate_avatar(probes, family, artifacts):
    require(family.get("cache") == "DirectMediaImageCache" and family.get("activeFadeResets") == 2, "Actual cache/active fade sequence missing")
    requests, deliveries = family.get("cacheRequests", []), family.get("deliveries", [])
    require(len(requests) >= 10 and all(item.get("nativeCacheHit") is True for item in requests), "Avatar did not use prewarmed native cache hits")
    require(len(deliveries) == 10 and all(item == {"starts": 1, "cancellations": 1} for item in deliveries), "Avatar pending subscriptions leaked")
    instance = family.get("avatarInstance")
    require(isinstance(instance, int) and instance > 0, "Missing actual AvatarNode identity")
    for palette in ("light", "dark"):
        prefix = "avatar-" + palette + "-"
        for step in AVATAR_STEPS:
            require(probes[prefix + step].get("dark") is (palette == "dark"), "Avatar palette did not match its probe")
        for step in AVATAR_STEPS[:11]:
            value = probes[prefix + step]["semantic"]
            value = value["avatar"] if step == "active-fade-reset" else value
            require(value.get("instance") == instance and "AvatarNode" in value.get("renderer", ""), "Avatar backend switch replaced the native node")
        for step in ("legacy", "letters", "blank", "override"):
            value = probes[prefix + step]["semantic"]
            require(value.get("parentRaster") is True and value.get("childRaster") is False, "Old child bitmap covers Avatar letters")
        pending = probes[prefix + "v2-pending"]["semantic"]
        require(pending.get("parentRaster") is False and pending.get("childRaster") is False and pending.get("displaySuspended") is True,
                "V2 pending retained stale legacy raster")
        for step in ("v2", "v2-return"):
            value = probes[prefix + step]["semantic"]
            require(value.get("parentRaster") is False and value.get("childRaster") is True and value.get("cornerRadius") == 30,
                    "V2 failed to replace/reset the current image backend")
        for side in (60, 38, 100):
            value = probes[prefix + f"bubble-{side}"]["semantic"]
            require(value.get("mask") == "appearance.avatar.bubbleClip" and value.get("cornerRadius") == 0 and value.get("size") == [side, side],
                    "Bubble has an old corner backend or stale size")
        fade = probes[prefix + "active-fade-reset"]["semantic"]
        require(fade.get("beforeImage") in artifacts and fade.get("afterImage") in artifacts, "Active fade before/after pixels missing")
        events = {item.get("name"): item for item in fade.get("events", [])}
        require(set(events) == {"fade-installed", "active-frame-1", "active-frame-2", "reset-to-letters", "letters-presented"},
                "ASC01 display-frame sequence incomplete")
        start, first, second, reset = (events[name] for name in ("fade-installed", "active-frame-1", "active-frame-2", "reset-to-letters"))
        opacity = first.get("presentationOpacity")
        require(start.get("emissionsAfterSetSignalReturn") == 2 and isinstance(opacity, (float, int)) and 0 < opacity <= 1,
                "ASC01 did not expose an already-presented old bitmap")
        require(first["displayTimestamp"] < second["displayTimestamp"] and reset.get("afterDisplayFrames") == 2
                and 0 < reset["mediaTime"] - start["mediaTime"] < 0.2, "ASC01 waited for the fade to finish instead of resetting at frame two")
        require(reset.get("oldBitmapReleased") is True and reset.get("oldLayerDetached") is True, "ASC01 retired bitmap/layer survived reset")
        for corners in (0, 14, 28):
            for radius in ("native", "unified"):
                value = probes[prefix + f"forum-{corners}-{radius}"]["semantic"]
                pairs = value.get("comparisons", [])
                require(value.get("corners") == corners and value.get("singleRadius") is (radius == "unified") and len(pairs) == 2
                        and [item.get("forum") for item in pairs] == [False, True]
                        and all(item.get("photoAlpha") == item.get("fallbackAlpha") and re.fullmatch(r"[0-9a-f]{64}", item.get("photoAlpha", "")) for item in pairs),
                        "Native complete-image forum/photo/letters contour evidence differs")
                require((pairs[0]["photoAlpha"] == pairs[1]["photoAlpha"]) == (corners == 0 or radius == "unified"),
                        "Regular/forum native contour distinction was lost")
    require(probes["avatar-cleanup"]["semantic"].get("attached") is False, "Avatar stayed attached")


def validate_composer(probes, family):
    states = {name: probe["semantic"] for name, probe in probes.items() if name not in ("home", "composer-cleanup")}
    base = states["composer-rich-light"]
    require("RichTextEngineEditorView" in family.get("backend", "") and family.get("parserCallsDuringLiteralPaste") == 0,
            "Composer used another backend or transformed literal code")
    require(base.get("mediaBitmaps", 0) > 0 and [block.get("kind") for block in base.get("content", {}).get("blocks", [])] == [0, 0, 6, 4, 3, 1],
            "Real heading/quote/table/local-media/code fixture was not rendered")
    for value in states.values():
        require(value.get("editorInstance") == base.get("editorInstance") and value.get("panelInstance") == base.get("panelInstance")
                and "RichTextEditorChatInputNode" in value.get("renderer", "") and "RichTextEngineEditorView" in value.get("backend", ""),
                "Composer swapped out the production panel/editor")
        require(re.fullmatch(r"[0-9a-f]{64}", value.get("documentSHA256", "")) is not None, "Missing actual native document identity evidence")
    original = base["content"]
    for name in ("composer-date-add-undone", "composer-date-removed", "composer-cell-selected", "composer-cell-undone", "composer-code-undone", "composer-rich-dark"):
        require(states[name]["content"] == original, "Composer undo/appearance lost rich structure: " + name)
    dated = states["composer-date-added"]["content"]
    require(dated != original and states["composer-date-remove-undone"]["content"] == dated, "Date add/remove did not round-trip")
    require(states["composer-date-add-undone"]["documentSHA256"] == base["documentSHA256"]
            and states["composer-date-add-undone"].get("canUndo") is False, "Date was not one native structural undo")
    for changed, target in ((dated, 1), (states["composer-cell-mentioned"]["content"], 3), (states["composer-code-pasted"]["content"], 5)):
        require(len(changed.get("blocks", [])) == 6 and changed["blocks"][target] != original["blocks"][target]
                and all(changed["blocks"][i] == original["blocks"][i] for i in range(6) if i != target), "Composer edit escaped its target block")
    cell_before = original["blocks"][3]["table"]["rows"][0]["cells"]
    cell_after = states["composer-cell-mentioned"]["content"]["blocks"][3]["table"]["rows"][0]["cells"]
    require(cell_after[1:] == cell_before[1:], "Mention mutated an unselected table cell")
    selection = states["composer-cell-selected"]
    require(selection.get("selectedText") == "cell" and selection.get("flatSelection", [0, -1])[1] == 0
            and len(selection.get("globalSelection", [])) == 2 and selection["globalSelection"][1] > selection["globalSelection"][0],
            "Cell selection was flattened or not captured by the native selection API")
    code = states["composer-code-pasted"]["content"]["blocks"][5]["code"]
    require("".join(run["text"] for run in code["runs"]) == "literal: https://example.test/?utm_source=code&keep=1", "Literal code URL bytes changed")
    require(states["composer-cell-undone"]["documentSHA256"] == selection["documentSHA256"]
            and states["composer-code-undone"]["documentSHA256"] == states["composer-cell-undone"]["documentSHA256"], "Native document IDs/structure changed through undo")
    require(probes["composer-rich-light"].get("dark") is False and probes["composer-rich-dark"].get("dark") is True, "Composer palettes not exercised")
    require(probes["composer-cleanup"]["semantic"] == {"attached": False, "firstResponder": False}, "Composer retained its panel/keyboard")


def recorded_frame_index(state, timing, info):
    """Variable-rate PTS in decoder order, including duplicates. Wall times locate
    a bracket, not an exact PTS; the reviewer resolves the visible transition."""
    frames = []
    for index, raw in enumerate(info.get("frames", [])):
        timestamp = raw.get("pts_time")
        if timestamp in (None, "N/A"):
            timestamp = raw.get("best_effort_timestamp_time")
        pts = float(timestamp)
        require(math.isfinite(pts) and pts >= 0, "Missing/invalid ffprobe frame timestamp")
        frames.append({"index": index, "pts": pts, "frame": f"frames/frames/{index:05d}.png",
                       "sheet": f"frames/sheet-{index // 16 + 1:02d}.png", "tile": index % 16})
    require(len(frames) > 1, "No indexed recorded frames")
    command = timing["recordCommandHostWallTime"]
    observed = timing["recordStartedObservedHostWallTime"]
    require(command <= observed, "Recording acknowledgement precedes its command")

    def locate(wall):
        lower, upper = max(0, wall - observed), max(0, wall - command)
        candidates = {item["index"] for item in frames if lower <= item["pts"] <= upper}
        before = [item["index"] for item in frames if item["pts"] < lower]
        after = [item["index"] for item in frames if item["pts"] > upper]
        if before:
            candidates.add(before[-1])
        if after:
            candidates.add(after[0])
        return {"recordingTimeBracket": [lower, upper], "candidateFrameIndices": sorted(candidates)}

    probes = []
    for index, probe in enumerate(state.get("probes", [])):
        item = {"name": probe["name"], "semantic": f"state.json#/probes/{index}", **locate(probe["wallTime"])}
        semantic = probe.get("semantic", {})
        item["nativeViewImage"] = semantic.get("nativeViewImage")
        if "nativeButtonImage" in semantic:
            item["nativeButtonImage"] = semantic["nativeButtonImage"]
        item["events"] = [{"name": event["name"], **locate(event["wallTime"]),
                           "semantic": f"state.json#/probes/{index}/semantic/events/{event_index}"}
                          for event_index, event in enumerate(semantic.get("events", []))]
        item["activeFadeImages"] = {key: semantic[key] for key in ("beforeImage", "afterImage") if key in semantic}
        probes.append(item)
    return {"format": "exteraless-ui-frame-handles/1", "timestampSource": "ffprobe PTS in decoder order; no index/fps",
            "alignment": "host recording-start bracket; inspect actual frames to resolve the transition",
            "scenario": state["scenario"], "runId": state["runId"], "buildSelection": state["facts"]["buildSelection"],
            "sourceManifestSHA256": state["facts"]["domainSources"]["sha256"], "frames": frames, "probes": probes,
            "artifacts": {"video": "recording.mp4", "timestamps": "ffprobe.json", "metrics": "frames/frames.tsv",
                          "trace": "state.json#/trace", "nativeImages": state["facts"].get("visualArtifacts", [])},
            "visualReview": "pending-recorded-frame-review"}
