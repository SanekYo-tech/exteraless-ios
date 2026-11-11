"""Рантайм-симуляция плагинов: жизненный цикл через subprocess-изоляцию.

Каждый плагин — отдельный процесс с таймаутом (RAM-политика: процесс
вышел — память освобождена; завис — убит таймаутом). Последовательно.

Запуск:  python -m tools.compat.simulate_runtime
Выход:   build/compat/runtime-sim.json + сводка.
"""

import argparse
import json
import os
import subprocess
import sys

from . import corpus

OUT_PATH = os.path.join(corpus.PROJECT_ROOT, "build", "compat",
                        "runtime-sim.json")
TIMEOUT_SECONDS = 30


def run_plugin(name):
    """Один плагин в отдельном процессе; JSON с stdout."""
    env = dict(os.environ)
    env["PYTHONUTF8"] = "1"
    env["EXTERALESS_PLUGIN_CORPUS"] = corpus.CORPUS_DIR
    try:
        proc = subprocess.run(
            [sys.executable, "-m", "tools.compat.runtime_worker", name],
            cwd=corpus.PROJECT_ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=TIMEOUT_SECONDS,
            env=env,
        )
    except subprocess.TimeoutExpired:
        return {"name": name, "import_ok": False,
                "import_error": f"timeout {TIMEOUT_SECONDS}s"}
    for line in (proc.stdout or "").splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return {"name": name, "import_ok": False,
            "import_error": f"no json (exit {proc.returncode}): "
                            f"{(proc.stderr or '')[-300:]}"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=0,
                        help="сколько плагинов (0 = все)")
    args = parser.parse_args()

    plugins = [p.name for p in corpus.load_corpus()]
    if not plugins:
        raise SystemExit(f"корпус пуст: {corpus.CORPUS_DIR}")
    if args.limit:
        plugins = plugins[:args.limit]

    results = []
    for index, name in enumerate(plugins, 1):
        result = run_plugin(name)
        results.append(result)
        flags = []
        if result.get("import_ok"):
            flags.append("import")
            for key in result:
                if key.startswith("instantiate:") and result[key].get("ok"):
                    flags.append("init")
                    break
            if result.get("create_settings", {}).get("ok"):
                flags.append("settings")
            hooks_ok = [h for h, data in result.get("hooks", {}).items()
                        if data.get("ok")]
            if hooks_ok:
                flags.append(f"hooks:{len(hooks_ok)}")
        print(f"[{index:2}/{len(plugins)}] {name}: "
              f"{', '.join(flags) or 'FAIL'}")

    total = len(results)
    imported = sum(1 for r in results if r.get("import_ok"))
    instantiated = sum(1 for r in results
                       if any(k.startswith("instantiate:")
                              and r[k].get("ok") for k in r))
    settings_ok = sum(1 for r in results
                      if r.get("create_settings", {}).get("ok"))
    hooks_total = sum(1 for r in results for h in r.get("hooks", {}).values()
                      if h.get("ok"))
    hooks_failed = sum(1 for r in results for h in r.get("hooks", {}).values()
                       if not h.get("ok"))
    requirements = []
    for r in results:
        for key, data in r.items():
            if isinstance(data, dict) and not data.get("ok", True) \
                    and "error" in data:
                requirements.append(f"{r['name']}#{key}: {data['error']}")

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    payload = {
        "plugins_total": total,
        "imported": imported,
        "instantiated": instantiated,
        "create_settings_ok": settings_ok,
        "hooks_ok": hooks_total,
        "hooks_failed": hooks_failed,
        "results": results,
        "bridge_requirements_sample": requirements[:40],
    }
    with open(OUT_PATH, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)

    print(f"\nитог: import {imported}/{total}, "
          f"instantiate {instantiated}/{total}, "
          f"create_settings {settings_ok}/{total}, "
          f"hooks ok/failed {hooks_total}/{hooks_failed}")
    print(f"отчёт: {OUT_PATH}")


if __name__ == "__main__":
    main()
