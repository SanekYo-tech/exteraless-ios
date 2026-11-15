#!/usr/bin/env python3
"""Build full Telegram + the loginless UIKit app with the repository's Bazel plumbing.

This intentionally does not call unsupported Make.py per-library builds. It
reuses Make's configuration/flags, its exact unsigned rules patch and its full
app/runtime aquery validators. Both top-level ios_application targets are built
in the same debug_sim_arm64 graph. Run only in a disposable CI source copy.
"""

from __future__ import annotations

import argparse
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

ROOT = Path(__file__).resolve().parents[2]
HARNESS = "//Tests/ExteralessHarness:ClientUIHarness"
APPLICATION = "//Telegram:Telegram"


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
        "Tests/ExteralessHarness/BUILD": ['name = "DomainSourceManifest"', '":DomainSourceManifest"'],
    }
    errors = []
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
    for target in ("MtProtoKitFramework", "SwiftSignalKitFramework", "PostboxFramework", "TelegramCoreFramework", "TelegramUIFramework"):
        block = re.search(r'^ios_framework\(\s*name\s*=\s*"' + target + r'".*?^\)', framework_build, re.M | re.S)
        if block is None or not any(label in block[0] for label in (
                '"//visibility:public"', '"//Tests:__subpackages__"', '"//Tests/ExteralessHarness:__pkg__"')):
            errors.append("Telegram/BUILD: " + target + " needs visibility for //Tests/ExteralessHarness:__pkg__")
    return errors


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
    """The published Feed factories are compiled only in DEBUG app modules."""
    graph = json.loads(Path(graph_path).read_text(encoding="utf-8"))
    targets = {str(item["id"]): item["label"] for item in graph.get("targets", [])}
    required = {"//submodules/TelegramCore:TelegramCore", "//submodules/TelegramUI:TelegramUI"}
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
        debug = "-DDEBUG" in args or any(a == "-D" and b == "DEBUG" for a, b in zip(args, args[1:]))
        if not debug or "-DNDEBUG" in args:
            raise ValueError("Domain render factories require DEBUG in " + owner)
        seen.add(owner)
    if seen != required:
        raise ValueError("Domain DEBUG compile actions missing: " + repr(sorted(required - seen)))
    return {"configuration": "debug_sim_arm64", "debug_modules": sorted(seen)}


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
                command([*startup, "aquery", "deps(set({} {}))".format(APPLICATION, HARNESS), *flags,
                         "--nobuild", "--output=jsonproto", "--include_artifacts", "--include_commandline",
                         "--include_param_files", "--include_file_write_contents"], cwd=telegram,
                        stdout=graph_file, stderr=log, log=log, timeout=min(300, deadline - time.monotonic()))
            unsigned = validate_unsigned_actions(graph)
            runtime = validate_runtime_actions(graph, manifest)
            domain_debug = validate_domain_debug_actions(graph)
            command([*startup, "build", APPLICATION, HARNESS, *flags], cwd=telegram, stdout=log,
                    timeout=deadline - time.monotonic())
            ipa = telegram / "bazel-bin/Tests/ExteralessHarness/ClientUIHarness.ipa"
            packaging = verify_ipa(ipa, telegram / "build-input/exteraless/runtime-staging.json", telegram)
            with zipfile.ZipFile(ipa) as archive:
                domain_sources = manifest_from_ipa(archive, APP_ROOT)
            # Later test builds can repoint bazel-bin. Freeze the verified archive
            # once so both serial recording batches consume exactly these bytes.
            retained_ipa = output / "ClientUIHarness.ipa"
            shutil.copyfile(ipa, retained_ipa)
            if digest(retained_ipa) != packaging["ipaSha256"]:
                raise ValueError("Retained harness IPA differs from the verified build output")
            write_json(output / "domain-source-fingerprints.json", domain_sources)
            write_json(output / "build-result.json", {"status": "built", "configuration": "debug_sim_arm64",
                "targets": [APPLICATION, HARNESS], "unsigned": unsigned, "runtime": runtime,
                "domainDebug": domain_debug, "domainSources": domain_sources,
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
    write_json(output / "preflight.json", result)
    if result["errors"]:
        raise SystemExit("UI HARNESS BUILD BLOCKED:\n" + "\n".join(result["errors"]))
    if args.phase == "build":
        if args.cache is None or args.bazel_root is None:
            parser.error("--cache and --bazel-root are required for the build phase")
        build(telegram, output, args.cache.resolve(), args.bazel_root.resolve(), args.build_seconds)


if __name__ == "__main__":
    main()
