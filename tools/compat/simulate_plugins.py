"""Симуляция корпуса: плагины исполняются поверх virtual-java.

Каждый плагин корпуса exec-ится в чистом namespace с:
  * virtual-java (import com.* / org.* -> прокси -> MockBackend);
  * перmissive-стабами SDK-модулей (base_plugin, ui.settings, ... —
    настоящий порт SDK придёт на этапе 3, стабы дают меру «совместимости
    импорта», не поведения).

Результат: build/compat/simulation.json + консольная сводка.
Значение метрики: плагины, чей импорт проходит через virtual-java,
переносимы на iOS без правок уровня импорта; ошибки показывают,
что именно стабить/портить следующим.

Запуск:  python -m tools.compat.simulate_plugins
"""

import json
import os
import sys
import traceback
import types
import warnings

from . import corpus

REPO_ROOT = corpus.PROJECT_ROOT
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from python.virtualjava import MockBackend, install, uninstall, reset_caches  # noqa: E402
from python.virtualjava.backend import _Universal  # noqa: E402

OUT_PATH = os.path.join(REPO_ROOT, "build", "compat", "simulation.json")

# Настоящий SDK exteraless (порт: python/sdk) — работает поверх
# virtual-java без правок. Стабы нужны только для pip/платформенных
# модулей, которых нет в окружении.
SDK_SRC = os.path.join(REPO_ROOT, "python", "sdk")


class _StubMeta(type):
    """Метакласс стаб-класса: любой атрибут класса -> перmissive объект."""

    def __getattr__(cls, name):
        if name.startswith("__") and name.endswith("__"):
            raise AttributeError(name)
        return _Universal(f"{cls.__name__}.{name}", cls._backend)

    def __call__(cls, *args, **kwargs):
        instance = super().__call__(*args, **kwargs)
        return instance


class _StubBase:
    def __getattr__(self, name):
        return _Universal(
            f"{type(self).__name__}.{name}", type(self)._backend)

    def __call__(self, *args, **kwargs):
        return _Universal(f"{type(self).__name__}()", type(self)._backend)


def _make_stub_class(name, backend):
    return _StubMeta(name, (_StubBase,), {"_backend": backend})


def _make_stub_module(name, backend):
    mod = types.ModuleType(name)
    mod.__path__ = []

    def _getattr(item, _name=name, _backend=backend):
        if item.startswith("__") and item.endswith("__"):
            raise AttributeError(item)
        if item[:1].isupper():
            return _make_stub_class(f"{_name}.{item}", _backend)
        return _Universal(f"{_name}.{item}", _backend)

    mod.__dict__["__getattr__"] = _getattr
    return mod


_SDK_MODULE_NAMES = (
    "base_plugin", "android_utils", "client_utils", "hook_utils",
    "file_utils", "intents", "markdown_utils", "plugin_settings",
    "pip_controller", "dev_server",
    "ui", "elyx_runtime", "extera_utils",
)


def _install_real_sdk():
    """Настоящий SDK поверх virtual-java (sdksrc без правок)."""
    if SDK_SRC not in sys.path:
        sys.path.insert(0, SDK_SRC)


def _clear_modules():
    for name in list(sys.modules):
        root = name.split(".", 1)[0]
        if root in ("java", "javax", "android", "androidx", "org", "com",
                    "kotlin", "dalvik") or name in _SDK_MODULE_NAMES:
            del sys.modules[name]


def _innermost_line(exc):
    frame = getattr(exc, "__traceback__", None)
    line = None
    while frame is not None:
        if frame.tb_frame.f_globals.get("__name__", "").startswith(
                namespace_marker()):
            line = frame.tb_lineno
        frame = frame.tb_next
    return line


def namespace_marker():
    return "__plugin__"


def simulate_plugin(plugin, backend, extra_stubs=()):
    """Исполнить плагин; вернуть отчёт."""
    uninstall()
    reset_caches()
    _clear_modules()
    install(backend)
    _install_real_sdk()
    for name in extra_stubs:
        sys.modules.setdefault(name, _make_stub_module(name, backend))

    namespace = {
        "__name__": namespace_marker() + plugin.name.replace(".", "_"),
        "__file__": plugin.path,
        "__doc__": None,
    }
    error = None
    calls_before = len(backend.calls)
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            exec(compile(plugin.source, plugin.name, "exec"), namespace)
    except BaseException as exc:  # noqa: BLE001 — отчёт о любой ошибке
        error = {
            "type": type(exc).__name__,
            "message": str(exc)[:300],
            "line": _innermost_line(exc),
        }
    plugin_classes = [
        name for name, value in namespace.items()
        if isinstance(value, type)
        and value.__module__ == namespace["__name__"]
    ]
    return {
        "name": plugin.name,
        "ok": error is None,
        "error": error,
        "plugin_classes": plugin_classes,
        "import_time_calls": len(backend.calls) - calls_before,
    }


JAVA_MODULE_ROOTS = ("java", "javax", "android", "androidx", "org",
                     "com", "kotlin", "dalvik")


def simulate_with_retries(plugin):
    """Симуляция со стабами недостающих pip/платформенных модулей.

    ModuleNotFoundError на внешний модуль -> стаб + повтор (до 3 раундов),
    стабы записываются в результат. Возвращает (result, backend).
    """
    backend = MockBackend()
    extra_stubs = set()
    for _attempt in range(3):
        result = simulate_plugin(plugin, backend, extra_stubs)
        error = result["error"]
        if (error and error["type"] == "ModuleNotFoundError"
                and error["message"].startswith("No module named '")):
            missing = error["message"].split("'")[1].split(".")[0]
            if (missing.split(".")[0] not in JAVA_MODULE_ROOTS
                    and missing not in _SDK_MODULE_NAMES):
                extra_stubs.add(missing)
                continue
        break
    result["stubbed_modules"] = sorted(extra_stubs)
    return result, backend


def main():
    plugins = list(corpus.load_corpus())
    if not plugins:
        raise SystemExit(f"корпус пуст: {corpus.CORPUS_DIR}")

    results = []
    touched = {}
    for plugin in plugins:
        result, backend = simulate_with_retries(plugin)
        results.append(result)
        for record in backend.calls:
            key = f"{record.target}#{record.member}"
            touched[key] = touched.get(key, 0) + 1

    ok = [r for r in results if r["ok"]]
    failed = [r for r in results if not r["ok"]]
    error_kinds = {}
    for r in failed:
        err = r["error"]
        key = f"{err['type']}: {(err['message'] or '')[:80]}"
        error_kinds[key] = error_kinds.get(key, 0) + 1
    stubbed = {}
    for r in results:
        for name in r["stubbed_modules"]:
            stubbed[name] = stubbed.get(name, 0) + 1

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    payload = {
        "plugins_total": len(results),
        "ok": len(ok),
        "failed": len(failed),
        "stubbed_modules": stubbed,
        "results": results,
        "import_time_touched": dict(sorted(
            touched.items(), key=lambda kv: -kv[1])[:500]),
        "error_kinds": dict(sorted(
            error_kinds.items(), key=lambda kv: -kv[1])),
    }
    with open(OUT_PATH, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)

    uninstall()
    reset_caches()
    _clear_modules()

    print(f"плагинов: {len(results)}  импорт ок: {len(ok)} "
          f"({100 * len(ok) / len(results):.0f}%)  ошибок: {len(failed)}")
    if stubbed:
        print("\nстабы pip/платформенных модулей (в iOS-рантайм нужно "
              "доставить их или шимы):")
        for name, count in sorted(stubbed.items()):
            print(f"  {name} — {count} плагинов")
    print("\nтоп ошибок импорта:")
    for kind, count in list(payload["error_kinds"].items())[:10]:
        print(f"  {count}x {kind}")
    print("\nпримеры упавших:")
    for r in failed[:10]:
        err = r["error"]
        print(f"  {r['name']}: {err['type']} (строка {err['line']}): "
              f"{err['message'][:120]}")
    print(f"\nотчёт: {OUT_PATH}")


if __name__ == "__main__":
    main()
