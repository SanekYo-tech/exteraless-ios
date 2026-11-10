"""Инвентаризация фич exteraless для порта на iOS (этап 6).

Сканирует Android-исходники и строит измеримый чек-лист порта:
  * конфиг-классы (ExteraConfig, NekoConfig, NaConfig, ...) — тумблеры;
  * модули app/exteraless/* — файлы, объём, статус порта;
  * tw.nekomimi.* и xyz.nextalone.* — унаследованные фичи NagramX.

Результат: build/compat/features.json + features-report.md.
Волны приоритетов — основа плана этапа 6.

Запуск:  python -m tools.compat.feature_inventory
"""

import json
import os
import re

from . import corpus

JAVA_ROOT = os.path.join(corpus.REPO, "TMessagesProj", "src", "main", "java")
OUT_DIR = os.path.join(corpus.PROJECT_ROOT, "build", "compat")

# Конфиг-классы: источник тумблеров фич.
CONFIG_CLASSES = [
    "com/exteragram/messenger/ExteraConfig.java",
    "app/exteraless/OpenExteraConfig.java",
    "app/exteraless/appearance/AppearanceConfig.java",
    "app/exteraless/chats/ChatsConfig.java",
    "app/exteraless/general/GeneralConfig.java",
    "app/exteraless/utils/UtilsConfig.java",
    "app/exteraless/icons/IconPacksConfig.java",
    "tw/nekomimi/nekogram/NekoConfig.java",
    "xyz/nextalone/nagram/NaConfig.java",
]

FEATURE_MODULES_DIR = os.path.join(JAVA_ROOT, "app", "exteraless")

# Унаследованные деревья NagramX/Nekogram (вне app.exteraless).
LEGACY_TREES = ["tw/nekomimi", "xyz/nextalone"]

# Волны этапа 6: приоритет порта фич (после плагин-ядра).
# plugins — не волна: это этапы 1–5 (ядро плагин-системы).
WAVES = {
    "wave1_visual_base": [
        "appearance", "appicons", "icons", "drawer", "settings", "general",
    ],
    "wave2_chat": [
        "chats", "feed", "pillstack", "player", "nowplaying", "math",
        "components",
    ],
    "wave3_privacy_background": [
        "ghost", "privacy", "notifications", "backup", "updater", "ai",
        "speech", "proxy",
    ],
    "wave4_rest": [
        "camera", "debug", "glyph", "shortcuts", "utils", "crash", "config",
    ],
}

_GETTER_RE = re.compile(
    r"public\s+static\s+(?:boolean|int|long|float|String)\s+(\w+)\s*\(")
_FIELD_RE = re.compile(
    r"public\s+static\s+(?:final\s+)?(?:boolean|int|long|float|String)\s+(\w+)\s*[=;]")


def scan_config_toggles():
    """Тумблеры по геттерам/полям конфиг-классов."""
    out = {}
    for rel in CONFIG_CLASSES:
        path = os.path.join(JAVA_ROOT, *rel.split("/"))
        name = rel.rsplit("/", 1)[-1][:-5]
        if not os.path.isfile(path):
            out[name] = {"found": False, "toggles": []}
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        getters = set(_GETTER_RE.findall(text))
        fields = set(_FIELD_RE.findall(text))
        toggles = sorted(
            f for f in (getters | fields)
            if not f.startswith(("ICON_PACK", "PREFS_"))
        )
        out[name] = {"found": True, "toggles": toggles, "count": len(toggles)}
    return out


def scan_modules():
    """Модули app/exteraless/*: файлы, объём, тумблеры волны."""
    out = {}
    if not os.path.isdir(FEATURE_MODULES_DIR):
        return out
    for entry in sorted(os.listdir(FEATURE_MODULES_DIR)):
        path = os.path.join(FEATURE_MODULES_DIR, entry)
        if not os.path.isdir(path):
            continue
        files = []
        for dirpath, _, names in os.walk(path):
            for fn in names:
                if fn.endswith(".java"):
                    files.append(os.path.join(dirpath, fn))
        size = 0
        for fp in files:
            size += os.path.getsize(fp)
        wave = "wave4_rest"
        for wave_name, members in WAVES.items():
            if entry in members:
                wave = wave_name
                break
        if entry == "plugins":
            wave = "stages_1_5"
        out[entry] = {
            "files": len(files),
            "kb": round(size / 1024),
            "wave": wave,
            "ported": False,
        }
    return out


def scan_legacy_trees():
    out = {}
    for rel in LEGACY_TREES:
        path = os.path.join(JAVA_ROOT, *rel.split("/"))
        if not os.path.isdir(path):
            continue
        files = []
        for dirpath, _, names in os.walk(path):
            for fn in names:
                if fn.endswith(".java"):
                    files.append(os.path.join(dirpath, fn))
        size = sum(os.path.getsize(fp) for fp in files)
        out[rel.replace("/", ".")] = {
            "files": len(files),
            "kb": round(size / 1024),
            "ported": False,
        }
    return out


def main():
    configs = scan_config_toggles()
    modules = scan_modules()
    legacy = scan_legacy_trees()

    total_toggles = sum(c.get("count", 0) for c in configs.values())
    total_kb = sum(m["kb"] for m in modules.values()) \
        + sum(m["kb"] for m in legacy.values())

    os.makedirs(OUT_DIR, exist_ok=True)
    payload = {
        "configs": configs,
        "modules": modules,
        "legacy_trees": legacy,
        "totals": {
            "config_toggles": total_toggles,
            "modules": len(modules),
            "java_kb": total_kb,
        },
        "waves": WAVES,
    }
    with open(os.path.join(OUT_DIR, "features.json"), "w",
              encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1, sort_keys=True)

    lines = ["# Инвентаризация фич exteraless (этап 6)", ""]
    lines.append(f"* тумблеров в конфигах: **{total_toggles}**")
    lines.append(f"* модулей app/exteraless: **{len(modules)}**")
    lines.append(f"* унаследованных деревьев (NagramX/Neko): "
                 f"**{len(legacy)}**")
    lines.append(f"* всего Java к порту: **{total_kb / 1024:.1f} МБ**")
    lines.append("")
    lines.append("## Конфиги")
    lines.append("")
    lines.append("| конфиг | тумблеров |")
    lines.append("|---|---|")
    for name, data in sorted(configs.items()):
        lines.append(f"| `{name}` | {data.get('count', '—')} |")
    lines.append("")
    lines.append("## Волны порта")
    lines.append("")
    lines.append("*`plugins` (853 KB) — не волна: ядро плагин-системы, "
                 "этапы 1–5.*")
    lines.append("")
    for wave, members in WAVES.items():
        wave_kb = sum(m["kb"] for m in modules.values() if m["wave"] == wave)
        lines.append(f"### {wave} ({wave_kb} KB)")
        for m in members:
            data = modules.get(m, {})
            lines.append(
                f"- `{m}` — {data.get('files', '?')} файлов, "
                f"{data.get('kb', '?')} KB")
        lines.append("")
    report = os.path.join(OUT_DIR, "features-report.md")
    with open(report, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    print(f"тумблеров: {total_toggles}, модулей: {len(modules)}, "
          f"java: {total_kb / 1024:.1f} MB")
    print(f"features: {os.path.join(OUT_DIR, 'features.json')}")
    print(f"report:   {report}")


if __name__ == "__main__":
    main()
