"""Pure exact-identity joins for independently captured source-route receipts.

Only ``load_manifests`` reads files. No SDK imports, source execution, live source
rehashing, or inferred implementation/verification is part of the join.
"""

from collections import Counter
from copy import deepcopy
import hashlib
import json
from pathlib import Path, PurePosixPath
import re


MAX_MANIFESTS = 16
MAX_BYTES = 16 * 1024 * 1024
MAX_ROWS = 12000
MAX_PINS = 2048
MAX_ROUTE = 64
SDK_DISPOSITIONS = {"pure-sdk", "native-adapter", "plugin-contract", "metadata", "unsupported", "partial"}
MODULE_DISPOSITIONS = SDK_DISPOSITIONS | {
    "native-adaptation", "native-lifecycle-adaptation", "native-flow",
    "equivalent-platform-role", "source-routed", "member-body",
    "platform-lifecycle", "platform-renderer",
}
DECLARATION_FIELDS = ("id", "module", "name", "kind", "line", "android_line", "parameters", "return_annotation", "origin")
ORIGINAL_ROOT = "third_party/exteraless-android/TMessagesProj/src/main/"
REPORT_PATH = "docs/parity/individual-source-join.json"


def fingerprint(value):
    raw = json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def declaration(record):
    return {key: deepcopy(record[key]) for key in DECLARATION_FIELDS if key in record}


def _path(value):
    if not isinstance(value, str) or not value or len(value) > 2048 or "\\" in value or ":" in value or "\0" in value:
        raise ValueError(f"invalid source-route path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or path.as_posix() != value:
        raise ValueError(f"non-relative source-route path: {value!r}")
    return value


def _sha(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ValueError("source-route receipt requires a raw SHA-256")
    return value


def _list(value, label, maximum=MAX_ROWS, nonempty=False):
    if not isinstance(value, list) or len(value) > maximum or nonempty and not value:
        raise ValueError(f"invalid/bounded source-route {label}")
    return value


def _text(value, label):
    if not isinstance(value, str) or not value.strip() or len(value) > 32768:
        raise ValueError(f"missing/bounded source-route {label}")


def _flags(value, required=False):
    for key in ("ported", "verified", "native_execution_claimed"):
        if key in value and value[key] is not False:
            raise ValueError(f"source route cannot promote {key}")
    if required and any(value.get(key) is not False for key in ("ported", "verified")):
        raise ValueError("source route requires explicit false ported/verified")
    implementation = value.get("implementation", {})
    if not isinstance(implementation, dict):
        raise ValueError("invalid source-route implementation claim")
    if implementation.get("status") in {"verified", "stock-equivalent-verified", "implemented"}:
        raise ValueError("source route cannot supply an implementation promotion")


def _reference(ref):
    if not isinstance(ref, dict):
        raise ValueError("route step must be an object")
    _path(ref.get("path"))
    _text(ref.get("symbol"), "symbol")
    _text(ref.get("role"), "role")
    if "line" in ref and (type(ref["line"]) is not int or ref["line"] < 1):
        raise ValueError("route line must be a positive original integer")


def _claim(row, dispositions, sdk=False):
    if not isinstance(row, dict) or row.get("disposition") not in dispositions:
        raise ValueError("unknown source-route disposition")
    _flags(row, required=True)
    if sdk and row.get("native_execution_claimed") is not False:
        raise ValueError("SDK source route requires native_execution_claimed=false")
    _text(row.get("contract"), "contract")
    limitations = row.get("limitations")
    if not isinstance(limitations, (list, dict)):
        raise ValueError("source route must retain typed limitations")
    if row["disposition"] in {"partial", "unsupported"} and not limitations:
        raise ValueError("partial/unsupported source route must name its limitation")
    for ref in _list(row.get("route"), "steps", MAX_ROUTE, nonempty=True):
        _reference(ref)
    if sdk:
        _list(row.get("evidence"), "evidence", MAX_ROUTE, nonempty=True)


def member_identity(original):
    if not isinstance(original, dict):
        raise ValueError("module member requires structured original identity")
    file = _path(original.get("file"))
    _text(original.get("name"), "original method name")
    parameters = _list(original.get("parameter_types"), "parameter types", 64)
    if any(not isinstance(value, str) for value in parameters):
        raise ValueError("parameter types must retain their original string tokens")
    line = original.get("line")
    if type(line) is not int or line < 1:
        raise ValueError("original method line must be a positive integer")
    return file, original["name"], tuple(parameters), line


def member_key(original):
    file, name, parameters, line = member_identity(original)
    return f"{file}::{name}({','.join(parameters)})@{line}"


def _exact(rows, key, expected, label):
    indexed = {}
    for row in _list(rows, label):
        identity = key(row)
        if identity in indexed:
            raise ValueError(f"duplicate {label} identity: {identity}")
        indexed[identity] = row
    missing, unknown = set(expected) - indexed.keys(), indexed.keys() - set(expected)
    if missing or unknown:
        raise ValueError(f"{label} identity mismatch: missing={len(missing)}, unknown={len(unknown)}; "
                         f"sample={sorted(map(str, missing | unknown))[:3]}")
    return indexed


def _symbol_claim(record, row, modules):
    _claim(row, SDK_DISPOSITIONS, sdk=True)
    if row.get("id") != record["id"]:
        raise ValueError("individual SDK identity changed")
    original = row.get("original", {})
    module = modules[record["module"]]
    paths = {module["file"]: record["line"]}
    if module.get("android_file"):
        paths[ORIGINAL_ROOT + module["android_file"]] = record.get("android_line")
    if (original.get("path") not in paths or original.get("line") != paths[original["path"]]
            or original.get("symbol") != record["name"]):
        raise ValueError(f"individual SDK original declaration changed: {record['id']}")
    for key in DECLARATION_FIELDS:
        if key in row and row[key] != record.get(key):
            raise ValueError(f"individual SDK original signature changed: {record['id']}: {key}")


def _module_claim(record, reported):
    _flags(reported)
    if reported.get("module_id") != record["id"]:
        raise ValueError("module route original module identity changed")
    originals = {member_identity(row): row for row in record["public_method_bodies"]}
    if len(originals) != len(record["public_method_bodies"]):
        raise ValueError("duplicate Original module identity")
    members = _exact(reported.get("members"), lambda row: member_identity(row.get("original")), originals, record["id"])
    for identity, row in members.items():
        _claim(row, MODULE_DISPOSITIONS)
        original = originals[identity]
        for supplied, target in (("original_result_type", "type"), ("original_binding", "binding")):
            if supplied in row and row[supplied] != original.get(target):
                raise ValueError(f"module original signature changed: {identity}: {supplied}")
        for key in ("arity", "type", "binding"):
            if key in row["original"] and row["original"][key] != original.get(key):
                raise ValueError(f"module original signature changed: {identity}: {key}")
    if "member_routes" in reported:
        keys = [member_key(row) for row in record["public_method_bodies"]]
        if len(keys) != len(set(keys)):
            raise ValueError("ambiguous string projection of structured module identities")
        routes = _exact(reported["member_routes"], lambda row: row.get("original_API_or_sdk_id"), keys, "member_routes")
        member_by_key = {member_key(row["original"]): row for row in members.values()}
        for identity, route in routes.items():
            _flags(route)
            _text(route.get("admission_lifecycle"), "admission_lifecycle")
            for key in ("provider_owner", "unavailable_reason"):
                if key not in route:
                    raise ValueError(f"member route requires explicit {key}, including null")
                if route[key] is not None:
                    _text(route[key], key)
            if "native_operation" not in route or route["native_operation"] is not None and not isinstance(route["native_operation"], str):
                raise ValueError("member route requires typed native_operation or explicit null")
            if route["provider_owner"] is None and route["native_operation"] is not None:
                raise ValueError("native operation has no provider owner")
            if member_by_key[identity]["disposition"] in {"partial", "unsupported"} and not route["unavailable_reason"]:
                raise ValueError("partial member route lost its unavailable reason")
            _list(route.get("evidence"), "member route evidence", MAX_ROUTE, nonempty=True)
    if "routes" in reported:
        ids = set()
        for route in _list(reported["routes"], "named routes"):
            _flags(route)
            _text(route.get("id"), "named route id")
            if route["id"] in ids:
                raise ValueError(f"duplicate named route: {route['id']}")
            ids.add(route["id"])
            for key in ("original_row_or_action", "search_route", "subpage_route", "reset_route", "unavailable_behavior"):
                _text(route.get(key), key)
            entry = route.get("native_entry")
            if not isinstance(entry, (dict, str)) or not entry:
                raise ValueError("named route requires an explicit native entry or unavailable reason")
            _list(route.get("evidence"), "named route evidence", MAX_ROUTE, nonempty=True)
    return members


def captured_pins(document):
    """Keep pins per receipt; a shared path at another read time is not an ID collision."""
    table = document.get("source_sha256", document.get("hash_pins", document.get("pins", {})).get("files", {}))
    if not isinstance(table, dict) or len(table) > MAX_PINS:
        raise ValueError("invalid/bounded captured source pin table")
    result = []
    for path, value in sorted(table.items()):
        pin = {"sha256": value} if isinstance(value, str) else deepcopy(value)
        if not isinstance(pin, dict):
            raise ValueError("invalid captured source pin")
        _sha(pin.get("sha256"))
        if "bytes" in pin and (type(pin["bytes"]) is not int or pin["bytes"] < 0):
            raise ValueError("invalid captured byte count")
        result.append({**pin, "path": _path(path)})
    return result


def _json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def load_manifests(project, policy):
    """Read only the optional explicit list; absent policy is valid for small fixtures."""
    result, paths, owners = [], set(), set()
    project = Path(project).resolve()
    for entry in _list(policy.get("individual_manifests", []), "manifest list", MAX_MANIFESTS):
        path = _path(entry.get("path"))
        owner = entry.get("owner")
        _text(owner, "manifest owner")
        if path in paths or owner in owners:
            raise ValueError("duplicate individual manifest path/owner")
        paths.add(path)
        owners.add(owner)
        file = project / path
        if not file.resolve().is_relative_to(project) or not file.is_file():
            raise ValueError(f"individual manifest not found in project: {path}")
        if file.stat().st_size > MAX_BYTES:
            raise ValueError(f"individual manifest exceeds byte bound: {path}")
        raw = file.read_bytes()
        if len(raw) > MAX_BYTES:
            raise ValueError(f"individual manifest exceeds byte bound: {path}")
        sha = hashlib.sha256(raw).hexdigest()
        if "sha256" in entry and sha != _sha(entry["sha256"]):
            raise ValueError(f"individual manifest revision changed; explicit policy update required: {path}")
        document = json.loads(raw.decode("utf-8"), object_pairs_hook=_json_object,
                              parse_constant=lambda value: (_ for _ in ()).throw(ValueError("nonfinite JSON value")))
        result.append({**deepcopy(entry), "sha256": sha, "bytes": len(raw), "document": document})
    return result


def _relation(source):
    row = source["reported"]
    return {"status": "source-route-" + row["disposition"], "disposition": row["disposition"],
            "receipt": deepcopy(source["receipt"]), "route_field": "individual_source.reported.route",
            "limitations": deepcopy(row["limitations"]),
            "reference_scope": "Captured owner source boundary and original line numbers; not live/tested anchors",
            "verified": False, "ported": False, "native_execution_claimed": False}


def preserve_record(current, previous):
    """Preserve the individual layer through ordinary and legacy source regeneration."""
    source = previous.get("individual_source")
    if source is None:
        return
    if fingerprint(source["reported"]) != source["reported_fingerprint"]:
        raise ValueError("captured individual route/limitation was modified")
    projection = current["public_method_bodies"] if source["kind"] == "module-members" else declaration(current)
    if fingerprint(projection) != source["original_fingerprint"]:
        raise ValueError(f"individual route Original signature/index changed: {current['id']}")
    current["individual_source"] = deepcopy(source)
    if source["kind"] == "sdk-symbol":
        current.setdefault("static_native_relation", deepcopy(current["native_relation"]))
        current["native_relation"] = _relation(source)
    else:
        _fulfill_rollup(current, source)


def _fulfill_rollup(record, source):
    rollup = record.get("rollup")
    if isinstance(rollup, dict):
        if "authorship_needed" in rollup:
            rollup["historical_authorship_needed"] = rollup.pop("authorship_needed")
        rollup["authorship_provided_by"] = deepcopy(source["receipt"])
        rollup["authorship_boundary"] = "Exact member/route authorship supplied; partial/unsupported contracts and native acceptance remain separate."


def refresh_sdk_counts(sdk):
    sdk.setdefault("totals", {})["native_relation"] = dict(sorted(Counter(row["native_relation"]["status"] for row in sdk["symbols"]).items()))


def _verified(client, sdk):
    rows = list(sdk.get("symbols", []))
    for key in ("features", "compatibility_apis", "modules", "legacy_trees"):
        section = client.get(key, [])
        rows.extend(section.values() if isinstance(section, dict) else section)
    return sorted(row["id"] for row in rows if row.get("implementation", {}).get("ported"))


def join(client, sdk, manifests, context=None):
    """Join complete SDK/module identity sets; never resolve a provider from a name."""
    result, surface = deepcopy(client), deepcopy(sdk)
    if not manifests:
        return result, surface, None
    _list(manifests, "manifests", MAX_MANIFESTS)
    before = _verified(client, sdk)
    originals = {row["id"]: row for row in surface.get("symbols", [])}
    if len(originals) != len(surface.get("symbols", [])):
        raise ValueError("duplicate original SDK identity")
    seen_ids, seen_modules, seen_owners, metadata, findings = set(), set(), set(), [], []
    for manifest in manifests:
        document = manifest["document"]
        if document.get("schema_version", document.get("schema")) != 1:
            raise ValueError("unknown individual receipt schema")
        _flags(document)
        boundary = document.get("source_boundary")
        if not isinstance(boundary, (dict, str)) or not boundary:
            raise ValueError("individual receipt requires its captured source boundary")
        if isinstance(boundary, dict):
            _flags(boundary)
        owner = manifest["owner"]
        if owner in seen_owners:
            raise ValueError("duplicate individual owner")
        seen_owners.add(owner)
        receipt = {"owner": owner, "path": _path(manifest["path"]), "sha256": _sha(manifest["sha256"])}
        pins = captured_pins(document)
        meta = {**receipt, "bytes": manifest["bytes"], "kind": manifest["kind"], "source_pins": pins,
                "source_pin_field_count": len(pins),
                "reported_metadata": {k: deepcopy(v) for k, v in document.items() if k not in {"symbols", "members", "routes", "member_routes"}}}
        for key in ("captured_revision", "inventory_revision", "source_pin_note"):
            if key in manifest:
                meta[key] = manifest[key]
        if manifest["kind"] == "sdk":
            modules = _list(document.get("modules"), "SDK modules", 64, nonempty=True)
            if len(set(modules)) != len(modules) or not set(modules) <= surface["modules"].keys():
                raise ValueError("duplicate/unknown individual SDK module")
            pin_table = {pin["path"]: pin["sha256"] for pin in pins}
            for name in modules:
                module = surface["modules"][name]
                for path, sha in ((module["file"], module.get("sha256")),
                                  (ORIGINAL_ROOT + module["android_file"] if module.get("android_file") else None, module.get("android_sha256"))):
                    if path in pin_table and sha is not None and pin_table[path] != sha:
                        raise ValueError(f"captured Original SDK source changed: {path}")
            expected = {fid for fid, row in originals.items() if row["module"] in modules}
            rows = _exact(document.get("symbols"), lambda row: row.get("id"), expected, owner)
            if seen_ids & rows.keys():
                raise ValueError("duplicate SDK identity across individual manifests")
            seen_ids.update(rows)
            for fid, row in rows.items():
                target = originals[fid]
                _symbol_claim(target, row, surface["modules"])
                source = {"kind": "sdk-symbol", "receipt": deepcopy(receipt),
                          "original_fingerprint": fingerprint(declaration(target)),
                          "reported_fingerprint": fingerprint(row), "reported": deepcopy(row)}
                target["individual_source"] = source
                target.setdefault("static_native_relation", deepcopy(target["native_relation"]))
                target["native_relation"] = _relation(source)
                if not target["implementation"].get("ported"):
                    target["implementation"] = {"status": "unsupported" if row["disposition"] == "unsupported" else "partial",
                                                "ported": False, "evidence": [{"kind": "source", **deepcopy(receipt), "id": fid}]}
            sig = boundary.get("original_signature_projection_sha256") if isinstance(boundary, dict) else None
            if sig:
                projection = [{k: originals[fid][k] for k in ("id", "kind", "parameters", "return_annotation", "origin") if k in originals[fid]} for fid in sorted(rows)]
                if fingerprint(projection) != sig:
                    raise ValueError("captured SDK original signature projection changed")
            meta["modules"] = modules
            meta["record_ids"] = sorted(rows)
            meta["original_identity_fingerprint"] = fingerprint([declaration(originals[fid]) for fid in sorted(rows)])
        elif manifest["kind"] == "module":
            module_id = document.get("module_id")
            if module_id != manifest.get("module_id") or module_id in seen_modules:
                raise ValueError("duplicate/incorrect individual module identity")
            targets = {row["id"]: row for row in result.get("modules", {}).values()}
            if module_id not in targets:
                raise ValueError(f"unknown individual module: {module_id}")
            seen_modules.add(module_id)
            target = targets[module_id]
            rows = _module_claim(target, document)
            reported = {k: deepcopy(document[k]) for k in ("module_id", "members", "routes", "member_routes", "remaining_portable_routes") if k in document}
            source = {"kind": "module-members", "receipt": deepcopy(receipt),
                      "original_fingerprint": fingerprint(target["public_method_bodies"]),
                      "reported_fingerprint": fingerprint(reported), "reported": reported}
            target["individual_source"] = source
            _fulfill_rollup(target, source)
            meta.update(module_id=module_id, original_identity_fingerprint=source["original_fingerprint"],
                        named_routes=len(document.get("routes", [])), member_routes=len(document.get("member_routes", [])))
            meta["named_action_routes"] = sum(row["id"].startswith("action:") for row in document.get("routes", []))
            meta["other_named_routes"] = meta["named_routes"] - meta["named_action_routes"]
            for expected, actual in (("expected_named_routes", "named_routes"), ("expected_action_routes", "named_action_routes"), ("expected_member_routes", "member_routes")):
                if expected in manifest and manifest[expected] != meta[actual]:
                    raise ValueError(f"individual module route count changed: {module_id}: {actual}")
        else:
            raise ValueError("unknown individual manifest kind")
        if len(rows) != manifest.get("expected_count"):
            raise ValueError(f"individual expected-count mismatch: {owner}")
        meta.update(records=len(rows), dispositions=dict(sorted(Counter(row["disposition"] for row in rows.values()).items())))
        metadata.append(meta)
        for finding in _list(document.get("findings", []), "findings", MAX_ROWS):
            findings.append({"receipt": deepcopy(receipt), "reported": deepcopy(finding), "closed_by_this_join": False})
    if any(item["kind"] == "sdk" for item in manifests) and seen_ids != originals.keys():
        raise ValueError("individual SDK partition is not complete")
    if _verified(result, surface) != before:
        raise ValueError("individual source join changed verification")
    refresh_sdk_counts(surface)
    summary = {"schema_version": 1, "kind": "individual-source-route-reconciliation", "report": REPORT_PATH,
               "manifests": metadata, "findings": findings, "context": deepcopy(context or {}),
               "previous_verified_ids": before,
               "counts": {"sdk_symbols": len(seen_ids), "module_maps": len(seen_modules),
                          "module_members": sum(m["records"] for m in metadata if m["kind"] == "module"),
                          "sdk_dispositions": dict(sorted(Counter(row["individual_source"]["reported"]["disposition"] for row in surface["symbols"] if "individual_source" in row).items())),
                          "module_dispositions": dict(sorted(Counter(member["disposition"] for row in result["modules"].values() if "individual_source" in row for member in row["individual_source"]["reported"]["members"]).items())),
                          "source_pin_fields": sum(m["source_pin_field_count"] for m in metadata),
                          "verified_before": len(before), "verified_after": len(before)},
               "boundary": "Exact captured source routes/dispositions, including missing providers and historical findings. No runtime/native/visual verification promotion; shared paths keep each receipt's hash and source boundary."}
    result["individual_source_reconciliation"] = deepcopy(summary)
    surface["individual_source_reconciliation"] = deepcopy(summary)
    validate(result, surface)
    return result, surface, summary


def validate(client, sdk):
    metadata = sdk.get("individual_source_reconciliation", client.get("individual_source_reconciliation"))
    if not metadata:
        return {}
    if client.get("individual_source_reconciliation") != sdk.get("individual_source_reconciliation"):
        raise ValueError("client/SDK individual manifest cohorts differ")
    receipts = {(m["owner"], m["path"], m["sha256"]): m for m in metadata["manifests"]}
    found, declarations, module_ids = Counter(), {}, set()
    seen = set()
    for row in [*sdk.get("symbols", []), *client.get("modules", {}).values()]:
        source = row.get("individual_source")
        if source is None:
            continue
        receipt = source["receipt"]
        key = tuple(receipt[k] for k in ("owner", "path", "sha256"))
        if key not in receipts:
            raise ValueError("individual record has no pinned owner manifest")
        if row["id"] in seen:
            raise ValueError("duplicate materialized individual identity")
        seen.add(row["id"])
        if fingerprint(source["reported"]) != source["reported_fingerprint"]:
            raise ValueError("captured individual route/limitation was modified")
        if source["kind"] == "sdk-symbol":
            _symbol_claim(row, source["reported"], sdk["modules"])
            projection = declaration(row)
            if row["native_relation"] != _relation(source):
                raise ValueError("individual SDK disposition/route relation lost")
            found[key] += 1
            declarations.setdefault(key, []).append(projection)
        elif source["kind"] == "module-members":
            _module_claim(row, source["reported"])
            projection = row["public_method_bodies"]
            found[key] += len(source["reported"]["members"])
            module_ids.add(row["id"])
        else:
            raise ValueError("unknown materialized individual record kind")
        if fingerprint(projection) != source["original_fingerprint"]:
            raise ValueError("materialized individual original signature/index changed")
    if any(found[key] != meta["records"] for key, meta in receipts.items()):
        raise ValueError("materialized individual identity partition incomplete")
    for key, rows in declarations.items():
        rows.sort(key=lambda row: row["id"])
        if [row["id"] for row in rows] != receipts[key]["record_ids"] or fingerprint(rows) != receipts[key]["original_identity_fingerprint"]:
            raise ValueError("materialized individual SDK identity/signature partition changed")
    if _verified(client, sdk) != metadata["previous_verified_ids"]:
        raise ValueError("individual source data changed verification")
    if len(module_ids) != metadata["counts"]["module_maps"] or sum(len(rows) for rows in declarations.values()) != metadata["counts"]["sdk_symbols"]:
        raise ValueError("individual materialized totals changed")
    return {"individual_sdk_symbols": metadata["counts"]["sdk_symbols"],
            "individual_module_maps": metadata["counts"]["module_maps"],
            "individual_module_members": metadata["counts"]["module_members"]}


def reconcile(report, client, sdk, summary):
    """Refresh only the derived SDK/module projection, retaining older cohort facts."""
    result = deepcopy(report or {})
    result["individual_source_reconciliation"] = deepcopy(summary)
    if "sdk_925_boundary" in result and result["sdk_925_boundary"] != summary["boundary"]:
        result.setdefault("historical_sdk_925_boundary", result["sdk_925_boundary"])
    result["sdk_925_boundary"] = summary["boundary"]
    result["sdk_symbol_partition"] = {status: [row["id"] for row in sdk["symbols"] if row["native_relation"]["status"] == status]
                                      for status in sorted({row["native_relation"]["status"] for row in sdk["symbols"]})}
    needs = result.setdefault("module_authorship_needs", {})
    for row in client.get("modules", {}).values():
        if "individual_source" in row and row["id"] in needs:
            result.setdefault("historical_module_authorship_needs", {})[row["id"]] = needs.pop(row["id"])
    for row in result.get("module_map", []):
        native = next(item for item in client["modules"].values() if item["id"] == row["id"])
        if "individual_source" in native:
            row["individual_source_receipt"] = deepcopy(native["individual_source"]["receipt"])
            row["individual_member_count"] = len(native["individual_source"]["reported"]["members"])
            row["scope"] = deepcopy(native.get("rollup", row.get("scope")))
    result["individual_data_checks"] = validate(client, sdk)
    return result
