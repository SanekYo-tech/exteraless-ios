"""Exact-route integrity and regeneration tests; no SDK/native/plugin imports."""

from copy import deepcopy
import hashlib
import json

import pytest

from tools.compat import feature_inventory as inventory
from tools.compat import individual_routes as routes


def inputs():
    methods = [
        {"file": "java/app/example/Helper.java", "name": "render", "parameter_types": ["int"], "line": 12, "arity": 1, "type": "void", "binding": "static"},
        {"file": "java/app/example/Helper.java", "name": "render", "parameter_types": ["float"], "line": 18, "arity": 1, "type": "void", "binding": "static"},
    ]
    client = {"features": [], "compatibility_apis": [], "legacy_trees": {}, "android_source": {"counts": {"bytes": 0}},
              "modules": {"sample": {"id": "module.sample", "public_method_bodies": methods, "implementation": {"status": "partial", "ported": False, "evidence": []},
                                     "ported": False, "rollup": {"authorship_needed": ["exact members"], "boundary": "Scoped source only"}}}}
    sdk = {"modules": {"sample": {"file": "python/sdk/sample.py", "sha256": "a" * 64}}, "totals": {}, "symbols": [
        {"id": "sdk.sample.send", "module": "sample", "name": "send", "kind": "function", "line": 11,
         "parameters": [{"name": "value", "kind": "keyword-only", "optional": True, "default": {"kind": "literal", "value": None}}],
         "return_annotation": "bool", "native_relation": {"status": "needs-review"}, "implementation": inventory._pending()},
        {"id": "sdk.sample.Widget", "module": "sample", "name": "Widget", "kind": "class", "line": 21,
         "native_relation": {"status": "needs-review"}, "implementation": inventory._pending()},
    ]}
    sdk_rows = [{"id": row["id"], "original": {"path": "python/sdk/sample.py", "line": row["line"], "symbol": row["name"]},
                 "route": [{"path": "shared.swift", "symbol": "send" if index == 0 else "Widget", "role": "missing-provider-boundary" if index == 0 else "declaration", "line": 90}],
                 "disposition": "partial" if index == 0 else "metadata", "contract": "Exact authored route",
                 "limitations": ["No send provider"] if index == 0 else [], "evidence": ["shared.swift:90"],
                 "ported": False, "verified": False, "native_execution_claimed": False} for index, row in enumerate(sdk["symbols"])]
    members = [{"original": {key: method[key] for key in ("file", "name", "parameter_types", "line")},
                "disposition": "partial" if index == 0 else "unsupported", "contract": "Exact overload with a named missing provider",
                "limitations": ["Missing native operation"], "route": [{"path": "shared.swift", "symbol": "render", "role": "counterpart-only", "line": 32}],
                "ported": False, "verified": False} for index, method in enumerate(methods)]
    module = {"schema_version": 1, "module_id": "module.sample", "source_boundary": "captured revision B", "ported": False, "verified": False,
              "pins": {"files": {"shared.swift": {"sha256": "b" * 64, "bytes": 123}}}, "members": members,
              "member_routes": [{"original_API_or_sdk_id": routes.member_key(method), "native_operation": None, "provider_owner": None,
                                 "admission_lifecycle": "No native provider claimed", "unavailable_reason": "Missing operation", "evidence": ["shared.swift:32"]} for method in methods],
              "findings": [{"id": "OPEN-01", "status": "open-source-gap", "ported": False, "verified": False}]}
    symbol_map = {"schema_version": 1, "modules": ["sample"], "source_boundary": {"code_revision": "a" * 40},
                  "source_sha256": {"shared.swift": "c" * 64, "python/sdk/sample.py": "a" * 64}, "symbols": sdk_rows,
                  "findings": [{"id": "OPEN-02", "counterexample": "Missing provider", "native_execution_claimed": False}]}
    manifests = []
    for owner, kind, document in (("sdk", "sdk", symbol_map), ("module", "module", module)):
        raw = json.dumps(document).encode()
        manifests.append({"owner": owner, "kind": kind, "path": f"maps/{owner}.json", "sha256": hashlib.sha256(raw).hexdigest(),
                          "bytes": len(raw), "expected_count": 2, "module_id": document.get("module_id"), "document": document})
    return client, sdk, manifests


def test_exact_routes_keep_shared_path_snapshots_original_signatures_and_missing_providers():
    client, sdk, manifests = inputs()
    before = deepcopy((client, sdk, manifests))
    result, mapped, report = routes.join(client, sdk, manifests)
    assert (client, sdk, manifests) == before
    assert [routes.declaration(row) for row in mapped["symbols"]] == [routes.declaration(row) for row in sdk["symbols"]]
    assert result["modules"]["sample"]["public_method_bodies"] == client["modules"]["sample"]["public_method_bodies"]
    assert mapped["symbols"][0]["native_relation"]["status"] == "source-route-partial"
    assert mapped["symbols"][0]["implementation"]["status"] == "partial"
    assert mapped["symbols"][0]["individual_source"]["reported"]["route"][0]["line"] == 90
    assert result["modules"]["sample"]["individual_source"]["reported"]["member_routes"][0]["provider_owner"] is None
    assert result["modules"]["sample"]["implementation"]["status"] == "partial"
    assert "authorship_needed" not in result["modules"]["sample"]["rollup"]
    assert report["manifests"][0]["source_pins"][-1]["sha256"] == "c" * 64
    assert report["manifests"][1]["source_pins"][0]["sha256"] == "b" * 64
    assert all(not finding["closed_by_this_join"] for finding in report["findings"])
    assert routes.validate(result, mapped)["individual_module_members"] == 2


@pytest.mark.parametrize("case", ["duplicate", "missing", "unknown", "path", "symbol", "line", "parameters", "cross-map", "original-bytes"])
def test_sdk_identity_and_original_declaration_corruption_is_rejected(case):
    client, sdk, manifests = inputs()
    rows = manifests[0]["document"]["symbols"]
    if case == "duplicate": rows[1] = deepcopy(rows[0])
    elif case == "missing": rows.pop()
    elif case == "unknown": rows[1]["id"] = "sdk.sample.unknown"
    elif case == "path": rows[0]["original"]["path"] = "unrelated.py"
    elif case == "symbol": rows[0]["original"]["symbol"] = "other"
    elif case == "line": rows[0]["original"]["line"] += 1
    elif case == "parameters": rows[0]["parameters"] = []
    elif case == "cross-map": manifests.append({**deepcopy(manifests[0]), "owner": "duplicate-owner"})
    else: sdk["modules"]["sample"]["sha256"] = "d" * 64
    with pytest.raises(ValueError):
        routes.join(client, sdk, manifests)


@pytest.mark.parametrize("field,value", [("ported", True), ("verified", True), ("verified", 0), ("native_execution_claimed", True), ("native_execution_claimed", "false")])
def test_source_map_cannot_supply_execution_or_verification_promotions(field, value):
    client, sdk, manifests = inputs()
    manifests[0]["document"]["symbols"][0][field] = value
    with pytest.raises(ValueError, match="promote|requires"):
        routes.join(client, sdk, manifests)


@pytest.mark.parametrize("case", ["same-arity-overload", "duplicate", "missing", "return", "route-identity", "provider", "unavailable"])
def test_module_structured_identities_and_typed_provider_routes_are_enforced(case):
    client, sdk, manifests = inputs()
    doc = manifests[1]["document"]
    if case == "same-arity-overload": doc["members"][0]["original"]["parameter_types"] = ["long"]
    elif case == "duplicate": doc["members"][1] = deepcopy(doc["members"][0])
    elif case == "missing": doc["members"].pop()
    elif case == "return": doc["members"][0]["original_result_type"] = "String"
    elif case == "route-identity": doc["member_routes"][1] = deepcopy(doc["member_routes"][0])
    elif case == "provider": doc["member_routes"][0]["native_operation"] = "madeUpProvider"
    else: doc["member_routes"][0]["unavailable_reason"] = None
    with pytest.raises(ValueError):
        routes.join(client, sdk, manifests)


def test_independent_prior_verification_survives_without_a_new_promotion():
    client, sdk, manifests = inputs()
    proven = {"status": "verified", "ported": True, "evidence": [{"kind": "test", "path": "old-result.json"}]}
    sdk["symbols"][0]["implementation"] = deepcopy(proven)
    result, mapped, report = routes.join(client, sdk, manifests)
    assert mapped["symbols"][0]["implementation"] == proven
    assert report["counts"]["verified_before"] == report["counts"]["verified_after"] == 1
    assert not mapped["symbols"][0]["native_relation"]["verified"]
    mapped["symbols"][1]["implementation"] = deepcopy(proven)
    with pytest.raises(ValueError, match="verification"):
        routes.validate(result, mapped)


@pytest.mark.parametrize("mutation", ["route", "limit", "duplicate-id", "original-signature", "receipt", "relation"])
def test_materialized_corruption_fails_data_validation(mutation):
    client, sdk, manifests = inputs()
    result, mapped, _ = routes.join(client, sdk, manifests)
    row = mapped["symbols"][0]
    if mutation == "route": row["individual_source"]["reported"]["route"][0]["line"] += 7
    elif mutation == "limit": row["individual_source"]["reported"]["limitations"] = []
    elif mutation == "duplicate-id": mapped["symbols"][1] = deepcopy(row)
    elif mutation == "original-signature": row["parameters"][0]["kind"] = "positional-only"
    elif mutation == "receipt": row["individual_source"]["receipt"]["sha256"] = "f" * 64
    else: row["native_relation"]["status"] = "implemented"
    with pytest.raises(ValueError):
        routes.validate(result, mapped)


def test_ordinary_merge_preserves_individual_layers_and_rejects_later_signature_drift():
    client, sdk, manifests = inputs()
    result, mapped, _ = routes.join(client, sdk, manifests)
    regenerated_client = inventory.merge_parity(client, result)
    regenerated_sdk = inventory.merge_parity(sdk, mapped)
    assert regenerated_sdk["symbols"][0]["individual_source"] == mapped["symbols"][0]["individual_source"]
    assert regenerated_client["modules"]["sample"]["individual_source"] == result["modules"]["sample"]["individual_source"]
    assert routes.validate(regenerated_client, regenerated_sdk)["individual_sdk_symbols"] == 2
    sdk["symbols"][0]["return_annotation"] = "int"
    with pytest.raises(ValueError, match="signature"):
        inventory.merge_parity(sdk, mapped)


def test_legacy_source_join_cannot_replace_individual_sdk_with_a_class_level_claim():
    client, sdk, manifests = inputs()
    result, mapped, _ = routes.join(client, sdk, manifests)
    policy = {"module_owners": {"sample": "owner"}, "rollups": {}, "sdk_claim_boundary": "class-level candidate",
              "sdk_exact_claims": {"sample": ["send", "Widget"]}}
    documents = {"owner": {"modules": {"sample": {"implementation": {"status": "partial", "ported": False, "evidence": []}}}}}
    _, remapped, _ = inventory.join_source_receipts(result, mapped, documents, policy)
    assert [row["native_relation"] for row in remapped["symbols"]] == [row["native_relation"] for row in mapped["symbols"]]


def write_manifests(root, manifests):
    policy = {"individual_manifests": []}
    for manifest in manifests:
        file = root / manifest["path"]
        file.parent.mkdir(parents=True, exist_ok=True)
        raw = json.dumps(manifest["document"]).encode()
        file.write_bytes(raw)
        policy["individual_manifests"].append({**{key: value for key, value in manifest.items() if key not in {"document", "bytes"}}, "sha256": hashlib.sha256(raw).hexdigest()})
    return policy


def test_explicit_loader_rejects_missing_changed_and_duplicate_json_but_no_policy_is_valid(tmp_path):
    assert routes.load_manifests(tmp_path, {}) == []
    _, _, manifests = inputs()
    policy = write_manifests(tmp_path, manifests)
    loaded = routes.load_manifests(tmp_path, policy)
    assert loaded[0]["document"] == manifests[0]["document"]
    (tmp_path / "maps/sdk.json").write_text('{"schema_version":1,"schema_version":1}')
    with pytest.raises(ValueError, match="revision changed"):
        routes.load_manifests(tmp_path, policy)
    policy["individual_manifests"][0].pop("sha256")
    with pytest.raises(ValueError, match="duplicate JSON"):
        routes.load_manifests(tmp_path, policy)
    (tmp_path / "maps/sdk.json").unlink()
    with pytest.raises(ValueError, match="not found"):
        routes.load_manifests(tmp_path, policy)


def test_normal_cli_regeneration_and_individual_only_retain_all_maps_without_source_files(tmp_path, monkeypatch):
    client, sdk, manifests = inputs()
    policy = write_manifests(tmp_path, manifests)
    docs = tmp_path / "docs/parity"
    docs.mkdir(parents=True)
    (docs / "join-policy.json").write_text(json.dumps(policy))
    monkeypatch.setattr(inventory, "build_client_inventory", lambda *_: deepcopy(client))
    monkeypatch.setattr(inventory, "build_sdk_inventory", lambda *_: deepcopy(sdk))
    monkeypatch.setattr(inventory, "render_index", lambda *_: "fixture index\n")
    args = ["--project-root", str(tmp_path), "--docs", str(docs), "--out", str(tmp_path / "build/compat"), "--docs-only"]
    assert inventory.main(args) == 0
    initial = {name: (docs / name).read_bytes() for name in ("client-features.json", "sdk-surface.json", "individual-source-join.json")}
    assert inventory.main(args + ["--check"]) == 0
    assert inventory.main(args) == 0
    assert all((docs / name).read_bytes() == raw for name, raw in initial.items())
    monkeypatch.setattr(inventory, "build_client_inventory", lambda *_: pytest.fail("individual-only rescanned source"))
    monkeypatch.setattr(inventory, "build_sdk_inventory", lambda *_: pytest.fail("individual-only rescanned SDK"))
    assert inventory.main(args + ["--individual-only", "--check"]) == 0
    assert not (tmp_path / "shared.swift").exists()
    assert not (tmp_path / "python/sdk/sample.py").exists()
    assert not (tmp_path / "build/compat").exists()


def test_bounds_and_duplicate_manifest_paths_are_explicit(tmp_path):
    with pytest.raises(ValueError, match="bounded"):
        routes.load_manifests(tmp_path, {"individual_manifests": [{}] * (routes.MAX_MANIFESTS + 1)})
    client, sdk, manifests = inputs()
    manifests[0]["document"]["symbols"][0]["route"] *= routes.MAX_ROUTE + 1
    with pytest.raises(ValueError, match="bounded"):
        routes.join(client, sdk, manifests)
    _, _, manifests = inputs()
    policy = write_manifests(tmp_path, manifests)
    policy["individual_manifests"].append(deepcopy(policy["individual_manifests"][0]))
    with pytest.raises(ValueError, match="duplicate individual manifest"):
        routes.load_manifests(tmp_path, policy)
