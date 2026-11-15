"""Rejection/indexing tests with synthetic metadata, never native/frame evidence."""

import base64
import copy
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "tools/runtime"))
import client_ui_harness as driver
import client_ui_harness_domains as domains
import client_ui_harness_visuals as visual


def avatar_evidence():
    probes = {}
    paths = set()
    for palette in ("light", "dark"):
        for step in visual.AVATAR_STEPS:
            value = {"instance": 17, "renderer": "AvatarNode.AvatarNode", "parentRaster": False, "childRaster": True,
                     "size": [60, 60], "cornerRadius": 30}
            if step in ("legacy", "letters", "blank", "override"):
                value.update(parentRaster=True, childRaster=False)
            if step == "v2-pending":
                value.update(parentRaster=False, childRaster=False, displaySuspended=True)
            if step.startswith("bubble-"):
                side = int(step.split("-")[1])
                value.update(size=[side, side], cornerRadius=0, mask="appearance.avatar.bubbleClip")
            if step.startswith("forum-"):
                _, corners, radius = step.split("-")
                same = corners == "0" or radius == "unified"
                value = {"corners": int(corners), "singleRadius": radius == "unified", "comparisons": [
                    {"forum": False, "photoAlpha": "a" * 64, "fallbackAlpha": "a" * 64},
                    {"forum": True, "photoAlpha": ("a" if same else "b") * 64, "fallbackAlpha": ("a" if same else "b") * 64}]}
            if step == "active-fade-reset":
                before, after = f"native/{palette}-before.png", f"native/{palette}-after.png"
                paths.update((before, after))
                value = {"avatar": value, "beforeImage": before, "afterImage": after, "events": [
                    {"name": "fade-installed", "mediaTime": 12, "emissionsAfterSetSignalReturn": 2},
                    {"name": "active-frame-1", "displayTimestamp": 12.0167, "presentationOpacity": 0.95},
                    {"name": "active-frame-2", "displayTimestamp": 12.0334, "presentationOpacity": 0.87},
                    {"name": "reset-to-letters", "mediaTime": 12.034, "afterDisplayFrames": 2, "oldBitmapReleased": True, "oldLayerDetached": True},
                    {"name": "letters-presented", "displayTimestamp": 12.0668}]}
            probes[f"avatar-{palette}-{step}"] = {"dark": palette == "dark", "semantic": value}
    probes["avatar-cleanup"] = {"semantic": {"attached": False}}
    family = {"cache": "DirectMediaImageCache", "activeFadeResets": 2, "avatarInstance": 17,
              "cacheRequests": [{"nativeCacheHit": True}] * 10, "deliveries": [{"starts": 1, "cancellations": 1}] * 10}
    return probes, family, paths


def composer_evidence():
    original = {"blocks": [{"kind": 0, "paragraph": {"style": "heading"}},
        {"kind": 0, "paragraph": {"text": "date", "underline": True}}, {"kind": 6, "blockQuote": {"text": "Quote"}},
        {"kind": 4, "table": {"rows": [{"cells": [{"text": "cell"}, {"text": "other"}]}]}},
        {"kind": 3, "media": {"localResource": 9200001, "displayWidth": 96}},
        {"kind": 1, "code": {"runs": [{"text": "literal: "}]}}]}
    base = {"content": original, "documentSHA256": "a" * 64, "editorInstance": 2, "panelInstance": 1,
            "renderer": "ChatRichTextEditorComposer.RichTextEditorChatInputNode", "backend": "RichTextEngineEditor.RichTextEngineEditorView",
            "mediaBitmaps": 1, "canUndo": False}
    probes = {name: {"semantic": copy.deepcopy(base)} for name in visual.PROBES["composer-render"][1:-1]}
    dated = copy.deepcopy(original)
    dated["blocks"][1]["paragraph"]["date"] = 1700000000
    for name in ("composer-date-added", "composer-date-remove-undone"):
        probes[name]["semantic"]["content"] = copy.deepcopy(dated)
    probes["composer-cell-selected"]["semantic"].update(selectedText="cell", flatSelection=[20, 0], globalSelection=[34, 38])
    probes["composer-cell-mentioned"]["semantic"]["content"]["blocks"][3]["table"]["rows"][0]["cells"][0]["mention"] = 777001
    probes["composer-code-pasted"]["semantic"]["content"]["blocks"][5]["code"]["runs"][0]["text"] += "https://example.test/?utm_source=code&keep=1"
    probes["composer-rich-light"]["dark"] = False
    probes["composer-rich-dark"]["dark"] = True
    probes["composer-cleanup"] = {"semantic": {"attached": False, "firstResponder": False}}
    return probes, {"backend": base["backend"], "parserCallsDuringLiteralPaste": 0}


class FinalVisualDriverTests(unittest.TestCase):
    def test_third_explicit_batch_keeps_original_three_plus_three_and_quota(self):
        self.assertEqual(driver.SCENARIOS, ("core-light", "core-dark", "sdk-ui"))
        self.assertEqual(domains.DOMAIN_SCENARIOS, ("feed-render", "player-render", "pill-render"))
        self.assertEqual(domains.selected_scenarios(None, driver.SCENARIOS), driver.SCENARIOS)
        self.assertEqual(domains.selected_scenarios(visual.VISUAL_SCENARIOS, driver.SCENARIOS), visual.VISUAL_SCENARIOS)
        for batch in (("avatar-render", "core-light"), ("composer-render", "feed-render"), ("avatar-render",) * 2,
                      driver.SCENARIOS + ("avatar-render",)):
            with self.assertRaises(ValueError):
                domains.selected_scenarios(batch, driver.SCENARIOS)
        for selected in (driver.SCENARIOS, domains.DOMAIN_SCENARIOS, visual.VISUAL_SCENARIOS):
            results = [{"scenario": name, "semanticPassed": True} for name in selected]
            self.assertTrue(domains.complete_batch(selected, results, results))
            self.assertFalse(domains.complete_batch(selected, results[:-1], results))
            self.assertFalse(domains.complete_batch(selected, results, results[:-1]))
        self.assertFalse(domains.complete_batch([], [], []))

    def test_visual_source_preflight_requires_actual_image_node_and_joined_factory(self):
        names = set(visual.COMMON_SOURCES + visual.VISUAL_SOURCES["avatar-render"] + visual.VISUAL_SOURCES["composer-render"])
        manifest = {"files": dict.fromkeys(names, "a" * 64)}
        visual.check_visual_sources(manifest, visual.VISUAL_SCENARIOS)
        for suffix in ("/Display/Source/ImageNode.swift", "/ExteralessComposerVisualFactory.swift", "/RetentionReadiness.swift"):
            bad = copy.deepcopy(manifest)
            del bad["files"][next(name for name in names if name.endswith(suffix))]
            with self.assertRaises(ValueError):
                visual.check_visual_sources(bad, visual.VISUAL_SCENARIOS)

    def test_active_fade_rejects_completed_animation_or_only_model_opacity(self):
        probes, family, paths = avatar_evidence()
        visual.validate_avatar(probes, family, paths)
        for field, changed in (("presentationOpacity", 0), ("presentationOpacity", None), ("mediaTime", 12.25), ("afterDisplayFrames", 8)):
            bad = copy.deepcopy(probes)
            events = bad["avatar-light-active-fade-reset"]["semantic"]["events"]
            events[1 if field == "presentationOpacity" else 3][field] = changed
            with self.assertRaises(ValueError):
                visual.validate_avatar(bad, family, paths)
        probes["avatar-light-letters"]["semantic"]["childRaster"] = True
        with self.assertRaises(ValueError):
            visual.validate_avatar(probes, family, paths)

    def test_composer_rejects_other_cell_changes_flat_selection_and_cleaned_code(self):
        probes, family = composer_evidence()
        visual.validate_composer(probes, family)
        bad = copy.deepcopy(probes)
        bad["composer-cell-mentioned"]["semantic"]["content"]["blocks"][3]["table"]["rows"][0]["cells"][1]["text"] = "changed outside selection"
        with self.assertRaises(ValueError):
            visual.validate_composer(bad, family)
        bad = copy.deepcopy(probes)
        bad["composer-cell-selected"]["semantic"]["globalSelection"] = []
        with self.assertRaises(ValueError):
            visual.validate_composer(bad, family)
        bad = copy.deepcopy(probes)
        bad["composer-code-pasted"]["semantic"]["content"]["blocks"][5]["code"]["runs"][0]["text"] = "literal: https://example.test/?keep=1"
        with self.assertRaises(ValueError):
            visual.validate_composer(bad, family)

    def test_pts_index_preserves_duplicates_and_variable_spacing_with_artifact_handles(self):
        state = {"runId": "synthetic", "scenario": "avatar-render", "facts": {"buildSelection": visual.BUILD_SELECTION,
                 "domainSources": {"sha256": "a" * 64}}, "probes": [{"name": "active-fade-reset", "wallTime": 100.25,
                 "semantic": {"events": [{"name": "reset-to-letters", "wallTime": 100.225}]}}]}
        timing = {"recordCommandHostWallTime": 100, "recordStartedObservedHostWallTime": 100.1}
        info = {"frames": [{"pts_time": str(value)} for value in (0, .11, .20, .20, .6)]}
        result = visual.recorded_frame_index(state, timing, info)
        self.assertEqual([frame["pts"] for frame in result["frames"]], [0, .11, .2, .2, .6])
        self.assertEqual(result["frames"][2]["frame"], "frames/frames/00002.png")
        self.assertEqual(result["frames"][3]["frame"], "frames/frames/00003.png")
        self.assertEqual(result["probes"][0]["candidateFrameIndices"], [1, 2, 3, 4])
        self.assertIn("semantic/events/0", result["probes"][0]["events"][0]["semantic"])
        self.assertEqual(result["visualReview"], "pending-recorded-frame-review")

    def test_native_png_export_is_whitelisted_and_fingerprinted(self):
        data = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGN4p2CCFTEMLQkAoxlQgUcPF4kAAAAASUVORK5CYII=")
        entry = {"path": "native/observed.png", "sha256": hashlib.sha256(data).hexdigest(), "width": 8, "height": 8, "bytes": len(data)}
        state = {"facts": {"visualArtifacts": [entry]}}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "source/native").mkdir(parents=True)
            (root / "source/native/observed.png").write_bytes(data)
            visual.copy_visual_artifacts(state, root / "source", root / "copied")
            self.assertEqual((root / "copied/native/observed.png").read_bytes(), data)
            for key, replacement in (("path", "../account"), ("sha256", "b" * 64), ("width", 16)):
                bad = copy.deepcopy(state)
                bad["facts"]["visualArtifacts"][0][key] = replacement
                with self.assertRaises(ValueError):
                    visual.copy_visual_artifacts(bad, root / "source", root / "refused")


if __name__ == "__main__":
    unittest.main()
