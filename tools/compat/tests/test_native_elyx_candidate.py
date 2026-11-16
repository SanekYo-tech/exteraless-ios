"""Darwin native ZIP transform -> independent zipfile CRC/body validation.

120-second compile / 10-second native execution; no application, accounts, CI or
network. The source fixture imports PluginHost from the local package only.
This proves candidate bytes, not the still-pending production FD publication ABI.
"""

import importlib.util
import json
from pathlib import Path
import shutil
import sys
import zipfile


HERE = Path(__file__).resolve().parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(directory):
    swift = shutil.which("swift")
    if swift is None:
        raise RuntimeError("native candidate fixture requires an already installed Swift toolchain")
    support = load("_native_candidate_bounded", "test_sdk_developer_native.py")
    source = load("_native_candidate_emitter", "test_native_elyx_developer.py")
    source.emit(directory)
    package = HERE / "fixtures/native_elyx"
    scratch = directory / "swift-build"
    support.run_bounded([swift, "build", "--package-path", str(package), "--scratch-path", str(scratch),
                         "--product", "NativeElyxCandidate"], timeout=120)
    output = support.run_bounded([str(scratch / "debug/NativeElyxCandidate"), str(directory)], timeout=10)
    assert "NATIVE_ELYX_CANDIDATE_OK" in output
    expected = json.loads((directory / "expected.json").read_text(encoding="utf-8"))
    with zipfile.ZipFile(directory / "owned.elyx") as before, zipfile.ZipFile(directory / "candidate.elyx") as after:
        assert after.testzip() is None
        for name, body in expected.items():
            assert after.read(name) == body.encode("utf-8")
        assert "obsolete.txt" not in after.namelist()
        assert "extra/one.txt" not in after.namelist()
        for name in before.namelist():
            if name not in expected and name != "obsolete.txt":
                assert before.read(name) == after.read(name), name
                assert before.getinfo(name).compress_type == after.getinfo(name).compress_type, name
    print(output, end="")


if __name__ == "__main__":
    run(Path(sys.argv[1]))
else:
    import pytest

    @pytest.mark.skipif(sys.platform != "darwin", reason="native candidate source fixture is provided for the Darwin Swift toolchain")
    def test_native_candidate_persists_code_and_resources(tmp_path):
        run(tmp_path)
