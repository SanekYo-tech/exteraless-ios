"""Darwin-only, bounded fixture of the real native loopback listener sources.

No app, account, copied listener, or HTTP service is involved. This does not
compile the separate PluginHost-dependent handoff bridge/composition hunk.
"""

from pathlib import Path
import os
import signal
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[3]
UI = ROOT / "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI"


def run_bounded(command, timeout):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=5)
        raise
    assert process.returncode == 0, output[-32768:]
    return output


def worker(directory):
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        raise RuntimeError("Darwin fixture requires an already installed swiftc")
    output = Path(directory) / "sdk-developer-native-probe"
    sources = [UI / name for name in ("PluginUIModel.swift", "PluginUIStyleModel.swift",
                                      "PluginDeveloperProtocol.swift", "PluginDeveloperServer.swift")]
    sources.append(Path(__file__).parent / "fixtures/sdk_developer/NativeDeveloperServerProbe.swift")
    # Compilation has a separate cold-cache budget. The actual listener process
    # remains limited to ten seconds, with process-group teardown on timeout.
    run_bounded([swiftc, "-parse-as-library", *map(str, sources), "-o", str(output)], timeout=120)
    result = run_bounded([str(output), str(directory)], timeout=10)
    assert "SDK_DEVELOPER_NATIVE_OK" in result
    print(result, end="")


if __name__ == "__main__":
    worker(sys.argv[1])
else:
    import pytest

    @pytest.mark.skipif(sys.platform != "darwin", reason="shipping listener imports Apple's Network; native fixture not run on Windows")
    def test_native_developer_listener_readiness_retry_and_auth(tmp_path):
        worker(tmp_path)
