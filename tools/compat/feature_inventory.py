"""Source-only Android/client/SDK inventory; never import or run plugin code.

Run ``python -m tools.compat.feature_inventory`` to refresh build/compat and the
tracked docs/parity reports. ``--check`` is read-only. See docs/parity/schema.md
for source boundaries, evidence semantics and independently supplied parity JSON.
This is a lexical inventory, not a Java/Kotlin compiler or a runtime parity test.
"""

from __future__ import annotations

import argparse
import ast
from collections import Counter, defaultdict
from copy import deepcopy
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re

from . import corpus, individual_routes


JAVA_ROOT = os.path.join(corpus.REPO, "TMessagesProj", "src", "main", "java")
KOTLIN_ROOT = os.path.join(corpus.REPO, "TMessagesProj", "src", "main", "kotlin")
OUT_DIR = os.path.join(corpus.PROJECT_ROOT, "build", "compat")
SCHEMA_VERSION = 2
MAX_SOURCE_FILES = 20000
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_RECORDS = 12000
MAX_REFS = 4                    # Per setting AND reference category, not total scan.
MAX_EXPRESSION = 180
SOURCE_SUFFIXES = {".java", ".kt"}
OWNED_PACKAGES = ("app/exteraless/", "tw/nekomimi/", "xyz/nextalone/", "com/exteragram/")
LEGACY_TREES = ["tw/nekomimi", "xyz/nextalone"]
CONFIG_DOMAINS = {
    "AppearanceConfig": "appearance", "ChatsConfig": "chats",
    "GeneralConfig": "general", "OpenExteraConfig": "openextera",
    "UtilsConfig": "utils", "IconPacksConfig": "icons",
    "PillStackConfig": "pillstack", "GlyphConfig": "glyph",
    "AiConfig": "ai", "FeedConfig": "feed", "NekoConfig": "neko",
    "NekoXConfig": "nekox", "NaConfig": "nagram", "DialogConfig": "dialog",
}
WAVES = {
    "wave1_visual_base": ["appearance", "appicons", "icons", "drawer", "settings", "general"],
    "wave2_chat": ["chats", "feed", "pillstack", "player", "nowplaying", "math", "components", "links"],
    "wave3_privacy_background": ["ghost", "privacy", "notifications", "backup", "updater", "ai", "speech", "proxy"],
    "wave4_rest": ["camera", "debug", "glyph", "shortcuts", "utils", "crash", "config"],
}
TYPE_NAMES = {"Bool": "bool", "Boolean": "bool", "Int": "int", "Long": "long",
              "Float": "float", "String": "text", "StringSet": "set<text>",
              "SetInt": "set<int>", "MapIntInt": "map<int,int>"}
CONSTRAINTS = {
    "native-ui": "Android Views/Canvas/Material components require native iOS rendering and frame evidence.",
    "android-system": "Android system integrations (Monet, launcher, notification icons, content capture) have different or absent public iOS APIs.",
    "camera": "Camera1/Camera2/CameraX are Android APIs; use AVFoundation and verify device capabilities.",
    "background": "iOS suspension/APNs/background execution differs from Android services; no continuous-work equivalence is claimed.",
    "sandbox": "Android filesystem/database/backup layouts are not iOS paths; adapt to app-group sandbox and account identity.",
    "credentials": "Provider keys and credentials require native secret storage; the inventory contains definitions only.",
    "network": "Provider/server/network behavior needs an integration test; a stored URL/flag is not a working service.",
    "glyph": "Nothing Phone Glyph hardware/service is absent on iPhone; original hardware effect is platform-constrained.",
    "jvm": "Java/DEX plugins and JVM/Xposed method replacement are excluded by the original plan; native extension points are distinct capabilities.",
    "feed": "Android channel aggregation is distinct from Telegram-iOS News; the latter is compile-time/server gated.",
}

# These are integration CANDIDATES, never evidence that an Exteraless key is read.
# Each file is checked and content-pinned when included. More precise per-setting
# implementation locations arrive in the domain agents' parity fragments.
IOS_TARGETS = {
    "appearance": ("SettingsUI/Sources/Themes/ThemeSettingsController.swift", "func themeSettingsController("),
    "avatars": ("AvatarNode/Sources/AvatarNode.swift", "public enum AvatarNodeClipStyle"),
    "chat-list": ("ChatListUI/Sources/ChatListController.swift", "class ChatListControllerImpl"),
    "navigation": ("TelegramUI/Sources/TelegramRootController.swift", "class TelegramRootController"),
    "chats": ("TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift", "class ChatMessageBubbleItemNode"),
    "composer": ("TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift", "class ChatTextInputPanelNode"),
    "camera": ("Camera/Sources/Camera.swift", "func setFps("),
    "player": ("TelegramUI/Sources/OverlayAudioPlayerControlsNode.swift", "class OverlayAudioPlayerControlsNode"),
    "translation": ("TranslateUI/Sources/TranslateScreen.swift", "func presentTranslateScreen("),
    "privacy": ("TelegramCore/Sources/State/ManagedAccountPresence.swift", "class AccountPresenceManagerImpl"),
    "read-state": ("TelegramCore/Sources/State/SynchronizePeerReadState.swift", "func synchronizePeerReadState("),
    "notifications": ("TelegramUIPreferences/Sources/InAppNotificationSettings.swift", "struct InAppNotificationSettings"),
    "tools": ("SettingsUI/Sources/Data and Storage/DataAndStorageSettingsController.swift", "func dataAndStorageController("),
    "proxy": ("SettingsUI/Sources/Data and Storage/ProxyListSettingsController.swift", "func proxySettingsController("),
    "speech": ("Media/LocalAudioTranscription/Sources/LocalAudioTranscription.swift", "func transcribeAudio("),
    "ai": ("TelegramUI/Components/TextProcessingScreen/Sources/TextProcessingTranslateContentComponent.swift", "class TextProcessingTranslateContentComponent"),
    "profile": ("TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift", "class PeerInfoScreen"),
    "themes": ("TelegramUI/Components/ChatThemeScreen/Sources/ChatThemeScreen.swift", "class ChatThemeScreen"),
    "feed": ("TelegramCore/Sources/TelegramEngine/Feed/TelegramEngineFeed.swift", "#if TELEGRAM_NEWS_FEED_API"),
    "chat-header": ("TelegramUI/Components/ChatTitleView/Sources/ChatTitleComponent.swift", "class ChatTitleComponent"),
}

_LEX = re.compile(r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*')
_BLOCK = re.compile(r"/\*|\*/")
_IDENT = re.compile(r"\b[A-Za-z_]\w*\b")
_JAVA_METHOD = re.compile(
    r"(?m)^[ \t]*(?P<mods>(?:(?:public|private|protected|static|final|synchronized|native|abstract|default)\s+)+)"
    r"(?:<[^>\n]+>\s*)?(?P<type>[\w.$]+(?:<[^;\n{}=]+>)?(?:\[\])?)\s+(?P<name>\w+)\s*\(")
_KT_METHOD = re.compile(r"\bfun\s+(?:<[^>\n]+>\s*)?(?P<name>\w+)\s*\(")
_ITEM_ASSIGN = re.compile(r"(?:\b(?:val|var)\s+(\w+)(?:\s*:\s*[^=\n]+)?|\bConfigItem\s+(\w+))\s*=\s*$")
_CONSTANT = re.compile(
    r"(?m)(?:\bconst\s+val\s+(\w+)(?:\s*:\s*\w+)?|\bstatic\s+final\s+(?:String|int|long|float|boolean)\s+(\w+))\s*=\s*([^;\n]+)")
_SENSITIVE = re.compile(r"(?i)(?:api.?key|token|password|secret|private.?key|app.?hash|provider\w*key)")
_PREF_READ = re.compile(r"\.get(Boolean|Int|Long|Float|String|StringSet)\s*\(")
_UI_PATH = re.compile(r"(?i)(?:/settings/|/preferences/|SettingsActivity|PreferencesActivity|StyleEditor|PreviewCell|ConfigCell)")
_STATE_FIELD = re.compile(r"(?i)(?:cache(?:time)?$|migrated$|lastActive|knownChannels$|selectedServiceHash$)")


def _blank(text):
    return re.sub(r"[^\n]", " ", text)


def mask_source(text, *, strings=False, nested_comments=False):
    """Mask comments, preserving character offsets/lines.

    Kotlin/Swift have nested comments; Java does not (real DialogsActivity contains
    ``/* || /*...*/``). Strings are retained for declarations, masked for searches.
    This avoids counting commented settings, string examples, and KDoc references.
    """
    chunks, offset = [], 0
    while match := _LEX.search(text, offset):
        chunks.append(text[offset:match.start()])
        end = match.end()
        token = match.group()
        if token == "/*":
            if nested_comments:
                depth = 1
                while depth and (closing := _BLOCK.search(text, end)):
                    depth += 1 if closing.group() == "/*" else -1
                    end = closing.end()
                if depth:
                    end = len(text)
            else:
                closing = text.find("*/", end)
                end = len(text) if closing < 0 else closing + 2
            token = text[match.start():end]
        chunks.append(_blank(token) if strings or token.startswith(("//", "/*")) else token)
        offset = end
    chunks.append(text[offset:])
    return "".join(chunks)


def _close(code, start):
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = [pairs[code[start]]]
    for pos in range(start + 1, len(code)):
        char = code[pos]
        if char in pairs:
            stack.append(pairs[char])
        elif char in ")]}":
            if not stack or char != stack.pop():
                raise ValueError(f"unbalanced source at offset {pos}")
            if not stack:
                return pos
    raise ValueError(f"unterminated source at offset {start}")


def _arguments(text, code, opening):
    end = _close(code, opening)
    parts, start, depth = [], opening + 1, 0
    # Generic type arguments can contain commas (HashMap<Int, Int>()). They are
    # masked only when they look like a type, not for comparisons in expressions.
    inner = re.sub(r"<\s*[A-Z][\w?., <>]*>", lambda m: " " * len(m.group()), code[opening + 1:end])
    for relative, char in enumerate(inner):
        pos = opening + 1 + relative
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            parts.append(text[start:pos].strip())
            start = pos + 1
    if text[start:end].strip():
        parts.append(text[start:end].strip())
    return parts, end


def _compact(text):
    return re.sub(r"\s+", " ", text).strip()


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _read(path):
    if path.stat().st_size > MAX_FILE_BYTES:
        raise ValueError(f"source exceeds {MAX_FILE_BYTES} bytes: {path}")
    raw = path.read_bytes()
    return raw.decode("utf-8-sig"), _sha(raw), len(raw)


def _source_paths(android_root):
    main = Path(android_root) / "TMessagesProj/src/main"
    found = []
    for language in ("java", "kotlin"):
        root = main / language
        if root.is_dir():
            found.extend(p for p in root.rglob("*") if p.suffix in SOURCE_SUFFIXES and p.is_file())
    if len(found) > MAX_SOURCE_FILES:
        raise ValueError("source file limit exceeded; increase the audited bound explicitly")
    return main, sorted(found, key=lambda p: p.relative_to(main).as_posix())


def _literal(expression, constants, seen=()):
    expression = _compact(expression)
    if expression in constants and expression not in seen:
        return _literal(constants[expression], constants, (*seen, expression))
    if expression in ("true", "false", "null"):
        return True, {"true": True, "false": False, "null": None}[expression]
    if re.fullmatch(r"[-+]?(?:0[xX][\da-fA-F_]+|\d[\d_]*)(?:[lL])?", expression):
        raw = expression.rstrip("lL").replace("_", "")
        return True, int(raw, 16 if "x" in raw.lower() else 10)
    if re.fullmatch(r"[-+]?\d[\d_]*(?:\.\d*)?(?:[eE][-+]?\d+)?[fFdD]?", expression):
        return True, float(expression.rstrip("fFdD").replace("_", ""))
    if expression.startswith('"') and expression.endswith('"'):
        try:
            value = ast.literal_eval(expression)
            if isinstance(value, str):
                return True, value
        except (SyntaxError, ValueError):
            pass
    return False, None


def _default(expression, constants, field):
    known, value = _literal(expression, constants)
    if known and isinstance(value, str) and value and (_SENSITIVE.search(field) or len(value) > MAX_EXPRESSION):
        return {"kind": "redacted", "reason": "sensitive or long default; inspect pinned source"}
    if known:
        result = {"kind": "literal", "value": value}
        if expression in constants:
            result["symbol"] = expression
        return result
    if len(_compact(expression)) > MAX_EXPRESSION or _SENSITIVE.search(field):
        return {"kind": "expression", "expression": "<inspect pinned source>"}
    return {"kind": "expression", "expression": _compact(expression)}


@dataclass
class Method:
    name: str
    result: str
    start: int
    body: int
    end: int
    public: bool
    arity: int
    static: bool
    parameter_types: tuple[str, ...]


def _methods(text, code, kotlin):
    result = []
    for match in (_KT_METHOD if kotlin else _JAVA_METHOD).finditer(code):
        args, end = _arguments(text, code, match.end() - 1)
        cursor = end + 1
        while cursor < len(code) and code[cursor] not in "{=;\n":
            cursor += 1
        if kotlin and cursor < len(code) and code[cursor] == "\n":
            cursor = end + 1
            while cursor < len(code) and code[cursor].isspace():
                cursor += 1
        if cursor >= len(code) or code[cursor] not in "{=":
            continue
        body = cursor + 1
        if code[cursor] == "{":
            finish = _close(code, cursor)
        else:
            finish = code.find("\n", body)
            finish = len(code) if finish < 0 else finish
            # Multiline expression getters: walk balanced calls/when blocks.
            nesting = 0
            for pos in range(body, len(code)):
                if code[pos] in "([{":
                    nesting += 1
                elif code[pos] in ")]}":
                    if nesting == 0:
                        break
                    nesting -= 1
                if code[pos] == "\n" and nesting == 0 and text[body:pos].strip():
                    finish = pos
                    break
        before = code[code.rfind("\n", 0, match.start()) + 1:match.start()]
        public = "private" not in before if kotlin else "public" in match.group("mods")
        type_name = _compact(text[end + 1:cursor]).lstrip(": ") if kotlin else match.group("type")
        parameter_types = []
        for arg in args:
            if kotlin:
                arg_type = arg.split(":", 1)[-1].split("=", 1)[0]
            else:
                arg_type = re.sub(r"@\w+(?:\([^)]*\))?\s*|\bfinal\s+", "", arg).rsplit(None, 1)[0]
            parameter_types.append(_compact(arg_type))
        result.append(Method(match.group("name"), type_name or "inferred", match.start(), body, finish,
                             public, len(args), kotlin or "static" in match.group("mods"), tuple(parameter_types)))
    return result


def _method_at(methods, position):
    candidates = [m for m in methods if m.start <= position <= m.end]
    return max(candidates, key=lambda m: m.start) if candidates else None


def _config_id(class_name, field):
    domain = CONFIG_DOMAINS.get(class_name, re.sub(r"Config$", "", class_name).lower())
    return f"{domain}.{field}"


def parse_config(text, file, global_constants=None):
    """Parse actual registrations/preferences, not every getter or static field.

    Public for small fixtures. ``file`` is relative to src/main. A Kotlin file
    under java/ is Kotlin, too. Unknown expressions stay unknown, never executed.
    """
    clean = mask_source(text, nested_comments=file.endswith(".kt"))
    code = mask_source(text, strings=True, nested_comments=file.endswith(".kt"))
    class_name = Path(file).stem
    constants = dict(global_constants or {})
    for match in _CONSTANT.finditer(clean):
        name = match.group(1) or match.group(2)
        constants[name] = match.group(3).strip()
    methods = _methods(clean, code, file.endswith(".kt"))
    items, registrations = [], []
    for match in re.finditer(r"\baddConfig\s*\(", code):
        assignment = _ITEM_ASSIGN.search(clean[max(0, match.start() - 220):match.start()])
        if not assignment:
            continue
        field = assignment.group(1) or assignment.group(2)
        args, end = _arguments(clean, code, match.end() - 1)
        registrations.append((match.start(), end))
        if len(args) == 1:  # addConfig(object : ConfigItem(...) { ... })
            nested = re.search(r"\bConfigItem\s*\(", code[match.end():end])
            if nested:
                args, _ = _arguments(clean, code, match.end() + nested.end() - 1)
        if len(args) not in (3, 4):
            raise ValueError(f"unrecognized ConfigItem registration: {file}#{field}")
        known, key = _literal(args[0], constants)
        if not known or not isinstance(key, str):
            raise ValueError(f"nonliteral ConfigItem key: {file}#{field}")
        linked = len(args) == 4 and "configType" not in args[1]
        type_match = re.search(r"configType(\w+)", args[1])
        kind = "bool" if linked else TYPE_NAMES.get(type_match.group(1) if type_match else "", "unknown")
        if kind == "unknown":
            raise ValueError(f"unrecognized ConfigItem type: {file}#{field}: {args[1]}")
        item = {"id": _config_id(class_name, field), "field": field, "class": class_name,
                "file": file, "line": text.count("\n", 0, match.start()) + 1,
                "key": key, "type": kind, "default": _default(args[-1], constants, field),
                "storage": "config-item", "scope": "global", "origin": "registered-field",
                "visibility": "private" if "private" in clean[max(0, match.start() - 80):match.start()] else "public"}
        if linked:
            item["storage_link"] = {"id": _config_id(class_name, args[1]), "bit": _default(args[2], constants, field)}
        items.append(item)
    # Preference-based configs (AiConfig, FeedConfig, NekoXConfig, DialogConfig).
    # Registration-based configs' remaining reads are migrations/cache state, not
    # extra settings. Keep those as initialization evidence instead.
    if not items:
        seen = set()
        for match in _PREF_READ.finditer(code):
            args, end = _arguments(clean, code, match.end() - 1)
            if len(args) != 2:
                continue
            receiver = code[max(0, match.start() - 100):match.start()]
            if not re.search(r"(?i)(?:preferences|prefs|settings)\w*(?:\([^\n;{}]*\))?\s*$", receiver):
                continue
            known, key = _literal(args[0], constants)
            method = _method_at(methods, match.start())
            if not known and (not method or not method.public):
                continue  # generic serializer helper; concrete keys handled below
            if known and not isinstance(key, str):
                continue
            prefix = clean[max(0, match.start() - 150):match.start()]
            assignment = re.search(r"\b(\w+)\s*=\s*[\w.()]+\s*$", prefix)
            getter = method and re.match(r"^(?:get|is)[A-Z]", method.name)
            if assignment and method is None:
                field = assignment.group(1)
                origin = "preference-field"
            elif getter:
                field = re.sub(r"^(?:get|is)(?=[A-Z])", "", method.name)
                field = field[:1].lower() + field[1:]
                origin = "preference-getter"
            elif known:
                field = key
                origin = "ancillary-storage"
            else:
                continue  # Unnamed generic storage plumbing, not a client setting.
            identity = key if known else _compact(args[0])
            if not field or identity in seen:
                continue
            seen.add(identity)
            items.append({"id": _config_id(class_name, field), "field": field,
                          "class": class_name, "file": file,
                          "line": text.count("\n", 0, match.start()) + 1,
                          "key": key if known else {"expression": _compact(args[0])},
                          "type": TYPE_NAMES[match.group(1)], "default": _default(args[1], constants, field),
                          "storage": "shared-preferences", "origin": origin,
                          "scope": "account" if class_name == "FeedConfig" else "parameterized" if not known else "global",
                          "accessors": [method.name] if method else [],
                          "visibility": "public" if method is None or method.public else "private"})
        # Typed collection readers delegate to generic read()/readIds(). Include
        # each literal KEY_* definition once, without enumerating stored values.
        for match in re.finditer(r"\b(readIds|read)\s*\(\s*(KEY_\w+)", code):
            known, key = _literal(match.group(2), constants)
            if not known or not isinstance(key, str) or any(i["key"] == key for i in items):
                continue
            method = _method_at(methods, match.start())
            items.append({"id": _config_id(class_name, key), "field": key, "class": class_name,
                          "file": file, "line": text.count("\n", 0, match.start()) + 1,
                          "key": key, "type": "set<long>" if match.group(1) == "readIds" else "json",
                          "default": {"kind": "literal", "value": []}, "storage": "serialized-collection",
                          "origin": "collection-preference", "scope": "account" if class_name == "FeedConfig" else "global",
                          "accessors": [method.name] if method else [], "visibility": "public"})
    package = re.search(r"(?m)^\s*package\s+([\w.]+)", code)
    return {"class": class_name, "fqcn": (package.group(1) + "." if package else "") + class_name,
            "file": file, "items": items,
            "methods": methods, "clean": clean, "code": code, "constants": constants}


def _symbol_index(configs):
    """Separate property access from function calls; follow getter aliases only.

    E.g. AppearanceConfig.centerTitle() reads NaConfig.centerActionBarTitle, NOT
    the obsolete AppearanceConfig.centerTitle storage registration.
    """
    fields, calls, owners = {}, {}, {}
    for config in configs:
        cls = config["class"]
        owners[cls] = config
        for item in config["items"]:
            fields[cls, item["field"]] = {item["id"]}
            calls[cls, "get" + item["field"][:1].upper() + item["field"][1:]] = {item["id"]}
            for accessor in item.get("accessors", []):
                calls.setdefault((cls, accessor), set()).add(item["id"])
        # Lists of ConfigItem pairs (ghostToggleItems, etc.) carry real setting
        # dependencies into consumers even if the getter iterates a local item.
        assignments = re.compile(r"\b(?:val|var|(?:private|public)\s+static\s+final\s+[\w<> ,]+)\s+(\w+)\s*=")
        for assignment in assignments.finditer(config["code"]):
            end = config["code"].find(";", assignment.end())
            if end < 0:
                end = config["code"].find("\n", assignment.end())
            body = config["code"][assignment.end():end]
            ids = set()
            for name in _IDENT.findall(body):
                ids.update(fields.get((cls, name), ()))
            if ids:
                fields.setdefault((cls, assignment.group(1)), set()).update(ids)
    # Fixed point handles getter->getter chains, but never setters/init/reset.
    for _ in range(12):
        changed = False
        for config in configs:
            cls, code = config["class"], config["code"]
            for method in config["methods"]:
                if method.result in {"void", "Unit"} or re.match(r"(?:set|save|load|reset|init|migrate|toggle|remove|persist|apply|update|notify|clear|forget|sanitize)(?:[A-Z]|$)", method.name):
                    continue
                body = code[method.body:method.end]
                ids = set(calls.get((cls, method.name), ()))
                for match in re.finditer(r"\b(\w+)(?:\s*\.\s*(?:INSTANCE|Companion))?\s*\.\s*(\w+)\s*\(", body):
                    ids.update(calls.get((match.group(1), match.group(2)), ()))
                for match in re.finditer(r"\b(\w+)(?:\s*\.\s*(?:INSTANCE|Companion))?\s*\.\s*(\w+)\b(?!\s*\()", body):
                    ids.update(fields.get((match.group(1), match.group(2)), ()))
                for match in re.finditer(r"(?<![\w.])([A-Za-z_]\w*)\b", body):
                    after = body[match.end():].lstrip()
                    table = calls if after.startswith("(") else fields
                    ids.update(table.get((cls, match.group(1)), ()))
                # Externally delegated properties are resolved above. Do not
                # accidentally alias an identically named storage field.
                if ids and calls.get((cls, method.name)) != ids:
                    calls[cls, method.name] = ids
                    changed = True
        if not changed:
            break
    return fields, calls, owners


def _references(code, fields, calls, owners):
    if not owners:
        return
    names = "|".join(re.escape(c) for c in sorted(owners))
    variables, blocked = {}, set()
    for imported in re.finditer(r"(?m)^\s*import\s+([\w.]+)(?:\s+as\s+(\w+))?\s*;?", code):
        qualified, alias = imported.groups()
        cls = qualified.rsplit(".", 1)[-1]
        if cls not in owners:
            continue
        if owners[cls]["fqcn"] != qualified and "." in owners[cls]["fqcn"]:
            blocked.add(alias or cls)
        elif alias:
            variables[alias] = cls
    for match in re.finditer(r"\b(" + names + r")\s+(\w+)\s*(?:[=,);])", code):
        variables[match.group(2)] = match.group(1)
    for match in re.finditer(r"\b(?:val|var)\s+(\w+)\s*=\s*(" + names + r")\s*\.", code):
        variables[match.group(1)] = match.group(2)
    for match in re.finditer(r"\b(?:val|var)\s+(\w+)\s*:\s*(" + names + r")\b", code):
        variables[match.group(1)] = match.group(2)
    lookup_names = "|".join(re.escape(c) for c in sorted(set(owners) | set(variables), key=len, reverse=True))
    pattern = re.compile(r"\b(" + lookup_names + r")\s*\.\s*(?:(?:INSTANCE|Companion)\s*\.\s*|getInstance\s*\([^;{}\n]*?\)\s*\.\s*)?(\w+)\b")
    for match in pattern.finditer(code):
        cls = variables.get(match.group(1), match.group(1))
        if cls in blocked or match.group(1) in blocked:
            continue
        member = match.group(2)
        after = code[match.end():].lstrip()
        ids = (calls if after.startswith("(") else fields).get((cls, member), ())
        if ids:
            yield match.start(), match.end(), cls, member, ids
    # Static imports and Kotlin property imports (including `as` aliases).
    for imp in re.finditer(r"(?m)^\s*import\s+(?:static\s+)?(?:\w+\.)*(" + names + r")\.(\w+|\*)(?:\s+as\s+(\w+))?", code):
        cls, member, alias = imp.groups()
        members = {m for c, m in fields if c == cls} | {m for c, m in calls if c == cls} if member == "*" else {member}
        for member in members:
            local = alias or member
            for match in re.finditer(r"(?<![\w.])" + re.escape(local) + r"\b", code):
                if match.start() <= imp.end():
                    continue
                after = code[match.end():].lstrip()
                ids = (calls if after.startswith("(") else fields).get((cls, member), ())
                if ids:
                    yield match.start(), match.end(), cls, member, ids


def _self_field_references(config):
    """Actual non-config helper consumers of their own preference-backed fields.

    Getter definitions alone do not make storage live. Class field reads in
    effectful methods are retained; local variables/parameters shadowing that
    field are skipped conservatively.
    """
    if config["class"].endswith("Config"):
        return
    for item in config["items"]:
        if item.get("origin") != "preference-field":
            continue
        name = item["field"]
        for method in config["methods"]:
            body = config["code"][method.body:method.end]
            if re.fullmatch(r"\s*return\s+(?:this\.)?" + re.escape(name) + r"\s*;?\s*", body):
                continue
            if re.search(r"\b(?:boolean|int|long|float|String|val|var)\s+" + re.escape(name) + r"\b", config["code"][method.start:method.end]):
                continue
            for match in re.finditer(r"(?<![\w.])(?:this\.)?" + re.escape(name) + r"\b", body):
                yield method.body + match.start(), method.body + match.end(), config["class"], name, {item["id"]}


def _reference_role(file, config_files, code, start, end):
    line = code[code.rfind("\n", 0, start) + 1:code.find("\n", end) if "\n" in code[end:] else len(code)]
    if line.lstrip().startswith(("import ", "package ")):
        return "import"
    if "/com/exteragram/" in file:
        return "compatibility"
    if file in config_files:
        return "config"
    if "/backup/" in file or "LegacyDefaults" in file:
        return "persistence"
    if _UI_PATH.search(file):
        return "ui"
    if re.search(r"(?:setTextAnd|setChecked|asCheck|ConfigCell)", line):
        return "ui"
    after = code[end:end + 100]
    if re.match(r"\s*(?:\(\s*\))?\s*\.\s*(?:setConfig|toggleConfig|key\b|type\b|defaultValue\b)", after):
        return "write-or-metadata"
    if re.match(r"\s*=(?!=)", after):
        return "write-or-metadata"
    return "effect"


def _group(item):
    field, domain = item["field"].lower(), item["id"].split(".")[0]
    package = item["file"].split("/app/exteraless/", 1)[-1].split("/", 1)[0] if "/app/exteraless/" in item["file"] else ""
    if package in {"plugins", "updater", "backup", "debug", "crash", "proxy", "utils"}:
        return "tools"
    if package in {"privacy", "ghost", "notifications"}:
        return "privacy"
    if package in {"ai", "speech"}:
        return "ai"
    if package in {"icons", "appicons", "drawer", "appearance", "pillstack"}:
        return "appearance"
    if item["class"] == "CloudSettingsHelper":
        return "tools"
    if item["class"] == "PasscodeHelper":
        return "privacy"
    if item["class"] == "BingTranslatorRaw":
        return "ai"
    if domain in {"ai"} or field.startswith(("llm", "deepl")):
        return "ai"
    if domain in {"glyph", "utils", "nekox", "general"}:
        if "botprivacy" in field:
            return "privacy"
        return "tools"
    if domain in {"feed", "pillstack"}:
        return "chats" if domain == "feed" else "appearance"
    if domain in {"icons", "appearance"}:
        return "appearance"
    if domain in {"chats", "dialog"}:
        return "chats"
    if re.search(r"ghost|sendread|sendonline|sendreadoffline|sendoffline|markread|sendupload|savedeleted|saveinarchived|locked$|block|ignorecontent|hidephone|privacy|pushservice|notification|disablecrash", field):
        return "privacy"
    if re.search(r"font|typeface|avatar|decoration|title|tab|divider|sliderstyle|switchstyle|navigation|drawer|monet|actionbar|hidedialog|floatingbutton|strok[e]|blur|icon|hidearchive|hidealltab|hidebottom|hidestoriesfromheader", field):
        return "appearance"
    if re.search(r"proxy|dns|ipv6|download|uploadboost|savepath|cachepath|map|systemaccount", field):
        return "tools"
    return "chats"


def _ios_plan(item):
    group = _group(item)
    field = item["field"]
    lower = field.lower()
    target = group
    constraints = []
    if group in {"appearance", "chats"}:
        constraints.append("native-ui")
    if "avatar" in lower or "cornerradius" in lower:
        target = "avatars"
    elif re.search(r"camera|flash|zoom|framespersecond|audiobitrate", lower):
        target = "camera"
        constraints.append("camera")
    elif re.search(r"player|pause|seek|pip|volume|quality", lower):
        target = "player"
    elif re.search(r"translate|translation|llm|deepl", lower):
        target = "translation"
        constraints.append("network")
    elif re.search(r"proxy", lower):
        target = "proxy"
        constraints.append("network")
    elif re.search(r"notification|push", lower):
        target = "notifications"
        constraints.append("background")
    elif re.search(r"sendread|markread|savedeleted|saveinarchived", lower):
        target = "read-state"
    elif re.search(r"navigation|drawer|maintabs", lower):
        target = "navigation"
    elif re.search(r"title|dialog|archive|tab|badge|sortby|storiesfromheader", lower):
        target = "chat-list"
    elif re.search(r"input|mention|attach|markdown|textstyle|inline|command", lower):
        target = "composer"
    elif lower == "customthemes":
        target = "themes"
    if "chatheader" in lower:
        target = "chat-header"
    if item["id"].startswith("glyph."):
        constraints.append("glyph")
    if re.search(r"monet|notificationicon|contentcapture|systemiconshape|pushservice", lower):
        constraints.append("android-system")
    if re.search(r"cache|path|backup|history|services$", lower):
        constraints.append("sandbox")
    if _SENSITIVE.search(field):
        constraints.append("credentials")
    if "feed" in lower or item["id"].startswith("feed."):
        constraints.append("feed")
    # Short names would collide across functional configs; make that explicit in
    # the proposed key rather than silently sharing persisted iOS storage.
    key_field = field
    if field == "enabled":
        key_field = item["class"].removesuffix("Config") + "Enabled"
        key_field = key_field[:1].lower() + key_field[1:]
    result = {"setting_key": f"{group}.{key_field}", "candidate_targets": [target],
              "existing_equivalent": None, "platform_constraints": sorted(set(constraints)),
              "disposition": "platform-constrained" if "glyph" in constraints else "port-needed"}
    if item["id"] == "appearance.iosNavigationBarStyle":
        result["existing_equivalent"] = {"target": "navigation", "scope": "stock Telegram-iOS bottom navigation; Android style toggle is not an iOS setting"}
    elif item["id"] == "appearance.iosChatHeader":
        result["existing_equivalent"] = {"target": "chat-header", "scope": "stock Telegram-iOS chat header concept; visual equivalence unverified"}
    elif item["id"] == "appearance.customThemes":
        result["existing_equivalent"] = {"target": "themes", "scope": "per-chat themes/wallpapers exist; global Exteraless enable/disable still needs a callsite"}
    if result["existing_equivalent"]:
        result["disposition"] = "stock-equivalent-candidate"
    if item["file"].split("/")[-2] == "speech":
        result["candidate_targets"] = ["speech"]
    return result


def _pending():
    return {"status": "pending", "ported": False, "evidence": []}


def _ui_label(clean, start, end):
    # Same semicolon-delimited statement only. Do not borrow a neighboring row's
    # title just because it is nearby. Resources are identifiers, not file text.
    left = max(clean.rfind(";", 0, start) + 1, start - 700)
    right = clean.find(";", end)
    right = min(len(clean), end + 700) if right < 0 else min(right, end + 700)
    statement = clean[left:right]
    if not re.search(r"setText|asCheck|asButton|ConfigCell|showSelector|add.*Item", statement):
        return []
    return list(dict.fromkeys(re.findall(r"R\.string\.(\w+)", statement)))[:4]


def _name(field):
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", field).replace("_", " ").capitalize()


def _ui_definitions(file, clean, code, references):
    """Independent index of named rows/actions/control bindings, not feature counts."""
    found = []
    pattern = re.compile(r"\b(addRow|ConfigCell\w+|setTextAnd(?:ValueAndCheck|Check|ValueAndIcon|Value)|asCheck|asButton|asSlider|asInput|asSelector)\s*\(")
    for match in pattern.finditer(code):
        args, end = _arguments(clean, code, match.end() - 1)
        if not args:
            continue
        ids = sorted({i for start, _, _, _, targets in references if match.start() <= start <= end for i in targets})
        resources = list(dict.fromkeys(re.findall(r"R\.string\.(\w+)", clean[match.start():end])))[:8]
        known, key = _literal(args[0], {})
        row_key = key if known and isinstance(key, str) and len(key) <= 100 else None
        if not row_key and not resources and not ids:
            continue
        identity = row_key or ".".join(([resources[0]] if resources else []) + ids)
        identity = re.sub(r"[^\w.]+", "_", identity)
        found.append({"id": f"ui.{Path(file).stem}.{match.group(1)}.{identity}",
                      "file": file, "line": clean.count("\n", 0, match.start()) + 1,
                      "definition": match.group(1), "row_key": row_key,
                      "resource_ids": resources, "setting_ids": ids})
    return found


def _module_summary(main, paths, prefix):
    files, size, languages, digest = [], 0, Counter(), hashlib.sha256()
    api, file_pins = [], {}
    for path in paths:
        rel = path.relative_to(main).as_posix()
        if not rel.split("/", 1)[1].startswith(prefix.rstrip("/") + "/"):
            continue
        text, sha, length = _read(path)
        files.append(rel)
        size += length
        languages[path.suffix.lstrip(".")] += 1
        digest.update(f"{rel}\0{sha}\n".encode())
        if prefix.startswith("app/exteraless/"):
            clean = mask_source(text, nested_comments=path.suffix == ".kt")
            code = mask_source(text, strings=True, nested_comments=path.suffix == ".kt")
            for method in _methods(clean, code, path.suffix == ".kt"):
                if not method.public:
                    continue
                api.append({"name": method.name, "file": rel,
                            "line": text.count("\n", 0, method.start) + 1,
                            "type": method.result, "arity": method.arity,
                            "parameter_types": list(method.parameter_types),
                            "binding": "kotlin-function" if path.suffix == ".kt" else "static" if method.static else "instance"})
            file_pins[rel] = {"sha256": sha, "bytes": length}
    if len(api) > MAX_RECORDS:
        raise ValueError(f"module API bound exceeded: {prefix}")
    return {"files": len(files), "source_files": files, "bytes": size,
            "kb": round(size / 1024), "languages": dict(sorted(languages.items())),
            "sha256": digest.hexdigest(), "ported": False, "implementation": _pending(),
            "public_method_bodies": api, "api_count": len(api), "file_pins": file_pins}


def scan_modules(android_root=None):
    main, paths = _source_paths(android_root or corpus.REPO)
    names = {p.relative_to(main).parts[3] for p in paths
             if len(p.relative_to(main).parts) > 4 and p.relative_to(main).parts[1:3] == ("app", "exteraless")}
    result = {}
    for name in sorted(names):
        item = _module_summary(main, paths, f"app/exteraless/{name}")
        item["id"] = f"module.{name}"
        item["name"] = _name(name)
        item["wave"] = "stages_1_5" if name == "plugins" else next((w for w, members in WAVES.items() if name in members), "wave4_rest")
        item["platform_constraints"] = ["jvm"] if name == "plugins" else [name] if name in CONSTRAINTS else ["native-ui"]
        candidate = {"appearance": "appearance", "appicons": "appearance", "icons": "appearance", "drawer": "navigation",
                     "chats": "chats", "components": "composer", "feed": "chat-list", "general": "tools",
                     "ghost": "privacy", "glyph": "notifications", "links": "composer", "math": "composer",
                     "notifications": "notifications", "nowplaying": "player", "pillstack": "navigation",
                     "player": "player", "privacy": "privacy", "proxy": "proxy", "speech": "speech", "ai": "ai",
                     "camera": "camera"}.get(name, "tools")
        item["ios"] = {"candidate_targets": [candidate], "existing_equivalent": None}
        result[name] = item
    return result


def scan_legacy_trees(android_root=None):
    main, paths = _source_paths(android_root or corpus.REPO)
    return {rel.replace("/", "."): dict(_module_summary(main, paths, rel), id="legacy." + rel.replace("/", ".")) for rel in LEGACY_TREES}


def _configs(main, paths):
    candidates, constants = [], {}
    for path in paths:
        rel = path.relative_to(main).as_posix()
        owned = rel.split("/", 1)[1].startswith(OWNED_PACKAGES)
        if owned:
            if "/com/exteragram/" in rel and path.stem != "ExteraConfig":
                continue
            text, sha, size = _read(path)
            if not (path.stem.endswith("Config") or path.stem == "PluginsConstants"
                    or "SharedPreferences" in text or "getPreferences" in text or "getGlobalMainSettings" in text
                    or re.search(r"=\s*addConfig\s*\(", text)):
                continue
            for match in _CONSTANT.finditer(mask_source(text, nested_comments=path.suffix == ".kt")):
                constants[f"{path.stem}.{match.group(1) or match.group(2)}"] = match.group(3).strip()
            candidates.append((path, rel, text, sha, size))
    configs, pins = [], {}
    for _, rel, text, sha, size in candidates:
        config = parse_config(text, rel, constants)
        if config["items"] or config["class"].endswith("Config"):
            configs.append(config)
            pins[rel] = {"sha256": sha, "bytes": size}
    return configs, pins


def scan_config_toggles(android_root=None):
    """Legacy summary API; count means declared settings, NEVER shim getter count."""
    main, paths = _source_paths(android_root or corpus.REPO)
    configs, _ = _configs(main, paths)
    return {c["class"]: {"found": True, "file": c["file"],
                         "toggles": sorted(i["field"] for i in c["items"]) if c["class"] != "ExteraConfig" else [],
                         "count": len(c["items"]) if c["class"] != "ExteraConfig" else 0,
                         "role": "compatibility-shim" if c["class"] == "ExteraConfig" else "functional-config"}
            for c in configs}


def _native_targets(project_root):
    result = {}
    for name, (relative, symbol) in IOS_TARGETS.items():
        relative = "telegram-ios/submodules/" + relative
        path = project_root / relative
        if not path.is_file():
            continue
        text, sha, _ = _read(path)
        pos = text.find(symbol)
        result[name] = {"file": relative, "symbol": symbol, "line": text.count("\n", 0, pos) + 1 if pos >= 0 else None,
                        "sha256": sha, "status": "candidate-not-implementation"}
    return result


def _source_annotations(project, main, fields, calls, raw_items, pins):
    """Reviewed dataflow edges/default notes, each backed by resolvable source anchors.

    This is intentionally a separate, small, tracked input: no hidden hand edits
    in generated reports and no attempt to execute language expressions.
    """
    path = project / "docs/parity/android-evidence.json"
    data = _load_json(path) or {}
    checked = []
    for record in data.get("derived_readers", []):
        ids = record["targets"]
        if any(i not in raw_items for i in ids):
            raise ValueError(f"unknown derived-reader target: {record}")
        evidence = []
        for reference in record["evidence"]:
            file = reference["file"]
            text, sha, size = _read(main / file)
            offset = text.find(reference["anchor"])
            if offset < 0:
                raise ValueError(f"source annotation anchor missing: {file}: {reference['anchor']}")
            pins[file] = {"sha256": sha, "bytes": size}
            evidence.append({"file": file, "line": text.count("\n", 0, offset) + 1})
        table = fields if record.get("access") == "property" else calls
        table.setdefault((record["class"], record["member"]), set()).update(ids)
        checked.append({k: v for k, v in record.items() if k != "evidence"} | {"evidence": evidence})
    notes = {}
    for record in data.get("feature_notes", []):
        if record["id"] not in raw_items:
            raise ValueError(f"unknown source-note target: {record['id']}")
        resolved = {k: v for k, v in record.items() if k not in {"id", "evidence"}}
        resolved["evidence"] = []
        for reference in record["evidence"]:
            file = reference["file"]
            text, sha, size = _read(main / file)
            offset = text.find(reference["anchor"])
            if offset < 0:
                raise ValueError(f"source note anchor missing: {file}: {reference['anchor']}")
            pins[file] = {"sha256": sha, "bytes": size}
            resolved["evidence"].append({"file": file, "line": text.count("\n", 0, offset) + 1})
        notes[record["id"]] = resolved
    return checked, notes


def _android_pin(root, main, paths):
    digest, counts = hashlib.sha256(), Counter()
    for path in paths:
        rel = path.relative_to(main).as_posix()
        _, sha, size = _read(path)
        digest.update(f"{rel}\0{sha}\n".encode())
        counts[path.suffix.lstrip(".")] += 1
        counts["bytes"] += size
    versions = {}
    properties = root / "gradle.properties"
    if properties.is_file():
        for line in properties.read_text(encoding="utf-8").splitlines():
            if line.startswith(("APP_VERSION_NAME=", "APP_VERSION_CODE=")):
                key, value = line.split("=", 1)
                versions[key] = value
    return {"snapshot_kind": "vendored-plain-source", "upstream_commit": None,
            "root": "third_party/exteraless-android", "source_root": "TMessagesProj/src/main",
            "version_properties": versions, "java_kotlin_sha256": digest.hexdigest(),
            "counts": dict(sorted(counts.items())),
            "digest_algorithm": "sha256 of sorted src/main relative path + NUL + raw-file sha256 + LF"}


def build_client_inventory(android_root=None, project_root=None):
    root, project = Path(android_root or corpus.REPO), Path(project_root or corpus.PROJECT_ROOT)
    main, paths = _source_paths(root)
    if not paths:
        raise ValueError(f"Android Java/Kotlin sources not found under {main}")
    configs, pins = _configs(main, paths)
    functional = [c for c in configs if c["class"] != "ExteraConfig"]
    fields, calls, owners = _symbol_index(configs)
    raw_items = {item["id"]: item for c in functional for item in c["items"]}
    if len(raw_items) != sum(len(c["items"]) for c in functional):
        raise ValueError("duplicate stable setting id")
    if len(raw_items) > MAX_RECORDS:
        raise ValueError("setting limit exceeded")
    derived_readers, source_notes = _source_annotations(project, main, fields, calls, raw_items, pins)
    for reader in derived_readers:
        # A checked helper can live outside the Config classes. It still needs
        # to participate in class filtering and static-import resolution.
        owners.setdefault(reader["class"], {"fqcn": reader.get("fqcn", reader["class"])})
    config_files = {c["file"] for c in configs if c["class"].endswith("Config") and (c["items"] or c["class"] == "ExteraConfig")}
    configs_by_file = {c["file"]: c for c in configs}
    refs, ref_counts, ui_labels = defaultdict(lambda: defaultdict(list)), defaultdict(Counter), defaultdict(set)
    ui_definitions = []
    # One source file in memory at a time. The full tree is searched, including
    # org.telegram and Ayu callsites; only retained evidence is bounded.
    for path in paths:
        text, sha, size = _read(path)
        file = path.relative_to(main).as_posix()
        ui_file = file.split("/", 1)[1].startswith(OWNED_PACKAGES) and bool(_UI_PATH.search(file))
        if not any(cls in text for cls in owners) and not ui_file:
            continue
        code = mask_source(text, strings=True, nested_comments=path.suffix == ".kt")
        clean = None
        seen = set()
        references = list(_references(code, fields, calls, owners))
        if file in configs_by_file:
            references.extend(_self_field_references(configs_by_file[file]))
        if ui_file:
            clean = mask_source(text, nested_comments=path.suffix == ".kt")
            ui_definitions.extend(_ui_definitions(file, clean, code, references))
            pins[file] = {"sha256": sha, "bytes": size}
        for start, end, cls, member, ids in references:
            role = _reference_role(file, config_files, code, start, end)
            if role == "import":
                continue
            line = text.count("\n", 0, start) + 1
            for feature_id in sorted(ids):
                if feature_id not in raw_items or (feature_id, line, role) in seen:
                    continue
                seen.add((feature_id, line, role))
                ref_counts[feature_id][role] += 1
                if len(refs[feature_id][role]) < MAX_REFS:
                    refs[feature_id][role].append({"file": file, "line": line, "symbol": f"{cls}.{member}"})
                    pins[file] = {"sha256": sha, "bytes": size}
                if role == "ui":
                    if clean is None:
                        clean = mask_source(text, nested_comments=path.suffix == ".kt")
                    ui_labels[feature_id].update(_ui_label(clean, start, end))
    features = []
    for feature_id, item in sorted(raw_items.items()):
        counts = ref_counts[feature_id]
        behavior = "effect-callsite" if counts["effect"] else "ui-only" if counts["ui"] else "unresolved"
        if item["visibility"] == "private" and not counts["effect"]:
            behavior = "storage-or-migration"
        android = {k: v for k, v in item.items() if k not in {"id", "field", "class", "visibility"}}
        android["definition_fingerprint"] = _sha(json.dumps(
            {k: item.get(k) for k in ("id", "key", "type", "default", "storage_link")}, sort_keys=True).encode())
        android.update({"symbol": f"{item['class']}.{item['field']}", "behavior": behavior,
                        "default_scope": "declaration; conditional initialization/migration may override",
                        "reference_counts": dict(sorted(counts.items())),
                        "references": dict(sorted(refs[feature_id].items())),
                        "ui_resources": sorted(ui_labels[feature_id])[:12]})
        state = (_STATE_FIELD.search(item["field"]) or item.get("origin") == "ancillary-storage"
                 or item["visibility"] == "private" and item["storage"] != "config-item"
                 or item["field"] in {"localSyncedDate", "pluginSettingJson"}
                 or item["class"] in {"BingTranslatorRaw", "EnergyProfiler", "LegacyDefaults", "PluginsWatchdog", "XposedHooks", "PluginCapabilityScan"})
        features.append({"id": feature_id, "name": _name(item["field"]), "group": _group(item),
                         "kind": "state" if state else "setting-template" if item.get("scope") == "parameterized" else "setting",
                         "android": android, "ios": _ios_plan(item), "implementation": _pending()})
        if feature_id in source_notes:
            android["source_review"] = source_notes[feature_id]
        android["derived_readers"] = [r for r in derived_readers if feature_id in r["targets"]]
    # Getter aliases are API entries, not duplicated settings. Raw preferences
    # without live destinations remain compatibility storage even with 139 APIs.
    compatibility = []
    for config in configs:
        if config["class"] != "ExteraConfig":
            continue
        for method in config["methods"]:
            if not method.public or not method.static:
                continue
            body = config["clean"][method.body:method.end]
            direct_targets = set(calls.get((config["class"], method.name), ()))
            for _, _, _, _, ids in _references(config["code"][method.body:method.end], fields, calls, owners):
                direct_targets.update(ids)
            destinations = sorted(direct_targets & raw_items.keys())
            storage = "getPreferences()" in body and bool(re.search(r"\.(?:get|put)(?:Boolean|Int|Float|Long|String)\(", body))
            record = {"id": f"compat.ExteraConfig.{method.name}({','.join(method.parameter_types)})",
                      "symbol": "ExteraConfig." + method.name, "file": config["file"],
                      "line": config["clean"].count("\n", 0, method.start) + 1,
                      "type": method.result, "arity": method.arity,
                      "parameter_types": list(method.parameter_types),
                      "behavior": "mapped-alias" if destinations else "compat-storage" if storage else "shim-utility-or-unresolved",
                      "targets": destinations, "implementation": _pending()}
            for raw in config["items"]:
                if method.start <= sum(len(line) + 1 for line in config["clean"].splitlines()[:raw["line"] - 1]) <= method.end:
                    record["storage_key"] = raw["key"]
                    record["default"] = raw["default"]
            compatibility.append(record)
    config_summary = {}
    for config in configs:
        shim = config["class"] == "ExteraConfig"
        config_summary[config["class"]] = {"found": True, "file": config["file"],
            "role": "compatibility-shim" if shim else "functional-config" if config["items"] and config["class"].endswith("Config") else "auxiliary-preference-store" if config["items"] else "configuration-helper",
            "count": 0 if shim else len(config["items"]),
            "toggles": [] if shim else sorted(i["field"] for i in config["items"]),
            "public_methods": sum(m.public for m in config["methods"]),
            "scalar_getter_methods": len({m.name for m in config["methods"] if m.public and m.static and m.result in {"boolean", "Boolean", "int", "Int", "long", "Long", "float", "Float", "String"}})}
    proposed = defaultdict(list)
    for item in features:
        proposed[item["ios"]["setting_key"]].append(item["id"])
    collisions = {key: ids for key, ids in proposed.items() if len(ids) > 1}
    for item in features:
        key = item["ios"]["setting_key"]
        if key in collisions:
            item["ios"]["key_collision"] = collisions[key]
    grouped_ui = {}
    for definition in ui_definitions:
        record = grouped_ui.setdefault(definition["id"], {**definition, "site_count": 0, "sites": []})
        record["site_count"] += 1
        if len(record["sites"]) < MAX_REFS:
            record["sites"].append({"file": definition["file"], "line": definition["line"]})
    ui_definitions = [grouped_ui[key] for key in sorted(grouped_ui)]
    payload = {"schema_version": SCHEMA_VERSION, "generator": "tools.compat.feature_inventory",
               "android_source": _android_pin(root, main, paths), "source_files": dict(sorted(pins.items())),
               "configs": config_summary, "features": features, "compatibility_apis": compatibility,
               "ui_definitions": ui_definitions,
               "modules": scan_modules(root), "legacy_trees": scan_legacy_trees(root),
               "native_targets": _native_targets(project), "platform_constraints": CONSTRAINTS,
               "setting_key_collisions": collisions, "waves": WAVES,
               "analysis_limits": {"references_per_kind": MAX_REFS, "max_source_files": MAX_SOURCE_FILES,
                                   "max_file_bytes": MAX_FILE_BYTES, "max_records": MAX_RECORDS,
                                   "method": "lexical source references; no reachability/runtime/visual claim"}}
    _totals(payload)
    if len(ui_definitions) > MAX_RECORDS:
        raise ValueError("UI definition limit exceeded")
    return payload


def _totals(payload):
    features = payload["features"]
    behavior = Counter(f["android"]["behavior"] for f in features)
    payload["totals"] = {"declared_settings_and_state": len(features),
                         "settings": sum(f["kind"] == "setting" for f in features),
                         "state": sum(f["kind"] == "state" for f in features),
                         "setting_templates": sum(f["kind"] == "setting-template" for f in features),
                         "config_toggles": sum(f["kind"] in {"setting", "setting-template"} for f in features),
                         "android_behavior": dict(sorted(behavior.items())),
                         "compatibility_api_members": len(payload["compatibility_apis"]),
                         "modules": len(payload["modules"]),
                         "ui_definition_sites": sum(d["site_count"] for d in payload.get("ui_definitions", [])),
                         "verified_features": sum(f["implementation"].get("ported", False) for f in features),
                         "java_kotlin_kb": round(payload["android_source"]["counts"]["bytes"] / 1024)}


def _all_records(payload):
    for section in ("features", "compatibility_apis", "modules", "legacy_trees", "symbols"):
        records = payload.get(section, [])
        if isinstance(records, dict):
            for name, record in records.items():
                record = dict(record)
                record.setdefault("id", ("module." if section == "modules" else "legacy.") + name)
                yield record
        else:
            yield from records


def _implementation(record):
    state = record.get("implementation", record.get("ios", {}).get("implementation"))
    if state is None and any(key in record for key in ("status", "ported", "evidence")):
        state = {k: record[k] for k in ("status", "ported", "evidence") if k in record}
    if state is None:
        return None
    state = deepcopy(state)
    status = state.get("status", "verified" if state.get("ported") else "pending")
    allowed = {"pending", "in-progress", "implemented", "partial", "verified", "stock-equivalent-verified", "blocked", "platform-prerequisite", "unsupported", "compat-storage"}
    if status not in allowed:
        raise ValueError(f"invalid parity status for {record['id']}: {status}")
    verified = status in {"verified", "stock-equivalent-verified"}
    evidence = state.get("evidence", [])
    if not isinstance(evidence, list) or len(evidence) > 32:
        raise ValueError(f"invalid or unbounded evidence for {record['id']}")
    if verified and not any(isinstance(e, dict) and e.get("kind") in {"test", "runtime", "visual", "review"}
                            and (e.get("path") or e.get("url")) for e in evidence):
        raise ValueError(f"verified parity requires verification evidence: {record['id']}")
    if state.get("ported") and not verified:
        raise ValueError(f"ported=true requires a verified status: {record['id']}")
    state.update(status=status, ported=verified and not state.get("source_review_required"), evidence=evidence)
    return state


def merge_parity(payload, previous=None, fragments=()):
    """Preserve verified statuses across regeneration; merge independent fragments.

    Fragments may change iOS plans and implementation evidence, never Android
    discovery. Unknown IDs/conflicting fragments fail instead of losing work.
    Previous records removed from Android are retained as orphaned_parity.
    """
    result = deepcopy(payload)
    records = {r["id"]: r for section in ("features", "compatibility_apis", "symbols") for r in result.get(section, [])}
    for section in ("modules", "legacy_trees"):
        records.update({r["id"]: r for r in result.get(section, {}).values() if "id" in r})
    orphaned, applied = {}, {}
    previous_documents = previous if isinstance(previous, list) else [previous or {}]
    documents = [(p, False) for p in previous_documents] + [(f, True) for f in fragments]
    for document, explicit in documents:
        for old in _all_records(document):
            feature_id = old["id"]
            state = _implementation(old)
            if feature_id not in records:
                if explicit:
                    raise ValueError(f"unknown parity id: {feature_id}")
                if state and state["status"] != "pending":
                    orphaned[feature_id] = {"id": feature_id, "implementation": state}
                continue
            if explicit and feature_id in applied and applied[feature_id] != old:
                raise ValueError(f"conflicting parity fragments: {feature_id}")
            if explicit:
                applied[feature_id] = old
            current = records[feature_id]
            if not explicit and state and state["status"] == "pending" and current.get("implementation", {}).get("status", "pending") != "pending":
                state = None  # An older generated default cannot erase evidence.
            if state:
                old_definition = old.get("android", {}).get("definition_fingerprint")
                new_definition = current.get("android", {}).get("definition_fingerprint")
                if not explicit and old_definition and new_definition and old_definition != new_definition and state["ported"]:
                    state["source_review_required"] = {"previous_definition": old_definition, "current_definition": new_definition}
                    state["ported"] = False
                current["implementation"] = state
                if "ported" in current:
                    current["ported"] = state["ported"]
            if "ios" in current and "ios" in old:
                for key in ("setting_key", "state_key", "test_environment_key", "existing_equivalent", "implementation_callsites", "adaptation", "platform_constraints"):
                    if key in old["ios"] and (explicit or key in old.get("parity_override_fields", []) or state and state["status"] != "pending"):
                        current["ios"][key] = deepcopy(old["ios"][key])
                        current.setdefault("parity_override_fields", [])
                        if key not in current["parity_override_fields"]:
                            current["parity_override_fields"].append(key)
            for key in ("source_claim", "secondary_source_claims", "source_disposition", "rollup", "domain_contributions"):
                if key in old:
                    current[key] = deepcopy(old[key])
                elif explicit:
                    current.pop(key, None)
            individual_routes.preserve_record(current, old)
            if "current_source_evidence" in old:
                current["current_source_evidence"] = deepcopy(old["current_source_evidence"])
    for document in previous_documents:
        orphaned.update({r["id"]: r for r in document.get("orphaned_parity", [])})
    if orphaned:
        result["orphaned_parity"] = [orphaned[k] for k in sorted(orphaned)]
    for document in previous_documents:
        for key in ("source_reconciliation", "pill_types", "individual_source_reconciliation", "current_source_reconciliation"):
            if key in document:
                result[key] = deepcopy(document[key])
    if "features" in result:
        _totals(result)
    if "symbols" in result and result.get("individual_source_reconciliation"):
        individual_routes.refresh_sdk_counts(result)
    return result


def _load_json(path):
    if not path.is_file():
        return None
    if path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError(f"inventory/fragment exceeds 32 MiB: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def normalize_source_receipt(document, owner, features):
    """Adapt published receipts without deriving completion from their schemas."""
    result = deepcopy(document)
    if owner == "pills":
        by_symbol = {r["android"]["symbol"]: r for r in features.values()}
        rows = []
        for raw in document["settings"]:
            original = by_symbol.get(raw["originalId"])
            if original is None or original["android"]["key"] != raw["androidKey"]:
                raise ValueError(f"Pill original symbol/key mismatch: {raw['originalId']}")
            symbol = raw["callsite"]
            path = document["callsiteFiles"][symbol.split(".")[0]]
            rows.append({"id": original["id"],
                         "ios": {"setting_key": raw["key"],
                                 "implementation_callsites": [{"path": path, "symbol": symbol}],
                                 "adaptation": {"source_status": document["status"], "setting": raw}},
                         "implementation": {"status": "partial", "ported": False,
                                            "evidence": [{"kind": "source", "path": path, "symbol": symbol}]}})
        result["features"] = rows
        result["modules"] = {"pillstack": {
            "implementation": {"status": "partial", "ported": False,
                               "evidence": [{"kind": "source", "path": document["handoff"]}]},
            "scope": {k: deepcopy(document[k]) for k in ("status", "pluginSurface", "verification")}}}
    for section in ("features", "compatibility_apis"):
        rows = result.get(section, [])
        ids = [r["id"] for r in rows]
        if len(ids) != len(set(ids)) or len(ids) > MAX_RECORDS:
            raise ValueError(f"duplicate/unbounded {owner} {section} IDs")
    return result


def join_source_receipts(client, sdk, documents, policy):
    """Pure exact-ID join. Author claims never grant verification.

    Precedence selects a primary claim, retaining secondary evidence verbatim.
    Input Android records and SDK identities are immutable; Pills types are a
    separate surface. Explicitly scoped rollups never infer a module pass.
    """
    result, sdk_result = deepcopy(client), deepcopy(sdk)
    originals = {r["id"]: r for r in client["features"]}
    normalized = {owner: normalize_source_receipt(doc, owner, originals) for owner, doc in documents.items()}
    candidates = defaultdict(list)
    for owner, doc in normalized.items():
        for record in doc.get("features", []):
            if record["id"] not in originals:
                raise ValueError(f"unknown source receipt id: {record['id']}")
            candidates[record["id"]].append((owner, record))
        if not set(doc.get("modules", {})) <= client["modules"].keys():
            raise ValueError(f"unknown source module receipt: {owner}")
        if not {r["id"] for r in doc.get("compatibility_apis", [])} <= {r["id"] for r in client["compatibility_apis"]}:
            raise ValueError(f"unknown source API receipt: {owner}")

    def claim(owner, row):
        return {"owner": owner, "reported": deepcopy(row)}

    def apply(current, owner, row):
        state = _implementation(row) or _pending()
        if state["ported"] or state["status"] in {"verified", "stock-equivalent-verified"}:
            raise ValueError(f"source receipt cannot grant verification: {current['id']}")
        # Preserve independently verified history, if a later cohort has any.
        prior = _implementation(current)
        if not prior or not prior["ported"]:
            current["implementation"] = state
            if "ported" in current:
                current["ported"] = False
        if "ios" in row:
            ios = current.setdefault("ios", {})
            if "platform_constraints" in ios:
                ios.setdefault("candidate_platform_constraints", deepcopy(ios["platform_constraints"]))
            ios["platform_constraints"] = []  # Candidate hints are not author dispositions.
            ios.update(deepcopy(row["ios"]))
            current["parity_override_fields"] = sorted(row["ios"])
        current["source_claim"] = claim(owner, row)

    missing, collisions = [], []
    for current in result["features"]:
        fid = current["id"]
        choices = candidates.get(fid, [])
        if not choices:
            missing.append(fid)
            continue
        preferred = policy.get("owner_precedence", {}).get(fid)
        if fid in policy.get("player_ids", []):
            preferred = "player"
        if not preferred:
            preferred = next((owner for prefix, owner in policy.get("prefix_precedence", {}).items()
                              if fid.startswith(prefix)), None)
        if len(choices) > 1 and not preferred:
            raise ValueError(f"source owner precedence required: {fid}")
        selected = next(((o, r) for o, r in choices if o == preferred), None) if preferred else choices[0]
        if selected is None:
            raise ValueError(f"authoritative source owner missing: {fid}: {preferred}")
        apply(current, *selected)
        secondary = [claim(o, r) for o, r in choices if o != selected[0]]
        if secondary:
            current["secondary_source_claims"] = secondary
            collisions.append({"id": fid, "primary": selected[0], "secondary": [r["owner"] for r in secondary]})
        else:
            current.pop("secondary_source_claims", None)
        categories = [kind for kind, ids in policy.get("disposition_ids", {}).items() if fid in ids]
        if len(categories) > 1:
            raise ValueError(f"conflicting source disposition: {fid}")
        current["source_disposition"] = {
            "classification": categories[0] if categories else
                "native-state-adaptation" if current["kind"] == "state" else "source-claim-with-explicit-scope",
            "reason": deepcopy(current.get("ios", {}).get("adaptation")),
            "constraints": deepcopy(current.get("ios", {}).get("platform_constraints", [])),
            "receipt_owner": selected[0], "verified": False}

    apis = {r["id"]: r for r in normalized.get("sdk-config", {}).get("compatibility_apis", [])}
    if set(apis) != {r["id"] for r in client["compatibility_apis"]}:
        raise ValueError("published SDK Config receipt must contain every exact original overload ID")
    for current in result["compatibility_apis"]:
        apply(current, "sdk-config", apis[current["id"]])

    selected_features = {r["id"]: r for r in result["features"]}
    for name, current in result["modules"].items():
        owner = policy.get("module_owners", {}).get(name)
        if owner:
            row = normalized[owner].get("modules", {}).get(name)
            if row is None:
                raise ValueError(f"authoritative module receipt missing: {name}: {owner}")
            apply(current, owner, {"id": current["id"], **row})
        else:
            rollup = policy.get("rollups", {}).get(name)
            if rollup is None:
                raise ValueError(f"module has no explicit receipt or scoped rollup: {name}")
            if not set(rollup["ids"]) <= selected_features.keys():
                raise ValueError(f"unknown rollup contribution: {name}")
            evidence = deepcopy(rollup.get("evidence", []))
            for fid in rollup["ids"]:
                child = selected_features[fid]
                evidence.append({"kind": "source", "path": "docs/parity/client-features.json", "id": fid,
                                 "owner": child["source_claim"]["owner"]})
            row = {"id": current["id"], "scope": deepcopy(rollup),
                   "implementation": {"status": "partial", "ported": False, "evidence": evidence}}
            apply(current, "data-aggregator-scoped-rollup", row)
            current["rollup"] = deepcopy(rollup)
    # These are complementary domain contributions, not superseding module passes.
    if "backup" in result["modules"]:
        result["modules"]["backup"]["domain_contributions"] = {
            owner: [r["id"] for r in result["features"] if r.get("source_claim", {}).get("owner") == owner]
            for owner in ("retention", "cloud-api") if owner in documents}
    result["pill_types"] = [{**deepcopy(r), "implementation": {"status": "partial", "ported": False},
                             "receipt_owner": "pills"} for r in documents.get("pills", {}).get("pills", [])]

    named = {f"sdk.{module}.{name}" for module, names in policy.get("sdk_exact_claims", {}).items() for name in names}
    excluded = {f"sdk.{module}.{name}" for module, names in policy.get("sdk_exact_exclusions", {}).items() for name in names}
    for row in sdk_result["symbols"]:
        if row.get("individual_source"):
            continue  # An older class-level policy cannot erase exact owner routes.
        fid = row["id"]
        forwarding = (row["module"] == "client_utils" and row["name"].startswith("AccountClient.")
                      and "sdk.client_utils." + row["name"].split(".")[-1] in named)
        relation = deepcopy(row["native_relation"])
        row["static_native_relation"] = relation
        if fid in named or forwarding or fid in excluded:
            row["native_relation"] = {"status": "unsupported" if fid in excluded else "published-source-subset",
                                      "reason": policy["sdk_claim_boundary"],
                                      "evidence": [{"kind": "source", "path": "docs/wave-2/sdk.md", "symbol": row["name"]}]}
            if not row["implementation"].get("ported"):
                row["implementation"] = {"status": "unsupported" if fid in excluded else "partial", "ported": False,
                                         "evidence": deepcopy(row["native_relation"]["evidence"])}
        elif relation.get("adapter"):
            row["native_relation"] = {**relation, "boundary": "Exact AST assignment only; behavior and provider availability unverified."}
        else:
            row["native_relation"] = {"status": "not-individually-reconciled",
                                      "reason": "No current exact-symbol behavior receipt selected. Historical builtin-only classification retained separately; generic helpers do not cover this symbol."}
    sdk_result["totals"]["native_relation"] = dict(sorted(Counter(r["native_relation"]["status"] for r in sdk_result["symbols"]).items()))
    keys = defaultdict(list)
    for row in result["features"]:
        row["ios"].pop("key_collision", None)
        if row["ios"].get("setting_key"):
            keys[row["ios"]["setting_key"]].append(row["id"])
    result["setting_key_collisions"] = {k: ids for k, ids in sorted(keys.items()) if len(ids) > 1}
    for ids in result["setting_key_collisions"].values():
        for fid in ids:
            selected_features[fid]["ios"]["key_collision"] = ids
    _totals(result)
    return result, sdk_result, {"missing_feature_receipts": sorted(missing), "owner_conflicts_resolved": collisions,
                               "original_id_sets": {"features": sorted(originals), "modules": sorted(r["id"] for r in client["modules"].values()),
                                                    "compatibility_apis": sorted(r["id"] for r in client["compatibility_apis"]),
                                                    "symbols": sorted(r["id"] for r in sdk["symbols"])},
                               "sdk_names_outside_original_inventory": sorted((named | excluded) - {r["id"] for r in sdk["symbols"]})}


def validate_source_join(client, sdk, report, policy, *, check_current=True):
    """Data integrity only; never compile, execute adapters, or inspect CI."""
    counts = policy["required_counts"]
    for section, rows, count_key in (("features", client["features"], "features"),
                                      ("modules", list(client["modules"].values()), "modules"),
                                      ("compatibility_apis", client["compatibility_apis"], "compatibility_apis"),
                                      ("symbols", sdk["symbols"], "sdk_symbols")):
        ids = [r["id"] for r in rows]
        if len(ids) != len(set(ids)) or len(ids) != counts[count_key]:
            raise ValueError(f"exact {section} identity/count failed")
        if sorted(ids) != report["original_id_sets"][section]:
            raise ValueError(f"original {section} IDs changed")
        if section in {"features", "compatibility_apis", "modules"}:
            for row in rows:
                source = row.get("source_claim", {})
                raw = source.get("reported", {})
                if raw.get("id") != row["id"]:
                    raise ValueError(f"source claim identity mismatch: {row['id']}")
                if not row["implementation"].get("ported") and row["implementation"]["status"] != raw["implementation"]["status"]:
                    raise ValueError(f"author status changed: {row['id']}")
                if "setting_key" in raw.get("ios", {}) and row.get("ios", {}).get("setting_key") != raw["ios"]["setting_key"]:
                    raise ValueError(f"published key changed: {row['id']}")
    selected = [r for r in client["features"] if "source_claim" in r]
    if len(selected) != counts["features"] or report["missing_feature_receipts"]:
        raise ValueError("original feature receipt partition incomplete")
    pills = [r for r in selected if r["source_claim"]["owner"] == "pills"]
    if len(pills) != counts["pill_settings"]:
        raise ValueError("Pill setting normalization lost IDs")
    types = [r["originalId"] for r in client["pill_types"]]
    if sorted(types) != list(range(1, counts["pill_types"] + 1)):
        raise ValueError("Pill type contracts lost or duplicated")
    before = report.get("previous_verified", 0)
    after = sum(bool(r.get("implementation", {}).get("ported")) for r in _all_records(client))
    after += sum(bool(r.get("implementation", {}).get("ported")) for r in sdk["symbols"])
    if after != before:
        raise ValueError("source join changed verified parity")
    if "feature_map" in report:
        mapping = {r["id"]: r for r in report["feature_map"]}
        if len(mapping) != len(report["feature_map"]) or set(mapping) != {r["id"] for r in selected}:
            raise ValueError("reconciliation feature-map partition changed")
        for row in selected:
            mapped = mapping[row["id"]]
            expected = (row["source_claim"]["owner"], row["ios"].get("setting_key"), row["source_claim"]["reported"]["implementation"]["status"])
            if (mapped["owner"], mapped["ios_key"], mapped["author_status"]) != expected:
                raise ValueError(f"reconciliation feature-map claim differs: {row['id']}")
    if "compatibility_api_map" in report:
        mapping = {r["id"]: r for r in report["compatibility_api_map"]}
        if len(mapping) != len(report["compatibility_api_map"]) or set(mapping) != {r["id"] for r in client["compatibility_apis"]}:
            raise ValueError("reconciliation API partition changed")
        for row in client["compatibility_apis"]:
            mapped = mapping[row["id"]]
            if mapped["status"] != row["implementation"]["status"] or mapped["ios"] != row["ios"]:
                raise ValueError(f"reconciliation API claim differs: {row['id']}")
    if "sdk_symbol_partition" in report:
        flat = [fid for ids in report["sdk_symbol_partition"].values() for fid in ids]
        if len(flat) != len(set(flat)) or set(flat) != {r["id"] for r in sdk["symbols"]}:
            raise ValueError("reconciliation SDK symbol partition changed")
        for row in sdk["symbols"]:
            if row["id"] not in report["sdk_symbol_partition"].get(row["native_relation"]["status"], []):
                raise ValueError(f"reconciliation SDK relation differs: {row['id']}")
    individual_checks = individual_routes.validate(client, sdk)
    current_checks = validate_current_source_overlay(client, sdk, report) if check_current else {}
    if check_current and policy.get("current_source_overlay"):
        receipt = client.get("current_source_reconciliation", {}).get("input_receipt", {})
        expected = policy["current_source_overlay"]
        if (receipt.get("path"), receipt.get("sha256")) != (expected["path"], expected["sha256"]):
            raise ValueError("materialized current overlay differs from explicit policy")
    return {"features": len(selected), "modules": len(client["modules"]), "sdk_symbols": len(sdk["symbols"]),
            "compatibility_apis": len(client["compatibility_apis"]), "pill_types": len(types),
            "verified_before": before, "verified_after": after, "result": "passed-data-only", **individual_checks, **current_checks}


class SourceSnapshot:
    """Pin targeted source reads; a supplied line number is never a fresh anchor.

    Only one source text is cached. Ambiguous symbol matches retain bounded
    candidates instead of choosing an arbitrary occurrence or shifting old lines.
    """
    def __init__(self, project):
        self.project = Path(project)
        self.files = {}
        self._last = (None, "")
        self._lines = []

    def text(self, path):
        if self._last[0] == path:
            return self._last[1]
        file = self.project / path
        if not file.is_file():
            return None
        text, sha, size = _read(file)
        prior = self.files.get(path)
        self.files[path] = {"sha256": sha, "bytes": size, "lines": len(text.splitlines())}
        if prior and prior["sha256"] != sha:
            self.files[path]["prior_read_hashes"] = sorted(set(prior.get("prior_read_hashes", []) + [prior["sha256"]]))
        self._last = (path, text)
        self._lines = text.splitlines()
        return text

    def reference(self, raw, setting_key=None, original_id=None):
        ref = deepcopy(raw)
        path = ref.get("path", ref.get("file"))
        if not isinstance(path, str):
            return ref
        path = path.replace("\\", "/")
        if path.startswith(("java/", "kotlin/")):
            path = "third_party/exteraless-android/TMessagesProj/src/main/" + path
        ref["path"] = path
        if "line" in ref:
            ref["reported_line"] = ref.pop("line")
        if "sha256" in ref:
            ref["reported_sha256"] = ref.pop("sha256")
        if path.startswith("docs/parity/"):
            ref["anchor_resolution"] = "inventory-record-reference"
            return ref  # Avoid self-referential hashes of materialized output.
        text = self.text(path)
        if text is None:
            ref["anchor_resolution"] = "referenced-path-unavailable"
            return ref
        ref["sha256"] = self.files[path]["sha256"]
        ref["reference_scope"] = "published-report" if path.startswith("docs/") else "source"
        candidates = []
        if ref.get("anchor"):
            candidates.append((ref["anchor"], "exact-anchor"))
        symbol = ref.get("symbol", "")
        if symbol:
            candidates.append((symbol, "published-symbol"))
            # Authors also supply qualified member names absent as contiguous text.
            for part in re.split(r"\s*/\s*|\s*->\s*", symbol):
                leaf = part.split(".")[-1].split("(")[0]
                if re.fullmatch(r"[A-Za-z_][\w]{3,}", leaf) and leaf not in {"default", "init", "register", "update", "value", "state"}:
                    candidates.append((leaf, "published-symbol-token"))
        if isinstance(setting_key, str) and setting_key:
            candidates.append((json.dumps(setting_key), "literal-setting-key"))
        if original_id:
            candidates.append((original_id.rsplit(".", 1)[-1], "original-field-token-candidate"))
        lines = self._lines
        for token, kind in candidates:
            pattern = re.compile(r"(?<![\w])" + re.escape(token) + r"(?![\w])")
            matches = [(n, line.strip()) for n, line in enumerate(lines, 1) if pattern.search(line)]
            if not matches:
                continue
            ref.update(anchor=token, anchor_resolution=kind, match_count=len(matches))
            ref["matches"] = [{"line": n, "text": line[:300]} for n, line in matches[:8]]
            if len(matches) == 1:
                ref["line"] = matches[0][0]
            return ref
        ref["anchor_resolution"] = "file-snapshot-only-no-resolved-symbol"
        return ref


def materialize_source_join(client, sdk, documents, sources, policy, project, previous_report=None):
    """Add read-time pins and exact projections to the pure source-claim join."""
    before = sum(bool(r.get("implementation", {}).get("ported")) for r in _all_records(client))
    before += sum(bool(r.get("implementation", {}).get("ported")) for r in sdk["symbols"])
    result, sdk_result, report = join_source_receipts(client, sdk, documents, policy)
    report.update(schema_version=2, kind="materialized-source-claim-reconciliation", previous_verified=before,
                  sources=deepcopy(sources), component_evidence=deepcopy(policy["component_evidence"]))
    snap = SourceSnapshot(project)
    references = []
    feature_ids = {r["id"] for r in result["features"]}
    for row in [*result["features"], *result["compatibility_apis"], *result["modules"].values()]:
        source_claim = row["source_claim"]
        owner = source_claim["owner"]
        if owner in sources:
            source_claim["receipt"] = {k: sources[owner][k] for k in ("path", "sha256")}
        for secondary in row.get("secondary_source_claims", []):
            secondary["receipt"] = {k: sources[secondary["owner"]][k] for k in ("path", "sha256")}
        for parent, key in ((row.get("ios", {}), "implementation_callsites"), (row["implementation"], "evidence")):
            for index, ref in enumerate(parent.get(key, [])):
                if isinstance(ref, dict):
                    references.append((ref.get("path", ref.get("file", "")), parent[key], index, row))
    # Group by file so large native blocks are read once, only for named anchors.
    for _, array, index, row in sorted(references, key=lambda r: r[0]):
        array[index] = snap.reference(array[index], row.get("ios", {}).get("setting_key"), row["id"] if row["id"] in feature_ids else None)

    features = {r["id"]: r for r in result["features"]}
    for group in policy.get("source_reference_groups", []):
        for fid, row in features.items():
            if row["source_claim"]["owner"] != group["owner"]:
                continue
            if fid not in group.get("ids", []) and not (group.get("id_prefix") and fid.startswith(group["id_prefix"])):
                continue
            anchor = fid.rsplit(".", 1)[-1] if group.get("field_token") else group["anchor"]
            ref = snap.reference({"path": group["path"], "anchor": anchor, "role": group["role"]})
            if not ref.get("match_count"):
                raise ValueError(f"targeted source group anchor missing: {fid}")
            ref["scope"] = group["scope"]
            ref["origin"] = "data-join-targeted-symbol"
            row["ios"].setdefault("implementation_callsites", []).append(ref)
    corrections = []
    for correction in policy.get("android_consumer_corrections", []):
        edges = []
        for raw in correction["references"]:
            ref = snap.reference(raw)
            if ref.get("match_count") != 1:
                raise ValueError(f"Android correction anchor must be unique: {raw}")
            edge = {k: v for k, v in ref.items() if k not in {"matches", "reported_line", "reference_scope"}}
            edges.append(edge)
        for fid in correction["ids"]:
            android = features[fid]["android"]
            android["behavior"] = "effect-callsite"
            android["source_join_correction"] = {"reason": correction["reason"], "references": deepcopy(edges)}
            if not android["reference_counts"].get("effect"):
                raise ValueError(f"checked effect edge not found by scanner: {fid}")
        corrections.append({"ids": correction["ids"], "reason": correction["reason"], "references": edges})
    report["android_consumer_corrections"] = corrections

    canonical = []
    for choice in policy.get("canonical_keys", []):
        row = features[choice["id"]]
        if row["source_claim"]["owner"] != choice["owner"] or row["ios"]["setting_key"] != choice["key"]:
            raise ValueError(f"canonical owner/key mismatch: {choice['id']}")
        anchors = [snap.reference(ref) for ref in choice["anchors"]]
        if any(ref.get("match_count") != 1 for ref in anchors):
            raise ValueError(f"canonical source anchor missing/ambiguous: {choice['id']}")
        absent = choice["absent_anchor"]
        text = snap.text(absent["path"])
        if text is None or absent["anchor"] in text:
            raise ValueError(f"legacy canonical declaration still present: {choice['id']}")
        canonical.append({**choice, "anchors": anchors, "absent_anchor": {**absent, "sha256": snap.files[absent["path"]]["sha256"], "present": False},
                          "source_state": "canonical-consumers-and-migrations-found", "verified": False})
    report["canonical_key_decisions"] = canonical

    report["review_layers"] = []
    for layer in policy.get("reports", []):
        if snap.text(layer["path"]) is None:
            raise ValueError(f"published review not found: {layer['path']}")
        report["review_layers"].append({**layer, "sha256": snap.files[layer["path"]]["sha256"],
                                      "resolved_by_this_join": False})
    report["applied_source_receipts"] = []
    for overlay in policy.get("applied_source_receipts", []):
        ref = snap.reference({"path": overlay["report"], "anchor": overlay["anchor"]})
        if ref.get("match_count") != 1:
            raise ValueError(f"integration report anchor missing/ambiguous: {overlay['id']}")
        report["applied_source_receipts"].append({**overlay, "reference": ref, "verified": False})
        if overlay["id"] == "network-passive-RTT":
            pill = next(r for r in result["pill_types"] if r["originalId"] == 11)
            pill["integration_overlay"] = {"state": "reported-Rust-passive-RTT-forwarding-applied", "reference": ref,
                                           "remaining": "MtProtoKit retained RTT and physical/native measurements unverified; no zero/RPC-latency substitution.", "verified": False}
    report["sdk_report"] = snap.reference({"path": "docs/wave-2/sdk.md", "anchor": "### client_utils (AccountClient forwards retain the same status)"})
    report["pill_type_contracts"] = deepcopy(result["pill_types"])
    report["module_authorship_needs"] = {"module." + name: data["authorship_needed"] for name, data in policy["rollups"].items() if data.get("authorship_needed")}
    report["module_rollup_gaps"] = []
    report["module_map"] = [{"id": row["id"], "owner": row["source_claim"]["owner"], "status": row["implementation"]["status"],
                             "scope": row.get("rollup", row["source_claim"]["reported"].get("scope")),
                             "domain_contributions": row.get("domain_contributions", {})} for row in result["modules"].values()]
    report["feature_map"] = [{"id": r["id"], "owner": r["source_claim"]["owner"],
                              "android": {k: r["android"][k] for k in ("symbol", "key", "file", "line")},
                              "ios_key": r["ios"].get("setting_key"), "author_status": r["source_claim"]["reported"]["implementation"]["status"],
                              "disposition": r["source_disposition"]["classification"], "ported": r["implementation"]["ported"]} for r in result["features"]]
    report["compatibility_api_map"] = [{"id": r["id"], "status": r["implementation"]["status"],
                                       "ios": deepcopy(r["ios"]), "ported": False} for r in result["compatibility_apis"]]
    report["sdk_symbol_partition"] = {status: [r["id"] for r in sdk_result["symbols"] if r["native_relation"]["status"] == status]
                                      for status in sorted({r["native_relation"]["status"] for r in sdk_result["symbols"]})}
    report["counts"] = {"features": len(features), "modules": len(result["modules"]), "sdk_symbols": len(sdk_result["symbols"]),
                        "compatibility_apis": len(result["compatibility_apis"]), "pill_settings": len(documents["pills"]["settings"]),
                        "pill_types": len(result["pill_types"]), "missing_feature_receipts": len(report["missing_feature_receipts"]),
                        "feature_author_statuses": dict(sorted(Counter(r["implementation"]["status"] for r in result["features"]).items())),
                        "api_author_statuses": dict(sorted(Counter(r["implementation"]["status"] for r in result["compatibility_apis"]).items()))}
    former = (previous_report or {}).get("former_gap_ids")
    if former is None:
        former = [fid for group in (previous_report or {}).get("missing_receipts", []) for fid in group["ids"]]
    report["former_gap_ids"] = sorted(former)
    report["former_gaps_now_present"] = sorted(set(former) & {r["id"] for r in result["features"] if "source_claim" in r})
    report["source_file_pins"] = dict(sorted(snap.files.items()))
    report["features_with_file_only_claim_references"] = sorted(r["id"] for r in result["features"]
        if not any(ref.get("match_count") for ref in r["ios"].get("implementation_callsites", []) + r["implementation"].get("evidence", []) if isinstance(ref, dict)))
    report["file_only_reference_meaning"] = "Published receipt and source-file hash exist, but no unambiguous supplied symbol/key was resolved by the bounded locator. This is an anchor-granularity limitation, not a missing receipt or a conclusion about runtime behavior."
    report["source_evidence_fingerprint"] = _sha(_json_text(report["source_file_pins"]).encode("utf-8"))
    report["proof_boundary"] = "Published author claims and targeted source anchors only. No code review, CI query, compilation, plugin/native execution, UI/frames or verified promotions. Reference counts do not establish runtime effects."
    report["sdk_925_boundary"] = policy["sdk_claim_boundary"]
    if result.get("current_source_reconciliation"):
        report["current_source_reconciliation"] = deepcopy(result["current_source_reconciliation"])
    report["data_checks"] = validate_source_join(result, sdk_result, report, policy, check_current=False)
    metadata = {"report": "docs/parity/wave-2-reconciliation.json", "receipts": {k: {f: v[f] for f in ("path", "sha256")} for k, v in sources.items()},
                "source_evidence_fingerprint": report["source_evidence_fingerprint"], "proof_boundary": report["proof_boundary"]}
    result["source_reconciliation"] = deepcopy(metadata)
    sdk_result["source_reconciliation"] = deepcopy(metadata)
    _totals(result)
    return result, sdk_result, report


def replay_source_documents(client, report):
    """Replay retained normalized claims, without rereading a moving SDK receipt."""
    documents = {owner: deepcopy(source["metadata"]) for owner, source in report["sources"].items()}
    for row in client["features"]:
        for claim in [row["source_claim"], *row.get("secondary_source_claims", [])]:
            owner, raw = claim["owner"], deepcopy(claim["reported"])
            if owner == "pills":
                documents[owner].setdefault("settings", []).append(raw["ios"]["adaptation"]["setting"])
            else:
                documents[owner].setdefault("features", []).append(raw)
    for name, row in client["modules"].items():
        claim = row["source_claim"]
        if claim["owner"] in documents and claim["owner"] != "pills":
            raw = deepcopy(claim["reported"])
            raw.pop("id", None)
            documents[claim["owner"]].setdefault("modules", {})[name] = raw
    documents["sdk-config"]["compatibility_apis"] = [deepcopy(r["source_claim"]["reported"]) for r in client["compatibility_apis"]]
    documents["pills"]["pills"] = [{k: deepcopy(v) for k, v in row.items() if k not in {"implementation", "receipt_owner", "integration_overlay"}}
                                     for row in client["pill_types"]]
    return documents


def _python_surface(path):
    """Public declarations, class members and explicit exports, using AST only."""
    text, sha, size = _read(path)
    tree = ast.parse(text, filename=str(path))
    result, exported = {}, None
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "__all__" for t in node.targets):
            try:
                exported = set(ast.literal_eval(node.value))
            except (ValueError, SyntaxError, TypeError):
                pass
    def collect(nodes, prefix=""):
        for node in nodes:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                if node.name.startswith("_") and node.name not in {"__init__", "__call__"}:
                    continue
                if not prefix and exported is not None and node.name not in exported:
                    continue
                name = prefix + node.name
                entry = {"name": name, "line": node.lineno,
                         "kind": "class" if isinstance(node, ast.ClassDef) else "method" if prefix else "function"}
                if not isinstance(node, ast.ClassDef):
                    args = node.args
                    positional = args.posonlyargs + args.args
                    defaults = {a.arg: d for a, d in zip(positional[len(positional) - len(args.defaults):], args.defaults)}
                    defaults.update({a.arg: d for a, d in zip(args.kwonlyargs, args.kw_defaults) if d is not None})
                    def parameter(arg, kind):
                        result = {"name": arg.arg, "kind": kind, "optional": arg.arg in defaults}
                        if arg.annotation:
                            result["annotation"] = _compact(ast.unparse(arg.annotation))[:MAX_EXPRESSION]
                        if arg.arg in defaults:
                            expression = ast.unparse(defaults[arg.arg])
                            try:
                                value = ast.literal_eval(defaults[arg.arg])
                                json.dumps(value, allow_nan=False)
                                if len(expression) <= MAX_EXPRESSION and not (_SENSITIVE.search(arg.arg) and value):
                                    result["default"] = {"kind": "literal", "value": value}
                                else:
                                    result["default"] = {"kind": "redacted"}
                            except (ValueError, TypeError, SyntaxError):
                                result["default"] = {"kind": "expression", "expression": "<inspect pinned source>" if _SENSITIVE.search(arg.arg) or len(expression) > MAX_EXPRESSION else expression}
                        return result
                    entry["parameters"] = ([parameter(a, "positional-only") for a in args.posonlyargs]
                        + [parameter(a, "positional-or-keyword") for a in args.args]
                        + ([{"name": args.vararg.arg, "kind": "var-positional"}] if args.vararg else [])
                        + [parameter(a, "keyword-only") for a in args.kwonlyargs]
                        + ([{"name": args.kwarg.arg, "kind": "var-keyword"}] if args.kwarg else []))
                    if node.returns:
                        entry["return_annotation"] = _compact(ast.unparse(node.returns))[:MAX_EXPRESSION]
                java = sorted({n.value for n in ast.walk(node) if isinstance(n, ast.Constant) and isinstance(n.value, str)
                               and re.fullmatch(r"(?:java|javax|android|androidx|org\.telegram|app\.exteraless|com\.exteragram|dalvik)\.[\w.$]+", n.value)})
                if java:
                    entry["native_class_references"] = java[:16]
                    entry["native_class_reference_count"] = len(java)
                result[name] = entry
                if isinstance(node, ast.ClassDef):
                    collect(node.body, name + ".")
            elif not prefix and isinstance(node, (ast.Import, ast.ImportFrom)):
                for alias in node.names:
                    name = alias.asname or (alias.name.split(".")[0] if isinstance(node, ast.Import) else alias.name)
                    if name == "*" or name.startswith("_") or exported is not None and name not in exported:
                        continue
                    result.setdefault(name, {"name": name, "line": node.lineno, "kind": "import",
                                             "origin": ((node.module or "") + "." if isinstance(node, ast.ImportFrom) else "") + alias.name})
            elif isinstance(node, (ast.Assign, ast.AnnAssign)):
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                for target in targets:
                    if not isinstance(target, ast.Name) or target.id.startswith("_"):
                        continue
                    if not prefix and exported is not None and target.id not in exported:
                        continue
                    name = prefix + target.id
                    result.setdefault(name, {"name": name, "line": node.lineno, "kind": "constant-or-alias"})
    collect(tree.body)
    for name in exported or ():
        if isinstance(name, str) and name not in result:
            result[name] = {"name": name, "line": 1, "kind": "dynamic-export"}
    return result, sha, size


def _bridge_surface(project):
    path = project / "swift/PluginHost/Sources/PluginHost/BridgeServices.swift"
    if not path.is_file():
        return {"members": [], "status": "source-unavailable"}
    text, sha, _ = _read(path)
    clean = mask_source(text, nested_comments=True)
    code = mask_source(text, strings=True, nested_comments=True)
    def body(function):
        start = code.find("func " + function + "(")
        if start < 0:
            return ""
        opening = code.find("{", start)
        return clean[opening:_close(code, opening)] if opening >= 0 else ""
    bodies = {name: body(name) for name in ("dispatch", "getStatic", "callStatic", "callRuntime", "callInstance", "callLocale")}
    runtime = "exteraless.ios.Runtime"
    members = []
    def add(cls, names, operation, anchor, constraint=""):
        offset = clean.find(anchor)
        if offset < 0:
            return  # No support claim if its implementing branch disappeared.
        for name in names:
            scope = ("callRuntime" if cls == runtime else "getStatic" if operation == "get" else
                     "dispatch" if operation == "get_instance" else
                     "callLocale" if cls.endswith(".LocaleController") and name != "getInstance" else
                     "callInstance" if operation == "call_instance" else "callStatic")
            if json.dumps(name.removesuffix("*")) not in bodies[scope]:
                continue  # Reflection metadata alone must not advertise support.
            members.append({"fqcn": cls, "member": name, "operation": operation,
                            "status": "supported-subset", "line": text.count("\n", 0, offset) + 1,
                            "constraint": constraint or "exact operation/arity, owner/handle/permission and native service availability checks apply"})
    # These are the *dispatch* cases, not manifest class presence or permissive
    # member_kind metadata. No constructors or writable Java members are accepted.
    add(runtime, ["getSetting", "setSetting", "removeSetting", "getFilesDir", "getPluginsDir", "getCacheDir", "log", "getVersion", "sendMessage", "addToClipboard", "openURL"], "call", "private func callRuntime(")
    add(runtime, ["hasPermission", "isUnsafeMode", "completeCallback"], "call", 'request.member == "completeCallback"')
    add("org.telegram.messenger.AndroidUtilities", ["dp", "dpf2", "runOnUIThread", "addToClipboard"], "call", 'case "dp", "dpf2":')
    add("org.telegram.messenger.AndroidUtilities", ["density"], "get", 'case ("org.telegram.messenger.AndroidUtilities", "density")')
    add("org.telegram.ui.ActionBar.Theme", ["getColor"], "call", 'where request.member == "getColor"')
    add("org.telegram.ui.ActionBar.Theme", ["key_*"], "get", 'request.member.hasPrefix("key_")', "only known theme snapshot keys; arbitrary keys are not supported")
    add("org.telegram.messenger.ApplicationLoader", ["applicationContext"], "get", 'case ("org.telegram.messenger.ApplicationLoader", "applicationContext")')
    add("org.telegram.messenger.ApplicationLoader", ["getFilesDir", "getFilesDirFixed", "getCacheDir"], "call", '["getFilesDir", "getFilesDirFixed", "getCacheDir"]')
    add("android.content.Context", ["getFilesDir", "getCacheDir"], "call_instance", "case .applicationContext:")
    add("java.io.File", ["getPath", "getAbsolutePath", "toString", "getName", "exists", "isDirectory"], "call_instance", "case .file(let url):", "host-issued per-plugin directory handles only; arbitrary Java File constructors/writes are unsupported")
    for operation in ("call", "call_instance"):
        add("org.telegram.messenger.LocaleController", ["getString", "getLocaleStringIso639"], operation, "private func callLocale(")
    add("org.telegram.messenger.LocaleController", ["getInstance"], "call", 'if request.member == "getInstance"')
    add("org.telegram.messenger.browser.Browser", ["openUrl", "openURL"], "call", 'case "org.telegram.messenger.browser.Browser"', "one URL or context+URL; http(s)/tg/mailto/tel; intents permission")
    account_match = re.search(r"accountClassNames[^=]*=\s*\[([^]]+)\]", clean)
    for cls in re.findall(r'"([\w.]+)"', account_match.group(1) if account_match else ""):
        add(cls, ["getInstance"], "call", "Self.accountClassNames.contains(request.fqcn)", "one active account index, not arbitrary getInstance for any Java class")
        add(cls, ["getCurrentAccount"], "call_instance", 'request.member == "getCurrentAccount"')
        add(cls, ["currentAccount"], "get_instance", 'request.member == "currentAccount"')
    add("org.telegram.messenger.UserConfig", ["selectedAccount"], "get", 'case ("org.telegram.messenger.UserConfig", "selectedAccount")')
    add("org.telegram.messenger.UserConfig", ["getClientUserId", "isClientActivated"], "call_instance", 'request.member == "getClientUserId"')
    add("org.telegram.messenger.AccountInstance", ["getUserConfig", "getMessagesController", "getSendMessagesHelper"], "call_instance", 'let classes = ["getUserConfig"')
    add("org.telegram.messenger.SendMessagesHelper", ["sendMessage"], "call_instance", 'record.fqcn == "org.telegram.messenger.SendMessagesHelper"', "only (peerId, plainText); Android SendMessageParams/TLRPC/media overloads unsupported")
    return {"file": path.relative_to(project).as_posix(), "sha256": sha,
            "members": sorted(members, key=lambda r: (r["fqcn"], r["member"], r["operation"])),
            "unknown_member": "JavaMemberError", "construct": "unsupported", "set": "unsupported", "set_instance": "unsupported",
            "extension_provider": "requires separately reviewed provider/SDK fragment; builtin dispatch table alone does not prove extension support",
            "verification": "static source review, not a bridge invocation"}


def _adapter_bindings(project):
    """Find explicit SDK monkey-patch boundaries without importing the adapter."""
    bindings, source_files = {}, {}
    root = project / "python/exteraless_runtime"
    for path in sorted(root.glob("*.py")):
        text, sha, size = _read(path)
        file = path.relative_to(project).as_posix()
        source_files[file] = {"sha256": sha, "bytes": size}
        tree = ast.parse(text, filename=file)
        aliases = {}
        for node in ast.walk(tree):
            if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.Call):
                continue
            call = node.value
            if isinstance(call.func, ast.Attribute) and call.func.attr == "import_module" and call.args and isinstance(call.args[0], ast.Constant):
                for target in node.targets:
                    if isinstance(target, ast.Name) and isinstance(call.args[0].value, str):
                        aliases[target.id] = call.args[0].value
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if not isinstance(target, ast.Attribute):
                        continue
                    parts = ast.unparse(target).split(".")
                    if parts[0] in aliases:
                        name = ".".join([aliases[parts[0]], *parts[1:]])
                        unsupported = isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Name) and node.value.func.id == "unsupported"
                        bindings[name] = {"file": file, "line": node.lineno,
                                          "status": "unsupported" if unsupported else "adapter-defined-unverified"}
            elif isinstance(node, ast.For) and isinstance(node.target, ast.Name):
                try:
                    names = ast.literal_eval(node.iter)
                except (ValueError, SyntaxError):
                    continue
                if not isinstance(names, (list, tuple)) or not all(isinstance(n, str) for n in names):
                    continue
                for child in ast.walk(node):
                    if not isinstance(child, ast.Call) or not isinstance(child.func, ast.Name) or child.func.id != "setattr" or len(child.args) != 3:
                        continue
                    if not isinstance(child.args[1], ast.Name) or child.args[1].id != node.target.id:
                        continue
                    parts = ast.unparse(child.args[0]).split(".")
                    if parts[0] not in aliases:
                        continue
                    value = child.args[2]
                    unsupported = isinstance(value, ast.Call) and isinstance(value.func, ast.Name) and value.func.id == "unsupported"
                    for name in names:
                        symbol = ".".join([aliases[parts[0]], *parts[1:], name])
                        bindings[symbol] = {"file": file, "line": child.lineno,
                                            "status": "unsupported" if unsupported else "adapter-defined-unverified"}
    return bindings, source_files


def _sdk_relation(module, name, entry, bindings):
    full = module + "." + name
    if full in bindings:
        return {"status": bindings[full]["status"], "adapter": bindings[full]}
    if module in {"hook_utils", "elyx_runtime.archive", "elyx_runtime.loader", "dev_server"}:
        return {"status": "unsupported", "reason": "JVM/DEX/Xposed/archive/development surface is outside the native iOS source-plugin contract"}
    if module in {"ui.alert", "ui.bulletin"}:
        return {"status": "unsupported", "reason": "Android widget constructors are not implemented by builtin BridgeServices; native UI adapter evidence required"}
    if module == "client_utils":
        leaf = name.split(".")[-1]
        getters = {"get_account_instance": "getInstance", "get_user_config": "getUserConfig",
                   "get_messages_controller": "getMessagesController", "get_send_messages_helper": "getSendMessagesHelper"}
        if leaf in getters:
            return {"status": "supported-subset", "native_member": "org.telegram.messenger.AccountInstance#" + getters[leaf],
                    "reason": "active account handle only; the returned controller does not imply all Android methods exist"}
        if leaf.startswith(("send_", "edit_message", "get_")) and leaf not in {"get_hook_account", "get_selected_account"}:
            return {"status": "unsupported", "reason": "Android controller/TLRPC/SendMessageParams path is absent from builtin bridge; Runtime.sendMessage alone does not adapt this SDK helper"}
    if module == "android_utils" and name == "run_on_ui_thread":
        return {"status": "supported-subset", "native_member": "org.telegram.messenger.AndroidUtilities#runOnUIThread",
                "reason": "callback runs on owning interpreter worker; no Python execution on UIKit main thread"}
    if module == "ui.settings":
        return {"status": "source-only", "reason": "SDK row/schema declaration; custom Android views are not implied by descriptor serialization"}
    if entry.get("native_class_references"):
        return {"status": "needs-review", "reason": "literal native references require exact member/operation/arity audit; importability is not support"}
    return {"status": "source-only", "reason": "Python declaration/export present; not evidence of native or device behavior"}


def build_sdk_inventory(android_root=None, project_root=None):
    root, project = Path(android_root or corpus.REPO), Path(project_root or corpus.PROJECT_ROOT)
    sdk_root, android_python = project / "python/sdk", root / "TMessagesProj/src/main/python"
    bindings, adapter_files = _adapter_bindings(project)
    paths = sorted(p for p in sdk_root.rglob("*.py") if "__pycache__" not in p.parts) if sdk_root.is_dir() else []
    modules, symbols = {}, []
    for path in paths:
        rel = path.relative_to(sdk_root)
        module = ".".join(rel.with_suffix("").parts)
        module = module.removesuffix(".__init__")
        if module == "__init__":
            continue
        surface, sha, size = _python_surface(path)
        android_path = android_python / rel
        original, original_sha, original_size = _python_surface(android_path) if android_path.is_file() else ({}, None, 0)
        modules[module] = {"file": path.relative_to(project).as_posix(), "sha256": sha, "bytes": size,
                           "android_file": "python/" + rel.as_posix() if android_path.is_file() else None,
                           "android_sha256": original_sha, "android_bytes": original_size,
                           "same_source": sha == original_sha, "public_symbols": len(surface),
                           "missing_android_symbols": sorted(original.keys() - surface.keys()),
                           "added_symbols": sorted(surface.keys() - original.keys())}
        for name, entry in sorted(surface.items()):
            symbols.append({"id": f"sdk.{module}.{name}", "module": module, **entry,
                            "android_line": original.get(name, {}).get("line"),
                            "native_relation": _sdk_relation(module, name, entry, bindings),
                            "implementation": _pending()})
    if len(symbols) > MAX_RECORDS:
        raise ValueError("SDK symbol bound exceeded")
    gradle = root / "TMessagesProj/build.gradle"
    direct = []
    gradle_sha, android_python_version = None, None
    if gradle.is_file():
        text, gradle_sha, _ = _read(gradle)
        clean, code = mask_source(text), mask_source(text, strings=True)
        version = re.search(r"\bpython\s*\{\s*version\s*['\"]([^'\"]+)['\"]", clean)
        if version:
            android_python_version = version.group(1)
        for match in re.finditer(r"\bpip\s*\{", code):
            end = _close(code, match.end() - 1)
            for install in re.finditer(r"\binstall\s*(?:\(\s*)?['\"]([^'\"]+)['\"]", clean[match.end():end]):
                direct.append({"requirement": install.group(1), "line": text.count("\n", 0, match.end() + install.start()) + 1})
    lock_path = project / "python/runtime/dependency-lock.json"
    lock = _load_json(lock_path) or {}
    normalize = lambda name: re.sub(r"[-_.]+", "-", name).lower()
    packages = {normalize(p["name"]): {k: p[k] for k in ("name", "version", "sha256", "import_roots", "requires_python", "requires_dist",
                                                     "artifact_kind", "projection", "implementation", "ios_constraints") if k in p}
                for p in lock.get("packages", [])}
    for dependency in direct:
        name = normalize(re.split(r"[<>=!~\[; ]", dependency["requirement"])[0])
        dependency["ios"] = "provided-pure-python" if name in packages else "not-provided"
        dependency["provided_version"] = packages.get(name, {}).get("version")
        if packages.get(name, {}).get("projection"):
            dependency["ios"] = "provided-python-projection"
            dependency["projection"] = packages[name]["projection"]
        if packages.get(name, {}).get("ios_constraints"):
            dependency["ios_constraints"] = packages[name]["ios_constraints"]
        if name in {"lxml", "pillow", "debugpy"}:
            dependency["constraint"] = "native/platform package requires an iOS packaging/runtime decision; a universal Python bundle is not a substitute"
    return {"schema_version": SCHEMA_VERSION, "generator": "tools.compat.feature_inventory",
            "method": "AST-only; Python SDK/vendor/plugin code is never imported or executed",
            "modules": modules, "symbols": symbols, "adapter_source_files": adapter_files,
            "strict_bridge": _bridge_surface(project),
            "dependencies": {"android_file": "TMessagesProj/build.gradle", "android_sha256": gradle_sha,
                             "android_python_version": android_python_version, "ios_python_version": lock.get("python"),
                             "android_direct": direct, "android_direct_count": len(direct),
                             "ios_lock": "python/runtime/dependency-lock.json", "ios_lock_sha256": _sha(lock_path.read_bytes()) if lock_path.is_file() else None,
                             "ios_provided": list(packages.values()), "ios_provided_count": len(packages),
                             "provision_evidence": "declarative build lock; does not establish importability in the current IPA or complete package behavior",
                             "runtime_install": "unsupported; provided dependency metadata is not device execution evidence"},
            "platform_exclusions": [{"surface": "Java/DEX plugins", "constraint": "No JVM/DEX runtime on iOS; original plan explicitly excludes this plugin format", "source": "docs/PLAN.md#L60"},
                                    {"surface": "Xposed JVM method replacement", "constraint": "Native extension points are separate bounded APIs; do not mark arbitrary Xposed methods implemented", "source": "docs/PLAN.md#L61"}],
            "totals": {"modules": len(modules), "public_symbols": len(symbols),
                       "native_relation": dict(sorted(Counter(s["native_relation"]["status"] for s in symbols).items()))}}


def _android_link(reference, label=None):
    return f"[{label or Path(reference['file']).name + ':' + str(reference['line'])}](../../third_party/exteraless-android/TMessagesProj/src/main/{reference['file']}#L{reference['line']})"


def render_index(payload, sdk):
    totals = payload["totals"]
    lines = ["# Client and SDK parity inventory", "",
             "Generated by `python -m tools.compat.feature_inventory`. [Schema and merge contract](schema.md).",
             "[Client JSON](client-features.json) · [SDK/API JSON](sdk-surface.json) · [Source audit notes](android-audit.md)", "",
             "**Source inventory, not runtime completion.** Published source claims, actual key aliases and",
             "scoped dispositions are distinct from verified behavior. [Wave-2 data join](wave-2-reconciliation.md).", "",
             f"- Declared settings/state: **{totals['declared_settings_and_state']}** ({totals['settings']} settings, {totals['setting_templates']} parameterized setting templates, {totals['state']} state records).",
             f"- Android behavior categories: `{json.dumps(totals['android_behavior'], sort_keys=True)}`.",
             f"- app/exteraless modules: **{totals['modules']}**, merging both source roots and both extensions.",
             f"- Named UI row/action/control definition sites: **{totals['ui_definition_sites']}** (not additional features).",
             f"- ExteraConfig API members: **{totals['compatibility_api_members']}**, counted separately from features.",
             f"- Verified client entries with supplied evidence: **{totals['verified_features']}**.",
             f"- Full Java/Kotlin snapshot digest: `{payload['android_source']['java_kotlin_sha256']}`.",
             "- Upstream commit: unknown (vendored plain-source snapshot; exact evidence file hashes are in JSON).", "",
             "## Configs", "", "| Config | Source | Settings/state | Public scalar getters | Role |", "|---|---|---:|---:|---|"]
    for cls, data in sorted(payload["configs"].items()):
        lines.append(f"| {cls} | `{data['file']}` | {data['count']} | {data['scalar_getter_methods']} | {data['role']} |")
    shim_counts = Counter(r["behavior"] for r in payload["compatibility_apis"])
    lines += ["", f"ExteraConfig API split: `{json.dumps(dict(shim_counts), sort_keys=True)}`.",
              "Its mapped getters point to setting IDs; compatibility storage does not add Android effects.", "",
              "## Modules", "", "Every module retains its complete bounded source-file list and a digest in client JSON.", "",
              "Public method bodies are indexed by source file, name, line, return type and arity;",
              "interface-only signatures and constructors are not counted as method bodies.", "",
              "| Module | Java | Kotlin | Method bodies | KiB | Wave | Implementation |", "|---|---:|---:|---:|---:|---|---|"]
    for module, data in sorted(payload["modules"].items()):
        lines.append(f"| {module} | {data['languages'].get('java', 0)} | {data['languages'].get('kt', 0)} | {data['api_count']} | {data['kb']} | {data['wave']} | {data['implementation']['status']} |")
    lines += ["", "## Native target candidates", "", "References below locate the native subsystem for implementation/review.",
              "They are not evidence of a registered setting, a live key read, or equivalent behavior.", "",
              "| Target | Native source | Anchor |", "|---|---|---|"]
    for name, target in sorted(payload["native_targets"].items()):
        url = "../../" + target["file"].replace(" ", "%20") + (f"#L{target['line']}" if target["line"] else "")
        lines.append(f"| {name} | [{Path(target['file']).name}:{target['line']}]({url}) | `{target['symbol']}` |")
    if payload["setting_key_collisions"]:
        lines += ["", "### Shared receipt keys / aliases", "", "Different Original IDs stay distinct; consult each source disposition before treating a shared key as equivalent.", ""]
        for key, ids in sorted(payload["setting_key_collisions"].items()):
            lines.append(f"- `{key}`: {', '.join('`' + i + '`' for i in ids)}")
    lines += ["", "## Settings and state", "", "Original IDs remain stable. Keys are taken from the authoritative published receipts; — means no Core key claimed.",
              "The effect link is one bounded Android consumer, not a runtime test. All retained UI definitions",
              "and consumers, types, defaults, aliases and file hashes are in client JSON."]
    for group in sorted({f["group"] for f in payload["features"]}):
        lines += ["", "### " + group, "", "| Original ID → receipt key | Type / declared default | Android definition | Android effect / classification | Native source / candidate | Source status |", "|---|---|---|---|---|---|"]
        for feature in payload["features"]:
            if feature["group"] != group:
                continue
            android, ios = feature["android"], feature["ios"]
            default = android["default"]
            value = json.dumps(default.get("value"), ensure_ascii=False) if default["kind"] == "literal" else default.get("expression", "redacted")
            value = value.replace("|", "\\|").replace("\n", " ")[:70]
            effects = android["references"].get("effect", [])
            effect = _android_link(effects[0]) if effects else android["behavior"]
            native = ", ".join(ios["candidate_targets"])
            refs = [r for r in ios.get("implementation_callsites", []) if isinstance(r, dict) and r.get("path")]
            if refs:
                ref = next((r for r in refs if r.get("line")), refs[0])
                suffix = f"#L{ref['line']}" if ref.get("line") else ""
                native = f"[{Path(ref['path']).name}:{ref.get('line') or 'file'}](../../{ref['path'].replace(' ', '%20')}{suffix})"
            lines.append(f"| `{feature['id']}` → `{ios.get('setting_key') or '—'}` | {android['type']} / `{value}` | {_android_link(android)} | {effect} | {native} | {feature['implementation']['status']} |")
    deps = sdk["dependencies"]
    lines += ["", "## SDK and dependency boundary", "",
              f"AST surface: **{sdk['totals']['modules']} modules**, **{sdk['totals']['public_symbols']} public declarations/exports**.",
              "These include data types, reexports and helpers; declaration presence is not native support.",
              "`sdk-surface.json` maps every entry to an explicit adapter/native relation and lists the strict",
              "builtin bridge operations separately. All implementation statuses still require evidence.", "",
              f"Android Gradle has **{deps['android_direct_count']} direct pip requirements**; the iOS lock has **{deps['ios_provided_count']} provided packages**.",
              "These sets are different. Transitive packages in the iOS bundle are not extra Android direct requirements.", "",
              "| Android requirement | iOS provided version | Relation |", "|---|---|---|"]
    for dependency in deps["android_direct"]:
        lines.append(f"| {dependency['requirement']} | {dependency['provided_version'] or '—'} | {dependency['ios']} |")
    lines += ["", "Java/DEX plugin loading is excluded by the original plan. JVM/Xposed method replacement has no",
              "blanket iOS equivalent; bounded native extension points are separate capabilities.",
              "Exact adapter claims and unreconciled symbols are separated in the SDK JSON; generic helpers",
              "do not prove all 925 behaviors. A manifest entry, Python import or native source file cannot prove device parity.", "",
              "## Platform constraints", ""]
    lines.extend(f"- **{name}**: {description}" for name, description in sorted(CONSTRAINTS.items()))
    lines += ["", "## Verification and remaining review", "",
              "Run `python -m pytest tools/compat/tests/test_feature_inventory_*.py` (or list the files explicitly on Windows).",
              "For a materialized cohort run `python -m tools.compat.feature_inventory --check-data`.",
              "A live SDK manifest is not required to remain frozen while its owner regenerates it.",
              "The lexical scanner cannot prove reflection reachability or local-variable dataflow. Review",
              "`ui-only`, `storage-or-migration`, `unresolved`, proposed-key collisions and conditional defaults.",
              "Independent implementer fragments preserve verified statuses on regeneration; see [schema.md](schema.md).", ""]
    individual = sdk.get("individual_source_reconciliation")
    if individual:
        counts = individual["counts"]
        lines[8:8] = [
            f"**Individual source routes:** {counts['sdk_symbols']} SDK symbols and {counts['module_maps']} module maps / {counts['module_members']} original member identities.",
            "[Exact individual join](individual-source-join.json) · [Captured-input audit](individual-source-input-audit.json) · [Previous fac6 cohort](cohorts/9bfce05f.json).",
            "Source dispositions retain partial/unsupported operations and active findings; route completeness grants no native/visual verification.", ""]
    current = payload.get("current_source_reconciliation")
    if current:
        lines[8:8] = [f"**Current review overlay:** {current['counts']['source_closed_scopes']} review-scoped source closures; "
                      f"{current['counts']['execution_blockers']} separate execution blockers; no verification promotions.",
                      "[Effective source/evidence layer](current-source-reconciliation.md) · [Overlay handoff](current-source-overlay-handoff.md).", ""]
    return "\n".join(lines)


def render_reconciliation(client, sdk, report):
    if report.get("individual_source_reconciliation"):
        return render_individual_reconciliation(client, sdk, report)
    counts = report["counts"]
    lines = ["# Wave 2 — final DATA join", "",
             f"**{counts['features']}/567 Original IDs имеют source receipt; receipt gaps: {counts['missing_feature_receipts']}. Verified/ported promotions: 0.**", "",
             "[Точная карта](wave-2-reconciliation.json) · [Основной inventory](client-features.json) · [SDK925](sdk-surface.json)", "",
             "567 features, 30 modules, 925 SDK symbols, 308 Config overloads, 20 Pill settings и 15 отдельных Pill types сохранены.",
             "`implemented` — claim автора о source, не native/runtime/visual pass. Старые 56 gaps теперь представлены все.", "",
             "## Snapshot", "",
             f"- HEAD при join: `{report.get('head_at_join', 'unrecorded')}`; исходный request pin — `{report['component_evidence']['head_at_request']}`.",
             "- Последний сообщённый полный Linux green: **43708260304 / 7d04a35a — 545 Core, 169 Host, 30 Hooks**.",
             "- CI для 6f718b11 pending/unread; новый native build/frames не получены. Fingerprints не являются compiled-status.",
             f"- SDK Config: **{json.dumps(counts['api_author_statuses'], sort_keys=True)}**; SHA-256 `{report['sources']['sdk-config']['sha256']}`.",
             "- Это именно опубликованный snapshot. Его original-inventory/source pins сохранены; после обновления входного inventory SDK owner может выпустить следующий receipt.", "",
             "## Выбранные source claims", "", "| Owner | IDs | Author statuses |", "|---|---:|---|"]
    for owner in sorted({r["source_claim"]["owner"] for r in client["features"]}):
        rows = [r for r in client["features"] if r["source_claim"]["owner"] == owner]
        states = dict(sorted(Counter(r["implementation"]["status"] for r in rows).items()))
        lines.append(f"| {owner} | {len(rows)} | `{json.dumps(states)}` |")
    lines += ["", "Owner precedence сохранён: Feed; Player 33 Appearance fields + player/nowplaying; Pills; Dialogs; Appearance predictiveBack; Tools crash/favorites.",
              "`nagram.showTextTranslate` — один Original ID: **Chat primary / chats.showTextTranslate**, AI secondary evidence сохранён.",
              "Actual policy reader, отсутствие отдельной AI definition и обе Root/Share migrations найдены по символам и закреплены свежими hashes/lines.",
              "Пять `defaultDeleteMenu*` теперь имеют actual Android derived-reader/effect chain и Chat moderation consumers; старое «нет consumer» снято.", "",
              "## Конкретные незакрытые ограничения", ""]
    for fid in ("nagram.performanceClass", "etgbackup.ChatSwipeAction", "neko.tabletMode", "neko.typeface", "appearance.monetStyle"):
        row = next(r for r in client["features"] if r["id"] == fid)
        lines.append(f"- **`{fid}`** ({row['implementation']['status']}): {row['ios'].get('adaptation')}")
    lines += ["", "Applied shared source receipts (Root/TLN04/05/CA04/AP/Tools modes/IDS Avatar/AF History) приведены с точными report anchors в JSON.",
              "Их более поздний статус приоритетнее старых ‘unapplied’ заметок внутри receipts; независимые findings этим join не закрываются.", "",
              "### Dispositions", ""]
    for category in ("unused-storage", "migrated-alias", "android-specific", "server-or-device-prerequisite"):
        ids = [r["id"] for r in client["features"] if r["source_disposition"]["classification"] == category]
        lines.append(f"- **{category}**: " + ", ".join(f"`{fid}`" for fid in ids) + ".")
    lines += ["", "Каждый disposition сохраняет конкретные original-source и owner reasons. ‘Android-specific’ относится только к названному механизму, не ко всей portable feature family.",
              "Pills11: старый type receipt ещё пишет pending forwarding; более поздний coordinator report сообщает Rust/passive RTT applied. MtProtoKit retained RTT и physical measurements отдельно не подтверждены.", "",
              "## Modules", "",
              "Шесть прежних rollup gaps сведены в **partial**, с actual feature/domain contributions. Число файлов/ключей не создаёт module pass."]
    for module, needs in report["module_authorship_needs"].items():
        lines.append(f"- `{module}` — coordinator authorship needed: " + " ".join(needs))
    lines += ["", "`module.backup` сохраняет Tools primary плюс Retention/Cloud contributions. Все indexed Android public methods остаются в inventory; их полное покрытие не выведено из feature-count.", "",
              "## SDK308 и SDK925", "",
              "Точные blocked overloads выбранного SDK snapshot:"]
    for row in client["compatibility_apis"]:
        if row["implementation"]["status"] == "blocked":
            lines.append(f"- `{row['id']}` — {row['ios']['adaptation'].get('note', '')}")
    lines += ["", "Все unsupported IDs/reasons и остальные 308 записей сохранены в JSON. Отдельно каждый из 925 SDK IDs имеет exact source relation или явно unreconciled status.",
              "Behavioral compatibility всех 925 неизвестна; class metadata, settings registration и generic helpers не повышают их до implemented/ported.", "",
              "## Review layers", "", "| Report | Published state | Open / follow-up IDs |", "|---|---|---|"]
    for layer in report["review_layers"]:
        lines.append(f"| [{Path(layer['path']).name}](../../{layer['path']}) | {layer['state']} | {', '.join(layer.get('open_ids', [])) or 'See scoped source closure in report'} |")
    lines += ["", "HNS-F/PFR/CMC/FU/SDK и остальные открытые хвосты сохраняются. Existing independent source closures импортированы только в review layer; никаких новых закрытий от агрегатора.", "",
              "## Source anchors / data checks", "",
              "Опубликованные строки сохранены как `reported_line`. Новые `line`/`matches` получены по exact anchors, symbols или явно помеченным field-token candidates; для неопределённых ссылок остаётся file-only pin.",
              "Неоднозначные ссылки не выбираются по близости к старому номеру. Declaration/token counts — не доказательство functional effect.",
              "`data_checks` подтверждает exact ID partitions, первичных владельцев и zero verification promotion. Проверка не исполняет SDK/plugins, не обращается к CI/network.", ""]
    if report.get("post_join_receipt_drift"):
        lines += ["**После выбранного snapshot изменились receipts:** " + ", ".join(report["post_join_receipt_drift"]) + ". Новый hash не подставлен в прежние claims; следующий cohort требует нового data join.", ""]
    return "\n".join(lines)


def render_individual_reconciliation(client, sdk, report):
    joined = report["individual_source_reconciliation"]
    counts = joined["counts"]
    context = joined.get("context", {})
    current = report.get("current_source_reconciliation")
    apis = Counter(row["implementation"]["status"] for row in client["compatibility_apis"])
    lines = ["# Individual source-route reconciliation", "",
             f"**{counts['sdk_symbols']}/{len(sdk['symbols'])} SDK symbols; {counts['module_maps']} module maps; {counts['module_members']} exact Original member identities. Verification promotions: 0.**", "",
             "[Individual JSON](individual-source-join.json) · [Client inventory](client-features.json) · [SDK925](sdk-surface.json)",
             "[Captured-source audit](individual-source-input-audit.json) · [fac6 history at 9bfce05f](cohorts/9bfce05f.json) · [Handoff](../wave-2/individual-source-join.md)", "",
             f"The retained feature cohort has {len(client['features'])} IDs, {len(client['modules'])} modules, {len(client['compatibility_apis'])} Config overloads and {len(client.get('pill_types', []))} separate Pill types.",
             f"Config remains {apis['implemented']} implemented / {apis['blocked']} blocked / {apis['unsupported']} unsupported. Original SDK signatures and module method indexes are unchanged.", "",
             "## Captured author maps", "",
             "| Owner | Records | Raw map SHA-256 | Captured pin fields | Dispositions |", "|---|---:|---|---:|---|"]
    for manifest in joined["manifests"]:
        lines.append(f"| [{manifest['owner']}](../../{manifest['path']}) | {manifest['records']} | `{manifest['sha256']}` | {manifest['source_pin_field_count']} | `{json.dumps(manifest['dispositions'], sort_keys=True)}` |")
    lines += ["", "Every SDK row carries its exact ordered route, contract, limitations and evidence in `individual_source.reported`.",
              "`native_relation.status=source-route-<disposition>` is source attribution, never a ported/native test result.",
              "Module `individual_source.reported` retains all structured members, Settings actions/flows and Plugins provider/lifecycle routes; module implementation statuses stay partial.",
              "The old three missing authorship maps are supplied. Their partial/unsupported operations remain visible; a missing provider never becomes implemented.", "",
              "## Mixed source boundaries", "",
              "Raw map hashes and each author's source boundary/pins are retained verbatim. Shared paths may have different hashes in different captured maps.",
              "Route lines remain captured lines; current source changes are listed separately in the input audit. Matching a later Git blob does not make it tested.",
              "General supplies a d7d499f7 boundary without an author pin table. Its raw map is pinned; separately derived Git pins are labelled in the audit.", "",
              "## Captured author findings (historical)" if current else "## Findings retained for follow-up", "",
              "| Receipt owner | Finding | Reported state |", "|---|---|---|"]
    for finding in joined["findings"]:
        value = finding["reported"]
        lines.append(f"| {finding['receipt']['owner']} | `{value.get('id', 'unnamed')}` | {value.get('status', 'source finding; no closure supplied by join')} |")
    lines += [""]
    if current:
        lines += ["The raw author states above remain immutable. The effective later closures are keyed by origin report and finding/scope ID.", "",
                  render_current_source_overlay(current, embedded=True)]
    else:
        lines.extend("- " + item for item in context.get("assigned_followups", []))
    lines += ["",
              "A new production edit or remediation report is not automatically a closure overlay. This data join creates no new behavior finding or review verdict.", "",
              "## Execution evidence boundary", ""]
    for evidence in context.get("execution_evidence", []):
        lines.append(f"- **{evidence['label']} {evidence['run_id']} / {evidence['commit']}**: {evidence['status']}. {evidence['scope']} [{Path(evidence['report']).name}](../../{evidence['report']}).")
    if context.get("latest_ipa") and not current:
        ipa = context["latest_ipa"]
        lines.append(f"- Full IPA **{ipa['run_id']} / {ipa['commit']}**: {ipa['status_at_handoff']}; not queried or promoted to success by this join.")
    if context.get("native_ui_plan") and not current:
        lines.append("- " + context["native_ui_plan"])
    lines += ["",
              "## Integrity", "",
              "The optional explicit `individual_manifests` policy is consumed by ordinary generation and by `--individual-only --docs-only`.",
              "Exact IDs, original signatures, typed module identities, raw owner hashes and false promotion flags are checked before writing. `--check-data` validates the materialized layer without reading moving production sources.",
              "The handoff records executed integrity tests and the scoped SDK manifest check; source-only checks cannot establish runtime/provider/visual parity.", ""]
    return "\n".join(lines)


def _json_text(value):
    return json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def _source_scope_key(value):
    if not isinstance(value, dict):
        raise ValueError("source overlay scope identity must be an object")
    path = individual_routes._path(value.get("origin_report"))
    identity = value.get("id")
    individual_routes._text(identity, "finding/scope identity")
    return path, identity


def _source_overlay_targets(client, sdk, groups):
    """Resolve only explicit stable IDs; a module-scope link is not a member pass."""
    if not isinstance(groups, dict) or len(groups) > 128:
        raise ValueError("invalid/bounded source overlay target groups")
    features = {row["id"] for row in client.get("features", [])}
    symbols = {row["id"] for row in sdk.get("symbols", [])}
    modules = {row["id"]: row for row in client.get("modules", {}).values()}
    members = {name: {individual_routes.member_key(row) for row in module.get("public_method_bodies", [])}
               for name, module in modules.items()}
    result = {}
    for name, targets in groups.items():
        individual_routes._text(name, "target group")
        resolved, seen = [], set()
        for target in individual_routes._list(targets, "overlay targets", 4096, nonempty=True):
            individual_routes._flags(target)
            kind, identity = target.get("kind"), target.get("id")
            if kind == "feature":
                valid = identity in features
            elif kind == "sdk-symbol":
                valid = identity in symbols
            elif kind == "module-scope":
                valid = identity in modules
            elif kind == "module-member":
                valid = identity in members.get(target.get("module_id"), set())
            else:
                valid = False
            if not valid:
                raise ValueError(f"unknown source overlay target: {target}")
            key = (kind, target.get("module_id"), identity)
            if key in seen:
                raise ValueError(f"duplicate source overlay target in {name}: {identity}")
            seen.add(key)
            resolved.append(deepcopy(target))
        result[name] = resolved
    return result


def _source_report_snapshot_path(pin, required=False):
    """Content-addressed raw report text; only old inputs may depend on Git."""
    if not isinstance(pin, dict):
        raise ValueError("source overlay document pin must be an object")
    sha = individual_routes._sha(pin.get("sha256"))
    if type(pin.get("bytes")) is not int or not 0 <= pin["bytes"] <= individual_routes.MAX_BYTES:
        raise ValueError("overlay document requires a bounded captured byte count")
    if type(required) is not bool:
        raise ValueError("require_report_snapshots must be a Boolean")
    if "snapshot_path" not in pin:
        if required:
            raise ValueError("hermetic source overlay requires every report snapshot")
        return None
    path = individual_routes._path(pin["snapshot_path"])
    if path != f"docs/parity/source-report-snapshots/{sha}.md":
        raise ValueError("report snapshot path must select its exact captured SHA-256 filename")
    return path


def compile_current_source_overlay(client, sdk, document):
    """Pure effective source states; captured claims and implementation stay intact."""
    if not isinstance(document, dict) or type(document.get("schema_version")) is not int or document["schema_version"] != 1:
        raise ValueError("unknown current source overlay schema")
    individual_routes._flags(document)
    if any(key in document for key in ("features", "symbols", "modules", "compatibility_apis", "implementation", "native_relation")):
        raise ValueError("source overlay cannot override inventory/implementation fields")
    groups = _source_overlay_targets(client, sdk, document.get("target_groups"))
    documents = document.get("documents", {})
    if not isinstance(documents, dict) or not documents or len(documents) > 96:
        raise ValueError("invalid/bounded source overlay document pins")
    for path, pin in documents.items():
        individual_routes._path(path)
        _source_report_snapshot_path(pin, document.get("require_report_snapshots", False))
    pins = document.get("source_pins", {})
    if not isinstance(pins, dict) or len(pins) > 256:
        raise ValueError("invalid/bounded implementation snapshot pins")
    for path, pin in pins.items():
        individual_routes._path(path)
        individual_routes._sha(pin.get("sha256"))
        if not re.fullmatch(r"[0-9a-f]{40}", pin.get("git_revision", "")):
            raise ValueError("implementation pin must keep its immutable Git revision")
    origins = {}
    for origin in individual_routes._list(document.get("origins"), "origin scopes", 256, nonempty=True):
        individual_routes._flags(origin)
        key = _source_scope_key(origin)
        if key in origins:
            raise ValueError(f"duplicate source overlay origin identity: {key}")
        if key[0] not in documents or origin.get("identity_kind") not in {"finding", "named-route", "named-scope"}:
            raise ValueError("source overlay origin lacks a pinned report/kind")
        individual_routes._text(origin.get("anchor"), "origin report anchor")
        if origin["id"] not in origin["anchor"]:
            raise ValueError("origin anchor must name its exact finding/scope identity")
        names = individual_routes._list(origin.get("target_groups"), "scope target groups", 32, nonempty=True)
        if len(names) != len(set(names)) or not set(names) <= groups.keys():
            raise ValueError("unknown/duplicate scope target group")
        origins[key] = origin
    closures = {}
    for closure in individual_routes._list(document.get("closures"), "source closures", 256, nonempty=True):
        individual_routes._flags(closure)
        key = _source_scope_key(closure)
        if key not in origins or key in closures:
            raise ValueError(f"unknown/duplicate source closure identity: {key}")
        if closure.get("source_state") not in {"source-closed", "source-partial", "source-open"}:
            raise ValueError("source closure state cannot be a runtime/verification promotion")
        individual_routes._text(closure.get("scope"), "review-scoped closure boundary")
        individual_routes._list(closure.get("limitations"), "closure limitations", 32, nonempty=True)
        for citation in individual_routes._list(closure.get("reviews"), "independent review citations", 16, nonempty=True):
            if citation.get("path") not in documents:
                raise ValueError("source closure review has no pinned document")
            individual_routes._text(citation.get("anchor"), "review verdict anchor")
        for path in closure.get("source_paths", []):
            if path not in pins:
                raise ValueError("source closure fix path has no captured Git pin")
        closures[key] = closure
    if closures.keys() != origins.keys():
        raise ValueError("current source overlay origin/closure partition incomplete")
    visiting, done = set(), set()
    def visit(key):
        if key in visiting:
            raise ValueError("cyclic source closure prerequisite")
        if key in done:
            return
        visiting.add(key)
        dependencies = [_source_scope_key(value) for value in closures[key].get("requires", [])]
        if len(dependencies) > 32 or len(dependencies) != len(set(dependencies)):
            raise ValueError("duplicate/bounded source closure prerequisites")
        for dependency in dependencies:
            if dependency not in closures:
                raise ValueError("unknown source closure prerequisite")
            visit(dependency)
            if closures[key]["source_state"] == "source-closed" and closures[dependency]["source_state"] != "source-closed":
                raise ValueError("aggregate source closure still has an open prerequisite")
        visiting.remove(key)
        done.add(key)
    for key in closures:
        visit(key)
    # Every formerly assigned captured finding and named reset route must remain
    # accounted for. A separate owner-reported source-fixed item is not promoted.
    captured = client.get("individual_source_reconciliation", {}).get("findings", [])
    assigned = {(row["receipt"]["path"], row["reported"]["id"]) for row in captured
                if row["reported"].get("status") != "source-fixed"}
    for module in client.get("modules", {}).values():
        source = module.get("individual_source", {})
        assigned.update((source["receipt"]["path"], value) for value in source.get("reported", {}).get("remaining_portable_routes", []))
    if not assigned <= origins.keys():
        raise ValueError("current source overlay dropped a captured assigned finding/route")
    effective = []
    for key, closure in closures.items():
        origin = origins[key]
        targets = []
        for name in origin["target_groups"]:
            for target in groups[name]:
                if target not in targets:
                    targets.append(deepcopy(target))
        effective.append({**deepcopy(closure), "identity_kind": origin["identity_kind"],
                          "origin_anchor": origin["anchor"], "origin_sha256": documents[key[0]]["sha256"],
                          "targets": targets, "verified": False, "ported": False,
                          "native_execution_claimed": False, "resolved_by_data_join": False})
    for collection in ("execution_evidence", "execution_blockers", "execution_history"):
        seen = set()
        for item in individual_routes._list(document.get(collection, []), collection, 64):
            individual_routes._text(item.get("id"), collection + " identity")
            if item["id"] in seen:
                raise ValueError("duplicate execution evidence/blocker identity")
            seen.add(item["id"])
            individual_routes._text(item.get("scope"), "execution evidence boundary")
            if item.get("report"):
                if item["report"] not in documents:
                    raise ValueError("execution evidence lacks its pinned report")
                individual_routes._text(item.get("anchor"), "execution report anchor")
            elif item.get("source") != "coordinator-handoff":
                raise ValueError("execution observation needs a report or explicit coordinator attribution")
    for delta in document.get("later_evidence_source_deltas", []):
        if delta.get("report") not in documents or delta.get("changes_original_route_assignments") is not False:
            raise ValueError("later execution source delta must keep original source groups")
        for path, pin in delta.get("source_pins", {}).items():
            individual_routes._path(path)
            individual_routes._sha(pin.get("sha256"))
            if not re.fullmatch(r"[0-9a-f]{40}", pin.get("git_revision", "")):
                raise ValueError("execution delta needs its own immutable Git source pin")
    closed = [row for row in effective if row["source_state"] == "source-closed"]
    return {"effective_scopes": effective,
            "counts": {"registered_scopes": len(origins), "source_closed_scopes": len(closed),
                       "remaining_source_scopes": len(effective) - len(closed),
                       "identity_kinds": dict(sorted(Counter(row["identity_kind"] for row in effective).items())),
                       "captured_assigned_scopes": len(assigned),
                       "captured_assigned_source_closed": sum((row["origin_report"], row["id"]) in assigned for row in closed),
                       "report_documents": len(documents), "implementation_source_pins": len(pins),
                       "execution_blockers": len(document.get("execution_blockers", [])), "verification_promotions": 0}}


def load_current_source_overlay(project, policy):
    descriptor = policy.get("current_source_overlay")
    if descriptor is None:
        return None
    project = Path(project).resolve()
    path = individual_routes._path(descriptor.get("path"))
    file = project / path
    if not file.is_file() or not file.resolve().is_relative_to(project) or file.stat().st_size > 4 * 1024 * 1024:
        raise ValueError("current source overlay missing/outside project/over byte bound")
    raw = file.read_bytes()
    if len(raw) > 4 * 1024 * 1024:
        raise ValueError("current source overlay exceeds byte bound")
    sha = _sha(raw)
    if sha != individual_routes._sha(descriptor.get("sha256")):
        raise ValueError("current source overlay revision differs from explicit policy")
    document = json.loads(raw.decode("utf-8"), object_pairs_hook=individual_routes._json_object)
    if raw != _json_text(document).encode("utf-8"):
        raise ValueError("owned source overlay input must use canonical inventory JSON serialization")
    if not isinstance(document.get("documents"), dict) or len(document["documents"]) > 96:
        raise ValueError("invalid/bounded source overlay document pins")
    texts = {}
    for report, pin in document.get("documents", {}).items():
        individual_routes._path(report)
        snapshot = _source_report_snapshot_path(pin, document.get("require_report_snapshots", False))
        if snapshot is not None:
            snapshot_file = project / snapshot
            if (not snapshot_file.resolve().is_relative_to(project) or not snapshot_file.is_file()
                    or snapshot_file.stat().st_size > individual_routes.MAX_BYTES):
                raise ValueError(f"captured report snapshot missing/outside project/over byte bound: {snapshot}")
            # Prefer and validate the archive even if the live report still matches.
            # A broken shipped archive must not be hidden by local files or Git.
            with snapshot_file.open("rb") as source:
                data = source.read(pin["bytes"] + 1)
        else:
            # Backward compatibility only: inputs without archived reports are
            # explicitly non-hermetic and may need locally available Git history.
            report_file = project / report
            data = report_file.read_bytes() if report_file.is_file() and report_file.resolve().is_relative_to(project) and report_file.stat().st_size <= individual_routes.MAX_BYTES else None
            if data is None or _sha(data) != pin["sha256"]:
                revision = pin.get("git_revision", "")
                if not re.fullmatch(r"[0-9a-f]{40}", revision):
                    raise ValueError(f"legacy non-hermetic captured review bytes unavailable: {report}")
                import subprocess
                data = subprocess.check_output(["git", "show", revision + ":" + report], cwd=project, timeout=10)
        if len(data) > individual_routes.MAX_BYTES or len(data) != pin["bytes"] or _sha(data) != pin["sha256"]:
            raise ValueError(f"captured source-review pin mismatch: {report}")
        texts[report] = data.decode("utf-8").splitlines()
    citations = [{"path": row["origin_report"], "anchor": row["anchor"]} for row in document.get("origins", [])]
    citations += [ref for row in document.get("closures", []) for ref in row.get("reviews", [])]
    citations += [{"path": item["report"], "anchor": item["anchor"]} for name in ("execution_evidence", "execution_blockers", "execution_history")
                  for item in document.get(name, []) if item.get("report")]
    anchors = []
    for citation in citations:
        lines = texts.get(citation["path"], [])
        matches = [(index, line) for index, line in enumerate(lines, 1) if citation["anchor"] in line]
        if len(matches) != 1:
            raise ValueError(f"source overlay report anchor missing/ambiguous: {citation}")
        index, line = matches[0]
        anchor = {"path": citation["path"], "sha256": document["documents"][citation["path"]]["sha256"],
                  "anchor": citation["anchor"], "line": index, "text": line}
        if anchor not in anchors:
            anchors.append(anchor)
    return {"input_receipt": {"path": path, "sha256": sha, "bytes": len(raw)},
            "input": document, "report_anchors": anchors,
            "report_anchors_fingerprint": individual_routes.fingerprint(anchors)}


def apply_current_source_overlay(client, sdk, loaded):
    result, surface = deepcopy(client), deepcopy(sdk)
    compiled = compile_current_source_overlay(result, surface, loaded["input"])
    summary = {"schema_version": 1, "kind": "current-review-scoped-source-overlay", **deepcopy(loaded), **compiled}
    records = {("feature", row["id"]): row for row in result.get("features", [])}
    records.update({("sdk-symbol", row["id"]): row for row in surface.get("symbols", [])})
    records.update({("module-scope", row["id"]): row for row in result.get("modules", {}).values()})
    for row in records.values():
        row.pop("current_source_evidence", None)
    for scope in compiled["effective_scopes"]:
        for target in scope["targets"]:
            kind = target["kind"]
            record = records[("module-scope", target["module_id"])] if kind == "module-member" else records[(kind, target["id"])]
            link = {"origin_report": scope["origin_report"], "id": scope["id"], "source_state": scope["source_state"],
                    "target": deepcopy(target), "overlay_sha256": loaded["input_receipt"]["sha256"],
                    "scope": scope["scope"], "verified": False, "ported": False}
            record.setdefault("current_source_evidence", []).append(link)
    result["current_source_reconciliation"] = deepcopy(summary)
    surface["current_source_reconciliation"] = deepcopy(summary)
    return result, surface, summary


def validate_current_source_overlay(client, sdk, report=None):
    summary = client.get("current_source_reconciliation")
    if not summary and not sdk.get("current_source_reconciliation"):
        return {}
    if summary != sdk.get("current_source_reconciliation") or report is not None and summary != report.get("current_source_reconciliation"):
        raise ValueError("current source overlay cohorts differ between reports")
    document = summary["input"]
    # The input is stored using canonical generator JSON, so its raw policy pin is
    # also independently recoverable without reading any moving report/source file.
    if _sha(_json_text(document).encode("utf-8")) != summary["input_receipt"]["sha256"]:
        raise ValueError("materialized source overlay input changed")
    if individual_routes.fingerprint(summary["report_anchors"]) != summary["report_anchors_fingerprint"]:
        raise ValueError("captured source overlay report anchors changed")
    expected_client, expected_sdk, expected = apply_current_source_overlay(client, sdk, {
        key: summary[key] for key in ("input_receipt", "input", "report_anchors", "report_anchors_fingerprint")})
    if expected != summary:
        raise ValueError("materialized effective source closure partition changed")
    for original, rebuilt, sections in ((client, expected_client, ("features", "modules")), (sdk, expected_sdk, ("symbols",))):
        for section in sections:
            left, right = original.get(section, []), rebuilt.get(section, [])
            pairs = zip(left.values(), right.values()) if isinstance(left, dict) else zip(left, right)
            if any(a.get("current_source_evidence") != b.get("current_source_evidence") for a, b in pairs):
                raise ValueError("materialized source overlay target links changed")
    return {"current_source_closed_scopes": summary["counts"]["source_closed_scopes"],
            "current_source_remaining_scopes": summary["counts"]["remaining_source_scopes"],
            "current_execution_blockers": summary["counts"]["execution_blockers"]}


def render_current_source_overlay(summary, embedded=False):
    document, counts = summary["input"], summary["counts"]
    lines = ["## Effective source closures" if embedded else "# Current source remediation / evidence overlay", "",
             f"**{counts['source_closed_scopes']} source-closed scopes; {counts['remaining_source_scopes']} registered source scopes remain open. "
             f"Execution blockers: {counts['execution_blockers']}. Verified/ported promotions: 0.**", "",
             f"Source snapshot: `{document['source_revision']}`. [Machine projection](current-source-reconciliation.json) · "
             "[Explicit input](current-source-followups.json) · [Handoff](current-source-overlay-handoff.md).", "",
             "Old raw maps, reported open fields, signatures, dispositions and their source pins remain unchanged. "
             "A source-closed counterexample does not implement every remaining partial/unsupported contract.", "",
             "| Origin / exact identity | Effective source state | Independent closure evidence |", "|---|---|---|"]
    for row in summary["effective_scopes"]:
        reviews = ", ".join(f"[{Path(ref['path']).name}](../../{ref['path']})" for ref in row["reviews"])
        lines.append(f"| [{Path(row['origin_report']).name}](../../{row['origin_report']}) · `{row['id']}` | {row['source_state']} | {reviews} |")
    lines += ["", "Scope bounds, dependency chains, exact inventory targets and frozen fix-file pins are in the JSON. "
              "IDs such as R1, S1 and NFD-01 are local to their origin report, never global aliases.", "",
              "### Available execution evidence", ""]
    for evidence in document.get("execution_evidence", []):
        link = f" [{Path(evidence['report']).name}](../../{evidence['report']})" if evidence.get("report") else " (coordinator handoff)"
        lines.append(f"- **{evidence['id']} — {evidence['status']}**: {evidence['scope']}{link}")
    if document.get("execution_history"):
        lines += ["", "### Earlier execution blockers (historical)", ""]
        lines.extend(f"- **{item['id']} / {item.get('run_id', 'no run')} — {item['status']}**: {item['scope']}"
                     for item in document["execution_history"])
    lines += ["", "### Current execution blockers / pending acceptance", ""]
    for blocker in document.get("execution_blockers", []):
        lines.append(f"- **{blocker['id']} — {blocker['status']}**: {blocker['scope']}")
    lines.extend("- " + value for value in document.get("pending_acceptance", []))
    lines += ["", "Historical failures and later isolated passes retain their exact scopes. They neither reopen independent source closures nor complete the full five-child/UIKit gates. "
              "No native scene frames were observed by this join.", ""]
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--android-root", type=Path, default=Path(corpus.REPO))
    parser.add_argument("--project-root", type=Path, default=Path(corpus.PROJECT_ROOT))
    parser.add_argument("--out", type=Path, default=Path(OUT_DIR))
    parser.add_argument("--docs", type=Path, default=Path(corpus.PROJECT_ROOT) / "docs/parity")
    parser.add_argument("--parity", type=Path, action="append", default=[], help="independent verified-parity JSON; repeatable")
    parser.add_argument("--check", action="store_true", help="compare generated reports without writing")
    parser.add_argument("--source-join", type=Path, help="data-only owner/format policy for published wave-2 receipts")
    parser.add_argument("--replay-source-join", action="store_true", help="reuse retained source claims/hashes instead of rereading live owner receipts")
    parser.add_argument("--receipts", type=Path, help="published receipt directory (default docs/wave-2)")
    parser.add_argument("--docs-only", action="store_true", help="write only docs/parity, without build/compat outputs")
    parser.add_argument("--check-data", action="store_true", help="validate materialized ID/status partitions only; no source/SDK regeneration")
    parser.add_argument("--individual-policy", type=Path, help="optional explicit individual_manifests policy (default: project docs/parity/join-policy.json)")
    parser.add_argument("--individual-only", action="store_true", help="join individual source maps to materialized inventories without rescanning source")
    args = parser.parse_args(argv)
    if args.check_data:
        policy = _load_json(args.docs / "join-policy.json")
        report = _load_json(args.docs / "wave-2-reconciliation.json")
        checked = validate_source_join(_load_json(args.docs / "client-features.json"), _load_json(args.docs / "sdk-surface.json"), report, policy)
        print(json.dumps(checked, sort_keys=True))
        return 0
    if args.individual_only and (args.source_join or args.parity):
        parser.error("--individual-only uses the materialized feature cohort; do not combine with feature receipt regeneration")
    individual_policy_path = args.individual_policy or args.source_join or args.project_root / "docs/parity/join-policy.json"
    individual_policy = _load_json(individual_policy_path) or {}
    individual_manifests = individual_routes.load_manifests(args.project_root, individual_policy)
    current_overlay = load_current_source_overlay(args.project_root, individual_policy)
    if args.individual_only and not individual_manifests:
        parser.error("--individual-only requires an explicit nonempty individual_manifests policy")
    documents, sources = {}, {}
    if args.source_join:
        policy = _load_json(args.source_join)
        if args.replay_source_join:
            frozen = _load_json(args.docs / "wave-2-reconciliation.json")
            documents = replay_source_documents(_load_json(args.docs / "client-features.json"), frozen)
            sources = frozen["sources"]
        paths = [] if args.replay_source_join else sorted((args.receipts or args.project_root / "docs/wave-2").glob("*-parity.json"))
        for path in paths:
            raw = path.read_bytes()
            if len(raw) > 32 * 1024 * 1024:
                parser.error("source receipt exceeds 32 MiB")
            owner = path.stem.removesuffix("-parity")
            document = json.loads(raw)
            documents[owner] = document
            sources[owner] = {"path": path.resolve().relative_to(args.project_root.resolve()).as_posix(), "sha256": _sha(raw),
                              "metadata": {k: v for k, v in document.items() if k not in {"features", "modules", "compatibility_apis", "settings", "pills"}}}
    fragments = [_load_json(p) for p in args.parity]
    if any(f is None for f in fragments):
        parser.error("parity fragment not found")
    client_path, sdk_path = args.docs / "client-features.json", args.docs / "sdk-surface.json"
    previous = [_load_json(args.out / "features.json") or {}, _load_json(client_path) or {}]
    client_fragments = [{k: v for k, v in f.items() if k != "symbols"} for f in fragments]
    if args.individual_only:
        payload, sdk = _load_json(client_path), _load_json(sdk_path)
        if payload is None or sdk is None:
            parser.error("materialized client and SDK inventories are required")
    else:
        payload = merge_parity(build_client_inventory(args.android_root, args.project_root), previous, client_fragments)
        sdk = merge_parity(build_sdk_inventory(args.android_root, args.project_root), _load_json(sdk_path),
                           [{"symbols": f["symbols"]} for f in fragments if "symbols" in f])
    reconciliation = None
    if args.source_join:
        old_client, old_sdk = _load_json(client_path), _load_json(sdk_path)
        for section, old, new in (("features", old_client, payload), ("compatibility_apis", old_client, payload), ("symbols", old_sdk, sdk)):
            if old and {r["id"] for r in old[section]} != {r["id"] for r in new[section]}:
                parser.error(f"original {section} ID set drift; explicit reconciliation required")
        payload, sdk, reconciliation = materialize_source_join(payload, sdk, documents, sources, policy, args.project_root,
                                                              _load_json(args.docs / "wave-2-reconciliation.json"))
        # Local git metadata only; no remote/CI command is involved.
        import subprocess
        reconciliation["head_at_join"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=args.project_root, text=True).strip()
        reconciliation["input_inventory_sha256"] = _sha(client_path.read_bytes())
        reconciliation["input_sdk_surface_sha256"] = _sha(sdk_path.read_bytes())
        reconciliation["policy_sha256"] = _sha(args.source_join.read_bytes())
        reconciliation["receipt_read_mode"] = "replayed retained normalized source claims; original read-time hashes retained" if args.replay_source_join else "published files read once and hash-pinned"
    individual = None
    if individual_manifests:
        payload, sdk, individual = individual_routes.join(payload, sdk, individual_manifests, individual_policy.get("individual_context"))
        reconciliation = individual_routes.reconcile(reconciliation or _load_json(args.docs / "wave-2-reconciliation.json"), payload, sdk, individual)
    current = None
    if current_overlay:
        payload, sdk, current = apply_current_source_overlay(payload, sdk, current_overlay)
        reconciliation = reconciliation or _load_json(args.docs / "wave-2-reconciliation.json") or {}
        reconciliation["current_source_reconciliation"] = deepcopy(current)
        if individual is not None:
            individual["current_source_overlay"] = {"report": "docs/parity/current-source-reconciliation.json",
                                                     "input_receipt": deepcopy(current["input_receipt"]),
                                                     "counts": deepcopy(current["counts"])}
            payload["individual_source_reconciliation"] = deepcopy(individual)
            sdk["individual_source_reconciliation"] = deepcopy(individual)
            reconciliation["individual_source_reconciliation"] = deepcopy(individual)
    if reconciliation and reconciliation.get("original_id_sets"):
        reconciliation["data_checks"] = validate_source_join(payload, sdk, reconciliation, individual_policy)
    outputs = {client_path: _json_text(payload), sdk_path: _json_text(sdk),
               args.docs / "index.md": render_index(payload, sdk)}
    if individual is not None:
        outputs[args.docs / "individual-source-join.json"] = _json_text(individual)
    if current is not None:
        outputs[args.docs / "current-source-reconciliation.json"] = _json_text(current)
        outputs[args.docs / "current-source-reconciliation.md"] = render_current_source_overlay(current)
    if not args.docs_only:
        outputs.update({args.out / "features.json": _json_text(payload), args.out / "features-report.md": render_index(payload, sdk)})
    if reconciliation is not None:
        outputs.update({args.docs / "wave-2-reconciliation.json": _json_text(reconciliation),
                        args.docs / "wave-2-reconciliation.md": render_reconciliation(payload, sdk, reconciliation)})
    stale = []
    for path, content in outputs.items():
        if args.check:
            if not path.is_file() or path.read_text(encoding="utf-8") != content:
                stale.append(str(path))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8", newline="\n")
    if stale:
        print("Stale inventory: " + ", ".join(stale))
        return 1
    print(f"settings/state: {len(payload['features'])}; modules: {len(payload['modules'])}; "
          f"shim API members (not features): {len(payload['compatibility_apis'])}; SDK symbols: {len(sdk['symbols'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
