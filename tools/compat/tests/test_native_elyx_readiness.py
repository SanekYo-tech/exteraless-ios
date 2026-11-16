"""Negative tests of the real data-only helper; no fake positive C/Host receipt.

The built-in gate and successful registry challenge run only in the fifth native
child. Each Python rejection check has a fresh, isolated <=20-second process.
"""

import importlib.machinery
import json
from pathlib import Path
import subprocess
import sys
import types


ROOT = Path(__file__).resolve().parents[3]


def worker(case):
    assert sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode
    sys.path.insert(0, str(ROOT / "python"))
    from exteraless_runtime import _elyx_readiness as helper, UnsupportedSurfaceError
    if case == "challenge":
        for value in (None, True, 1, "", "0" * 63, "0" * 65, "G" * 64, "A" * 64):
            try:
                helper.probe_json(value)
            except ValueError:
                pass
            else:
                raise AssertionError("malformed challenge was accepted")
    else:
        bridge = types.ModuleType("_exteraless_bridge")
        bridge.__spec__ = importlib.machinery.ModuleSpec("_exteraless_bridge", None, origin="built-in")
        calls = []

        def counterfeit(*values):
            calls.append(values)
            return {"abi": helper.ABI, "challenge": "0" * 64, "gate": "builtin",
                    "hooks": ["inspect", "manifest", "verifiedLoad"], "rejected": True}

        counterfeit.__name__ = "xt_elyx_source"
        counterfeit.__module__ = "_exteraless_bridge"
        counterfeit.__self__ = bridge
        bridge.xt_elyx_source = counterfeit if case == "python-gate" else len
        if case == "nonbuiltin-module":
            bridge.__spec__.origin = "own-counterfeit-extension"
        sys.modules["_exteraless_bridge"] = bridge
        try:
            helper.probe_json("0" * 64)
        except UnsupportedSurfaceError as error:
            assert "built-in gate" in str(error)
        else:
            raise AssertionError("counterfeit gate was accepted")
        assert calls == []
    import exteraless_runtime as runtime
    assert runtime._state is None
    assert not any(name.startswith("ElyxPlugins.") for name in sys.modules)
    print(json.dumps({"case": case, "entry_calls": 0, "native_readiness_claimed": False}))


if __name__ == "__main__":
    worker(sys.argv[1])
else:
    import pytest

    @pytest.mark.parametrize("case", ("challenge", "python-gate", "different-builtin", "nonbuiltin-module"))
    def test_readiness_rejects_invalid_input_and_counterfeit_gate(case, tmp_path):
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), case],
                                cwd=tmp_path, text=True, capture_output=True, timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
