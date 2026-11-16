"""Review-scoped data overlays: no SDK, native process, CI or plugin execution."""

from copy import deepcopy
import hashlib
import json
import subprocess

import pytest

from tools.compat import feature_inventory as inventory
from tools.compat import individual_routes
from tools.compat.tests.test_feature_inventory_individual import inputs, write_manifests


def fixture():
    client, sdk, _ = inputs()
    client["features"] = [{"id": "neko.fixture", "kind": "setting", "android": {"behavior": "effect-callsite"},
                           "ios": {"setting_key": "native.fixture"}, "implementation": {"status": "partial", "ported": False, "evidence": []}}]
    sdk["symbols"][0]["implementation"]["status"] = "unsupported"
    sdk["symbols"][0]["native_relation"] = {"status": "unsupported", "reason": "missing provider"}
    texts = {"reports/original-a.md": "# Original A\n## F01 OPEN\n", "reports/original-b.md": "# Original B\n## F01 OPEN\n",
             "reports/closed.md": "# Independent review\nA SOURCE-CLOSED\nB SOURCE-CLOSED\n"}
    document = {
        "schema_version": 1, "source_revision": "a" * 40,
        "documents": {path: {"sha256": hashlib.sha256(text.encode()).hexdigest(), "bytes": len(text.encode())} for path, text in texts.items()},
        "source_pins": {},
        "target_groups": {"a": [{"kind": "sdk-symbol", "id": sdk["symbols"][0]["id"]}],
                          "b": [{"kind": "feature", "id": "neko.fixture"}, {"kind": "module-member", "module_id": "module.sample", "id": individual_routes.member_key(client["modules"]["sample"]["public_method_bodies"][0])}]},
        "origins": [{"origin_report": f"reports/original-{name}.md", "id": "F01", "identity_kind": "finding", "anchor": "## F01 OPEN", "target_groups": [name]} for name in ("a", "b")],
        "closures": [{"origin_report": f"reports/original-{name}.md", "id": "F01", "source_state": "source-closed", "scope": f"Only {name}'s counterexample",
                      "limitations": ["Missing providers and native execution remain separate"], "requires": [], "source_paths": [],
                      "reviews": [{"path": "reports/closed.md", "anchor": name.upper() + " SOURCE-CLOSED"}]} for name in ("a", "b")],
        "execution_evidence": [], "execution_blockers": [], "pending_acceptance": []}
    return client, sdk, document, texts


def loaded(document):
    raw = inventory._json_text(document).encode()
    return {"input_receipt": {"path": "docs/parity/current-source-followups.json", "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)},
            "input": deepcopy(document), "report_anchors": [], "report_anchors_fingerprint": individual_routes.fingerprint([])}


def without_overlay(payload):
    value = deepcopy(payload)
    value.pop("current_source_reconciliation", None)
    for section in ("features", "symbols", "modules"):
        rows = value.get(section, [])
        for row in rows.values() if isinstance(rows, dict) else rows:
            row.pop("current_source_evidence", None)
    return value


def test_same_finding_name_in_different_reports_never_closes_the_wrong_scope():
    client, sdk, document, _ = fixture()
    before = deepcopy((client, sdk, document))
    result, mapped, summary = inventory.apply_current_source_overlay(client, sdk, loaded(document))
    assert (client, sdk, document) == before
    assert summary["counts"]["source_closed_scopes"] == 2
    assert mapped["symbols"][0]["current_source_evidence"][0]["origin_report"] == "reports/original-a.md"
    assert result["features"][0]["current_source_evidence"][0]["origin_report"] == "reports/original-b.md"
    assert mapped["symbols"][0]["implementation"]["status"] == "unsupported"
    assert mapped["symbols"][0]["native_relation"]["reason"] == "missing provider"
    assert without_overlay(result) == client and without_overlay(mapped) == sdk
    assert inventory.validate_current_source_overlay(result, mapped)["current_source_remaining_scopes"] == 0


@pytest.mark.parametrize("case", ["wrong-origin", "unknown-id", "duplicate", "missing", "duplicate-origin", "unknown-target", "wrong-overload", "unpinned-review"])
def test_overlay_exact_scope_target_and_report_identity_is_enforced(case):
    client, sdk, document, _ = fixture()
    if case == "wrong-origin": document["closures"][0]["origin_report"] = "reports/wrong.md"
    elif case == "unknown-id": document["closures"][0]["id"] = "F02"
    elif case == "duplicate": document["closures"][1] = deepcopy(document["closures"][0])
    elif case == "missing": document["closures"].pop()
    elif case == "duplicate-origin": document["origins"].append(deepcopy(document["origins"][0]))
    elif case == "unknown-target": document["target_groups"]["a"][0]["id"] = "sdk.sample.Missing"
    elif case == "wrong-overload": document["target_groups"]["b"][1]["id"] = "java/app/example/Helper.java::render(long)@12"
    else: document["closures"][0]["reviews"][0]["path"] = "reports/unpinned.md"
    with pytest.raises(ValueError):
        inventory.compile_current_source_overlay(client, sdk, document)


@pytest.mark.parametrize("mutation", ["verified-state", "implemented-state", "ported", "native", "feature-override"])
def test_source_closure_cannot_promote_or_override_original_implementation(mutation):
    client, sdk, document, _ = fixture()
    if mutation == "verified-state": document["closures"][0]["source_state"] = "verified"
    elif mutation == "implemented-state": document["closures"][0]["source_state"] = "implemented"
    elif mutation == "ported": document["closures"][0]["ported"] = True
    elif mutation == "native": document["closures"][0]["native_execution_claimed"] = True
    else: document["features"] = [{"id": "neko.fixture", "implementation": {"ported": True}}]
    with pytest.raises(ValueError):
        inventory.compile_current_source_overlay(client, sdk, document)


@pytest.mark.parametrize("case", ["missing", "cycle", "open-child"])
def test_aggregate_closure_requires_exact_closed_acyclic_prerequisites(case):
    client, sdk, document, _ = fixture()
    a, b = document["closures"]
    a["requires"] = [{"origin_report": b["origin_report"], "id": b["id"]}]
    if case == "missing": a["requires"][0]["id"] = "not-published"
    elif case == "cycle": b["requires"] = [{"origin_report": a["origin_report"], "id": a["id"]}]
    else: b["source_state"] = "source-partial"
    with pytest.raises(ValueError):
        inventory.compile_current_source_overlay(client, sdk, document)


def test_captured_assigned_findings_and_named_routes_cannot_disappear():
    client, sdk, document, _ = fixture()
    client["individual_source_reconciliation"] = {"findings": [{"receipt": {"path": "reports/captured.json"}, "reported": {"id": "LOST-01"}}]}
    with pytest.raises(ValueError, match="dropped"):
        inventory.compile_current_source_overlay(client, sdk, document)
    client.pop("individual_source_reconciliation")
    client["modules"]["sample"]["individual_source"] = {"receipt": {"path": "reports/general.json"}, "reported": {"remaining_portable_routes": ["exact reset scope"]}}
    with pytest.raises(ValueError, match="dropped"):
        inventory.compile_current_source_overlay(client, sdk, document)


def test_execution_failure_and_later_isolated_pass_do_not_reopen_source_closures():
    client, sdk, document, _ = fixture()
    document["execution_history"] = [{"id": "listener", "source": "coordinator-handoff", "status": "failed-readiness", "scope": "Historical observed readiness failure"}]
    document["execution_evidence"] = [{"id": "listener-isolated", "source": "coordinator-handoff", "status": "scoped-PASS", "scope": "Darwin only; no full pipeline"}]
    document["execution_blockers"] = [{"id": "full-pipeline", "source": "coordinator-handoff", "status": "pending", "scope": "Five children and UIKit incomplete"}]
    report = inventory.compile_current_source_overlay(client, sdk, document)
    assert report["counts"]["source_closed_scopes"] == 2 and report["counts"]["execution_blockers"] == 1
    assert report["counts"]["verification_promotions"] == 0


@pytest.mark.parametrize("field", ["input", "effective", "link", "anchor"])
def test_materialized_overlay_corruption_fails_pure_data_checks(field):
    client, sdk, document, _ = fixture()
    result, mapped, summary = inventory.apply_current_source_overlay(client, sdk, loaded(document))
    if field == "link":
        mapped["symbols"][0]["current_source_evidence"][0]["origin_report"] = "reports/original-b.md"
    else:
        for data in (result, mapped):
            current = data["current_source_reconciliation"]
            if field == "input": current["input"]["closures"][0]["scope"] = "expanded scope"
            elif field == "effective": current["effective_scopes"][0]["source_state"] = "source-open"
            else: current["report_anchors"].append({"text": "invented anchor"})
    with pytest.raises(ValueError):
        inventory.validate_current_source_overlay(result, mapped)


def write_overlay(tmp_path, document, texts):
    for path, text in texts.items():
        file = tmp_path / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text, encoding="utf-8", newline="\n")
    path = "docs/parity/current-source-followups.json"
    file = tmp_path / path
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(inventory._json_text(document), encoding="utf-8", newline="\n")
    return {"current_source_overlay": {"path": path, "sha256": hashlib.sha256(file.read_bytes()).hexdigest()}}


def test_report_hash_and_unique_anchor_are_checked_but_absent_policy_is_valid(tmp_path):
    client, sdk, document, texts = fixture()
    assert inventory.load_current_source_overlay(tmp_path, {}) is None
    policy = write_overlay(tmp_path, document, texts)
    evidence = inventory.load_current_source_overlay(tmp_path, policy)
    assert len(evidence["report_anchors"]) == 4
    assert evidence["report_anchors"][0]["line"] == 2
    (tmp_path / "reports/closed.md").write_text("later unrelated report")
    with pytest.raises(ValueError, match="unavailable"):
        inventory.load_current_source_overlay(tmp_path, policy)
    document["closures"][0]["reviews"][0]["anchor"] = "not present"
    policy = write_overlay(tmp_path, document, texts)
    with pytest.raises(ValueError, match="missing/ambiguous"):
        inventory.load_current_source_overlay(tmp_path, policy)


def test_later_report_edits_use_captured_git_bytes_without_relocating_old_claim(tmp_path, monkeypatch):
    # Legacy inputs without snapshot_path deliberately retain non-hermetic Git fallback.
    _, _, document, texts = fixture()
    document["documents"]["reports/closed.md"]["git_revision"] = "c" * 40
    policy = write_overlay(tmp_path, document, texts)
    (tmp_path / "reports/closed.md").write_text("new unrelated content\n" * 40)
    calls = []
    def git(args, **kwargs):
        calls.append(args)
        return texts["reports/closed.md"].encode()
    monkeypatch.setattr(subprocess, "check_output", git)
    evidence = inventory.load_current_source_overlay(tmp_path, policy)
    assert calls == [["git", "show", "c" * 40 + ":reports/closed.md"]]
    assert [row["line"] for row in evidence["report_anchors"] if row["path"] == "reports/closed.md"] == [2, 3]


def test_current_links_survive_ordinary_merge_without_changing_captured_source_layer():
    client, sdk, document, _ = fixture()
    result, mapped, summary = inventory.apply_current_source_overlay(client, sdk, loaded(document))
    rebuilt_client = inventory.merge_parity(client, result)
    rebuilt_sdk = inventory.merge_parity(sdk, mapped)
    assert rebuilt_client["current_source_reconciliation"] == summary
    assert rebuilt_sdk["symbols"][0]["current_source_evidence"] == mapped["symbols"][0]["current_source_evidence"]
    assert inventory.validate_current_source_overlay(rebuilt_client, rebuilt_sdk)["current_source_closed_scopes"] == 2


def test_ordinary_and_individual_only_cli_regeneration_preserve_overlay_and_raw_maps(tmp_path, monkeypatch):
    client, sdk, manifests = inputs()
    policy = write_manifests(tmp_path, manifests)
    _, _, document, _ = fixture()
    texts = {m["path"]: (tmp_path / m["path"]).read_text() for m in manifests}
    texts["reports/closed.md"] = "SDK SOURCE-CLOSED\nMODULE SOURCE-CLOSED\n"
    document["documents"] = {path: {"sha256": hashlib.sha256(text.encode()).hexdigest(), "bytes": len(text.encode())} for path, text in texts.items()}
    document["target_groups"]["b"] = [document["target_groups"]["b"][1]]
    for index, (path, identity, anchor) in enumerate((("maps/sdk.json", "OPEN-02", "SDK"), ("maps/module.json", "OPEN-01", "MODULE"))):
        document["origins"][index].update(origin_report=path, id=identity, anchor='"id": "' + identity + '"')
        document["closures"][index].update(origin_report=path, id=identity, reviews=[{"path": "reports/closed.md", "anchor": anchor + " SOURCE-CLOSED"}])
    policy.update(write_overlay(tmp_path, document, texts))
    docs = tmp_path / "docs/parity"
    (docs / "join-policy.json").write_text(inventory._json_text(policy))
    monkeypatch.setattr(inventory, "build_client_inventory", lambda *_: deepcopy(client))
    monkeypatch.setattr(inventory, "build_sdk_inventory", lambda *_: deepcopy(sdk))
    monkeypatch.setattr(inventory, "render_index", lambda *_: "fixture index\n")
    args = ["--project-root", str(tmp_path), "--docs", str(docs), "--out", str(tmp_path / "build"), "--docs-only"]
    assert inventory.main(args) == 0
    first = {name: (docs / name).read_bytes() for name in ("client-features.json", "sdk-surface.json", "individual-source-join.json", "current-source-reconciliation.json", "wave-2-reconciliation.json")}
    assert inventory.main(args + ["--check"]) == 0
    assert inventory.main(args + ["--individual-only", "--check"]) == 0
    assert inventory.main(args) == 0
    assert all((docs / name).read_bytes() == raw for name, raw in first.items())
    materialized = json.loads((docs / "sdk-surface.json").read_bytes())
    assert materialized["symbols"][0]["individual_source"]["reported"] == manifests[0]["document"]["symbols"][0]
    assert materialized["current_source_reconciliation"]["counts"]["source_closed_scopes"] == 2
    assert not (tmp_path / "shared.swift").exists()


def archive_reports(root, document, texts):
    document = deepcopy(document)
    document["require_report_snapshots"] = True
    for path, pin in document["documents"].items():
        raw = texts[path].encode("utf-8")
        assert hashlib.sha256(raw).hexdigest() == pin["sha256"]
        pin["snapshot_path"] = f"docs/parity/source-report-snapshots/{pin['sha256']}.md"
        file = root / pin["snapshot_path"]
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(raw)
    return document


def deny_subprocess(*args, **kwargs):
    pytest.fail("hermetic report loading/regeneration attempted Git or another subprocess")


@pytest.mark.parametrize("live", ["missing", "changed"])
def test_snapshots_alone_load_exact_captured_reports_without_git(tmp_path, monkeypatch, live):
    _, _, document, texts = fixture()
    # Preserve raw CRLF and Unicode too; an archive is not a re-rendered Markdown file.
    texts["reports/original-a.md"] = "# Captured А\r\n## F01 OPEN\r\n"
    raw = texts["reports/original-a.md"].encode()
    document["documents"]["reports/original-a.md"].update(sha256=hashlib.sha256(raw).hexdigest(), bytes=len(raw))
    document = archive_reports(tmp_path, document, texts)
    policy = write_overlay(tmp_path, document, texts)
    before = inventory.load_current_source_overlay(tmp_path, policy)
    for path in texts:
        if live == "missing": (tmp_path / path).unlink()
        else: (tmp_path / path).write_text("Later report\n" * 50)
    monkeypatch.setattr(subprocess, "check_output", deny_subprocess)
    monkeypatch.setattr(subprocess, "run", deny_subprocess)
    monkeypatch.setattr(subprocess, "Popen", deny_subprocess)
    assert inventory.load_current_source_overlay(tmp_path, policy) == before
    assert not (tmp_path / ".git").exists()


@pytest.mark.parametrize("corruption", ["bytes", "byte-count", "hash", "wrong-name", "wrong-folder", "traversal", "missing", "missing-pin", "over-bound"])
def test_required_report_snapshot_corruption_cannot_fall_back_to_live_or_git(tmp_path, monkeypatch, corruption):
    _, _, document, texts = fixture()
    document = archive_reports(tmp_path, document, texts)
    pin = document["documents"]["reports/closed.md"]
    snapshot = tmp_path / pin["snapshot_path"]
    if corruption == "bytes": snapshot.write_bytes(snapshot.read_bytes().replace(b"SOURCE-CLOSED", b"SOURCE-FAILED"))
    elif corruption == "byte-count": pin["bytes"] += 1
    elif corruption == "hash":
        pin["sha256"] = "f" * 64
        pin["snapshot_path"] = "docs/parity/source-report-snapshots/" + pin["sha256"] + ".md"
        (tmp_path / pin["snapshot_path"]).write_bytes(snapshot.read_bytes())
    elif corruption == "wrong-name": pin["snapshot_path"] = "docs/parity/source-report-snapshots/" + "f" * 64 + ".md"
    elif corruption == "wrong-folder": pin["snapshot_path"] = "reports/" + pin["sha256"] + ".md"
    elif corruption == "traversal": pin["snapshot_path"] = "../source-report-snapshots/" + pin["sha256"] + ".md"
    elif corruption == "missing": snapshot.unlink()
    elif corruption == "missing-pin": pin.pop("snapshot_path")
    else: pin["bytes"] = individual_routes.MAX_BYTES + 1
    # Live reports are still correct: a bad shipped archive must nevertheless fail.
    policy = write_overlay(tmp_path, document, texts)
    monkeypatch.setattr(subprocess, "check_output", deny_subprocess)
    with pytest.raises(ValueError):
        inventory.load_current_source_overlay(tmp_path, policy)


def test_snapshot_symlink_escape_is_rejected_even_when_external_bytes_match(tmp_path, monkeypatch):
    project = tmp_path / "project"
    _, _, document, texts = fixture()
    document = archive_reports(project, document, texts)
    policy = write_overlay(project, document, texts)
    snapshot = project / document["documents"]["reports/closed.md"]["snapshot_path"]
    outside = tmp_path / "outside.md"
    outside.write_bytes(snapshot.read_bytes())
    snapshot.unlink()
    try:
        snapshot.symlink_to(outside)
    except OSError:
        # Windows without symlink privilege: exercise the same resolved-boundary
        # guard, without skipping it or reading the external file through the loader.
        snapshot.write_bytes(outside.read_bytes())
        original_resolve = type(snapshot).resolve
        def resolve(path, *args, **kwargs):
            return outside if path == snapshot else original_resolve(path, *args, **kwargs)
        monkeypatch.setattr(type(snapshot), "resolve", resolve)
    monkeypatch.setattr(subprocess, "check_output", deny_subprocess)
    with pytest.raises(ValueError, match="outside project"):
        inventory.load_current_source_overlay(project, policy)


@pytest.mark.parametrize("text", ["# Review\nB SOURCE-CLOSED\n", "A SOURCE-CLOSED\nA SOURCE-CLOSED\nB SOURCE-CLOSED\n"])
def test_valid_snapshot_hash_does_not_waive_missing_or_ambiguous_verdict_anchor(tmp_path, monkeypatch, text):
    _, _, document, texts = fixture()
    texts["reports/closed.md"] = text
    document["documents"]["reports/closed.md"].update(sha256=hashlib.sha256(text.encode()).hexdigest(), bytes=len(text.encode()))
    document = archive_reports(tmp_path, document, texts)
    policy = write_overlay(tmp_path, document, texts)
    for path in texts: (tmp_path / path).unlink()
    monkeypatch.setattr(subprocess, "check_output", deny_subprocess)
    with pytest.raises(ValueError, match="missing/ambiguous"):
        inventory.load_current_source_overlay(tmp_path, policy)


@pytest.mark.parametrize("live", ["missing", "changed"])
def test_shallow_source_free_cli_uses_captured_snapshots_in_both_generation_modes(tmp_path, monkeypatch, live):
    client, sdk, manifests = inputs()
    # These immutable JSON author maps are inventory inputs, not a live source tree.
    policy = write_manifests(tmp_path, manifests)
    _, _, document, _ = fixture()
    texts = {m["path"]: (tmp_path / m["path"]).read_text() for m in manifests}
    texts["reports/closed.md"] = "SDK SOURCE-CLOSED\nMODULE SOURCE-CLOSED\n"
    document["documents"] = {p: {"sha256": hashlib.sha256(t.encode()).hexdigest(), "bytes": len(t.encode())} for p, t in texts.items()}
    document["target_groups"]["b"] = [document["target_groups"]["b"][1]]
    for index, (path, identity, anchor) in enumerate((("maps/sdk.json", "OPEN-02", "SDK"), ("maps/module.json", "OPEN-01", "MODULE"))):
        document["origins"][index].update(origin_report=path, id=identity, anchor='"id": "' + identity + '"')
        document["closures"][index].update(origin_report=path, id=identity, reviews=[{"path": "reports/closed.md", "anchor": anchor + " SOURCE-CLOSED"}])
    document = archive_reports(tmp_path, document, texts)
    policy.update(write_overlay(tmp_path, document, texts))
    docs = tmp_path / "docs/parity"
    (docs / "join-policy.json").write_text(inventory._json_text(policy))
    (docs / "client-features.json").write_text(inventory._json_text(client))
    (docs / "sdk-surface.json").write_text(inventory._json_text(sdk))
    # Simulate the ordinary scanner's inventory data without any source files.
    monkeypatch.setattr(inventory, "build_client_inventory", lambda *_: deepcopy(client))
    monkeypatch.setattr(inventory, "build_sdk_inventory", lambda *_: deepcopy(sdk))
    monkeypatch.setattr(inventory, "render_index", lambda *_: "fixture index\n")
    monkeypatch.setattr(subprocess, "check_output", deny_subprocess)
    monkeypatch.setattr(subprocess, "run", deny_subprocess)
    monkeypatch.setattr(subprocess, "Popen", deny_subprocess)
    args = ["--project-root", str(tmp_path), "--docs", str(docs), "--out", str(tmp_path / "build"), "--docs-only"]
    assert inventory.main(args) == 0
    names = ("client-features.json", "sdk-surface.json", "individual-source-join.json", "current-source-reconciliation.json", "wave-2-reconciliation.json")
    before = {name: (docs / name).read_bytes() for name in names}
    anchors = json.loads(before["current-source-reconciliation.json"])["report_anchors"]
    if live == "missing": (tmp_path / "reports/closed.md").unlink()
    else: (tmp_path / "reports/closed.md").write_text("new unrelated report\n" * 50)
    assert inventory.main(args + ["--check"]) == 0
    assert inventory.main(args) == 0
    monkeypatch.setattr(inventory, "build_client_inventory", lambda *_: pytest.fail("individual-only scanned source"))
    monkeypatch.setattr(inventory, "build_sdk_inventory", lambda *_: pytest.fail("individual-only scanned SDK"))
    assert inventory.main(args + ["--individual-only", "--check"]) == 0
    assert inventory.main(args + ["--individual-only"]) == 0
    assert all((docs / name).read_bytes() == value for name, value in before.items())
    assert json.loads((docs / "current-source-reconciliation.json").read_bytes())["report_anchors"] == anchors
    assert not (tmp_path / ".git").exists() and not (tmp_path / "python").exists()
