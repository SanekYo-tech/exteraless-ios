"""Small data fixtures for source-claim joins; no SDK/native/plugin execution."""

from copy import deepcopy
import hashlib

import pytest

from tools.compat import feature_inventory as inventory


def feature(fid="nagram.showTextTranslate", symbol="NaConfig.showTextTranslate", key="showTextTranslate"):
    return {"id": fid, "kind": "setting", "android": {"symbol": symbol, "key": key, "behavior": "effect-callsite"},
            "ios": {"setting_key": "old.proposal"}, "implementation": inventory._pending()}


def receipt(fid="nagram.showTextTranslate", key="chats.showTextTranslate", status="partial"):
    return {"id": fid, "ios": {"setting_key": key, "implementation_callsites": [{"path": "consumer.swift", "line": 10}]},
            "implementation": {"status": status, "ported": False, "evidence": []}}


def baseline(rows=None, apis=None, modules=None):
    client = {"features": rows or [feature()], "compatibility_apis": apis or [], "modules": modules or {},
              "android_source": {"counts": {"bytes": 1}}}
    sdk = {"symbols": [], "totals": {}}
    return client, sdk


def policy(**changes):
    return {"owner_precedence": {"nagram.showTextTranslate": "chat"}, "module_owners": {}, "rollups": {},
            "sdk_claim_boundary": "Published source only; behavioral compatibility unknown.", **changes}


def test_primary_owner_keeps_secondary_evidence_and_null_keys_without_mutating_inputs():
    client, sdk = baseline()
    sources = {"ai": {"features": [receipt(key="ai.showTextTranslate")]},
               "chat": {"features": [receipt()]}}
    before = deepcopy(sources)
    joined, _, report = inventory.join_source_receipts(client, sdk, sources, policy())
    row = joined["features"][0]
    assert row["ios"]["setting_key"] == "chats.showTextTranslate"
    assert row["source_claim"]["owner"] == "chat"
    assert row["secondary_source_claims"][0]["reported"] == sources["ai"]["features"][0]
    assert report["owner_conflicts_resolved"] == [{"id": row["id"], "primary": "chat", "secondary": ["ai"]}]
    assert not row["implementation"]["ported"]
    assert sources == before and client["features"][0]["ios"]["setting_key"] == "old.proposal"
    sources["chat"]["features"][0]["ios"]["setting_key"] = None
    joined, _, _ = inventory.join_source_receipts(client, sdk, sources, policy())
    assert joined["features"][0]["ios"]["setting_key"] is None
    assert joined["setting_key_collisions"] == {}


@pytest.mark.parametrize("malformation", ["unknown", "duplicate", "no-owner", "wrong-owner"])
def test_unknown_duplicate_and_ambiguous_claims_are_not_silently_dropped(malformation):
    client, sdk = baseline()
    documents = {"chat": {"features": [receipt()]}}
    rules = policy()
    if malformation == "unknown":
        documents["chat"]["features"].append(receipt("nagram.missing"))
    elif malformation == "duplicate":
        documents["chat"]["features"].append(receipt())
    elif malformation == "no-owner":
        documents["ai"] = {"features": [receipt(key="ai.showTextTranslate")]}
        rules["owner_precedence"] = {}
    else:
        rules["owner_precedence"]["nagram.showTextTranslate"] = "missing-owner"
    with pytest.raises(ValueError):
        inventory.join_source_receipts(client, sdk, documents, rules)


def test_pills_normalize_by_original_symbol_and_android_key_not_ios_alias_or_row_count():
    original = feature("pillstack.activePillsRaw", "PillStackConfig.activePillsRaw", "OEPillActivePills")
    document = {"status": "source-implemented-native-pending", "handoff": "pills.md", "verification": {},
                "callsiteFiles": {"PillLayout": "PillRegistry.swift"}, "pluginSurface": {"sdkStatus": "partial"},
                "settings": [{"originalId": "PillStackConfig.activePillsRaw", "androidKey": "OEPillActivePills",
                              "key": "chats.activePillsRaw", "callsite": "PillLayout.visible", "default": "5,6"}],
                "pills": [{"originalId": 11, "symbol": "PillType.DC_PING", "status": "rtt-unavailable", "limits": ["no fabricated zero"]}]}
    client, sdk = baseline([original], modules={"pillstack": {"id": "module.pillstack", "implementation": inventory._pending()}})
    rules = policy(module_owners={"pillstack": "pills"})
    joined, _, _ = inventory.join_source_receipts(client, sdk, {"pills": document}, rules)
    assert [r["id"] for r in joined["features"]] == [original["id"]]
    assert joined["features"][0]["ios"]["setting_key"] == "chats.activePillsRaw"
    assert joined["features"][0]["implementation"]["status"] == "partial"
    assert joined["pill_types"][0]["status"] == "rtt-unavailable"
    assert joined["pill_types"][0]["limits"] == ["no fabricated zero"]
    assert not joined["pill_types"][0]["implementation"]["ported"]
    document["settings"][0]["androidKey"] = "wrong-but-same-symbol"
    with pytest.raises(ValueError, match="symbol/key mismatch"):
        inventory.join_source_receipts(client, sdk, {"pills": document}, rules)


def test_sdk_overloads_require_exact_identity_and_sdk_primary_supersedes_classifications():
    ids = ["compat.ExteraConfig.radius(int)", "compat.ExteraConfig.radius(float)"]
    client, sdk = baseline(apis=[{"id": fid, "implementation": inventory._pending()} for fid in ids])
    documents = {"chat": {"features": [receipt()]},
                 "tools": {"compatibility_apis": [receipt(ids[0], status="blocked")]},
                 "sdk-config": {"compatibility_apis": [receipt(ids[0], status="implemented"), receipt(ids[1], key=None, status="blocked")]}}
    joined, _, _ = inventory.join_source_receipts(client, sdk, documents, policy())
    assert [r["implementation"]["status"] for r in joined["compatibility_apis"]] == ["implemented", "blocked"]
    assert all(r["source_claim"]["owner"] == "sdk-config" for r in joined["compatibility_apis"])
    documents["sdk-config"]["compatibility_apis"][1]["id"] = "compat.ExteraConfig.radius(String)"
    with pytest.raises(ValueError, match="unknown source API"):
        inventory.join_source_receipts(client, sdk, documents, policy())


def test_scoped_rollup_stays_partial_even_when_contributing_feature_claims_implemented():
    client, sdk = baseline(modules={"settings": {"id": "module.settings", "ported": False, "implementation": inventory._pending()}})
    documents = {"chat": {"features": [receipt(status="implemented")]}}
    scope = {"owner": "coordinator", "ids": [client["features"][0]["id"]], "boundary": "Only registered native editor route",
             "authorship_needed": ["Exact remaining action-to-native-operation map"]}
    joined, _, _ = inventory.join_source_receipts(client, sdk, documents, policy(rollups={"settings": scope}))
    module = joined["modules"]["settings"]
    assert module["implementation"]["status"] == "partial"
    assert module["rollup"] == scope
    assert not module["ported"]


def test_source_claim_cannot_promote_verified_and_prior_independent_verification_survives():
    client, sdk = baseline()
    verified = {"status": "verified", "ported": True, "evidence": [{"kind": "test", "path": "test-result.json"}]}
    doc = {"chat": {"features": [{**receipt(), "implementation": verified}]}}
    with pytest.raises(ValueError, match="cannot grant verification"):
        inventory.join_source_receipts(client, sdk, doc, policy())
    client["features"][0]["implementation"] = deepcopy(verified)
    joined, _, _ = inventory.join_source_receipts(client, sdk, {"chat": {"features": [receipt()]}}, policy())
    assert joined["features"][0]["implementation"] == verified
    assert joined["features"][0]["source_claim"]["reported"]["implementation"]["status"] == "partial"


def test_sdk_class_or_generic_helper_does_not_cover_unlisted_members():
    client, sdk = baseline()
    sdk["symbols"] = [{"id": "sdk.ui.alert." + name, "name": name, "module": "ui.alert",
                       "native_relation": {"status": "unsupported", "reason": "old builtin-only map"},
                       "implementation": inventory._pending()} for name in ["Builder", "Builder.show", "Builder.arbitraryAndroidView"]]
    joined, mapped, _ = inventory.join_source_receipts(client, sdk, {"chat": {"features": [receipt()]}},
                                                       policy(sdk_exact_claims={"ui.alert": ["Builder", "Builder.show"]}))
    assert mapped["symbols"][0]["implementation"]["status"] == "partial"
    assert mapped["symbols"][1]["native_relation"]["status"] == "published-source-subset"
    assert mapped["symbols"][2]["native_relation"]["status"] == "not-individually-reconciled"
    assert mapped["symbols"][2]["implementation"]["status"] == "pending"


def test_source_anchor_relocated_by_symbol_not_old_line_and_ambiguity_stays_explicit(tmp_path):
    text = "// added header\n\nfunc actualConsumer() {}\n\nfunc other() {}\n"
    (tmp_path / "consumer.swift").write_text(text, encoding="utf-8", newline="\n")
    snapshot = inventory.SourceSnapshot(tmp_path)
    ref = snapshot.reference({"path": "consumer.swift", "line": 99, "symbol": "Owner.actualConsumer"})
    assert ref["line"] == 3 and ref["reported_line"] == 99
    assert ref["sha256"] == hashlib.sha256(text.encode()).hexdigest()
    unresolved = snapshot.reference({"path": "consumer.swift", "line": 3})
    assert "line" not in unresolved and unresolved["reported_line"] == 3
    assert unresolved["anchor_resolution"] == "file-snapshot-only-no-resolved-symbol"
    (tmp_path / "many.swift").write_text("func render() {}\nrender()\n", encoding="utf-8")
    ambiguous = snapshot.reference({"path": "many.swift", "line": 1, "symbol": "render"})
    assert ambiguous["match_count"] == 2 and "line" not in ambiguous
    assert [r["line"] for r in ambiguous["matches"]] == [1, 2]


def test_source_claim_evidence_survives_ordinary_regeneration():
    client, sdk = baseline()
    joined, _, _ = inventory.join_source_receipts(client, sdk, {"chat": {"features": [receipt()]}}, policy())
    regenerated = inventory.merge_parity(client, joined)
    assert regenerated["features"][0]["source_claim"] == joined["features"][0]["source_claim"]
    assert regenerated["features"][0]["ios"]["implementation_callsites"] == joined["features"][0]["ios"]["implementation_callsites"]


@pytest.mark.parametrize("mutation", ["same-count-wrong-id", "key", "status", "verification", "report-map"])
def test_final_data_check_rejects_identity_key_status_and_verification_drift(mutation):
    client, sdk = baseline()
    rules = policy(required_counts={"features": 1, "modules": 0, "sdk_symbols": 0, "compatibility_apis": 0, "pill_settings": 0, "pill_types": 0})
    joined, mapped, report = inventory.join_source_receipts(client, sdk, {"chat": {"features": [receipt()]}}, rules)
    report["feature_map"] = [{"id": "nagram.showTextTranslate", "owner": "chat", "ios_key": "chats.showTextTranslate", "author_status": "partial"}]
    assert inventory.validate_source_join(joined, mapped, report, rules)["result"] == "passed-data-only"
    row = joined["features"][0]
    if mutation == "same-count-wrong-id":
        row["id"] = "nagram.anotherId"
    elif mutation == "key":
        row["ios"]["setting_key"] = "ai.duplicateKey"
    elif mutation == "status":
        row["implementation"]["status"] = "implemented"
    elif mutation == "verification":
        row["implementation"]["ported"] = True
    else:
        report["feature_map"][0]["owner"] = "ai"
    with pytest.raises(ValueError):
        inventory.validate_source_join(joined, mapped, report, rules)


def test_replay_uses_retained_claims_and_keeps_ai_secondary_without_live_receipt_reads():
    client, sdk = baseline()
    documents = {"chat": {"features": [receipt()]}, "ai": {"features": [receipt(key="ai.showTextTranslate")]}}
    joined, _, _ = inventory.join_source_receipts(client, sdk, documents, policy())
    pinned = {"sources": {owner: {"metadata": {"source_snapshot": "original"}, "sha256": "old-published-hash"}
                           for owner in ("chat", "ai", "pills", "sdk-config")}}
    replay = inventory.replay_source_documents(joined, pinned)
    assert replay["chat"]["features"] == documents["chat"]["features"]
    assert replay["ai"]["features"] == documents["ai"]["features"]
    assert replay["sdk-config"]["source_snapshot"] == "original"
    assert replay["pills"]["pills"] == []
