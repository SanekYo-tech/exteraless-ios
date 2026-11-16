"""Bounded source/command identity for the existing UIKit app and its stubs."""

import ast
import hashlib
import json
from pathlib import Path
import runpy

from check_bazel_imports import normalized_label
from native_test_plan import digest, glob_sources, source_inventory_fingerprint
from client_ui_harness_domains import check_manifest
from client_ui_harness_visuals import VISUAL_SCENARIOS, check_visual_sources
from client_ui_harness_supplements import SUPPLEMENT_SCENARIOS, check_sources as check_supplement_sources

ROOT = Path(__file__).resolve().parents[2]
TOOLS = (
    '.github/workflows/client-ui-harness.yml',
    'tools/runtime/client_ui_harness.py', 'tools/runtime/client_ui_harness_domains.py',
    'tools/runtime/client_ui_control_frames.py',
    'tools/runtime/client_ui_harness_supplements.py', 'tools/runtime/verify_client_ui_supplements.py',
    'tools/runtime/client_ui_harness_map.py', 'tools/runtime/native_fd_evidence.py',
    'tools/runtime/client_ui_harness_visuals.py', 'tools/runtime/client_ui_harness_build.py',
    'tools/runtime/client_ui_harness_inputs.py', 'tools/runtime/client_ui_harness_workspace.py',
    'tools/runtime/client_ui_harness_tools.py', 'tools/runtime/record_client_ui_batch.py',
    'tools/runtime/native_test_plan.py', 'tools/runtime/run_native_integration_tests.py',
    'tools/runtime/native_test_resources.py', 'tools/runtime/native_bundle_resources.py',
    'tools/runtime/native_test_disk.py', 'tools/runtime/native_test_cache.py',
    'tools/runtime/verify_client_ui_batches.py',
)


def harness_inputs(telegram, *, source_checkout=False):
    telegram = Path(telegram).resolve()
    external = telegram.parent if source_checkout else telegram / 'build-input/exteraless'
    inputs, domain_files, generated, rules = {}, {}, {}, {}
    source_key = runpy.run_path(str(telegram / 'Tests/ExteralessHarness/Tools/domain_source_manifest.py'))['source_key']

    def record(path, *, domain=False):
        path = Path(path)
        if not path.is_file() or path.stat().st_size > 8 * 1024 * 1024:
            raise ValueError('Missing/unbounded harness input: ' + str(path))
        logical = ('telegram-ios/' + path.relative_to(telegram).as_posix()
                   if path.is_relative_to(telegram) and not path.is_relative_to(external)
                   else path.relative_to(external).as_posix())
        inputs[logical] = digest(path)
        if domain:
            domain_files[source_key(path)] = inputs[logical]
        if len(inputs) > 2000:
            raise ValueError('Harness source identity exceeded its bound')
        return logical

    def rule(target, workspace=telegram, package=''):
        if target.startswith('@exteraless//'):
            target, workspace = target.removeprefix('@exteraless'), external
        if target.startswith(':'):
            target = '//' + package + target
        target = normalized_label(target)
        package, name = target[2:].split(':', 1)
        key = workspace, package
        if key not in rules:
            path = workspace / package / 'BUILD'
            if not path.is_file():
                path = path.with_name('BUILD.bazel')
            record(path)
            found = {}
            for node in ast.parse(path.read_text(encoding='utf-8')).body:
                if not isinstance(node, ast.Expr) or not isinstance(node.value, ast.Call):
                    continue
                call = node.value
                attrs = {item.arg: item.value for item in call.keywords}
                if isinstance(call.func, ast.Name) and isinstance(attrs.get('name'), ast.Constant):
                    found[attrs['name'].value] = call.func.id, attrs
            rules[key] = found
        if name not in rules[key] and (workspace / package / name).is_file():
            return workspace, package, "source_file", {"path": workspace / package / name}
        return workspace, package, *rules[key][name]

    def sources(value, workspace, package, seen=()):
        if isinstance(value, (ast.List, ast.Tuple)):
            for item in value.elts:
                sources(item, workspace, package, seen)
        elif isinstance(value, ast.BinOp) and isinstance(value.op, ast.Add):
            sources(value.left, workspace, package, seen)
            sources(value.right, workspace, package, seen)
        elif isinstance(value, ast.Call) and isinstance(value.func, ast.Name) and value.func.id == 'glob':
            for path in glob_sources(workspace / package, value):
                record(path, domain=True)
        elif isinstance(value, ast.Constant) and isinstance(value.value, str):
            name = value.value
            if not name.startswith((':', '//', '@exteraless//')):
                record(workspace / package / name, domain=True)
                return
            child, child_package, kind, attrs = rule(name, workspace, package)
            if kind == 'source_file':
                record(attrs['path'], domain=True)
                return
            key = str(child / child_package) + ':' + ast.literal_eval(attrs['name'])
            if key in seen:
                raise ValueError('Cycle in harness fingerprint sources')
            if kind == 'filegroup':
                sources(attrs['srcs'], child, child_package, (*seen, key))
            elif kind == 'genrule' and child_package == 'Tests/ExteralessHarness' and ast.literal_eval(attrs['name']) == 'ContextStubs':
                generator = telegram / 'Tests/ExteralessHarness/Tools/generate_context_stubs.py'
                protocol = telegram / 'submodules/AccountContext/Sources/AccountContext.swift'
                declared = ast.literal_eval(attrs['srcs'])
                if declared != ['Tools/generate_context_stubs.py', '//submodules/AccountContext:ClientHarnessProtocolSource']:
                    raise ValueError('ContextStubs input declaration changed')
                outputs = ast.literal_eval(attrs['outs'])
                if outputs != ['ClientHarnessContext+Generated.swift']:
                    raise ValueError('ContextStubs output declaration changed')
                record(generator, domain=True)
                record(protocol, domain=True)
                data = runpy.run_path(str(generator))['generate'](protocol.read_text(encoding='utf-8')).encode('utf-8')
                logical = 'telegram-ios/Tests/ExteralessHarness/' + outputs[0]
                domain_files[logical] = hashlib.sha256(data).hexdigest()
                generated[logical] = {'sha256': domain_files[logical], 'size': len(data),
                                     'command': ast.literal_eval(attrs['cmd']), 'inputs': declared}
            else:
                raise ValueError('Unsupported harness source producer: ' + key)
        else:
            raise ValueError('Unsupported harness source expression in ' + package)

    workspace, package, _, attrs = rule('//Tests/ExteralessHarness:DomainFingerprintInputs')
    sources(attrs['srcs'], workspace, package)
    for relative in ('MODULE.bazel', 'MODULE.bazel.lock', 'versions.json',
                     'build-system/exteraless/native-bundle-resources.json',
                     'build-system/Make/NativeBundleResources.py'):
        record(telegram / relative)
    # The bundled trusted helper and the one copied plugin method must match
    # the current coordinator-owned smoke sources, never a cached older copy.
    helper_source = 'python/runtime/smoke/native_plugin_probe.py'
    wave_source = 'python/runtime/smoke/plugins/native_wave_probe.plugin'
    helper_copy = telegram / 'Tests/ExteralessHarness/Fixtures/native_plugin_probe.py'
    if digest(helper_copy) != digest(ROOT / helper_source):
        raise ValueError('UIKit FD helper differs from current native_plugin_probe source')
    def fd_method(path):
        tree = ast.parse(path.read_text(encoding='utf-8'))
        return ast.dump(next(node for node in ast.walk(tree)
                             if isinstance(node, ast.FunctionDef) and node.name == 'fd_family_probe'), include_attributes=False)
    if fd_method(ROOT / wave_source) != fd_method(telegram / 'Tests/ExteralessHarness/Fixtures/client_ui_fixture.plugin'):
        raise ValueError('UIKit FD method differs from the actual nativeWaveProbe operation')
    inputs[helper_source] = digest(ROOT / helper_source)
    inputs[wave_source] = digest(ROOT / wave_source)
    for name in TOOLS:
        inputs[name] = digest(ROOT / name)
    manifest = {'format': 'exteraless-ui-domain-sources/1', 'files': domain_files,
                'sha256': source_inventory_fingerprint(domain_files)}
    check_manifest(manifest)
    check_visual_sources(manifest, VISUAL_SCENARIOS)
    check_supplement_sources(manifest, SUPPLEMENT_SCENARIOS)
    payload = {'schema': 1, 'input_sha256': dict(sorted(inputs.items())),
               'generated_sources': generated, 'domain_sources': manifest}
    payload['fingerprint'] = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return payload


def acceptance_identity(plan, harness, staging, ipa_sha256):
    return {'nativePlanSha256': plan['source_fingerprint'], 'harnessInputsSha256': harness['fingerprint'],
            'stagingSourceSha256': source_inventory_fingerprint(staging['source_files']), 'ipaSha256': ipa_sha256}


def require_build_identity(build, plan, harness, staging, ipa):
    identity = acceptance_identity(plan, harness, staging, digest(ipa))
    if (build.get('acceptanceIdentity') != identity or build.get('nativeTestPlan') != plan
            or build.get('domainSources') != harness['domain_sources']
            or build.get('packaging', {}).get('ipaSha256') != identity['ipaSha256']):
        raise ValueError('Native/recording inputs differ from the single compiled acceptance snapshot')
    return identity
