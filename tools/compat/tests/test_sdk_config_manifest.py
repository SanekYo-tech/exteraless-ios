"""Exact source/API identity and regeneration, bounded without executing plugins."""

from pathlib import Path
from copy import deepcopy
import json
import os
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


def test_ci_inventory_metadata_refresh_keeps_exact_generated_outputs(monkeypatch):
    """Compat runs feature_inventory before pytest; that rewrites derived claims."""
    baseline, receipt = generator.build()
    source = json.loads((ROOT / generator.INVENTORY_PATH).read_text(encoding="utf-8"))
    changed = deepcopy(source)
    changed["native_targets"] = {"fixture": {"available": False, "line": 999}}
    changed["modules"] = {}
    changed["setting_key_collisions"] = {"fixture": ["unused"]}
    for row in changed["features"]:
        row["ios"] = {"setting_key": "candidate.not.a.registration"}
        row["implementation"] = {"status": "pending", "ported": False}
    for row in changed["compatibility_apis"]:
        row["implementation"] = {"status": "pending", "ported": False}
        row.pop("ios", None)
    changed["features"].reverse()
    changed["compatibility_apis"].reverse()
    for record in changed["configs"].values(): record["scalar_getter_methods"] = 999
    text = generator.inventory._json_text(changed)
    assert text != (ROOT / generator.INVENTORY_PATH).read_text(encoding="utf-8")
    original = generator.read
    def refreshed(path, pins):
        if path == ROOT / generator.INVENTORY_PATH: return text
        return original(path, pins)
    monkeypatch.setattr(generator, "read", refreshed)
    actual, actual_receipt = generator.build()
    assert generator.render(actual) == generator.render(baseline)
    assert json.dumps(actual_receipt, ensure_ascii=False, indent=2) == json.dumps(receipt, ensure_ascii=False, indent=2)
    assert generator.INVENTORY_PATH not in actual["SOURCES"]
    assert actual["INVENTORY_CONTRACT"]["hash_mode"] == "sdk-config-input-v1"


@pytest.mark.parametrize("change", ("signature", "source_hash", "feature_id", "config_path", "behavior"))
def test_consumed_inventory_changes_invalidate_contract(change):
    source = json.loads((ROOT / generator.INVENTORY_PATH).read_text(encoding="utf-8"))
    original = generator.inventory_pin(generator.inventory_contract(source))
    if change == "signature": source["compatibility_apis"][0]["parameter_types"] = ["String"]
    elif change == "source_hash": source["source_files"][source["configs"]["ExteraConfig"]["file"]]["sha256"] = "f" * 64
    elif change == "feature_id": source["features"][0]["id"] += ".changed"
    elif change == "config_path":
        path = source["configs"]["ExteraConfig"]["file"]
        source["source_files"]["changed/ExteraConfig.java"] = source["source_files"][path]
        source["configs"]["ExteraConfig"]["file"] = "changed/ExteraConfig.java"
    else: source["compatibility_apis"][0]["behavior"] = "changed"
    assert generator.inventory_pin(generator.inventory_contract(source)) != original


_DETERMINISM_PROBE = r'''
import hashlib, json, sys
from pathlib import PurePosixPath, PureWindowsPath
from tools.compat import sdk_config_manifest as g
baseline, _ = g.build()
real_root = g.ROOT
inputs = {name: (real_root / name).read_bytes() for name in (*baseline["SOURCES"], g.INVENTORY_PATH)}
flavor = PurePosixPath if sys.argv[1] == "posix" else PureWindowsPath
g.ROOT = flavor("/fixture" if sys.argv[1] == "posix" else "C:/fixture")
g.ANDROID = g.ROOT / "third_party/exteraless-android/TMessagesProj/src/main"
g.CORE = g.ROOT / "swift/ExteralessCore/Sources/ExteralessCore"
g.OUTPUT = g.ROOT / "python/exteraless_runtime/_config_manifest.py"
g.RECEIPT = g.ROOT / "docs/wave-2/sdk-config-parity.json"
g.inventory.Path = flavor
def digest(path): return hashlib.sha256(inputs[path.relative_to(g.ROOT).as_posix()]).hexdigest()
def read(path, pins):
    key = path.relative_to(g.ROOT).as_posix()
    pins[key] = digest(path)
    return inputs[key].decode("utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")
g.digest, g.read = digest, read
manifest, receipt = g.build()
print(hashlib.sha256(g.render(manifest).encode("utf-8")).hexdigest(),
      hashlib.sha256(json.dumps(receipt, ensure_ascii=False, indent=2).encode("utf-8")).hexdigest())
'''


def test_generator_is_path_flavor_and_hash_seed_independent():
    results = []
    for flavor, seed in (("posix", "0"), ("windows", "0"), ("posix", "731"), ("windows", "731")):
        result = subprocess.run([sys.executable, "-X", "utf8", "-B", "-c", _DETERMINISM_PROBE, flavor],
            cwd=ROOT, env=dict(os.environ, PYTHONHASHSEED=seed), capture_output=True, text=True, encoding="utf-8", timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
        results.append(result.stdout.strip())
    assert len(set(results)) == 1, results


def test_check_failure_reports_changed_pin_and_bounded_diff(monkeypatch, tmp_path):
    output = tmp_path / "manifest.py"
    actual = generator.render({"SOURCES": {"fixture.swift": "a" * 64}})
    output.write_text(actual, encoding="utf-8")
    monkeypatch.setattr(generator, "OUTPUT", output)
    monkeypatch.setattr(generator, "RECEIPT", tmp_path / "receipt.json")
    monkeypatch.setattr(generator, "build", lambda: ({"SOURCES": {"fixture.swift": "b" * 64}}, {}))
    monkeypatch.setattr(sys, "argv", ["sdk_config_manifest", "--check"])
    with pytest.raises(SystemExit) as failure: generator.main()
    message = str(failure.value)
    delta_line = next(line for line in message.splitlines() if line.startswith("SDK_CONFIG_DELTA_JSON="))
    delta = json.loads(delta_line.split("=", 1)[1])
    assert delta["changes"] == [{"path": "SOURCES['fixture.swift']", "change": "value", "stored": "a" * 64, "expected": "b" * 64}]
    assert delta["stored"]["sha256"] != delta["expected"]["sha256"]
    assert "--- stored/" in message and "+++ expected/" in message
    assert len(message.encode("utf-8")) <= generator.DIAGNOSTIC_LIMIT
    assert output.read_text(encoding="utf-8") == actual


def test_stale_diagnostic_handles_order_types_and_large_lines():
    equal_values = generator.stale_diagnostic(generator.OUTPUT, "X = {'b': 2, 'a': 1}\n", "X = {'a': 1, 'b': 2}\n")
    assert "serialized ordering/format differs" in equal_values
    typed = generator.stale_diagnostic(generator.OUTPUT, "X = {'flag': True}\n", "X = {'flag': 1}\n")
    assert "type bool -> int" in typed
    large = generator.stale_diagnostic(generator.OUTPUT, generator.render({"X": {"field": "a" * 20_000}}),
                                        generator.render({"X": {"field": "b" * 20_000}}))
    assert "X['field']" in large and len(large.encode("utf-8")) <= generator.DIAGNOSTIC_LIMIT
    unicode = generator.stale_diagnostic(generator.OUTPUT,
        generator.render({"X": {"雪" * 240 + str(i): "雨" * 500 for i in range(12)}}),
        generator.render({"X": {"雪" * 240 + str(i): "日" * 500 for i in range(12)}}))
    delta = json.loads(next(line.split("=", 1)[1] for line in unicode.splitlines() if line.startswith("SDK_CONFIG_DELTA_JSON=")))
    assert delta["changes_truncated"] and delta["changes"]
    assert len(unicode.encode("utf-8")) <= generator.DIAGNOSTIC_LIMIT
