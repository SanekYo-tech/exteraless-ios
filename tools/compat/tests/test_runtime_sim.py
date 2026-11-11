"""Гейт рантайм-симуляции: жизненный цикл плагинов в subprocess-изоляции.

RAM-политика: только выборка (3 плагина) — полная симуляция запускается
отдельно (python -m tools.compat.simulate_runtime) и в CI.
"""

import os
import sys

import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from tools.compat import corpus  # noqa: E402
from tools.compat import simulate_runtime  # noqa: E402

SAMPLE = ("AisE.plugin", "direct.plugin", "templates.plugin")


@pytest.fixture(scope="module")
def sample_results():
    if not corpus.load_corpus():
        pytest.skip(f"no corpus at {corpus.CORPUS_DIR}")
    return [simulate_runtime.run_plugin(name)
            for name in SAMPLE if corpus_loadable(name)]


def corpus_loadable(name):
    return any(p.name == name for p in corpus.load_corpus())


def test_runtime_sample_imports(sample_results):
    ok = sum(1 for r in sample_results if r.get("import_ok"))
    assert ok == len(sample_results), [
        f"{r['name']}: {r.get('import_error')}" for r in sample_results
        if not r.get("import_ok")]


def test_runtime_sample_instantiates(sample_results):
    for r in sample_results:
        if not r.get("import_ok"):
            continue
        instantiated = any(
            k.startswith("instantiate:") and r[k].get("ok") for k in r)
        assert instantiated, (
            f"{r['name']}: ни один класс не инстанцируется — "
            f"{[r[k] for k in r if k.startswith('instantiate:')]}")


def test_runtime_sample_create_settings(sample_results):
    for r in sample_results:
        if not r.get("import_ok"):
            continue
        settings = r.get("create_settings")
        assert settings and settings.get("ok"), (
            f"{r['name']}: create_settings упал: {settings}")


def test_runtime_hooks_never_crash_hard(sample_results):
    # Хук может отсутствовать (тогда его нет в отчёте), но если
    # вызывался — не должен ронять процесс воркера.
    for r in sample_results:
        for hook, data in r.get("hooks", {}).items():
            assert data.get("ok") or "error" in data, (
                f"{r['name']}#{hook}: непонятный статус {data}")
