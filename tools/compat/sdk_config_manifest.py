"""Build the SDK-only Config mirror/receipt from pinned source, without executing it.

The parity scanner and its inventories are read-only inputs. Only reviewed native
definition forms are recognized; a proposed inventory key is never a registration.
"""

import argparse
import ast
from collections import Counter
import difflib
import hashlib
from itertools import islice
import json
from pathlib import Path
import re
import sys

from . import feature_inventory as inventory


ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / "third_party/exteraless-android/TMessagesProj/src/main"
CORE = ROOT / "swift/ExteralessCore/Sources/ExteralessCore"
OUTPUT = ROOT / "python/exteraless_runtime/_config_manifest.py"
RECEIPT = ROOT / "docs/wave-2/sdk-config-parity.json"
INVENTORY_PATH = "docs/parity/client-features.json"
CLIENT_ROOT = "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift"
CONFIGS = ("AppearanceConfig", "ChatsConfig", "GeneralConfig", "OpenExteraConfig", "UtilsConfig",
           "IconPacksConfig", "PillStackConfig", "NekoConfig", "NaConfig")
ENUMS = ("AvatarCornerType", "DividerStyle", "GlassOutlineStyle", "CameraType", "VideoMessagesCamera",
         "TranslationFormality", "TabIconsMode", "IconPackType", "ProxyDisableCondition")
HELPERS = {
    "AppearanceFeatures.swift": {}, "AppearanceAdditionalFeatures.swift": {},
    "CoreAppearanceFontFamilyPolicy.swift": {}, "AppearanceLayoutModePolicy.swift": {},
    "CoreAppearanceMonetPolicy.swift": {},
    "ToolsFeatures.swift": {}, "ToolsNativeModePolicy.swift": {}, "FeedFeatures.swift": {},
    "ToolsPerformancePolicy.swift": {},
    "ChatFeatures.swift": {"toggle": ("chats.", "bool")},
    "StickerFeatures.swift": {"toggle": ("chats.", "bool")},
    "PlayerFeatures.swift": {"toggle": ("appearance.", "bool"), "choice": ("appearance.", "int"), "range": ("appearance.", "int")},
    "PrivacyFeatures.swift": {"flag": ("privacy.", "bool")},
    "PrivacyExtrasFeatures.swift": {"flag": ("privacy.", "bool"), "collection": ("privacy.", "json")},
    "AIFeatures.swift": {"boolean": ("ai.", "bool"), "string": ("ai.", "text")},
    "AINativePolicyVisibility.swift": {},
    "CorePillFeatures.swift": {"field": ("chats.", None)},
    "CoreDialogFeatures.swift": {"toggle": ("", "bool"), "page": ("chats.", "int")},
    "IdentityFeatures.swift": {"flag": ("identity.", "bool")},
    "RetentionFeatures.swift": {"flag": ("privacy.", "bool"), "mode": ("privacy.", "int")},
    "ExteraConfigCompatibility.swift": {"boolean": ("compat.exteraconfig.", "bool"), "enumeration": ("compat.exteraconfig.", "int")},
}
KINDS = {"bool": "bool", "integer": "int", "number": "float", "string": "text",
         "null": "nullable", "array": "json", "object": "json"}
SECRET = re.compile(r"api.?key|token|password|secret|private.?key|provider\w*key|llm(?:system|user)prompt", re.I)
MANAGER_FIELDS = {"PluginsDevMode": "developerMode", "PluginsSafeMode": "safeMode", "PluginsCompactView": "compactView",
                  "PinnedPlugins": "pinned", "PluginsEngine": "engineEnabled"}
NATIVE_REGISTRATIONS = {
    "CoreAppearanceFontFamilyPolicy.swift": ("swift/ExteralessCore/Sources/ExteralessCore/AppearanceFeatures.swift",
        ("CoreAppearanceFontFamilyPolicy.definitions",)),
    "AppearanceAdditionalFeatures.swift": ("swift/ExteralessCore/Sources/ExteralessCore/AppearanceFeatures.swift",
        ("AppearanceAdditionalFeatures.definitions", "AppearanceAdditionalFeatures.settingsSectionDefinitions")),
    "AppearanceLayoutModePolicy.swift": ("swift/ExteralessCore/Sources/ExteralessCore/AppearanceFeatures.swift",
        ("AppearanceLayoutModePolicy.definitions",)),
    "CoreAppearanceMonetPolicy.swift": ("swift/ExteralessCore/Sources/ExteralessCore/AppearanceFeatures.swift",
        ("AppearanceMonetPolicy.definitions",)),
    "ToolsNativeModePolicy.swift": ("swift/ExteralessCore/Sources/ExteralessCore/ToolsFeatures.swift",
        ("ToolsNativeModePolicy.videoBitrateDefinition", "ToolsNativeModePolicy.voiceEnhancementDefinition",
         "ToolsNativeModePolicy.groupAudioBitrateDefinition", "ToolsNativeModePolicy.rpcErrorsDefinition")),
    "AINativePolicyVisibility.swift": ("telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIIntegration.swift",
        ("settings.store.register(AINativeVisibilityPolicy.definitions)",)),
}
REGISTERED_MEMBERS = {
    "CoreAppearanceFontFamilyPolicy.swift": ("definitions",),
    "AppearanceAdditionalFeatures.swift": ("definitions", "settingsSectionDefinitions"),
    "AppearanceLayoutModePolicy.swift": ("definitions",),
    "CoreAppearanceMonetPolicy.swift": ("definition",),
    "ToolsNativeModePolicy.swift": ("videoBitrateDefinition", "voiceEnhancementDefinition", "groupAudioBitrateDefinition", "rpcErrorsDefinition"),
    "ToolsPerformancePolicy.swift": ("definition",),
    "AINativePolicyVisibility.swift": ("definitions",),
}
MIGRATION_ONLY = {
    "nagram.disableCrashlyticsCollection": "migration-only flag: legacy true disables crashReports and clears itself; false does not enable collection. Use GeneralConfig.crashReports for the live native control",
    "neko.enhancedFileLoader": "migration-only flag: legacy true upgrades only a missing/zero downloadSpeedBoost; false is not a downgrade. Use GeneralConfig.downloadSpeedBoost for the live native control",
}
# Reviewed source Bool -> native Front(0)/Rear(1) projection. Ask(2) cannot be
# represented by the old Bool / two-case ExteraConfig enum and fails by name.
VALUE_CODECS = {"neko.rearVideoMessages": ("tools.videoMessageCameraFacing", "int", "front_rear_bool")}
COMPUTED = {
    "getAvatarSquareness": ("squareness", ["appearance.avatarCorners"]),
    "getPillRadius": ("pill_radius", ["appearance.avatarCorners"]),
    "getOnlineDotInnerRadius": ("dot_inner", ["appearance.avatarCorners"]),
    "getOnlineDotOuterRadius": ("dot_outer", ["appearance.avatarCorners"]),
    "getOnlineDotOffset": ("dot_offset", ["appearance.avatarCorners"]),
    "getSectionRadiusDp": ("section_radius", ["appearance.sectionRadius"]),
    "getSectionsSeparatedHeaders": ("separate_headers", ["appearance.dividerStyle", "appearance.separateHeaders"]),
    "setSectionsSeparatedHeaders": ("set_separate_headers", ["appearance.dividerStyle", "appearance.separateHeaders"]),
    "getCurrentLangName": ("language_name", ["nagram.preferredTranslateTargetLang"]),
    "getDoubleTapSeekDurationMillis": ("seek_duration", ["chats.doubleTapSeekDuration"]),
    "isProxyDisabledOn": ("proxy_condition", ["openextera.proxyDisableConditions"]),
    "setProxyDisabledOn": ("set_proxy_condition", ["openextera.proxyDisableConditions"]),
}
INVENTORY_API_FIELDS = ("id", "symbol", "file", "line", "type", "arity", "parameter_types", "behavior")
DIAGNOSTIC_LIMIT = 6_000


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path, pins):
    if path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError(f"SDK Config input exceeds bound: {path}")
    raw = path.read_bytes()
    pins[path.relative_to(ROOT).as_posix()] = hashlib.sha256(raw).hexdigest()
    return raw.decode("utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")


def inventory_contract(source):
    """Only original Config inputs, not the aggregate inventory's derived claims.

    The Compat workflow regenerates client-features.json before pytest. Its
    native-target/UI/module/parity metadata is not consumed by this generator.
    Canonicalize the consumed contract instead of pinning that mutable envelope.
    Actual Java/Kotlin/Swift sources and domain receipts retain raw-byte pins.
    """
    configs = {name: {"file": source["configs"][name]["file"]} for name in (*CONFIGS, "ExteraConfig")}
    files = {row["file"]: {"sha256": source["source_files"][row["file"]]["sha256"]} for row in configs.values()}
    feature_ids = [row["id"] for row in source["features"]]
    apis = [{key: row[key] for key in INVENTORY_API_FIELDS} for row in source["compatibility_apis"]]
    if len(feature_ids) != len(set(feature_ids)) or len(apis) != len({row["id"] for row in apis}):
        raise ValueError("duplicate original IDs in Config inventory contract")
    return {"version": 1, "schema_version": source["schema_version"], "configs": configs,
            "source_files": files, "feature_ids": sorted(feature_ids),
            "compatibility_apis": sorted(apis, key=lambda row: (row["file"], row["line"], row["id"]))}


def inventory_pin(contract):
    canonical = json.dumps(contract, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n"
    return {"path": INVENTORY_PATH, "hash_mode": "sdk-config-input-v1",
            "contract_sha256": hashlib.sha256(canonical.encode("utf-8")).hexdigest()}


def selected_declarations(text, members):
    """Keep only the named, referenced static initializers, preserving line offsets.

    An extra array in the same source file is not a registered setting group.
    This intentionally supports the reviewed array/constructor/closure forms,
    rather than treating arbitrary Swift declarations as a registry.
    """
    code = inventory.mask_source(text, strings=True, nested_comments=True)
    output = ["\n" if char == "\n" else " " for char in text]
    for member in members:
        matches = list(re.finditer(r"\bstatic\s+let\s+" + re.escape(member) + r"\b[^=\n]*=\s*", code))
        if len(matches) != 1: raise ValueError("missing/ambiguous registered declaration: " + member)
        match = matches[0]
        end = match.end()
        while end < len(code):
            char = code[end]
            if char in "([{": end = inventory._close(code, end) + 1
            elif char == "\n" and not code[end + 1:].lstrip().startswith("+"): break
            elif char in ";}": break
            else: end += 1
        output[match.start():end] = text[match.start():end]
    return "".join(output)


def root_registration(pins):
    text = inventory.mask_source(read(ROOT / CLIENT_ROOT, pins), nested_comments=True)
    code = inventory.mask_source(text, strings=True, nested_comments=True)
    matches = list(re.finditer(r"static\s+var\s+definitions\s*:\s*\[ClientSettingDefinition\]\s*\{", code))
    if len(matches) != 1 or "ClientSettings.shared.register(Self.definitions)" not in text:
        raise ValueError("review changed ClientSettings root registration")
    start = matches[0].end() - 1
    body = text[start:inventory._close(code, start) + 1]
    groups = sorted(set(re.findall(r"\b\w+\.(?:definitions|galleryDefinitions)\b", body)))
    for required in ("AppearanceFeatures.definitions", "ToolsFeatures.definitions", "ExteraConfigCompatibility.definitions"):
        if required not in groups: raise ValueError("missing actual root registration: " + required)
    return {"path": CLIENT_ROOT, "line": text.count("\n", 0, start) + 1, "groups": groups}


def native_definitions(pins):
    registered_root = root_registration(pins)
    definitions = {}
    def add(key, kind, secret, path, text, position, symbols=()):
        if not kind or "\\(" in key:
            return
        record = {"key": key, "type": kind, "secret": secret,
                  "path": path.relative_to(ROOT).as_posix(), "line": text.count("\n", 0, position) + 1,
                  "symbols": sorted(set(symbols))}
        if key in definitions and definitions[key]["type"] != kind:
            raise ValueError(f"conflicting native Config definition: {key}")
        definitions[key] = record

    for filename, helpers in HELPERS.items():
        path = CORE / filename
        text = inventory.mask_source(read(path, pins), nested_comments=True)
        if filename == "IdentityFeatures.swift":
            # Account-local editor definitions are explicitly not ClientSettings registrations.
            text = text.split("public static let accountDefinitions", 1)[0]
        constants = dict(re.findall(r'public static let (\w+)\s*=\s*"([^"\\]+)"', text)) if filename in (
            "AINativePolicyVisibility.swift", "ToolsPerformancePolicy.swift", "CoreAppearanceMonetPolicy.swift") else {}
        registration = []
        if filename in ("ToolsPerformancePolicy.swift", "CoreAppearanceMonetPolicy.swift"):
            policy = "ToolsPerformancePolicy" if filename == "ToolsPerformancePolicy.swift" else "AppearanceMonetPolicy"
            group = selected_declarations(text, ("definitions",))
            if not re.fullmatch(r"static\s+let\s+definitions\s*(?::\s*\[ClientSettingDefinition\])?\s*=\s*\[\s*definition\s*\]", group.strip()):
                raise ValueError("review changed " + policy + ".definitions membership")
            registration.append({"kind": "source", "path": path.relative_to(ROOT).as_posix(),
                "line": text.count("\n", 0, text.index("static let definitions")) + 1,
                "note": policy + ".definitions contains definition"})
        if filename == "ToolsPerformancePolicy.swift":
            reference = "ToolsPerformancePolicy.definitions"
            if reference not in registered_root["groups"]:
                raise ValueError("native definition is no longer registered: " + reference)
            registration.append({"kind": "source", "path": CLIENT_ROOT,
                "line": registered_root["line"], "note": reference})
        elif filename in NATIVE_REGISTRATIONS:
            owner_path, references = NATIVE_REGISTRATIONS[filename]
            owner = inventory.mask_source(read(ROOT / owner_path, pins), nested_comments=True)
            if filename != "AINativePolicyVisibility.swift": owner = selected_declarations(owner, ("definitions",))
            for reference in references:
                if reference not in owner: raise ValueError("native definition is no longer registered: " + reference)
                registration.append({"kind": "source", "path": owner_path,
                    "line": owner.count("\n", 0, owner.index(reference)) + 1, "note": reference})
        if filename in REGISTERED_MEMBERS: text = selected_declarations(text, REGISTERED_MEMBERS[filename])
        code = inventory.mask_source(text, strings=True, nested_comments=True)
        for match in re.finditer(r'(?:ClientSettingDefinition|\.init)\s*\(\s*key:\s*(?:"([^"\\]+)"|(\w+))(?=\s*,)', text):
            opening = text.index("(", match.start())
            end = inventory._close(code, opening)
            body = text[opening:end]
            kind = re.search(r"defaultValue:\s*\.(\w+)", body)
            symbols = re.findall(r'"((?:[A-Z]\w*Config)\.[A-Za-z_]\w*)"', body)
            key = match[1] or constants.get(match[2])
            if key:
                add(key, KINDS.get(kind[1]) if kind else None, bool(re.search(r"isSecret:\s*true", body)), path, text, match.start(), symbols)
                if registration and key in definitions: definitions[key]["registration"] = registration
        for helper, (prefix, kind) in helpers.items():
            for match in re.finditer(r'\b' + helper + r'\s*\(\s*"([\w.]+)"', text):
                opening = text.index("(", match.start())
                args, end = inventory._arguments(text, code, opening)
                body, field = text[opening:end], match[1]
                actual = kind
                if actual is None:
                    value_type = re.search(r"^\.(\w+)\(", args[2])
                    actual = KINDS.get(value_type[1]) if value_type else None
                symbols = re.findall(r'"((?:[A-Z]\w*Config)\.[A-Za-z_]\w*)"', body)
                if filename == "PlayerFeatures.swift": symbols.append("AppearanceConfig." + field)
                if filename == "CorePillFeatures.swift": symbols.append("PillStackConfig." + field)
                actual_prefix = prefix
                if filename == "RetentionFeatures.swift":
                    override = re.search(r'prefix:\s*"(\w+)"', body)
                    if override: actual_prefix = override[1] + "."
                    symbols.append("NaConfig." + field)
                elif helper == "flag" and filename in ("PrivacyFeatures.swift", "PrivacyExtrasFeatures.swift"):
                    owner = re.search(r'owner:\s*"(\w+)"', body)
                    symbols.append((owner[1] if owner else "NekoConfig" if filename == "PrivacyFeatures.swift" else "NaConfig") + "." + field)
                add(actual_prefix + field, actual, bool(re.search(r"secret:\s*true", body)), path, text, match.start(), symbols)

    # These two source-declared maps expand into typed definitions at registration.
    path = CORE / "ChatFeatures.swift"
    text = read(path, pins)
    marker = '["doubleTapAction", "doubleTapActionOut"].map'
    if marker not in text: raise ValueError("review changed native double-tap definition map")
    for field in ("doubleTapAction", "doubleTapActionOut"):
        add("chats." + field, "int", False, path, text, text.index(marker), ["NaConfig." + field])
    if "ChatFormattingPolicy.actions.map" not in text: raise ValueError("native formatting definitions are no longer registered")
    policy = CORE / "ChatPolicy.swift"
    text = read(policy, pins)
    for match in re.finditer(r'Action\(id: "\w+", settingField: "(\w+)"', text):
        add("chats." + match[1], "bool", False, policy, text, match.start(), ["NaConfig." + match[1]])
    registration = read(CORE / "ChatFeatures.swift", pins)
    if "ChatMenuPolicy.preferences.map" not in registration: raise ValueError("native menu preferences are not registered")
    policy = CORE / "ChatMenuPolicy.swift"
    text = inventory.mask_source(read(policy, pins), nested_comments=True)
    code = inventory.mask_source(text, strings=True, nested_comments=True)
    for match in re.finditer(r'\.init\(\s*"(\w+)"', text):
        opening = text.index("(", match.start())
        _, end = inventory._arguments(text, code, opening)
        body = text[opening:end]
        owner = re.search(r'source:\s*"(\w+)"', body)
        add("chats." + match[1], "bool", False, policy, text, match.start(), [(owner[1] if owner else "NaConfig") + "." + match[1]])
    return definitions


def source_reference(expression, symbols):
    expression = expression.replace(".INSTANCE.", ".")
    match = re.fullmatch(r"(\w+)\.(\w+)(\(\))?", expression)
    if not match: return None
    owner, field = match[1], match[2]
    if match[3] and field.startswith("get"):
        field = field[3:4].lower() + field[4:]
    return symbols.get(owner + "." + field)


def compatibility_defaults(pins):
    text = inventory.mask_source(read(CORE / "ExteraConfigCompatibility.swift", pins), nested_comments=True)
    code = inventory.mask_source(text, strings=True, nested_comments=True)
    defaults, enums = {}, {}
    for match in re.finditer(r'boolean\("(\w+)",\s*(true|false)\)', text):
        defaults[match[1]] = match[2] == "true"
    for match in re.finditer(r'enumeration\("(\w+)",\s*(\d+),\s*\[([^]]+)\]\)', text):
        defaults[match[1]] = int(match[2])
        enums[match[1]] = re.findall(r'"(\w+)"', match[3])
    for match in re.finditer(r'ClientSettingDefinition\(key:\s*"compat\.exteraconfig\.(\w+)"', text):
        end = inventory._close(code, text.index("(", match.start()))
        value = re.search(r'defaultValue:\s*\.(?:integer|string)\(("(?:\\.|[^"\\])*"|-?\d+)\)', text[match.start():end])
        if not value: raise ValueError("review nonliteral native compatibility default")
        known, default = inventory._literal(value[1], {})
        if not known: raise ValueError("unknown native compatibility default")
        defaults[match[1]] = default
    if len(defaults) != 22: raise ValueError("native compatibility defaults must contain exactly 22 closed fields")
    return defaults, enums


def api_route(api, body, symbols, compatibility):
    name, params = api["symbol"].split(".")[-1], api["parameter_types"]
    result = {"id": api["id"], "name": name, "parameters": params, "result": api["type"], "targets": [], "route": "unavailable"}
    if api["behavior"] == "compat-storage":
        field_name = name[3:4].lower() + name[4:]
        binding = compatibility[field_name]
        result.update(route="write" if params else "read", targets=[binding["identity"]], transform="identity")
        if binding.get("enum"):
            result.update(transform="enum", enum=binding["enum"], fallback=binding["fallback"])
        return result
    if name == "canUseYandexMaps":
        result.update(route="read", targets=[compatibility["useYandexMaps"]["identity"]], transform="identity")
        return result
    if name == "setForceSnow":
        result["targets"] = ["neko.actionBarDecoration", "nagram.chatDecoration"]
        result["route"] = "force_snow"
        return result
    if name == "pluginsSafeMode":
        result.update(route="manager_get", field="safeMode")
        return result
    manager = MANAGER_FIELDS.get(name[3:]) if name.startswith(("get", "set")) else None
    if manager:
        result.update(route="manager_set" if params else "manager_get", field=manager)
        return result
    if name in ("getPluginsDisableArtOpts", "setPluginsDisableArtOpts"):
        result.update(reason="Android ART Profile Saver compatibilityMode is explicitly absent; native PluginConfigBridgeExtension returns a named unsupported error", disposition="unsupported")
        return result
    if name == "getAvatarCorners" and params:
        result.update(route="avatar_radius", targets=["appearance.avatarCorners", "appearance.singleCornerRadius"])
        return result
    if name in COMPUTED:
        result["route"], result["targets"] = COMPUTED[name]
        return result
    if name in ("getCenterTitle", "setCenterTitle"):
        result.update(route="write" if params else "read", targets=["nagram.centerActionBarTitle"], transform="identity")
        return result
    if name in ("inAppVibration", "forceSnow"):
        result.update(route="read", targets=["neko.disableVibration" if name == "inAppVibration" else "neko.actionBarDecoration"],
                      transform="not" if name == "inAppVibration" else "equals_one")
        return result
    receiver = r"(\w+(?:\.INSTANCE)?\.(?:\w+\(\)|\w+))"
    expression = re.sub(r"\s+", " ", body).strip().removeprefix("ensureLoaded(); ")
    read_match = re.fullmatch(r"return (.+);", expression)
    if read_match:
        expression = read_match[1]
        cast = re.fullmatch(r"\(float\) \((.+)\)", expression)
        if cast: expression = cast[1]
        enum = re.fullmatch(r"enumAt\((\w+)\.values\(\), (.+), \1\.(\w+)\)", expression)
        if enum: expression = enum[2]
        match = re.fullmatch(r"(!)?" + receiver + r"\.(Bool|Int|Long|Float|String)\(\)( / 100\.0f| == 1)?", expression)
        if match and (target := source_reference(match[2], symbols)):
            transform = "not" if match[1] else "percent" if match[4] == " / 100.0f" else "equals_one" if match[4] else "float" if cast else "identity"
            result.update(route="read", targets=[target], transform=transform)
            if enum: result.update(transform="enum", enum=enum[1], fallback=enum[3])
            return result
        match = re.fullmatch(receiver + r"\.Bool\(\) \? VideoMessagesCamera.REAR : VideoMessagesCamera.FRONT", expression)
        if match and (target := source_reference(match[1], symbols)):
            result.update(route="read", targets=[target], transform="camera_enum")
            return result
    else:
        match = re.fullmatch(receiver + r"\.setConfig(?:Bool|Int|Long|Float|String)\((.+)\);", expression)
        if match and (target := source_reference(match[1], symbols)):
            transforms = {"value": "identity", "!value": "not", "Math.round(value)": "round",
                          "Math.round(value * 100)": "percent", "value.ordinal()": "enum", "value == VideoMessagesCamera.REAR": "camera_enum"}
            if match[2] in transforms:
                result.update(route="write", targets=[target], transform=transforms[match[2]])
                return result
    if "Plugins" in name or name == "pluginsSafeMode":
        result["reason"] = "requires actual coordinator runtime/safe-engine or NativeUI manager metadata; no current native getter/setter contract"
    else:
        result["reason"] = "named Android utility/state API has no reviewed native operation"
    return result


def build():
    pins = {}
    # Keep the aggregate's raw hash out of SOURCES: it is rewritten by the prior
    # CI inventory step. The explicitly scoped canonical pin below remains checked.
    source = json.loads(read(ROOT / INVENTORY_PATH, {}))
    contract = inventory_contract(source)
    contract_pin = inventory_pin(contract)
    apis = contract["compatibility_apis"]
    if len(apis) != 308 or Counter(a["behavior"] for a in apis) != {"mapped-alias": 220, "compat-storage": 44, "shim-utility-or-unresolved": 44}:
        raise ValueError("review the changed 308-ID Config inventory before regeneration")
    features = set(contract["feature_ids"])
    fragments = {}
    for name in ("appearance", "chat", "privacy", "ai", "ai-visibility", "tools", "dialogs", "identity", "retention"):
        fragment = json.loads(read(ROOT / f"docs/wave-2/{name}-parity.json", pins))
        for record in fragment.get("features", []):
            key = record.get("ios", {}).get("setting_key")
            if key: fragments.setdefault(record["id"], set()).add(key)
    native = native_definitions(pins)
    registered_root = root_registration(pins)
    dispositions = json.loads(read(ROOT / "docs/wave-2/sdk-config-binding-dispositions.json", pins))
    parsed, bindings, classes, symbols = {}, {}, {}, {}
    for name in (*CONFIGS, "ExteraConfig"):
        relative = contract["configs"][name]["file"]
        path = ANDROID / relative
        text = read(path, pins)
        if digest(path) != contract["source_files"][relative]["sha256"]:
            raise ValueError(f"pinned Android Config source changed: {relative}")
        config = inventory.parse_config(text, relative)
        parsed[name] = config
        if name == "ExteraConfig": continue
        cls = {"fields": {}, "getters": {}, "scalar": {}, "unsupported": [], "constants": {}, "singleton": path.suffix == ".kt"}
        classes[config["fqcn"]] = cls
        for item in config["items"]:
            ident = item["id"]
            if ident not in features: raise ValueError(f"Config item absent from pinned inventory: {ident}")
            symbol = name + "." + item["field"]
            symbols[symbol] = ident
            choices = {key for key, definition in native.items() if symbol in definition["symbols"]}
            if not choices:
                choices = fragments.get(ident, set()) & native.keys()
            if ident == "nagram.showTextTranslate": choices = {"chats.showTextTranslate"}
            definition = native[next(iter(choices))] if len(choices) == 1 else None
            secret = bool(SECRET.search(item["field"])) or bool(definition and definition["secret"])
            compatible = definition and (item["type"] == definition["type"] or item["type"] == "long" and definition["type"] == "int" or item["type"] == "float" and definition["type"] == "int")
            projection = VALUE_CODECS.get(ident)
            if projection and definition:
                if item["type"] != "bool" or (definition["key"], definition["type"]) != projection[:2]:
                    raise ValueError("review changed native Config value projection: " + ident)
                compatible = True
            binding = {"symbol": symbol, "source_key": item["key"], "type": item["type"], "secret": secret,
                       "key": definition["key"] if compatible and not secret else None,
                       "source": {"path": path.relative_to(ROOT).as_posix(), "line": item["line"]}}
            if definition: binding["native"] = definition
            if projection and binding["key"]: binding["value_codec"] = projection[2]
            if not binding["key"]:
                binding["reason"] = "native credential value is private" if secret else "native value shape differs from ConfigItem" if definition else "no unique source-registered native setting"
                if not secret and ident in dispositions:
                    binding["disposition"] = dispositions[ident]["status"]
                    binding["reason"] = dispositions[ident]["reason"]
                    binding["evidence"] = dispositions[ident]["evidence"]
            if ident in ("pillstack.activePillsRaw", "pillstack.hiddenPillsRaw", "pillstack.lastActivePillId"):
                binding["key"] = None
                binding["reason"] = "requires the native pill layout original/native ID projection, not raw native IDs"
            if ident in MIGRATION_ONLY:
                binding["key"] = None
                binding["reason"] = MIGRATION_ONLY[ident]
                binding["disposition"] = "unsupported"
            bindings[ident] = binding
            if item["visibility"] != "public": continue
            cls["fields"][item["field"]] = ident
            if path.suffix == ".kt" and not re.search(r"@JvmField\s+(?:val|var)\s+" + re.escape(item["field"]) + r"\b", config["clean"]):
                cls["getters"]["get" + item["field"][:1].upper() + item["field"][1:]] = ident
        for name_, expression in config["constants"].items():
            known, value = inventory._literal(expression, config["constants"])
            if known and type(value) in (int, float, bool) and not name_.startswith("_"):
                cls["constants"][name_] = value
        for method in config["methods"]:
            if not method.public: continue
            body = config["clean"][method.body:method.end].strip().removeprefix("return ").rstrip(";")
            if name == "GeneralConfig" and method.name in ("contentCapture", "crashReports"):
                # These exact wrappers only ensure Android's shared cache is
                # loaded before reading their field. Native Root owns loading;
                # the getter still reads the actual registered native setting.
                loader_getter = r"loadConfig\s*\(\s*false\s*\)\s*;?\s*return\s+" + re.escape(method.name) + r"\s*\.\s*Bool\s*\(\s*\)"
                if re.fullmatch(loader_getter, body):
                    body = method.name + ".Bool()"
            match = re.fullmatch(r"(\w+)\.(Bool|Int|Float|Long|String)\(\)", body)
            if not method.arity and match and match[1] in cls["fields"]:
                cls["scalar"][method.name] = cls["fields"][match[1]]
            else:
                cls["unsupported"].append(method.name)
        cls["unsupported"] = sorted(set(cls["unsupported"]) - cls["getters"].keys() - cls["scalar"].keys())

    aliases_path = ANDROID / "python/extera_utils/class_aliases.py"
    tree = ast.parse(read(aliases_path, pins))
    aliases = next(ast.literal_eval(node.value)["com.exteragram.messenger.ExteraConfig"] for node in tree.body
                   if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "_FIELD_SHAPED" for t in node.targets))
    enum_values = {}
    for name in ENUMS:
        path = ANDROID / f"java/com/exteragram/messenger/{name}.java"
        text = read(path, pins)
        body = text[text.index("{") + 1:].split(";", 1)[0]
        values = re.findall(r"\b([A-Z][A-Z_0-9]*)(?:\((\d+)\))?", body)
        if not values: raise ValueError(f"enum has no source values: {name}")
        enum_values[name] = [(label, int(flag) if flag else None) for label, flag in values]

    config = parsed["ExteraConfig"]
    methods = {(m.name, m.parameter_types): m for m in config["methods"] if m.public and m.static}
    native_defaults, native_enums = compatibility_defaults(pins)
    compatibility = {}
    for api in apis:
        if api["behavior"] != "compat-storage" or api["arity"]: continue
        name = api["symbol"].split(".")[-1]
        method = methods[name, ()]
        body = config["clean"][method.body:method.end]
        match = re.search(r'getPreferences\(\)\.get(Boolean|Int|Long|String)\("(\w+)",\s*([^;]+)', body)
        if not match: raise ValueError("unrecognized original compatibility getter: " + api["id"])
        field = match[2]
        key = "compat.exteraconfig." + field
        definition = native.get(key)
        kind = {"Boolean": "bool", "Int": "int", "Long": "long", "String": "text"}[match[1]]
        if not definition or definition["type"] != ("int" if kind == "long" else kind):
            raise ValueError("missing/mismatched native compatibility definition: " + key)
        identity = "compat.exteraconfig." + field
        compatibility[field] = {"identity": identity}
        if api["type"] in enum_values:
            fallback = re.search(r'getInt\("\w+",\s*(\w+)\.(\w+)\.ordinal\(\)\)', body)
            if not fallback: raise ValueError("unrecognized compatibility enum default")
            compatibility[field].update(enum=fallback[1], fallback=fallback[2])
            labels = [value[0] for value in enum_values[fallback[1]]]
            if native_enums.get(field) != labels: raise ValueError("native compatibility enum ordinals differ: " + field)
            default = labels.index(fallback[2])
        else:
            literal = re.search(r'get(?:Boolean|Int|Long|String)\("\w+",\s*(true|false|-?\d+L?|"(?:\\.|[^"\\])*")\)', body)
            if not literal: raise ValueError("unknown source compatibility default: " + field)
            known, default = inventory._literal(literal[1], {})
            if not known: raise ValueError("unparsed source compatibility default: " + field)
        if type(native_defaults.get(field)) is not type(default) or native_defaults[field] != default:
            raise ValueError("native compatibility default changed from original: " + field)
        bindings[identity] = {"symbol": "ExteraConfig." + field, "source_key": field, "type": kind, "secret": False,
            "key": key, "native": definition, "source": {"path": "third_party/exteraless-android/TMessagesProj/src/main/" + api["file"], "line": api["line"]}}
    if len(compatibility) != 22: raise ValueError("original compatibility namespace must contain exactly 22 fields")
    for path in (
        "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ClientSettingsBridgeExtension.swift",
        "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginConfigBridgeExtension.swift",
        "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginManagerPreferences.swift",
        "telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift",
        "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift",
    ): read(ROOT / path, pins)
    routes, records = [], []
    for api in apis:
        method = methods[(api["symbol"].split(".")[-1], tuple(api["parameter_types"]))]
        route = api_route(api, config["clean"][method.body:method.end], symbols, compatibility)
        routes.append(route)
        targets = [bindings[target] for target in route["targets"]]
        implemented = route["route"] != "unavailable" and all(target["key"] for target in targets)
        reason = "live native settings; defaults/validation belong to ClientSettings" if implemented else route.get("reason") or "; ".join(target["symbol"] + ": " + target["reason"] for target in targets if not target["key"])
        if route["route"].startswith("manager_"):
            reason = "actual PluginManagerPreferences snapshot; typed settings-authorized FIFO setter admission delegates to existing native Runtime controls"
        if any(target.get("value_codec") == "front_rear_bool" for target in targets):
            reason = "native tools.videoMessageCameraFacing Front(0)/Rear(1) projects to the legacy Bool; writes select 0/1; Ask(2) reads fail explicitly instead of inventing Front"
        status = "implemented" if implemented else "blocked" if api["behavior"] != "shim-utility-or-unresolved" or "requires" in reason else "unsupported"
        if not implemented and (route.get("disposition") == "unsupported" or targets and all(target.get("key") or target.get("disposition") == "unsupported" for target in targets)):
            status = "unsupported"
        evidence = [{"kind": "source", "path": "third_party/exteraless-android/TMessagesProj/src/main/" + api["file"], "line": api["line"]},
                    {"kind": "source", "path": OUTPUT.relative_to(ROOT).as_posix(), "note": api["id"]},
                    {"kind": "source", "path": "python/exteraless_runtime/_config.py", "note": reason}]
        evidence.extend({"kind": "source", "path": target["native"]["path"], "line": target["native"]["line"], "note": target["key"] or target["reason"]} for target in targets if "native" in target)
        for target in targets:
            evidence.extend(target.get("evidence", []))
            evidence.extend(target.get("native", {}).get("registration", []))
        if route["route"].startswith("manager_") or "PluginsDisableArtOpts" in route["name"]:
            evidence.append({"kind": "source", "path": "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginConfigBridgeExtension.swift", "note": "settings + C epoch validation; actual manager snapshot; FIFO accepted-not-delivered mutation"})
        if route["route"] == "force_snow":
            evidence.append({"kind": "source", "path": "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ClientSettingsBridgeExtension.swift", "note": "setClientSettings opaque JSON -> strict decode -> one ClientSettings.applyPublic"})
        records.append({"id": api["id"], "ios": {"setting_key": targets[0]["key"] if len(targets) == 1 else None,
            "adaptation": {"sdk_route": route["route"], "canonical_keys": [t["key"] for t in targets if t["key"]], "note": reason}},
            "implementation": {"status": status, "ported": False, "evidence": evidence}})

    manifest = {"SOURCES": dict(sorted(pins.items())), "INVENTORY_CONTRACT": contract_pin, "ROOT_REGISTRATION": registered_root,
                 "BINDINGS": bindings, "CLASSES": classes,
                 "ENUMS": enum_values, "APIS": routes, "FIELD_ALIASES": aliases}
    implementation_counts = Counter(row["implementation"]["status"] for row in records)
    receipt = {"schema_version": 2, "generator": "python -m tools.compat.sdk_config_manifest --write",
        "scope": "SDK API mirror only; not UI/client-effect parity or a new native execution pass",
        "source_inventory": contract_pin,
        "source_pins": dict(sorted(pins.items())), "source_classification_counts": dict(Counter(a["behavior"] for a in apis)),
        "implementation_counts": {status: implementation_counts[status] for status in ("implemented", "blocked", "unsupported")},
        "root_registration": registered_root,
        "registered_config_classes": sorted([*classes, "com.exteragram.messenger.ExteraConfig"]), "compatibility_apis": records,
        "compat_storage_boundary": "44 overloads use 22 closed global compat.exteraconfig definitions in the actual ClientSettings root registration set. No per-plugin substitution or new client feature is claimed.",
        "runtime_metadata_boundary": "Manager snapshots and native FIFO mode operations are bound. Android ART compatibilityMode has a named native unsupported disposition; no fake JIT/engine value.",
        "kotlin_name_boundary": "No KTConfig class exists in the pinned source; actual Kotlin object FQCNs are registered.",
        "supersedes_classification_only_fragment": "12 overlapping compatibility_apis in docs/wave-2/tools-parity.json must be omitted from the coordinator merge when this SDK-owned receipt is selected."}
    # Validate every exact overload against the actual inventory fragment schema.
    inventory.merge_parity(source, fragments=[receipt])
    return manifest, receipt


def render(manifest):
    lines = ['"""Generated SDK Config metadata. Regenerate with tools.compat.sdk_config_manifest."""', ""]
    for name, value in manifest.items():
        if isinstance(value, dict):
            lines.append(name + " = {")
            lines.extend("    " + repr(key) + ": " + repr(item) + "," for key, item in sorted(value.items()))
            lines.append("}")
        else:
            lines.append(name + " = [")
            lines.extend("    " + repr(item) + "," for item in value)
            lines.append("]")
        lines.append("")
    return "\n".join(lines)


def _artifact_values(text, python):
    if len(text.encode("utf-8")) > 8 * 1024 * 1024:
        raise ValueError("diagnostic parse size limit")
    if not python: return json.loads(text)
    tree = ast.parse(text)
    return {node.targets[0].id: ast.literal_eval(node.value) for node in tree.body
            if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name)}


def _preview(value):
    if value is None or type(value) in (bool, int): return value
    if isinstance(value, str): return value if len(value) <= 120 else value[:117] + "..."
    if isinstance(value, (dict, list, tuple)): return f"<{type(value).__name__}: {len(value)} entries>"
    return repr(value)[:120]


def _change(path, before, after, kind="value"):
    return {"path": path[:240], "change": kind, "stored": _preview(before), "expected": _preview(after)}


def _changes(before, after, path="", depth=0):
    if depth > 16:
        if before != after: yield _change(path, before, after, "depth limit")
        return
    if type(before) is not type(after):
        yield _change(path, before, after, f"type {type(before).__name__} -> {type(after).__name__}")
    elif isinstance(before, dict):
        for key in sorted(before.keys() | after.keys()):
            label = f"{path}[{key!r}]" if path else str(key)
            if key not in before: yield _change(label, "<missing>", after[key], "added")
            elif key not in after: yield _change(label, before[key], "<missing>", "removed")
            else: yield from _changes(before[key], after[key], label, depth + 1)
    elif isinstance(before, (list, tuple)):
        if len(before) != len(after): yield _change(path, len(before), len(after), "length")
        for index, (old, new) in enumerate(zip(before, after)):
            yield from _changes(old, new, f"{path}[{index}]", depth + 1)
    elif before != after:
        yield _change(path, before, after)


def _delta_json(delta):
    while True:
        text = json.dumps(delta, ensure_ascii=False, separators=(",", ":"))
        if len(text.encode("utf-8")) <= DIAGNOSTIC_LIMIT // 2 or not delta["changes"]: return text
        delta["changes"].pop()
        delta["changes_truncated"] = True


def stale_diagnostic(path, actual, expected):
    try: label = path.relative_to(ROOT).as_posix()
    except ValueError: label = path.as_posix()
    lines = [f"SDK Config generated output is stale: {label}"]
    delta = {"version": 1, "artifact": label, "python": sys.version.split()[0], "platform": sys.platform,
             "hash_scope": "UTF-8 text with universal newlines", "changes": []}
    for name, text in (("stored", actual), ("expected", expected)):
        if text is None:
            delta[name] = None
        else:
            raw = text.encode("utf-8")
            delta[name] = {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
    if actual is None:
        delta["missing"] = True
        return "\n".join(lines + ["SDK_CONFIG_DELTA_JSON=" + _delta_json(delta)])
    try:
        before = _artifact_values(actual, path.suffix == ".py")
        after = _artifact_values(expected, path.suffix == ".py")
        keys = list(islice(_changes(before, after), 9))
        delta["changes"] = keys[:8]
        delta["changes_truncated"] = len(keys) > 8
        delta["format_only"] = not keys
    except (ValueError, SyntaxError, TypeError, RecursionError) as error:
        delta["parse_error"] = type(error).__name__
    old_lines, new_lines = actual.splitlines(), expected.splitlines()
    first = next((i for i, pair in enumerate(zip(old_lines, new_lines)) if pair[0] != pair[1]), min(len(old_lines), len(new_lines)))
    start = max(0, first - 1)
    delta["first_differing_line"] = first + 1
    lines.append("SDK_CONFIG_DELTA_JSON=" + _delta_json(delta))
    if delta.get("format_only"): lines.append("Values match; serialized ordering/format differs.")
    lines.append(f"Bounded diff near line {first + 1} (12-line window, 240 chars/line):")
    diff = difflib.unified_diff(old_lines[start:start + 12], new_lines[start:start + 12],
                                fromfile="stored/" + label, tofile="expected/" + label, n=1, lineterm="")
    for line in islice(diff, 28): lines.append(line if len(line) <= 240 else line[:237] + "...")
    result = "\n".join(lines)
    raw = result.encode("utf-8")
    if len(raw) > DIAGNOSTIC_LIMIT:
        result = raw[:DIAGNOSTIC_LIMIT - 40].decode("utf-8", errors="ignore") + "\n... diagnostic truncated"
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    options = parser.parse_args()
    manifest, receipt = build()
    outputs = {OUTPUT: render(manifest), RECEIPT: json.dumps(receipt, ensure_ascii=False, indent=2) + "\n"}
    for path, content in outputs.items():
        if options.write:
            path.write_text(content, encoding="utf-8", newline="\n")
        else:
            actual = path.read_text(encoding="utf-8") if path.is_file() else None
            if actual != content: raise SystemExit(stale_diagnostic(path, actual, content))
    print(json.dumps({"apis": len(receipt["compatibility_apis"]), "bindings": len(manifest["BINDINGS"]),
                      "implementation": receipt["implementation_counts"],
                      "inventory_hash_mode": receipt["source_inventory"]["hash_mode"],
                      "inventory_raw_sha256": digest(ROOT / INVENTORY_PATH)}))


if __name__ == "__main__":
    main()
