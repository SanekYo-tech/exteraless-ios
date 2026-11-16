"""DEV-LIFECYCLE-01: actual Root writes and native provider queues, no listener.

The fixture carves exact production methods/initializers rather than reimplementing
Root behavior. Only UI/context/transport boundaries and Python execution are
recorders. The real Host activation/registry and the real atomic store execute.
Separate <=120 s compilation and <=30 s test process-group deadlines.
"""

import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import sys
import time


ROOT = Path(__file__).resolve().parents[3]
UI = ROOT / "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI"
APP = ROOT / "telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift"
QUEUE = ROOT / "swift/ExteralessCore/Sources/ExteralessCore/ExteraConfigCompatibility.swift"
HERE = Path(__file__).parent / "fixtures/native_elyx_mode"
SOURCES = tuple(UI / name for name in (
    "PluginUIModel.swift", "PluginUIStyleModel.swift", "PluginDeveloperProtocol.swift", "PluginManagerPreferences.swift",
    "PluginRuntimeRecovery.swift", "PluginDeveloperBridgeExtension.swift", "PluginConfigBridgeExtension.swift", "PluginElyxDeveloperIngress.swift"))
SUPPORT = ROOT / "swift/PluginHost/Tests/PluginHostTests/HostLifecycleTestSupport.swift"
METHODS = ("updateManagerPreference", "updateDeveloperServer", "retireElyxDeveloperService", "elyxActivationScope",
           "stopDeveloperServices", "applyGlobalPluginConfig", "requirePluginExecution")


def source(path):
    return path.read_bytes().decode("utf-8")


def balanced(text, opening):
    """Match Swift source braces/parentheses outside comments and string literals."""
    pairs = {"(": ")", "{": "}", "[": "]"}
    stack = []
    i = opening
    while i < len(text):
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = len(text) if end < 0 else end + 1
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end < 0:
                raise ValueError("unterminated Swift comment")
            i = end + 2
            continue
        if text[i] == '"':
            i += 1
            while i < len(text) and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            if i == len(text):
                raise ValueError("unterminated Swift string")
        elif text[i] in pairs:
            stack.append(pairs[text[i]])
        elif text[i] in pairs.values():
            if not stack or stack.pop() != text[i]:
                raise ValueError("unbalanced production Swift source")
            if not stack:
                return i + 1
        i += 1
    raise ValueError("unterminated production Swift declaration")


def declaration(text, marker, delimiter="{"):
    if text.count(marker) != 1:
        raise ValueError("production Root/queue marker must match once: " + marker)
    at = text.index(marker)
    start = text.rfind("\n", 0, at) + 1
    end = balanced(text, text.index(delimiter, at))
    return text[start:end] + "\n"


def prepare(directory):
    if directory.exists() and any(directory.iterdir()):
        raise ValueError("mode-ABA fixture output must be empty")
    app, queue = source(APP), source(QUEUE)
    snippets = {name: declaration(app, "private func " + name + "(") for name in METHODS}
    snippets["pluginExecutionRequested"] = declaration(app, "public var pluginExecutionRequested:")
    initializers = {name: declaration(app, "let " + name + " = " + type_name + "(", "(")
                    for name, type_name in (("pluginConfig", "PluginConfigBridgeExtension"), ("developer", "PluginDeveloperBridgeExtension"))}
    core = {name: declaration(queue, marker + name) for name, marker in (
        ("ExteraConfigManagerMutation", "public enum "), ("ExteraConfigCommandError", "public enum "),
        ("ExteraConfigCommandQueue", "public final class "))}
    frame = source(HERE / "RootFixture.swift")
    for marker in ("// PRODUCTION_BRIDGE_INITIALIZERS", "// PRODUCTION_ROOT_METHODS"):
        if frame.count(marker) != 1:
            raise ValueError("invalid fixture insertion marker")
    frame = frame.replace("        // PRODUCTION_BRIDGE_INITIALIZERS\n", "\n".join(initializers.values()))
    frame = frame.replace("    // PRODUCTION_ROOT_METHODS\n", "\n".join(snippets.values()))
    app_dir, core_dir, tests = (directory / name for name in ("Sources/NativeElyxModeRoot", "Sources/ExteralessCore", "Tests/ModeTests"))
    for path in (app_dir, core_dir, tests):
        path.mkdir(parents=True)
    (app_dir / "RootFixture.swift").write_bytes(frame.encode())
    (core_dir / "ExteraConfigCommands.swift").write_bytes(("import Foundation\n\n" + "\n".join(core.values())).encode())
    inputs = [APP, QUEUE, HERE / "RootFixture.swift", HERE / "ModeABATests.swift", SUPPORT, *SOURCES, Path(__file__)]
    host_package = ROOT / "swift/PluginHost"
    inputs += [host_package / "Package.swift", *(path for path in (host_package / "Sources").rglob("*") if path.is_file())]
    pins = {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    for path in SOURCES:
        shutil.copyfile(path, app_dir / path.name)
    for path in (SUPPORT, HERE / "ModeABATests.swift"):
        shutil.copyfile(path, tests / path.name)
    host = json.dumps((ROOT / "swift/PluginHost").as_posix())
    (directory / "Package.swift").write_text('''// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "NativeElyxModeABA", platforms: [.macOS(.v12)], dependencies: [.package(path: HOST)], targets: [
    .target(name: "ExteralessCore"),
    .target(name: "NativeElyxModeRoot", dependencies: ["ExteralessCore", .product(name: "PluginHost", package: "PluginHost")]),
    .testTarget(name: "ModeTests", dependencies: ["NativeElyxModeRoot", .product(name: "PluginHost", package: "PluginHost")])])
'''.replace("HOST", host), encoding="utf-8")
    spans = {"root." + name: value for name, value in snippets.items()}
    spans.update({"root.init." + name: value for name, value in initializers.items()})
    spans.update({"core." + name: value for name, value in core.items()})
    receipt = {"source_sha256": pins, "exact_span_sha256": {name: hashlib.sha256(value.encode()).hexdigest() for name, value in spans.items()},
               "native_execution": "not yet run", "compile_timeout_seconds": 120, "test_timeout_seconds": 30,
               "boundary": "exact Root methods/initializers, actual native queues/store/Host/registry; UI/context/transport and Python execution recorders"}
    (directory / "inputs.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return receipt


def run(directory):
    swift = shutil.which("swift")
    if swift is None:
        raise RuntimeError("mode-ABA fixture requires an installed native Swift toolchain")
    receipt = prepare(directory)
    spec = importlib.util.spec_from_file_location("_mode_aba_bounded", Path(__file__).with_name("test_sdk_developer_native.py"))
    bounded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bounded)
    common = ["--package-path", str(directory), "--scratch-path", str(directory / "build"), "--jobs", "2"]
    started = time.monotonic()
    bounded.run_bounded([swift, "build", *common, "--build-tests"], timeout=120)
    build_seconds = time.monotonic() - started
    started = time.monotonic()
    result = bounded.run_bounded([swift, "test", *common, "--skip-build", "--filter", "NativeElyxModeABATests"], timeout=30)
    test_seconds = time.monotonic() - started
    names = re.findall(r"\bfunc (test\w+)\(", source(HERE / "ModeABATests.swift"))
    assert len(names) == 4 and all(re.search(r"Test Case .*" + re.escape(name) + r".*\bpassed\b", result) for name in names), result
    assert all(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == sha for name, sha in receipt["source_sha256"].items())
    (directory / "native-results.json").write_text(json.dumps({"native_execution": True, "passed_test_cases": names,
        "build_seconds": round(build_seconds, 3), "test_seconds": round(test_seconds, 3),
        "compile_timeout_seconds": 120, "test_timeout_seconds": 30, "boundary": receipt["boundary"],
        "exact_span_sha256": receipt["exact_span_sha256"], "source_sha256": receipt["source_sha256"]},
        indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(result, end="")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--prepare":
        print(json.dumps(prepare(Path(sys.argv[2])), indent=2, sort_keys=True))
    else:
        run(Path(sys.argv[1]))
else:
    import pytest

    @pytest.mark.skipif(sys.platform not in ("darwin", "linux"), reason="native Root mode-ABA execution requires Darwin/Linux Swift")
    def test_native_root_developer_mode_aba(tmp_path):
        run(tmp_path)
