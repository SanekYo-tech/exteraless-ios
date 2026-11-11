"""Воркер рантайм-симуляции: ОДИН плагин в отдельном процессе.

Изоляция по процессам — требование пользователя по RAM: процесс
завершается -> память освобождена; зависание убивает внешний таймаут
(simulate_runtime). Внутри — никаких циклов по событиям: только
жизненный цикл импорта и первичных вызовов хоста.

Запуск: python -m tools.compat.runtime_worker <имя_файла_плагина>
Выход: JSON в stdout.
"""

import json
import os
import sys
import traceback
import warnings

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
SDK = os.path.join(REPO_ROOT, "python", "sdk")
for path in (REPO_ROOT, SDK):
    if path not in sys.path:
        sys.path.insert(0, path)


def _step(result, name, fn):
    try:
        value = fn()
        result[name] = {"ok": True, "value_type": type(value).__name__}
        return value
    except Exception as exc:
        result[name] = {
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}"[:200],
        }
        return None


def main():
    os.environ.setdefault("PYTHONUTF8", "1")
    target = sys.argv[1]
    from python.virtualjava import MockBackend, install
    from python.virtualjava.backend import _Universal

    from tools.compat import corpus
    plugins = [p for p in corpus.load_corpus() if p.name == target]
    if not plugins:
        print(json.dumps({"name": target, "import_ok": False,
                          "error": "not found"}))
        return
    plugin = plugins[0]

    result = {"name": target}
    backend = MockBackend()
    install(backend)

    # Импорт (+ авто-стабы pip/платформенных модулей, как в
    # simulate_plugins.simulate_with_retries).
    namespace = {
        "__name__": "__plugin__rt",
        "__file__": plugin.path,
        "__doc__": None,
    }
    stubbed = []
    from .simulate_plugins import _make_stub_module
    from .simulate_plugins import _SDK_MODULE_NAMES, JAVA_MODULE_ROOTS
    for _attempt in range(3):
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                exec(compile(plugin.source, plugin.name, "exec"), namespace)
            result["import_ok"] = True
            break
        except ModuleNotFoundError as exc:
            missing = str(exc).split("'")[1].split(".")[0]
            if (missing not in JAVA_MODULE_ROOTS
                    and missing not in _SDK_MODULE_NAMES
                    and missing not in sys.modules):
                sys.modules[missing] = _make_stub_module(missing, backend)
                stubbed.append(missing)
                namespace = {
                    "__name__": "__plugin__rt",
                    "__file__": plugin.path,
                    "__doc__": None,
                }
                continue
            result["import_ok"] = False
            result["import_error"] = f"ModuleNotFoundError: {exc}"[:200]
            break
        except Exception as exc:
            result["import_ok"] = False
            result["import_error"] = f"{type(exc).__name__}: {exc}"[:200]
            break
    result["stubbed_modules"] = stubbed
    if not result.get("import_ok"):
        print(json.dumps(result))
        return

    # 2. Поиск класса плагина (наследник BasePlugin).
    import base_plugin as base_plugin_module
    plugin_classes = []
    for name, value in list(namespace.items()):
        if (isinstance(value, type)
                and issubclass(value, base_plugin_module.BasePlugin)
                and value is not base_plugin_module.BasePlugin):
            plugin_classes.append(name)
    result["plugin_classes"] = plugin_classes

    mock_arg = _Universal("runtime:arg", backend)

    # 3. Инстанцирование главного класса.
    instance = None
    for class_name in plugin_classes:
        cls = namespace[class_name]
        made = _step(result, "instantiate:" + class_name, lambda: cls())
        if made is not None:
            instance = made
            break

    # 4. Жизненный цикл: create_settings.
    if instance is not None:
        if hasattr(type(instance), "create_settings"):
            _step(result, "create_settings", instance.create_settings)
        else:
            result["create_settings"] = {"ok": True, "note": "not defined"}

        # 5. High-level хуки (сигнатуры из base_plugin.py).
        hooks = {
            "on_send_message_hook": lambda: instance.on_send_message_hook(
                0, mock_arg),
            "on_app_event": lambda: instance.on_app_event("test", mock_arg),
            "on_update": lambda: instance.on_update(mock_arg),
            "on_updates": lambda: instance.on_updates(mock_arg),
        }
        result["hooks"] = {}
        for hook_name, call in hooks.items():
            hook = getattr(type(instance), hook_name, None)
            if hook is None or getattr(hook, "__module__", "") == "base_plugin":
                continue  # плагин не переопределял — вызывать нечего
            _step(result["hooks"], hook_name, call)

    # Требования к мосту: сколько вызовов ушло в бэкенд.
    result["backend_calls"] = len(backend.calls)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
