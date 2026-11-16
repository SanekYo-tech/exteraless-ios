"""Actual Foundation ingress/protocol XCTest sources with the local Host package.

Only test execution is recorded by the Swift tests; no Python, listener, account
or application is started. Compile separately; the test process has a 30 s cap.
"""

import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys


ROOT = Path(__file__).resolve().parents[3]
UI = ROOT / "telegram-ios/submodules/TelegramUI"
INPUTS = [UI / "Sources/ExteralessClient/PluginUI" / name for name in (
    "PluginUIModel.swift", "PluginUIStyleModel.swift", "PluginDeveloperProtocol.swift", "PluginElyxDeveloperIngress.swift")]
TEST = UI / "Tests/PluginElyxDeveloperProtocolTests.swift"


def run(directory):
    swift = shutil.which("swift")
    if swift is None:
        raise RuntimeError("native ingress fixture requires an installed Swift toolchain")
    spec = importlib.util.spec_from_file_location("_elyx_ingress_bounded", Path(__file__).with_name("test_sdk_developer_native.py"))
    bounded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bounded)
    source_dir, test_dir = directory / "Sources/TelegramUI", directory / "Tests/IngressTests"
    source_dir.mkdir(parents=True)
    test_dir.mkdir(parents=True)
    pins = {}
    for source in [*INPUTS, TEST]:
        target = (test_dir if source == TEST else source_dir) / source.name
        shutil.copyfile(source, target)
        pins[str(source)] = hashlib.sha256(source.read_bytes()).hexdigest()
        assert hashlib.sha256(target.read_bytes()).hexdigest() == pins[str(source)]
    host = json.dumps((ROOT / "swift/PluginHost").as_posix())
    (directory / "Package.swift").write_text('''// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "NativeElyxIngress", platforms: [.macOS(.v12)],
    dependencies: [.package(path: HOST)], targets: [
        .target(name: "TelegramUI", dependencies: [.product(name: "PluginHost", package: "PluginHost")]),
        .testTarget(name: "IngressTests", dependencies: ["TelegramUI", .product(name: "PluginHost", package: "PluginHost")])])
'''.replace("HOST", host), encoding="utf-8")
    (directory / "input-sha256.json").write_text(json.dumps(pins, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    common = ["--package-path", str(directory), "--scratch-path", str(directory / "build")]
    bounded.run_bounded([swift, "build", *common, "--build-tests"], timeout=120)
    result = bounded.run_bounded([swift, "test", *common, "--skip-build"], timeout=30)
    assert all(hashlib.sha256(Path(path).read_bytes()).hexdigest() == sha for path, sha in pins.items())
    print(result, end="")


if __name__ == "__main__":
    run(Path(sys.argv[1]))
else:
    import pytest

    @pytest.mark.skipif(sys.platform not in ("darwin", "linux"), reason="native ingress fixture needs the Darwin/Linux Swift toolchain")
    def test_actual_native_elyx_ingress_and_wire_outcomes(tmp_path):
        run(tmp_path)
