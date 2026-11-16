"""Independent ZIP/JSON checks of the tiny fifth-child inputs, never a native pass."""

import ast
import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import zipfile


ROOT = Path(__file__).resolve().parents[3]
EMITTER = ROOT / "tools/runtime/fixtures/emit_elyx_developer_probe.py"


def test_fifth_child_inputs_exercise_real_code_resource_wheel_and_policy_changes(tmp_path):
    spec = importlib.util.spec_from_file_location("_owned_elyx_dev_emitter", EMITTER)
    emitter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(emitter)
    emitter.emit(tmp_path)
    artifacts = sorted(tmp_path.iterdir())
    assert {path.name for path in artifacts} == {"owned.elyx", "expected-next.elyx", "changes.json", "compare-next.json",
                                                "reject-requires.json", "reject-python.json"}
    assert sum(path.stat().st_size for path in artifacts) < 32768
    with zipfile.ZipFile(tmp_path / "owned.elyx") as first, zipfile.ZipFile(tmp_path / "expected-next.elyx") as after:
        assert first.testzip() is None and after.testzip() is None
        before = {name: first.read(name) for name in first.namelist()}
        expected = {name: after.read(name) for name in after.namelist()}
    assert set(before) == set(expected)
    assert before["helpers.py"] == b"VALUE = 'first'\n" and expected["helpers.py"] == b"VALUE = 'next'\n"
    assert before["assets/value.txt"] == b"asset-first" and expected["assets/value.txt"] == b"asset-next"
    assert [node.name for node in ast.parse(expected["main.py"]).body if isinstance(node, ast.ClassDef)] == ["NativeElyxDeveloperProbeNext"]
    assert json.loads(expected["meta.json"])["permissions"] == ["network"]
    command = json.loads((tmp_path / "changes.json").read_text(encoding="utf-8"))
    assert command["@"] == "elyx_changes" and command["plugin_id"] == "native_elyx_dev"
    assert {change["path"] for change in command["changes"]} == {name for name in before if before[name] != expected[name]}
    for change in command["changes"]:
        assert change["#"] == "modified" and base64.b64decode(change["content"], validate=True) == expected[change["path"]]
    hashes = json.loads((tmp_path / "compare-next.json").read_text(encoding="utf-8"))["hashes"]
    assert hashes == {name: hashlib.sha256(value).hexdigest() for name, value in expected.items()}
    wheel_name = "wheels/elyxprobe-1.0-py3-none-any.whl"
    for image, value in ((before, "first"), (expected, "next")):
        with zipfile.ZipFile(io.BytesIO(image[wheel_name])) as wheel:
            assert wheel.testzip() is None
            assert wheel.read("elyxprobe/__init__.py") == ("VALUE = 'wheel-" + value + "'\n").encode()
            assert b"Version: 1.0\n" in wheel.read("elyxprobe-1.0.dist-info/METADATA")
    for name in ("requires", "python"):
        refusal = json.loads((tmp_path / ("reject-" + name + ".json")).read_text(encoding="utf-8"))
        assert refusal["@"] == "elyx_changes" and refusal["plugin_id"] == command["plugin_id"]
        assert len(refusal["changes"]) == 1
        change = refusal["changes"][0]
        data = base64.b64decode(change["content"], validate=True)
        if name == "requires":
            assert change["path"] == "meta.json" and json.loads(data)["requires"] == {command["plugin_id"]: None}
        else:
            assert change["path"] == wheel_name
            with zipfile.ZipFile(io.BytesIO(data)) as wheel:
                assert wheel.testzip() is None
                assert b"Requires-Python: >=99\n" in wheel.read("elyxprobe-1.0.dist-info/METADATA")
