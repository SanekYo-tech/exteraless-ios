import json

import pytest

from tools.compat import feature_inventory as inventory


def sample_inventory():
    return {"features": [{"id": "chats.live", "kind": "setting", "android": {"behavior": "effect-callsite"},
                           "ios": {"setting_key": "chats.live"}, "implementation": inventory._pending()}],
            "compatibility_apis": [],
            "modules": {"chats": {"id": "module.chats", "ported": False, "implementation": inventory._pending()}},
            "legacy_trees": {}, "android_source": {"counts": {"bytes": 100}}}


def verified():
    return {"status": "verified", "ported": True,
            "evidence": [{"kind": "test", "path": "tests/fixture_result.json"}]}


def test_regeneration_preserves_verified_features_modules_and_callsites():
    generated = sample_inventory()
    fragment = {"features": [{"id": "chats.live", "implementation": verified(),
                              "ios": {"implementation_callsites": [{"path": "consumer.swift", "line": 9}]}}],
                "modules": {"chats": {"implementation": verified()}}}
    merged = inventory.merge_parity(generated, fragments=[fragment])
    regenerated = inventory.merge_parity(sample_inventory(), previous=json.loads(json.dumps(merged)))
    assert regenerated["features"][0]["implementation"] == verified()
    assert regenerated["features"][0]["ios"]["implementation_callsites"][0]["line"] == 9
    assert regenerated["modules"]["chats"]["ported"] is True
    assert regenerated["totals"]["verified_features"] == 1
    assert generated["modules"]["chats"]["ported"] is False  # Inputs not mutated.


def test_old_generated_module_status_is_merged_instead_of_reset():
    previous = {"modules": {"chats": {"ported": True, "status": "verified", "evidence": verified()["evidence"]}}}
    result = inventory.merge_parity(sample_inventory(), previous=previous)
    assert result["modules"]["chats"]["ported"] is True


def test_generated_and_tracked_previous_sources_cannot_erase_proof_with_pending_defaults():
    proven = {"modules": {"chats": {"implementation": verified()}}}
    result = inventory.merge_parity(sample_inventory(), previous=[proven, sample_inventory()])
    assert result["modules"]["chats"]["ported"] is True
    assert result["modules"]["chats"]["implementation"]["evidence"] == verified()["evidence"]


def test_unverified_bare_ported_claim_is_rejected_not_promoted():
    with pytest.raises(ValueError, match="requires verification evidence"):
        inventory.merge_parity(sample_inventory(), previous={"modules": {"chats": {"ported": True}}})


def test_explicit_status_downgrade_and_removed_evidence_are_not_lost():
    previous = {"features": [{"id": "chats.live", "implementation": verified()},
                             {"id": "chats.removed", "implementation": verified()}]}
    result = inventory.merge_parity(sample_inventory(), previous, [{"features": [
        {"id": "chats.live", "implementation": {"status": "partial", "evidence": []}}]}])
    assert result["features"][0]["implementation"]["ported"] is False
    assert result["orphaned_parity"][0]["id"] == "chats.removed"


def test_unknown_and_conflicting_fragment_ids_fail():
    with pytest.raises(ValueError, match="unknown parity id"):
        inventory.merge_parity(sample_inventory(), fragments=[{"features": [{"id": "typo", "implementation": verified()}]}])
    with pytest.raises(ValueError, match="conflicting parity fragments"):
        inventory.merge_parity(sample_inventory(), fragments=[
            {"features": [{"id": "chats.live", "implementation": verified()}]},
            {"features": [{"id": "chats.live", "implementation": inventory._pending()}]},
        ])


def test_changed_android_default_keeps_historical_proof_but_requires_reverification():
    old = sample_inventory()
    old["features"][0]["android"]["definition_fingerprint"] = "old-default"
    old["features"][0]["implementation"] = verified()
    new = sample_inventory()
    new["features"][0]["android"]["definition_fingerprint"] = "new-default"
    result = inventory.merge_parity(new, old)
    state = result["features"][0]["implementation"]
    assert state["status"] == "verified"
    assert state["evidence"] == verified()["evidence"]
    assert state["ported"] is False
    assert state["source_review_required"]["current_definition"] == "new-default"
    assert inventory.merge_parity(new, result)["features"][0]["implementation"]["ported"] is False
    renewed = inventory.merge_parity(new, result, [{"features": [{"id": "chats.live", "implementation": verified()}]}])
    assert renewed["features"][0]["implementation"]["ported"] is True


def test_bridge_metadata_is_not_native_support(tmp_path):
    bridge = tmp_path / "swift/PluginHost/Sources/PluginHost/BridgeServices.swift"
    bridge.parent.mkdir(parents=True)
    bridge.write_text('''
        private func callRuntime(_ request: Request) throws -> Any {
            switch request.member {
            case "getSetting": return storage.getSetting()
            default: throw unsupported(request)
            }
        }
        private func memberKind() -> String {
            let names = ["setSetting", "sendMessage", "getCacheDir"]
            return "method"
        }
    ''', encoding="utf-8")
    surface = inventory._bridge_surface(tmp_path)
    assert [(r["member"], r["operation"]) for r in surface["members"]] == [("getSetting", "call")]
    assert surface["construct"] == "unsupported"


def test_sdk_ast_does_not_execute_and_pip_sets_are_distinct(tmp_path):
    sdk = tmp_path / "python/sdk"
    sdk.mkdir(parents=True)
    sdk.joinpath("sample.py").write_text('''
raise RuntimeError("must never execute")
__all__ = ["public", "Model"]
def public(a, /, b=1, *, flag=False): pass
def hidden_by_exports(): pass
class Model:
    def render(self, value): pass
''', encoding="utf-8")
    android = tmp_path / "android"
    gradle = android / "TMessagesProj/build.gradle"
    gradle.parent.mkdir(parents=True)
    gradle.write_text("python { pip { install 'requests'\n install('lxml') } }\n// install 'not-a-package'", encoding="utf-8")
    lock = tmp_path / "python/runtime/dependency-lock.json"
    lock.parent.mkdir(parents=True)
    lock.write_text(json.dumps({"packages": [{"name": "requests", "version": "2.0", "import_roots": ["requests"]},
                                             {"name": "urllib3", "version": "2.0", "import_roots": ["urllib3"]}]}), encoding="utf-8")
    result = inventory.build_sdk_inventory(android, tmp_path)
    ids = {r["id"] for r in result["symbols"]}
    assert ids == {"sdk.sample.public", "sdk.sample.Model", "sdk.sample.Model.render"}
    assert result["dependencies"]["android_direct_count"] == 2
    assert result["dependencies"]["ios_provided_count"] == 2
    relations = {r["requirement"]: r["ios"] for r in result["dependencies"]["android_direct"]}
    assert relations == {"requests": "provided-pure-python", "lxml": "not-provided"}
    params = next(s for s in result["symbols"] if s["id"] == "sdk.sample.public")["parameters"]
    assert [p["kind"] for p in params] == ["positional-only", "positional-or-keyword", "keyword-only"]
    assert params[0]["optional"] is False
    assert params[1]["default"] == {"kind": "literal", "value": 1}
    assert params[2]["default"] == {"kind": "literal", "value": False}
    assert inventory.merge_parity(result)["symbols"] == result["symbols"]


def test_same_arity_java_overloads_have_distinct_compatibility_ids(tmp_path):
    path = tmp_path / "TMessagesProj/src/main/java/com/exteragram/messenger/ExteraConfig.java"
    path.parent.mkdir(parents=True)
    path.write_text('''
        public class ExteraConfig {
            public static float getAvatarCorners(float size, boolean forum) { return size; }
            public static float getAvatarCorners(int size, boolean forum) { return size; }
        }
    ''', encoding="utf-8")
    records = inventory.build_client_inventory(tmp_path, tmp_path)["compatibility_apis"]
    assert {r["id"] for r in records} == {
        "compat.ExteraConfig.getAvatarCorners(float,boolean)",
        "compat.ExteraConfig.getAvatarCorners(int,boolean)",
    }


def test_dependency_provision_does_not_claim_debugger_runtime_parity(tmp_path):
    gradle = tmp_path / "TMessagesProj/build.gradle"
    gradle.parent.mkdir(parents=True)
    gradle.write_text("python { version '3.11'\n pip { install 'debugpy' } }", encoding="utf-8")
    lock = tmp_path / "python/runtime/dependency-lock.json"
    lock.parent.mkdir(parents=True)
    lock.write_text(json.dumps({"python": "3.12", "packages": [{
        "name": "debugpy", "version": "1.8.22", "artifact_kind": "sdist-python", "projection": "debugpy-python",
        "ios_constraints": {"listen": "process spawning unavailable", "connect": "not verified"}
    }]}), encoding="utf-8")
    result = inventory.build_sdk_inventory(tmp_path, tmp_path)["dependencies"]
    dependency = result["android_direct"][0]
    assert dependency["ios"] == "provided-python-projection"
    assert dependency["ios_constraints"]["listen"] == "process spawning unavailable"
    assert result["ios_provided"][0]["artifact_kind"] == "sdist-python"
    assert result["android_python_version"] == "3.11"
    assert result["ios_python_version"] == "3.12"
