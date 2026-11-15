"""Probe-only regression for CPython's partially initialized module window."""

import importlib.util
import sys
import types
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


def observer():
    source = ROOT / "python/runtime/smoke/native_plugin_probe.py"
    spec = importlib.util.spec_from_file_location("_probe_observer_fixture", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_partial_module_execution_does_not_taint_later_native_observations(monkeypatch):
    probe = observer()
    bridge = types.ModuleType("_exteraless_bridge")
    bridge.__spec__ = types.SimpleNamespace(_initializing=True)
    monkeypatch.setitem(sys.modules, "_exteraless_bridge", bridge)

    probe._profile(sys._getframe(), "c_call", len)
    assert probe._problems == []
    assert probe._backend_calls == 0

    # Once execution publishes the real backend, the very same observer must
    # resume counting its methods instead of suppressing all bootstrap events.
    bridge.BridgeBackend = dict
    bridge.__spec__._initializing = False
    probe._profile(sys._getframe(), "c_call", {}.get)
    assert probe._backend_calls == 1
    assert probe._problems == []


def test_published_broken_backend_still_fails_the_probe(monkeypatch):
    probe = observer()
    bridge = types.ModuleType("_exteraless_bridge")
    bridge.BridgeBackend = object()  # A published non-type is a real observer error.
    monkeypatch.setitem(sys.modules, "_exteraless_bridge", bridge)
    probe._profile(sys._getframe(), "c_call", {}.get)
    assert len(probe._problems) == 1
    assert probe._problems[0].startswith("TypeError:")
