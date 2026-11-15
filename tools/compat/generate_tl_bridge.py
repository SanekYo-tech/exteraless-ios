#!/usr/bin/env python3
"""Generate the plugin TL data registry from the *native build input*.

No network, SDK imports or code execution from the Android sources. Java names
are admitted only by an actual declared constructor id, never by TL_ spelling.
Run --check in CI after changing swift_scheme.tl or the Android reference.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "telegram-ios/submodules/TelegramApi/swift_scheme.tl"
ANDROID = ROOT / "third_party/exteraless-android/TMessagesProj/src/main/java/org/telegram/tgnet"
JSON_OUTPUT = ROOT / "python/runtime/tl-schema.json"
SWIFT_OUTPUT = ROOT / "telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLSchemaGenerated.swift"

DECLARATION = re.compile(r"([\w.]+)#([0-9a-fA-F]{1,8})\s*(.*?)\s*=\s*(.*?)\s*;", re.S)
OPTIONAL = re.compile(r"(\w+)\.(\d+)\?(.+)")
PRIMITIVES = {"int", "long", "double", "string", "bytes", "int128", "int256", "#", "true"}
JAVA_NOISE = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', re.S)
JAVA_TOKENS = re.compile(
    r"\b(?:class|interface|enum)\s+(?P<name>\w+)(?P<base>[^{};]*)\{"
    r"|\b(?:public\s+)?static\s+(?:final\s+)?int\s+constructor\s*=\s*(?P<id>0x[\da-fA-F]+|-?\d+)\s*;"
    r"|(?P<brace>[{}])"
)


def signed32(value: int) -> int:
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value >= 0x80000000 else value


def native_layout_hash(source: str) -> str:
    """Same FNV-1a as SwiftTL/main.swift; line endings are normalized by git."""
    value = 0xCBF29CE484222325
    for byte in (source + "SwiftTL-Storage/1").encode("utf-8"):
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{value:016x}"


def parse_schema(source: str) -> list[dict]:
    source = re.sub(r"//[^\n]*", "", source)
    records: list[dict] = []
    kind = "constructor"
    for line_number, line in enumerate(source.splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        if line in ("---functions---", "---types---"):
            kind = "method" if line == "---functions---" else "constructor"
            continue
        match = DECLARATION.fullmatch(line)
        if not match:
            raise ValueError(f"TL line {line_number}: unrecognized declaration")
        name, constructor, arguments, result = match.groups()
        generic = bool(re.search(r"\{.*?\}", arguments))
        arguments = re.sub(r"\{.*?\}", "", arguments).strip()
        fields = []
        if name != "vector":
            for argument in arguments.split():
                if ":" not in argument:
                    raise ValueError(f"{name}: invalid field {argument}")
                field_name, field_type = argument.split(":", 1)
                fields.append({"name": field_name, "type": field_type})
        unsupported = "generic TL transport envelope" if generic else None
        if name == "vector":
            unsupported = "use a typed Vector<T> value"
        records.append({"id": signed32(int(constructor, 16)), "name": name,
                        "kind": kind, "params": fields, "type": result,
                        "supported": unsupported is None,
                        **({"unsupportedReason": unsupported} if unsupported else {})})

    # SwiftTL adds exactly this native diagnostic method (not in swift_scheme.tl).
    records.append({"id": signed32(0xC0E202F7), "name": "help.test", "kind": "method",
                    "params": [], "type": "Bool", "supported": True,
                    "source": "SwiftTL/main.swift"})
    validate_schema(records)
    return records


def validate_schema(records: list[dict]) -> None:
    names, ids = set(), set()
    types = {r["type"] for r in records if r["kind"] == "constructor" and r["supported"]}
    constructors = {r["name"] for r in records if r["kind"] == "constructor" and r["supported"]}

    def validate_type(value: str) -> None:
        vector = re.fullmatch(r"(?:Vector|vector)<(.+)>", value)
        if vector:
            validate_type(vector[1])
        elif value not in PRIMITIVES | types | constructors:
            raise ValueError(f"unresolved TL type {value}")

    for record in records:
        if record["name"] in names or record["id"] in ids:
            raise ValueError(f"duplicate TL name/id: {record['name']}")
        names.add(record["name"])
        ids.add(record["id"])
        if not record["supported"]:
            continue
        flags = set()
        fields = set()
        for field in record["params"]:
            if field["name"] in fields or field["name"] == "_":
                raise ValueError(f"duplicate/reserved field: {record['name']}.{field['name']}")
            fields.add(field["name"])
            field_type = field["type"]
            condition = OPTIONAL.fullmatch(field_type)
            if condition:
                if condition[1] not in flags or not 0 <= int(condition[2]) < 32:
                    raise ValueError(f"invalid flags reference: {record['name']}.{field['name']}")
                field_type = condition[3]
            if field_type == "#":
                if condition:
                    raise ValueError("optional flags word")
                flags.add(field["name"])
            validate_type(field_type)
        validate_type(record["type"])


def java_classes(path: Path) -> list[dict]:
    """Track brace scopes, so constructors in a method/string cannot create aliases."""
    raw = path.read_text(encoding="utf-8")
    clean = JAVA_NOISE.sub(lambda m: "\n" * m[0].count("\n") + " " * (len(m[0]) - m[0].count("\n")), raw)
    package = re.search(r"\bpackage\s+([\w.]+)\s*;", clean)
    if not package:
        raise ValueError(f"missing Java package: {path}")
    stack: list[dict | None] = []
    result = []
    for token in JAVA_TOKENS.finditer(clean):
        if token["name"]:
            parents = [item["simpleName"] for item in stack if item is not None]
            # All reference TL classes are top-level or nested directly in a class.
            # A local class inside a method is not part of the public data registry.
            if stack and stack[-1] is None:
                stack.append(None)
                continue
            base = re.search(r"\bextends\s+([\w.$]+)", token["base"])
            record = {"fqcn": package[1] + "." + "$".join(parents + [token["name"]]),
                      "simpleName": token["name"], "base": base[1] if base else None,
                      "path": path.relative_to(ROOT).as_posix() if path.is_relative_to(ROOT) else path.name}
            stack.append(record)
            result.append(record)
        elif token["id"]:
            if stack and stack[-1] is not None:
                record = stack[-1]
                if "id" in record:
                    raise ValueError(f"duplicate Java constructor: {record['fqcn']}")
                record["id"] = signed32(int(token["id"], 0))
        elif token["brace"] == "{":
            stack.append(None)
        elif stack:
            stack.pop()
        else:
            raise ValueError(f"unbalanced Java class scopes: {path}")
    if stack:
        raise ValueError(f"unclosed Java class scopes: {path}")
    return result


def android_registry(records: list[dict], root: Path) -> dict:
    paths = [root / "TLRPC.java"] + sorted((root / "tl").glob("*.java"))
    classes = [item for path in paths for item in java_classes(path)]
    by_id = {r["id"]: r for r in records}
    aliases, unavailable, field_aliases = {}, {}, {}
    by_fqcn = {c["fqcn"]: c for c in classes}
    base_results: dict[str, set[str]] = {}

    def base_of(item: dict) -> dict | None:
        base = item["base"]
        if not base:
            return None
        namespace = item["fqcn"].rsplit("$", 1)[0]
        candidates = [namespace + "$" + base, "org.telegram.tgnet." + base.replace(".", "$"),
                      "org.telegram.tgnet.tl." + base.replace(".", "$"), base]
        return next((by_fqcn[n] for n in candidates if n in by_fqcn), None)

    for item in classes:
        if "id" not in item:
            continue
        schema_record = by_id.get(item["id"])
        if schema_record is None:
            unavailable[item["fqcn"]] = {"id": item["id"], "reason": "constructor absent from native schema"}
            continue
        if not schema_record["supported"]:
            unavailable[item["fqcn"]] = {"id": item["id"], "reason": schema_record["unsupportedReason"]}
            continue
        aliases[item["fqcn"]] = schema_record["name"]
        # Java cannot declare a field named `long`; the actual GeoPoint family uses _long.
        if any(p["name"] == "long" for p in schema_record["params"]):
            field_aliases[item["fqcn"]] = {"_long": "long"}
        if schema_record["kind"] == "constructor":
            seen = set()
            parent = base_of(item)
            while parent is not None and parent["fqcn"] not in seen:
                seen.add(parent["fqcn"])
                base_results.setdefault(parent["fqcn"], set()).add(schema_record["type"])
                parent = base_of(parent)

    # A sum-type alias describes only a data base class; it cannot be serialized.
    type_aliases = {name: next(iter(types)) for name, types in base_results.items()
                    if len(types) == 1 and name not in aliases and "id" not in by_fqcn[name]}
    hook_names: dict[str, set[str]] = {}
    hook_aliases: dict[str, set[str]] = {}
    for alias, canonical in aliases.items():
        simple = alias.rsplit("$", 1)[-1].rsplit(".", 1)[-1]
        hook_names.setdefault(canonical, set()).add(simple)
        hook_aliases.setdefault(simple, set()).add(canonical)
    preferred = {}
    for canonical, choices in hook_names.items():
        # This only ranks *existing, id-matched* names. It never invents an alias.
        preferred[canonical] = min(choices, key=lambda n: (
            n != "TL_" + canonical.replace(".", "_"), "_layer" in n, n))
    return {"aliases": dict(sorted(aliases.items())), "typeAliases": dict(sorted(type_aliases.items())),
            "fieldAliases": dict(sorted(field_aliases.items())),
            "hookNames": {k: sorted(v) for k, v in sorted(hook_names.items())},
            "hookAliases": {k: sorted(v) for k, v in sorted(hook_aliases.items())},
            "preferredHookNames": dict(sorted(preferred.items())),
            "unsupportedAliases": dict(sorted(unavailable.items())),
            "androidSources": [p.relative_to(ROOT).as_posix() for p in paths],
            "androidConstructorCount": sum("id" in c for c in classes)}


def generate(schema: Path = SCHEMA, android: Path = ANDROID) -> tuple[str, str]:
    source = schema.read_text(encoding="utf-8")
    records = parse_schema(source)
    android_data = android_registry(records, android)
    digest = hashlib.sha256(source.encode("utf-8")).hexdigest()
    layout_hash = native_layout_hash(source)
    document = {"schemaVersion": 1, "source": "telegram-ios/submodules/TelegramApi/swift_scheme.tl",
                "sourceSHA256": digest, "nativeLayoutHash": layout_hash,
                "constructors": [r for r in records if r["kind"] == "constructor"],
                "methods": [r for r in records if r["kind"] == "method"], **android_data}
    json_text = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
    # Compact source records avoid thousands of Swift expression type-checks and
    # do not need an extra runtime resource bundle. Parsing is once, then immutable.
    rows = []
    for record in records:
        fields = " ".join(p["name"] + ":" + p["type"] for p in record["params"])
        rows.append("|".join(["m" if record["kind"] == "method" else "c", str(record["id"]),
                              record["name"], record["type"], "1" if record["supported"] else "0", fields]))
    swift_text = (
        "// Generated by tools/compat/generate_tl_bridge.py. Do not edit.\n"
        "// Source: TelegramApi/swift_scheme.tl + SwiftTL's help.test addition.\n"
        "import Foundation\n\n"
        "enum ExteralessTLSchemaGenerated {\n"
        f'    static let sourceSHA256 = "{digest}"\n'
        f"    static let nativeLayoutHash: UInt64 = 0x{layout_hash}\n"
        '    static let records = """\n' + "\n".join(rows) + '\n"""\n'
        '    static let hookNames = """\n'
        + "\n".join(name + "|" + alias for name, alias in android_data["preferredHookNames"].items())
        + '\n"""\n}\n'
    )
    return json_text, swift_text


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail when committed outputs are stale")
    args = parser.parse_args()
    json_text, swift_text = generate()
    changed = []
    for path, expected in ((JSON_OUTPUT, json_text), (SWIFT_OUTPUT, swift_text)):
        actual = path.read_text(encoding="utf-8") if path.exists() else None
        if actual != expected:
            changed.append(path.relative_to(ROOT).as_posix())
            if not args.check:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(expected, encoding="utf-8", newline="\n")
    document = json.loads(json_text)
    print(json.dumps({"constructors": len(document["constructors"]), "methods": len(document["methods"]),
                      "supportedMethods": sum(r["supported"] for r in document["methods"]),
                      "androidAliases": len(document["aliases"]), "unsupportedAndroidAliases": len(document["unsupportedAliases"]),
                      "changed": changed}, indent=2))
    return int(args.check and bool(changed))


if __name__ == "__main__":
    raise SystemExit(main())
