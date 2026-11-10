"""Генератор манифеста совместимости (этап 0).

Сканирует корпус плагинов, сопоставляет использование с исходниками
exteraless (Android) и выдаёт:

  build/compat/manifest.json  — машинно-читаемая поверхность:
      классы { члены: арности, сколько плагинов, примеры },
      xposed-цели, high-level SDK-хуки, покрытие;
  build/compat/report.md      — человекочитаемый отчёт с приоритетами.

Запуск:
  python -m tools.compat.generate_manifest
Переменные окружения — см. tools/compat/corpus.py.
"""

import argparse
import json
import os
from collections import defaultdict

from . import corpus
from . import javaapi
from . import scanner

GENERATED = ("R", "BuildConfig")
OUT_DIR = os.path.join(corpus.PROJECT_ROOT, "build", "compat")


def type_exists(fqcn):
    if javaapi.type_of(fqcn) is not None:
        return True
    return javaapi.kotlin_type_of(fqcn) is not None


def declared_members(fqcn):
    jtype = javaapi.type_of(fqcn) or javaapi.kotlin_type_of(fqcn)
    if jtype is None:
        return None
    return {
        "kind": jtype.kind,
        "methods": {name: len(sigs) for name, sigs in jtype.methods.items()},
        "fields": sorted(jtype.fields),
        "nested": sorted(jtype.nested),
    }


def aggregate(scans, resolve):
    classes = {}
    sdk_hooks = defaultdict(set)
    xposed_targets = {}

    for scan in scans:
        plugin = scan["name"]
        for fqcn in scan["refs"]:
            entry = classes.setdefault(fqcn, {
                "users": set(), "via_refs": 0,
                "members": defaultdict(lambda: {"users": set(), "arities": set()}),
            })
            entry["users"].add(plugin)
            entry["via_refs"] += 1
        for call in scan["calls"]:
            fqcn = call["class"]
            if fqcn not in classes:
                classes[fqcn] = {
                    "users": set(), "via_refs": 0,
                    "members": defaultdict(lambda: {"users": set(), "arities": set()}),
                }
            entry = classes[fqcn]
            entry["users"].add(plugin)
            member = entry["members"][call["member"]]
            member["users"].add(plugin)
            if call["argc"] is not None:
                member["arities"].add(call["argc"])
        for hook in scan["sdk_hooks"]:
            sdk_hooks[hook].add(plugin)
        for target in scan["xposed"]:
            key = (target["class"], target["method"])
            xposed_targets.setdefault(key, {"users": set(), "kind": target["kind"]})
            xposed_targets[key]["users"].add(plugin)

    out_classes = {}
    for fqcn, entry in sorted(classes.items()):
        if fqcn.partition("$")[0].rpartition(".")[2] in GENERATED:
            continue
        members = {
            name: {
                "plugins": len(data["users"]),
                "arities": sorted(data["arities"]),
            }
            for name, data in entry["members"].items()
        }
        declared = declared_members(fqcn)
        out_classes[fqcn] = {
            "plugins": len(entry["users"]),
            "examples": sorted(entry["users"])[:5],
            "members": members,
            "declared_in_fork": declared is not None,
            "declared": declared,
        }

    out_xposed = {
        f"{fqcn}#{method or '<init>'}": {
            "plugins": len(data["users"]),
            "examples": sorted(data["users"])[:5],
            "kind": data["kind"],
            "class_in_fork": type_exists(fqcn),
        }
        for (fqcn, method), data in sorted(xposed_targets.items())
    }

    out_hooks = {
        hook: {"plugins": len(users), "examples": sorted(users)[:5]}
        for hook, users in sorted(sdk_hooks.items())
    }

    return out_classes, out_xposed, out_hooks


def coverage_stats(classes):
    owned = {k: v for k, v in classes.items()
             if k.startswith(scanner.OWNED_PREFIXES)}
    known = {k: v for k, v in owned.items() if v["declared_in_fork"]}
    unknown = {k: v for k, v in owned.items() if not v["declared_in_fork"]}
    return owned, known, unknown


def write_report(scans, classes, xposed, hooks, path):
    owned, known, unknown = coverage_stats(classes)
    parsed = sum(1 for s in scans if s["parsed"])
    lines = []
    add = lines.append
    add("# Совместимость плагинов: отчёт по корпусу")
    add("")
    add(f"* плагинов в корпусе: **{len(scans)}** (парсится AST: {parsed})")
    add(f"* Java-классов используется (owned-префиксы): **{len(owned)}**")
    add(f"  * найдено в исходниках форка: **{len(known)}**")
    add(f"  * отсутствует (нужен шим/порт): **{len(unknown)}**")
    add(f"* Xposed-целей: **{len(xposed)}**; плагинов с Xposed-мостом: "
        f"**{sum(1 for s in scans if s['xposed_bridge'])}**")
    add(f"* Плагинов с subclass-хуками (PyMethodHook и наследники): "
        f"**{sum(1 for s in scans if s['hook_subclasses'])}**")
    add("")
    add("## SDK-хуки (приоритет extension points на iOS)")
    add("")
    add("| хук | плагинов |")
    add("|---|---|")
    for hook, data in sorted(hooks.items(), key=lambda kv: -kv[1]["plugins"]):
        add(f"| `{hook}` | {data['plugins']} |")
    add("")
    add("## Топ классов по числу плагинов")
    add("")
    add("| класс | плагинов | членов зовётся | в форке |")
    add("|---|---|---|---|")
    top = sorted(owned.items(), key=lambda kv: -kv[1]["plugins"])[:40]
    for fqcn, data in top:
        add(f"| `{fqcn}` | {data['plugins']} | {len(data['members'])} | "
            f"{'да' if data['declared_in_fork'] else '**нет**'} |")
    add("")
    add("## Топ вызываемых членов (класс#член)")
    add("")
    rows = []
    for fqcn, data in owned.items():
        for member, mdata in data["members"].items():
            rows.append((mdata["plugins"], fqcn, member, mdata["arities"]))
    rows.sort(key=lambda r: (-r[0], r[1], r[2]))
    add("| класс#член | плагинов | арности |")
    add("|---|---|---|")
    for plugins, fqcn, member, arities in rows[:60]:
        add(f"| `{fqcn}#{member}` | {plugins} | {arities} |")
    add("")
    if unknown:
        add("## Отсутствующие в форке классы")
        add("")
        for fqcn, data in sorted(unknown.items(), key=lambda kv: -kv[1]["plugins"])[:30]:
            add(f"* `{fqcn}` — {data['plugins']} плагинов "
                f"(примеры: {', '.join(data['examples'][:3])})")
        add("")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", default=OUT_DIR)
    args = parser.parse_args()

    plugins = list(corpus.load_corpus())
    if not plugins:
        raise SystemExit(
            f"корпус пуст: {corpus.CORPUS_DIR}\n"
            "запусти python -m tools.compat.collect_corpus")
    print(f"corpus: {len(plugins)} плагинов из {corpus.CORPUS_DIR}")

    alias_module = scanner.load_aliases()
    resolve = scanner._alias_resolve(alias_module)
    if alias_module is None:
        print("WARN: class_aliases.py не найден, имена как есть")

    scans = [scanner.scan_plugin(p, resolve) for p in plugins]
    classes, xposed, hooks = aggregate(scans, resolve)

    os.makedirs(args.out_dir, exist_ok=True)
    manifest = {
        "corpus": {
            "dir": corpus.CORPUS_DIR,
            "plugins": len(plugins),
            "parsed": sum(1 for s in scans if s["parsed"]),
        },
        "classes": classes,
        "xposed_targets": xposed,
        "sdk_hooks": hooks,
        "plugins": scans,
    }
    manifest_path = os.path.join(args.out_dir, "manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=1, sort_keys=True)

    report_path = os.path.join(args.out_dir, "report.md")
    write_report(scans, classes, xposed, hooks, report_path)

    owned, known, unknown = coverage_stats(classes)
    print(f"classes: {len(classes)} total, owned {len(owned)}, "
          f"known {len(known)}, missing {len(unknown)}")
    print(f"xposed targets: {len(xposed)}; sdk hooks: {len(hooks)}")
    print(f"manifest: {manifest_path}")
    print(f"report:   {report_path}")


if __name__ == "__main__":
    main()
