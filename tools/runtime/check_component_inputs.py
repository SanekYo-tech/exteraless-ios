"""Inventory Python Framework's current source/plumbing inputs and sparse coverage.

Reads declarations and source receipts only. No Apple compiler, simulator, corpus
execution or final IPA source freeze is involved. Cone membership includes files
directly in ancestors, exactly as Git's cone-mode sparse checkout does.
"""

import argparse
import ast
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = '.github/workflows/python-framework.yml'
UI = 'telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI'
TL_FIXTURE_RUNNER = 'tools/compat/tests/tl_bridge/run_native_fixtures.py'
UI_FIXTURE_RUNNER = UI + '/Tests/run_fixture.py'
UI_REMEDIATION_RUNNER = UI + '/Tests/run_remediation_fixture.py'
JAVA_FIXTURE_RUNNER = 'tools/runtime/check_java_tl_codec.py'
SKIP_DIRS = {'.git', '.build', '.pytest_cache', '__pycache__', 'build', 'dist'}


def sparse_cones(text):
    blocks, result, indentation = 0, [], None
    for line in text.splitlines():
        if line.strip() == 'sparse-checkout: |':
            blocks += 1
            indentation = len(line) - len(line.lstrip())
            continue
        if indentation is not None and line.strip():
            if len(line) - len(line.lstrip()) <= indentation:
                indentation = None
            elif not line.lstrip().startswith('#'):
                value = line.strip()
                if value.startswith('/') or '..' in value.split('/') or any(c in value for c in '*?[]\\'):
                    raise ValueError('Expected literal sparse checkout directory: ' + value)
                result.append(value.rstrip('/'))
    if blocks != 1 or not result or 'sparse-checkout-cone-mode: false' in text:
        raise ValueError('Expected one cone-mode sparse checkout block')
    return result


def covered_by(path, cones):
    path = PurePosixPath(path)
    for value in cones:
        cone = PurePosixPath(value)
        if path.is_relative_to(cone):
            return {'cone': value, 'kind': 'recursive'}
        if path.parent in cone.parents:
            return {'cone': value, 'kind': 'ancestor-file'}
    return None


@contextmanager
def module_at(name, path):
    previous = sys.path[:]
    try:
        sys.path.insert(0, str(path.parent))
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        yield module
    finally:
        sys.path[:] = previous


def fixture_compiler_inputs():
    """Read the same declarations the fixture compilers actually consume."""
    from check_java_tl_codec import COMPILE_SOURCES
    from sdk_followup_inputs import (DEVELOPER_NATIVE_TEST, developer_native_sources,
        NATIVE_FILES_TEST, NATIVE_INGRESS_TEST, NATIVE_MODE_TEST, host_compile_inputs,
        ingress_native_sources, mode_aba_native_sources)
    result = {JAVA_FIXTURE_RUNNER: [ROOT / name for name in COMPILE_SOURCES]}
    result[DEVELOPER_NATIVE_TEST] = developer_native_sources()
    result[NATIVE_FILES_TEST] = host_compile_inputs(tests=True)
    result[NATIVE_INGRESS_TEST] = host_compile_inputs(tests=False) + ingress_native_sources()
    result[NATIVE_MODE_TEST] = host_compile_inputs(tests=False) + mode_aba_native_sources()
    with module_at('component_tl_fixture_inputs', ROOT / TL_FIXTURE_RUNNER) as runner:
        result[TL_FIXTURE_RUNNER] = list(runner.SOURCE_NAMES)
    with module_at('component_ui_remediation_inputs', ROOT / UI_REMEDIATION_RUNNER) as runner:
        result[UI_REMEDIATION_RUNNER] = [runner.UI / name for name in runner.SOURCES]
    tree = ast.parse((ROOT / UI_FIXTURE_RUNNER).read_text(encoding='utf-8'))
    assignments = [node for node in ast.walk(tree) if isinstance(node, ast.Assign)
                   and any(isinstance(target, ast.Name) and target.id == 'sources' for target in node.targets)]
    if len(assignments) != 1 or not isinstance(assignments[0].value, ast.ListComp):
        raise ValueError('Review changed Foundation UI fixture source declaration')
    result[UI_FIXTURE_RUNNER] = [ROOT / UI / name
        for name in ast.literal_eval(assignments[0].value.generators[0].iter)]
    for runner, sources in result.items():
        if not sources or len(sources) != len(set(sources)):
            raise ValueError('Empty/duplicate fixture compiler inputs: ' + runner)
    return result


def inventory(*, compiler_inputs=None, records=None):
    from check_java_tl_codec import source_fingerprint as java_inputs
    from check_swift_plugin_embedding import (JAVA_COHORT_INPUTS, JAVA_RUNTIME_INPUTS,
        ARCHIVE_SWIFT_PROBE, ARCHIVE_HELPER, ARCHIVE_FIXTURE_EMITTER, ARCHIVE_PYTHON_INPUTS, SDK_TL_CODEC_SOURCES)
    from sdk_followup_inputs import (SDK_PYTESTS, SWIFTPM_FOLLOWUP_TESTS, NATIVE_CANDIDATE_TEST,
        NATIVE_CANDIDATE_INPUTS, NATIVE_DEVELOPER_TESTS)
    from fixtures import elyx_developer_probe_driver
    from client_ui_harness_inputs import harness_inputs
    from native_test_plan import Declarations, build_plan
    from prepare_telegram_runtime import application_resources, source_inventory
    from UnsignedBuild import RULES_APPLE_REVISION
    sys.path.insert(0, str(ROOT))
    from tools.compat.sdk_config_manifest import CLIENT_ROOT, root_registration

    deadline = time.monotonic() + 30
    files = records if records is not None else {}
    def add(paths, consumer):
        for path in paths:
            if time.monotonic() >= deadline:
                raise TimeoutError('Component input inventory exceeded 30 seconds')
            path = Path(path)
            if not path.is_absolute():
                path = ROOT / path
            relative = path.relative_to(ROOT).as_posix()
            if relative not in files:
                if not path.is_file():
                    raise ValueError('Missing component source input: ' + relative)
                with path.open('rb') as stream:
                    sha = hashlib.file_digest(stream, 'sha256').hexdigest()
                files[relative] = {'sha256': sha, 'bytes': path.stat().st_size, 'consumers': []}
            if consumer not in files[relative]['consumers']:
                files[relative]['consumers'].append(consumer)

    add([WORKFLOW, 'tools/runtime/check_component_inputs.py'], 'component-preflight')
    compiler_inputs = fixture_compiler_inputs() if compiler_inputs is None else compiler_inputs
    for runner, sources in compiler_inputs.items():
        add([runner, *sources], 'compiler:' + runner)
    add(['.gitmodules', 'telegram-ios/.gitmodules'], 'component-gitlink-bootstrap')
    add(source_inventory(ROOT), 'relocated-runtime-public-inputs')
    for directory in ('python/runtime', 'python/virtualjava', 'python/sdk', 'python/exteraless_runtime',
                      'swift/PluginHost', 'swift/PluginHooks', 'swift/ExteralessCore',
                      'tools/runtime', 'tools/ci', 'tools/compat', 'telegram-ios/build-system/Make'):
        for parent, dirs, names in os.walk(ROOT / directory):
            dirs[:] = [name for name in dirs if name not in SKIP_DIRS]
            add((Path(parent) / name for name in names if Path(name).suffix in (
                '.py', '.swift', '.c', '.h', '.modulemap', '.json', '.plugin', '.bzl')
                or name in ('BUILD', 'BUILD.bazel')), directory)
    add(JAVA_COHORT_INPUTS, 'native-sdk-children/java-receipt')
    add(('python/' + path for path in JAVA_RUNTIME_INPUTS), 'native-sdk-children/java-adapter')
    add([ARCHIVE_SWIFT_PROBE, ARCHIVE_HELPER, ARCHIVE_FIXTURE_EMITTER], 'fourth-native-sdk-child/owned-archives')
    add(SDK_TL_CODEC_SOURCES, 'native-sdk-children/actual-compiled-tl-codec')
    add(('python/' + path for path in ARCHIVE_PYTHON_INPUTS), 'fourth-native-sdk-child/production-archive-inputs')
    add(elyx_developer_probe_driver.source_inputs(ROOT / 'python'), 'fifth-native-sdk-child/actual-readiness-fd-inputs')
    add(['docs/wave-2/native-elyx-developer-final-inputs.json', 'tools/runtime/verify_native_sdk_cohort.py'],
        'five-native-sdk-children/final-evidence-contract')
    add(SDK_PYTESTS, 'bounded-sdk-followup-pytests')
    add(NATIVE_DEVELOPER_TESTS, 'bounded-native-files-ingress-readiness-selectors')
    add(SWIFTPM_FOLLOWUP_TESTS, 'automatic-swiftpm-followup-tests')
    add([NATIVE_CANDIDATE_TEST, *NATIVE_CANDIDATE_INPUTS], 'darwin-native-archive-candidate')
    pins = {}
    registration = root_registration(pins)
    add(pins, 'native-sdk-children/root-registration')
    add([CLIENT_ROOT.replace('ExteralessClientRuntime.swift', 'ClientSettingsBridgeExtension.swift')],
        'native-sdk-children/compiled-config-provider')
    add(java_inputs(ROOT), 'java-foundation-tl-codec')
    with module_at('component_ui_fixture', ROOT / UI_REMEDIATION_RUNNER) as ui:
        add(ui.source_inventory(), 'ui-remediation-23')
        receipt = json.loads((ROOT / ui.POSTIMAGE_MANIFEST).read_text(encoding='utf-8'))
        add(receipt['files'], 'ui-remediation-postimage')
        add((pin['path'] for pin in receipt['regions']), 'ui-remediation-postimage-region')
        postimage = ui.verify_postimage(ROOT)
        completion = ui.COMPLETION
    actual = set(compiler_inputs[UI_FIXTURE_RUNNER])
    declarations = Declarations(ROOT / 'telegram-ios', source_checkout=True)
    package, _, group = declarations.rule('//submodules/TelegramUI:ExteralessNativeUIContractSources')
    declared = set(declarations.sources(group['srcs'], package)) | {ROOT / UI / 'Tests/PluginUIFixture.swift'}
    if actual != declared:
        raise ValueError('Foundation UI driver and declared source filegroup inputs differ')
    add([ROOT / UI_FIXTURE_RUNNER, *actual], 'foundation-ui-contracts')
    # The unit tests of the native planner read fixture declarations, not just
    # the helper's Python file. Keep this inventory separate from an IPA freeze;
    # no aggregate XCTest plan or method total is emitted here.
    plan, paths = build_plan(ROOT / 'telegram-ios', source_checkout=True)
    add(paths.values(), 'native-planner-unittests')
    add(harness_inputs(ROOT / 'telegram-ios', source_checkout=True)['input_sha256'],
        'uikit-source-contract-unittests/actual-harness-inputs')
    tbf = '//Tests/Exteraless:RuntimeRecoveryContinuationTests'
    if plan['contract']['required_sources'].get('Tests/Exteraless/RuntimeRecoveryContinuationTests.swift') != tbf:
        raise ValueError('Missing published TBF05 native source binding')
    if not any(target['label'] == tbf for target in plan['targets']):
        raise ValueError('TBF05 native target is outside IntegrationTests')
    add(['telegram-ios/build-system/bazel-rules/rules_apple/apple/internal/ios_rules.bzl',
         'telegram-ios/build-system/patches/unsigned-rules-apple.patch',
         'telegram-ios/build-system/exteraless-configuration.json',
         'telegram-ios/build-system/exteraless/runtime-assets.json',
         'telegram-ios/third-party/exteraless/BUILD',
         'telegram-ios/third-party/exteraless/runtime.BUILD.bazel'], 'unsigned/runtime-plumbing')
    add(('telegram-ios/' + item['source'] for item in application_resources(ROOT / 'telegram-ios').values()),
        'pinned-main-bundle-resources')
    public_groups = {}
    outer = Declarations(ROOT)
    for build in ('BUILD.bazel', 'swift/PluginHost/BUILD.bazel', 'swift/PluginHooks/BUILD.bazel',
                  'swift/ExteralessCore/BUILD.bazel', 'python/runtime/BUILD.bazel'):
        package = Path(build).parent.as_posix()
        for node in ast.parse((ROOT / build).read_text(encoding='utf-8')).body:
            if not isinstance(node, ast.Expr) or not isinstance(node.value, ast.Call):
                continue
            call = node.value
            attrs = {item.arg: item.value for item in call.keywords}
            if isinstance(call.func, ast.Name) and call.func.id == 'filegroup':
                name = '//' + ('' if package == '.' else package) + ':' + ast.literal_eval(attrs['name'])
                inputs = outer.sources(attrs['srcs'], '' if package == '.' else package)
                add(inputs, name)
                public_groups[name] = [path.relative_to(ROOT).as_posix() for path in inputs]
            elif isinstance(call.func, ast.Name) and call.func.id == 'exports_files':
                add((Path(package) / value for value in ast.literal_eval(call.args[0])), 'public-exports:' + build)
    return files, {'root_registration': registration, 'ui_postimage': postimage,
                   'ui_completion': completion, 'tbf05_native_label': tbf, 'public_filegroups': public_groups,
                   'required_gitlinks': {'telegram-ios/build-system/bazel-rules/rules_apple': {
                       'commit': RULES_APPLE_REVISION,
                       'cones': ['apple/internal', 'apple/testing/default_runner'],
                   }}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('--output must be a new receipt; existing inventories are not overwritten')
    result = {'schema': 2, 'status': 'not-checked', 'native_execution_verified': False,
              'compiler_input_contract': 'runner-declarations-v2', 'source_files': {},
              'scope': 'Python Framework component inputs; not an IPA source freeze',
              'generated_inputs': {
                  'python/vendor/exteraless-dependencies.json': 'vendor_dependencies.py step before SDK audit-path pytests and native children',
                   'SDKConfigRootRegistration.swift': 'check_swift_plugin_embedding.py from the inspected shipping root expression',
                    'owned archive ZIP/wheel fixtures': 'test_ios_elyx_archives.py --emit-fixtures; fourth isolated native child',
                    'owned developer ZIP/JSON fixtures': 'emit_elyx_developer_probe.py; six bounded inputs for the fifth child',
                  'CPython support slices': 'support.py fetch using support-lock.json before simulator/device compilation',
              }}
    try:
        cones = sparse_cones((ROOT / WORKFLOW).read_text(encoding='utf-8'))
        compiler_inputs = fixture_compiler_inputs()
        result['fixture_compiler_inputs'] = {runner: [path.relative_to(ROOT).as_posix() for path in paths]
                                             for runner, paths in compiler_inputs.items()}
        files, details = inventory(compiler_inputs=compiler_inputs, records=result['source_files'])
        missing = []
        for name, record in files.items():
            record['sparse'] = covered_by(name, cones)
            if record['sparse'] is None:
                missing.append(name)
        result.update(details, sparse_cones=cones, source_files=files, missing_sparse=missing,
                      status='missing-inputs' if missing else 'inputs-covered')
        print(json.dumps({'status': result['status'], 'component_source_files': len(files),
                          'missing_sparse_directories': sorted({str(PurePosixPath(name).parent) for name in missing})}, indent=2))
        return 1 if missing else 0
    except (OSError, ValueError, TimeoutError) as error:
        result.update(status='failed', error=str(error))
        raise
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open('x', encoding='utf-8') as receipt:
            receipt.write(json.dumps(result, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    raise SystemExit(main())
