"""Exact source/API identity and regeneration, bounded without executing plugins."""

from pathlib import Path
import json
import subprocess
import sys
import pytest

from tools.compat import sdk_config_manifest as generator


ROOT = Path(__file__).resolve().parents[3]


def test_config_source_receipt_is_current():
    result = subprocess.run([sys.executable, "-X", "utf8", "-B", "-m", "tools.compat.sdk_config_manifest", "--check"],
                            cwd=ROOT, text=True, capture_output=True, encoding="utf-8", timeout=20)
    assert result.returncode == 0, result.stdout + result.stderr
    receipt = json.loads(generator.RECEIPT.read_text(encoding="utf-8"))
    records = {row["id"]: row for row in receipt["compatibility_apis"]}
    for identity, key in {
        "compat.ExteraConfig.getHideAllChats()": "appearance.hideAllTab",
        "compat.ExteraConfig.setHideAllChats(boolean)": "appearance.hideAllTab",
        "compat.ExteraConfig.getUseSystemIconShape()": "appearance.useSystemIconShape",
        "compat.ExteraConfig.setUseSystemIconShape(boolean)": "appearance.useSystemIconShape",
    }.items():
        assert records[identity]["implementation"]["status"] == "implemented"
        assert records[identity]["ios"]["adaptation"]["canonical_keys"] == [key]


def test_only_registered_child_declarations_are_discovered(monkeypatch):
    original = generator.read
    def with_unregistered_array(path, pins):
        text = original(path, pins)
        if path.name == "AppearanceAdditionalFeatures.swift":
            text += '\nprivate enum UnregisteredSDKFixture { static let unused: [ClientSettingDefinition] = [\n.init(key: "fixture.unregistered", title: "Unused", section: "Fixture", defaultValue: .bool(false), androidSymbols: ["NekoConfig.hideAllTab"])\n] }\n'
        return text
    monkeypatch.setattr(generator, "read", with_unregistered_array)
    pins = {}
    definitions = generator.native_definitions(pins)
    assert "fixture.unregistered" not in definitions
    for key in ("appearance.hideAllTab", "appearance.useSystemIconShape", "appearance.hideHelpSection",
                "tools.enhancedVideoBitrate", "tools.voiceEnhancement", "tools.groupAudioBitrate", "tools.showRPCError"):
        assert definitions[key]["registration"]
    assert any(path.endswith("AppearanceAdditionalFeatures.swift") for path in pins)
    assert any(path.endswith("ToolsNativeModePolicy.swift") for path in pins)


def test_missing_root_registration_cannot_be_filled_by_fixture_defaults(monkeypatch):
    original = generator.read
    def without_compatibility_group(path, pins):
        text = original(path, pins)
        return text.replace("+ ExteraConfigCompatibility.definitions", "") if path.as_posix().endswith(generator.CLIENT_ROOT) else text
    monkeypatch.setattr(generator, "read", without_compatibility_group)
    with pytest.raises(ValueError, match="missing actual root registration: ExteraConfigCompatibility.definitions"):
        generator.native_definitions({})


def test_unreferenced_child_array_is_not_registered(monkeypatch):
    original = generator.read
    def without_sections(path, pins):
        text = original(path, pins)
        return text.replace("+ AppearanceAdditionalFeatures.settingsSectionDefinitions", "") if path.name == "AppearanceFeatures.swift" else text
    monkeypatch.setattr(generator, "read", without_sections)
    with pytest.raises(ValueError, match="no longer registered: AppearanceAdditionalFeatures.settingsSectionDefinitions"):
        generator.native_definitions({})
