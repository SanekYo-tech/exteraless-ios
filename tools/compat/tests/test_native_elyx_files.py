"""Compile actual native FD/registry tests, then cap the test process at 30 s.

Local PluginHost package only. No external dependencies, accounts or networking.
Windows cannot execute the Darwin/Linux filesystem backend; it is an explicit
skip, not a native execution receipt.
"""

import importlib.util
from pathlib import Path
import shutil
import sys


ROOT = Path(__file__).resolve().parents[3]


def run(directory):
    swift = shutil.which("swift")
    if swift is None:
        raise RuntimeError("native FD fixture requires an installed Swift toolchain")
    spec = importlib.util.spec_from_file_location("_elyx_fd_native_bounded", Path(__file__).with_name("test_sdk_developer_native.py"))
    bounded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bounded)
    common = ["--package-path", str(ROOT / "swift/PluginHost"), "--scratch-path", str(directory / "build")]
    bounded.run_bounded([swift, "build", *common, "--build-tests"], timeout=120)
    output = bounded.run_bounded([swift, "test", *common, "--skip-build", "--filter",
        "PluginElyxDeveloper(Files|Activation)?Tests"], timeout=30)
    print(output, end="")


if __name__ == "__main__":
    run(Path(sys.argv[1]))
else:
    import pytest

    @pytest.mark.skipif(sys.platform not in ("darwin", "linux"), reason="native FD tests require Darwin/Linux kqueue/inotify and rename exchange")
    def test_native_elyx_fd_authority(tmp_path):
        run(tmp_path)
