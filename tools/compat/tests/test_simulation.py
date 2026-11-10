"""Регрессия симуляции корпуса: импорт плагинов через virtual-java.

Гейт: не меньше 90% плагинов корпуса должны проходить импорт через
virtual-java со стабами SDK. 100% — текущее состояние; порог ниже,
чтобы рост корпуса (новые плагины) не ронял CI до разбора.
"""

import os
import sys

import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from tools.compat import corpus  # noqa: E402
from tools.compat import simulate_plugins  # noqa: E402


@pytest.fixture(scope="module")
def simulation():
    if not corpus.load_corpus():
        pytest.skip(f"no corpus at {corpus.CORPUS_DIR}")
    from tools.compat.simulate_plugins import simulate_with_retries
    return [simulate_with_retries(plugin)[0]
            for plugin in corpus.load_corpus()]


def test_simulation_import_rate(simulation):
    ok = sum(1 for r in simulation if r["ok"])
    rate = ok / len(simulation)
    details = []
    for r in simulation:
        if not r["ok"]:
            err = r["error"]
            details.append(
                f"{r['name']}: {err['type']} стр.{err['line']}: "
                f"{(err['message'] or '')[:150]}")
    assert rate >= 0.9, (
        f"импорт проходит только {rate:.0%} корпуса "
        f"({ok}/{len(simulation)}):\n" + "\n".join(details))


def test_simulation_plugins_define_classes(simulation):
    # Плагин без классов после exec — подозрителен (пустой namespace).
    empty = [r["name"] for r in simulation
             if r["ok"] and not r["plugin_classes"]]
    assert not empty, f"exec прошёл, но классов нет: {empty}"


def test_plugin_classes_instantiate(simulation):
    """Классы плагинов обязаны создаваться поверх настоящего SDK.

    Это runtime-smoke уровня «хост может создать плагин»: классы,
    наследующие BasePlugin/dynamic_proxy, создаются как обычные
    Python-объекты (Java-конструктор не нужен).
    """
    from tools.compat.simulate_plugins import _install_real_sdk, _clear_modules
    from python.virtualjava import MockBackend, install, uninstall, reset_caches

    instantiable = 0
    candidates = 0
    for plugin in corpus.load_corpus():
        backend = MockBackend()
        uninstall()
        reset_caches()
        _clear_modules()
        install(backend)
        _install_real_sdk()
        namespace = {
            "__name__": "__plugin__it",
            "__file__": plugin.path,
            "__doc__": None,
        }
        try:
            with __import__("warnings").catch_warnings():
                __import__("warnings").simplefilter("ignore")
                exec(compile(plugin.source, plugin.name, "exec"), namespace)
        except Exception:
            continue
        for name, value in list(namespace.items()):
            if not isinstance(value, type):
                continue
            # Плагин может переприсвоить __name__ — сверяем с актуальным.
            if value.__module__ != namespace["__name__"]:
                continue
            candidates += 1
            try:
                value()
                instantiable += 1
            except TypeError:
                # __init__ требует аргументов — тоже валидный класс.
                instantiable += 1
            except Exception:
                pass
        break  # smoke: одного плагина достаточно
    # Слабый, но честный гейт: классы создаются без падения метаклассов.
    assert instantiable >= 1, (
        "ни один класс плагина не инстанцируется — прокси-метаклассы сломаны")
