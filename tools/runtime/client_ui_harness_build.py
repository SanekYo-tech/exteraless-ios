#!/usr/bin/env python3
"""Build full Telegram + the loginless UIKit app with the repository's Bazel plumbing.

This intentionally does not call unsupported Make.py per-library builds. It
reuses Make's configuration/flags, its exact unsigned rules patch and its full
app/runtime aquery validators. Both top-level ios_application targets are built
in the same debug_sim_arm64 graph. Run only in a disposable CI source copy.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import sys
import time
import zipfile
from types import SimpleNamespace

from client_ui_harness import APP_ROOT, command, digest, verify_ipa, write_json
from client_ui_harness_domains import manifest_from_ipa
from client_ui_harness_visuals import BUILD_SELECTION, VISUAL_SCENARIOS
from client_ui_harness_map import MAP_SCENARIOS
from native_bundle_resources import verify_native_bundle_resources
from native_test_plan import build_plan
from client_ui_harness_inputs import acceptance_identity, harness_inputs

ROOT = Path(__file__).resolve().parents[2]
HARNESS = BUILD_SELECTION["target"]
APPLICATION = "//Telegram:Telegram"
DIAGNOSTIC_TAIL_BYTES = 16 * 1024


def postbox_visibility_errors(telegram):
    """Check the explicit test-client edge that failed the real initial aquery."""
    path = Path(telegram) / "submodules/Postbox/BUILD"
    try:
        rules = {}
        for node in ast.parse(path.read_text(encoding="utf-8")).body:
            if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call):
                attrs = {item.arg: item.value for item in node.value.keywords}
                if isinstance(attrs.get("name"), ast.Constant):
                    rules[attrs["name"].value] = attrs
        packages = ast.literal_eval(rules["test_clients"]["packages"])
        visibility = ast.literal_eval(rules["Postbox"]["visibility"])
        if "//Tests/ExteralessHarness" in packages and ":test_clients" in visibility:
            return []
    except (OSError, SyntaxError, KeyError, ValueError, TypeError):
        pass
    return ["submodules/Postbox/BUILD: Postbox must expose :test_clients to //Tests/ExteralessHarness"]


def diagnostic_tail(path):
    """Read at most 16 KiB of stderr/build log, with an exact byte-range receipt."""
    path = Path(path)
    with path.open("rb") as stream:
        size = stream.seek(0, os.SEEK_END)
        offset = max(0, size - DIAGNOSTIC_TAIL_BYTES)
        stream.seek(offset)
        data = stream.read(DIAGNOSTIC_TAIL_BYTES)
    return {"path": str(path), "fileBytes": size, "byteOffset": offset, "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(), "text": data.decode("utf-8", errors="replace")}


def logged_build_command(args, *, phase, output, log, **options):
    """Surface redirected stderr while the partial/private aquery stdout stays private."""
    try:
        return command(args, log=log, **options)
    except Exception as error:
        log.flush()
        try:
            diagnostic = diagnostic_tail(Path(output) / "build.log")
        except OSError as read_error:
            diagnostic = {"path": str(Path(output) / "build.log"), "text": "", "readError": str(read_error)}
        write_json(Path(output) / "build-failure.json", {
            "status": "build-command-failed", "phase": phase, "configuration": "debug_sim_arm64",
            "targets": [APPLICATION, HARNESS], "command": [str(arg) for arg in args],
            "errorType": type(error).__name__, "error": str(error), "diagnostic": diagnostic,
            "buildVerified": False, "uikitExecuted": False,
        })
        raise RuntimeError("UIKit {} failed; redirected diagnostics from {} (at most {} bytes):\n{}".format(
            phase, diagnostic["path"], DIAGNOSTIC_TAIL_BYTES, diagnostic["text"])) from error


def pinned_xcode_app(telegram):
    version = json.loads((Path(telegram) / "versions.json").read_text(encoding="utf-8"))["xcode"]
    if not isinstance(version, str) or not re.fullmatch(r"\d+(?:\.\d+){1,2}", version):
        raise ValueError("Expected the pinned Xcode version in versions.json")
    return Path("/Applications") / ("Xcode_" + version + ".app")


def source_preflight(telegram):
    """Cheap integration blockers, not a Swift typecheck or substitute build."""
    required = {
        "submodules/Display/Source/NativeWindowHostView.swift": ["nativeWindowHostView(windowScene:"],
        "submodules/TelegramUI/Sources/Exteraless/PluginManagerController.swift": [
            "public let settingsScope:", "scopeIsCurrent: self.actions.settingsScope?(id)"],
        "submodules/TelegramUI/Sources/Exteraless/PluginSettingsController.swift": [
            "public func exteralessPluginSettingsController("],
        "submodules/AccountContext/BUILD": ['name = "ClientHarnessProtocolSource"'],
        "Tests/ComposerHarness/BUILD": ['name = "DisposableAccountSources"'],
        "Tests/ExteralessHarness/BUILD": ['name = "DomainSourceManifest"', '":DomainSourceManifest"',
            '"//submodules/LocationUI:LocationUI"', '"Fixtures/map-attribution-grid.png"', '"Fixtures/native_plugin_probe.py"'],
        "Tests/ExteralessHarness/Fixtures/client_ui_fixture.plugin": ["def fd_family_probe("],
        "Tests/ExteralessHarness/Sources/ClientHarnessNativeObservation.swift": [
            "private let native = CPythonXCFrameworkEngine()", "_fd_module._probe_darwin_family_fds(",
            'if _fd_sys.platform != "ios":', "self.fdPaths.append(observation)"],
        "Tests/ExteralessHarness/Sources/ClientHarnessRuntime.swift": [
            "NativeBridgeBinding(services: self.host.bridge)", "try self.binding.install()",
            "page: PluginSettingsPageExecution.current"],
        "Tests/ExteralessHarness/Sources/ClientHarnessComposer.swift": ["runInlineMathConfigurationSegment(host: host)"],
        "Tests/ExteralessHarness/Sources/ClientHarnessPills.swift": ["pillConfigurationProbe("],
        "Tests/ExteralessHarness/Sources/ClientHarnessScenarios.swift": ["runResetSupplement()", "runTrustSecondarySupplement()", "runMapAttributionSupplement()"],
        "submodules/TelegramUI/BUILD": ["-DPLUGIN_TRUST_SECONDARY_UI_FIXTURE"],
        "submodules/LocationUI/BUILD": ["-DEXTERALESS_MAP_ATTRIBUTION_FIXTURE", 'name = "ClientHarnessMapFingerprintSources"'],
        "submodules/LocationUI/Sources/Tests/ExteralessMapAttributionFixture.swift": [
            "#if EXTERALESS_MAP_ATTRIBUTION_FIXTURE", "public enum ExteralessMapAttributionFixture", "overlay.loadTile(at: path)"],
        "Tests/ExteralessHarness/Sources/ClientHarnessMapAttribution.swift": ["ExteralessMapAttributionFixture.run(hostView:"],
        "submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessComposerVisualFactory.swift": [
            "#if DEBUG", "public func makeExteralessComposerPanel(",
            "inputPanelForChatPresentationIntefaceState(", "panel.loadTextInputNodeIfNeeded()"],
    }
    errors = postbox_visibility_errors(telegram)
    for relative, needles in required.items():
        path = telegram / relative
        text = path.read_text(encoding="utf-8") if path.is_file() else ""
        for needle in needles:
            if needle not in text:
                errors.append(relative + ": missing " + needle)
    # Verify every explicit label in our BUILD names a package and real rule or
    # source output. Bazel's analysis remains the final visibility/platform gate.
    build = (telegram / "Tests/ExteralessHarness/BUILD").read_text(encoding="utf-8")
    for package, target in sorted(set(re.findall(r'"//([^":]+):([^"\s]+)"', build))):
        if package == "visibility" or target.startswith("__"):
            continue
        package_path = telegram / package
        package_build = package_path / "BUILD"
        if not package_build.is_file():
            package_build = package_path / "BUILD.bazel"
        if not package_build.is_file():
            errors.append("missing dependency package: //" + package)
            continue
        content = package_build.read_text(encoding="utf-8")
        if (not re.search(r'\bname\s*=\s*[\'"]' + re.escape(target) + r'[\'"]', content)
                and target not in content and not (package_path / target).is_file()):
            errors.append("missing dependency target: //" + package + ":" + target)
    framework_build = (telegram / "Telegram/BUILD").read_text(encoding="utf-8")
    if not re.search(r'alias\(\s*name\s*=\s*"ClientUIHarness",\s*actual\s*=\s*"//Tests/ExteralessHarness:ClientUIHarness"', framework_build):
        errors.append("Telegram/BUILD: the frozen visual build-selection alias must resolve to the existing harness app")
    for target in ("MtProtoKitFramework", "SwiftSignalKitFramework", "PostboxFramework", "TelegramCoreFramework", "TelegramUIFramework"):
        block = re.search(r'^ios_framework\(\s*name\s*=\s*"' + target + r'".*?^\)', framework_build, re.M | re.S)
        if block is None or not any(label in block[0] for label in (
                '"//visibility:public"', '"//Tests:__subpackages__"', '"//Tests/ExteralessHarness:__pkg__"')):
            errors.append("Telegram/BUILD: " + target + " needs visibility for //Tests/ExteralessHarness:__pkg__")
    return errors


def declaration_preflight(telegram, *, source_checkout=True):
    plan, _ = build_plan(telegram, source_checkout=source_checkout)
    snapshot = harness_inputs(telegram, source_checkout=source_checkout)
    return {"nativeTestMap": {"targets": len(plan["targets"]),
        "classes": sum(len(target["classes"]) for target in plan["targets"]),
        "methods": sum(len(case["methods"]) for target in plan["targets"] for case in target["classes"]),
        "requiredSources": len(plan["contract"]["required_sources"]), "sourceFingerprint": plan["source_fingerprint"]},
        "harnessInputsSha256": snapshot["fingerprint"],
        "domainSourceSha256": snapshot["domain_sources"]["sha256"], "generatedSources": snapshot["generated_sources"]}


def preflight(telegram, *, check_xcode=True):
    errors = source_preflight(telegram)
    versions = json.loads((telegram / "versions.json").read_text(encoding="utf-8"))
    report = {"status": "source-preflight", "requiredXcode": versions["xcode"], "errors": errors,
              "targets": [APPLICATION, HARNESS], "configuration": "debug_sim_arm64",
               "swiftTypechecked": False, "uikitExecuted": False}
    if check_xcode:
        if sys.platform != "darwin" or platform.machine() != "arm64":
            errors.append("macOS arm64/Xcode is required; no native/model fallback")
        else:
            actual = command(["xcodebuild", "-version"], timeout=10).splitlines()[0].removeprefix("Xcode ")
            report["actualXcode"] = actual
            if actual != versions["xcode"]:
                errors.append("Full app graph requires Xcode {}; selected {}. Use {} on the xcode-27 app runner. "
                              "The SDK version check must pass before compiling UIKit.".format(
                                  versions["xcode"], actual, pinned_xcode_app(telegram)))
    if errors:
        report["status"] = "build-blocked"
    return report


def validate_domain_debug_actions(graph_path):
    """Require real compiler definitions for the published Feed and Map entries."""
    graph = json.loads(Path(graph_path).read_text(encoding="utf-8"))
    targets = {str(item["id"]): item["label"] for item in graph.get("targets", [])}
    required = {"//submodules/TelegramCore:TelegramCore": "DEBUG", "//submodules/TelegramUI:TelegramUI": "DEBUG",
                "//submodules/LocationUI:LocationUI": "EXTERALESS_MAP_ATTRIBUTION_FIXTURE"}
    seen = set()
    for action in graph.get("actions", []):
        if not action.get("mnemonic", "").startswith("SwiftCompile"):
            continue
        label = targets.get(str(action.get("targetId")), "")
        owner = next((name for name in required if label.endswith(name)), None)
        if owner is None:
            continue
        args = list(action.get("arguments", []))
        for parameters in action.get("paramFiles", []):
            args.extend(parameters.get("arguments", []))
        definition = required[owner]
        debug = "-D" + definition in args or any(a == "-D" and b == definition for a, b in zip(args, args[1:]))
        if not debug or "-DNDEBUG" in args:
            raise ValueError("Domain render factories require " + definition + " in " + owner)
        seen.add(owner)
    if seen != set(required):
        raise ValueError("Domain DEBUG compile actions missing: " + repr(sorted(set(required) - seen)))
    return {"configuration": "debug_sim_arm64", "debug_modules": sorted(seen), "required_definitions": required}


def build(telegram, output, cache, bazel_root, seconds):
    deadline = time.monotonic() + seconds
    os.chdir(telegram)
    sys.path.insert(0, str(telegram / "build-system/Make"))
    from BazelLocation import locate_bazel
    from Make import BazelCommandLine, resolve_configuration
    from RuntimePackaging import load_staging_manifest, validate_runtime_actions
    from UnsignedBuild import prepare_unsigned_rules, validate_unsigned_actions

    prepare_unsigned_rules(str(telegram))
    bazel = locate_bazel(base_path=str(telegram), cache_host_or_path=None, cache_dir=str(cache))
    line = BazelCommandLine(bazel=bazel, override_bazel_version=False, override_xcode_version=False,
                            bazel_user_root=str(bazel_root))
    resolve_configuration(base_path=str(telegram), bazel_command_line=line,
        arguments=SimpleNamespace(unsigned=True, configurationPath=str(telegram / "build-system/exteraless-configuration.json")),
        additional_codesigning_output_path=None)
    line.set_unsigned()
    line.set_configuration("debug_sim_arm64")
    line.set_build_number("1")  # A fresh device makes installd's same-version cache irrelevant.
    line.add_cache_dir(str(cache))
    manifest = load_staging_manifest(str(telegram))
    native_plan, _ = build_plan(telegram)
    snapshot = harness_inputs(telegram)
    write_json(output / "native-test-plan.json", native_plan)
    write_json(output / "harness-inputs.json", snapshot)
    startup = [bazel, *line.get_startup_bazel_arguments(), "--host_jvm_args=-Xmx4096m", "--max_idle_secs=30"]
    flags = ["--//Telegram:disableProvisioningProfiles", *line.common_args, *line.common_build_args,
             *line.get_define_arguments(), *line.get_additional_build_arguments(), "--disk_cache=" + str(cache),
             *line.configuration_args, "--jobs=2", "--local_resources=cpu=2", "--local_resources=memory=6000"]
    graph = output / "private-actions.json"
    try:
        with (output / "build.log").open("w", encoding="utf-8") as log:
            # The same platform/flags for validation and compilation. Include the
            # whole normal app (six extensions) plus the separate harness app.
            with graph.open("w", encoding="utf-8") as graph_file:
                logged_build_command([*startup, "aquery", "deps(set({} {}))".format(APPLICATION, HARNESS), *flags,
                          "--nobuild", "--output=jsonproto", "--include_artifacts", "--include_commandline",
                          "--include_param_files", "--include_file_write_contents"], cwd=telegram,
                         phase="aquery", output=output, stdout=graph_file, stderr=log, log=log,
                         timeout=min(300, deadline - time.monotonic()))
            unsigned = validate_unsigned_actions(graph)
            runtime = validate_runtime_actions(graph, manifest)
            domain_debug = validate_domain_debug_actions(graph)
            logged_build_command([*startup, "build", APPLICATION, HARNESS, *flags, "--keep_going"], cwd=telegram, stdout=log,
                    phase="build", output=output, log=log,
                    timeout=deadline - time.monotonic())
            ipa = telegram / "bazel-bin/Tests/ExteralessHarness/ClientUIHarness.ipa"
            packaging = verify_ipa(ipa, telegram / "build-input/exteraless/runtime-staging.json", telegram)
            native_resources = {
                "Telegram": verify_native_bundle_resources(telegram / "bazel-bin/Telegram/Telegram.ipa", telegram, "Telegram"),
                "ClientUIHarness": verify_native_bundle_resources(ipa, telegram, "ClientUIHarness"),
            }
            write_json(output / "native-bundle-resources.json", native_resources)
            with zipfile.ZipFile(ipa) as archive:
                domain_sources = manifest_from_ipa(archive, APP_ROOT, VISUAL_SCENARIOS + MAP_SCENARIOS)
            if (domain_sources != snapshot["domain_sources"] or harness_inputs(telegram) != snapshot
                    or build_plan(telegram)[0] != native_plan or load_staging_manifest(telegram) != manifest):
                raise ValueError("Compiled acceptance manifest/source/staging differs from its declared snapshot")
            # Later test builds can repoint bazel-bin. Freeze the verified archive
            # once so every serial recording batch consumes these bytes.
            retained_ipa = output / "ClientUIHarness.ipa"
            shutil.copyfile(ipa, retained_ipa)
            if digest(retained_ipa) != packaging["ipaSha256"]:
                raise ValueError("Retained harness IPA differs from the verified build output")
            write_json(output / "domain-source-fingerprints.json", domain_sources)
            write_json(output / "build-result.json", {"status": "built", "configuration": "debug_sim_arm64",
                "targets": [APPLICATION, HARNESS], "unsigned": unsigned, "runtime": runtime,
                "domainDebug": domain_debug, "domainSources": domain_sources,
                "buildSelection": BUILD_SELECTION,
                "nativeTestPlan": native_plan,
                "acceptanceIdentity": acceptance_identity(native_plan, snapshot, manifest, packaging["ipaSha256"]),
                "driverSha256": snapshot["input_sha256"]["tools/runtime/client_ui_harness.py"],
                "nativeResources": native_resources,
                "packaging": packaging, "ipa": str(retained_ipa), "visualReview": "not-run"})
    finally:
        # aquery can contain generated configuration file contents; publish only
        # structural reports and compilation diagnostics.
        graph.unlink(missing_ok=True)
        try:
            command([*startup, "shutdown"], timeout=20)
        except Exception:
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--telegram-root", type=Path, default=ROOT / "telegram-ios")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--bazel-root", type=Path)
    parser.add_argument("--phase", choices=("preflight", "build"), default="build")
    parser.add_argument("--source-only", action="store_true", help="Only with preflight; no compiler or build claim")
    parser.add_argument("--build-seconds", type=int, default=6600)
    args = parser.parse_args()
    if args.source_only and args.phase != "preflight":
        parser.error("--source-only never permits a build without Xcode")
    if not 1 <= args.build_seconds <= 6600:
        parser.error("Build deadline must be 1...6600 seconds")
    telegram, output = args.telegram_root.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    result = preflight(telegram, check_xcode=not args.source_only)
    if not result["errors"]:
        result.update(declaration_preflight(telegram, source_checkout=args.phase == "preflight"))
    write_json(output / "preflight.json", result)
    if result["errors"]:
        raise SystemExit("UI HARNESS BUILD BLOCKED:\n" + "\n".join(result["errors"]))
    if args.phase == "build":
        if args.cache is None or args.bazel_root is None:
            parser.error("--cache and --bazel-root are required for the build phase")
        build(telegram, output, args.cache.resolve(), args.bazel_root.resolve(), args.build_seconds)


if __name__ == "__main__":
    main()
