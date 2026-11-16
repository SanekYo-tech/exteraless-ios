"""Darwin-only, bounded fixture of the real native loopback listener sources.

No app, account, copied listener, or HTTP service is involved. This does not
compile the separate PluginHost-dependent handoff bridge/composition hunk.
"""

from pathlib import Path
import hashlib
import json
import os
import signal
import shutil
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[3]
UI = ROOT / "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI"


def run_bounded(command, timeout, *, log=None):
    command = list(map(str, command))
    if log is not None:
        log = Path(log)
        log.write_text("COMMAND " + json.dumps(command) + "\n", encoding="utf-8")
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        output, _ = process.communicate(timeout=5)
        if log is not None:
            with log.open("a", encoding="utf-8") as stream:
                stream.write(output)
                stream.write("\nPROCESS INTERRUPTED\n")
        raise
    if log is not None:
        with log.open("a", encoding="utf-8") as stream:
            stream.write(output)
            stream.write("\nEXIT " + str(process.returncode) + "\n")
    assert process.returncode == 0, output[-32768:]
    return output


def worker(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        raise RuntimeError("Darwin fixture requires an already installed swiftc")
    output = Path(directory) / "sdk-developer-native-probe"
    sources = [UI / name for name in ("PluginUIModel.swift", "PluginUIStyleModel.swift",
                                      "PluginDeveloperProtocol.swift", "PluginDeveloperServer.swift")]
    sources.append(Path(__file__).parent / "fixtures/sdk_developer/NativeDeveloperServerProbe.swift")
    evidence = directory / "evidence"
    evidence.mkdir(exist_ok=True)
    inputs = [*sources, Path(__file__)]
    pins = {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    for path in inputs:
        target = evidence / "sources" / path.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
    report = {"ok": False, "phase": "compile", "source_sha256": pins,
              "compile_timeout_seconds": 120, "execution_timeout_seconds": 10,
              "boundary": "actual Darwin Network listener and protocol; own loopback clients; no Python runtime or iOS claim"}
    def record():
        (evidence / "native-listener.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    record()
    # Compilation has a separate cold-cache budget. The actual listener process
    # remains limited to ten seconds, with process-group teardown on timeout.
    try:
        started = time.monotonic()
        run_bounded([swiftc, "-parse-as-library", *map(str, sources), "-o", str(output)], timeout=120, log=evidence / "compile.log")
        report.update(compile_seconds=round(time.monotonic() - started, 3), phase="execute")
        record()
        started = time.monotonic()
        result = run_bounded([str(output), str(directory)], timeout=10, log=evidence / "execute.log")
        assert "SDK_DEVELOPER_NATIVE_OK" in result
        assert all(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == sha for name, sha in pins.items()), "Native listener sources changed during execution"
        report.update(ok=True, phase="complete", execute_seconds=round(time.monotonic() - started, 3))
        print(result, end="")
    except BaseException as error:
        report["error_type"] = type(error).__name__
        raise
    finally:
        record()


if __name__ == "__main__":
    worker(sys.argv[1])
else:
    import pytest

    @pytest.mark.skipif(sys.platform != "darwin", reason="shipping listener imports Apple's Network; native fixture not run on Windows")
    def test_native_developer_listener_readiness_retry_and_auth(tmp_path):
        worker(tmp_path)
