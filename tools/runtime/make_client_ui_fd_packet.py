"""Emit, but never apply, the small owner-worker FD join for the distinct UIKit fixture."""

import argparse
import ast
import difflib
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HELPER = 'python/runtime/smoke/native_plugin_probe.py'
WAVE = 'python/runtime/smoke/plugins/native_wave_probe.plugin'
UI = 'telegram-ios/Tests/ExteralessHarness/'


def replace_once(text, before, after):
    if text.count(before) != 1:
        raise ValueError('Coordinator source moved; refresh this exact FD join: ' + before[:120])
    return text.replace(before, after, 1)


def build_packet(root=ROOT):
    root = Path(root)
    read = lambda name: (root / name).read_text(encoding='utf-8')
    helper, wave = read(HELPER), read(WAVE)
    tree = ast.parse(wave)
    cls = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == 'NativeWaveProbe')
    method = next(node for node in cls.body if isinstance(node, ast.FunctionDef) and node.name == 'fd_family_probe')
    method_source = ''.join(wave.splitlines(keepends=True)[method.lineno-1:method.end_lineno])
    before, after = {}, {UI + 'Fixtures/native_plugin_probe.py': helper}
    def change(name, transform):
        before[name] = read(name)
        after[name] = transform(before[name])

    change(UI + 'Fixtures/client_ui_fixture.plugin', lambda text: replace_once(text,
        '    def owner(self):', method_source + '\n    def owner(self):'))
    change(UI + 'BUILD', lambda text: text.replace('        "Fixtures/client_ui_fixture.plugin",',
        '        "Fixtures/client_ui_fixture.plugin",\n        "Fixtures/native_plugin_probe.py",'))
    engine = UI + 'Sources/ClientHarnessNativeObservation.swift'
    def engine_join(text):
        text = replace_once(text, '/// Transparent native engine forwarder. No source injection, interpreter\n/// replacement, rendered pixels, or fabricated return values.',
            '/// Host sources are forwarded exactly once. Two separately counted FD-helper\n/// calls follow each real plugin load on the same owner worker; no backend replacement.')
        text = replace_once(text, '    private var scriptCalls = 0',
            '    private var scriptCalls = 0\n    private var fdProbeScriptCalls = 0\n    private var fdPaths: [[String: Any]] = []')
        text = replace_once(text, '        return try self.native.runScript(reference, source)', r'''        let result = try self.native.runScript(reference, source)
        if source.hasPrefix("_exteraless_runtime.load_json(") {
            guard let helper = Bundle.main.url(forResource: "native_plugin_probe", withExtension: "py") else {
                throw ClientHarnessFailure(description: "missing bundled actual FD helper")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let helperPath = String(decoding: try encoder.encode(helper.path), as: UTF8.self)
            _ = try self.native.runScript(reference, """
            import importlib.util as _fd_import, sys as _fd_sys, json as _fd_json, hashlib as _fd_hash, _thread as _fd_thread
            from extera_utils import plugin_loader as _fd_loader
            from base_plugin import PythonBridge as _fd_bridge
            import exteraless_runtime as _fd_runtime, _exteraless_bridge as _fd_native
            if _fd_sys.platform != "ios":
                raise AssertionError("UIKit FD witness requires actual sys.platform ios")
            _fd_spec = _fd_import.spec_from_file_location("_client_ui_native_fd", \(helperPath))
            _fd_module = _fd_import.module_from_spec(_fd_spec)
            _fd_spec.loader.exec_module(_fd_module)
            _fd_record = _fd_loader.plugins["clientUIFixture"]
            if _fd_runtime._state.plugin_id != "clientUIFixture" or _fd_record.instance.worker != _fd_thread.get_ident():
                raise AssertionError("FD witness left the actual UIKit plugin owner")
            with _fd_loader.plugin_context("clientUIFixture"):
                _fd_module._probe_darwin_family_fds(_fd_record, _fd_bridge.getCacheDir())
            with open(\(helperPath), "rb") as _fd_input:
                _fd_digest = _fd_hash.file_digest(_fd_input, "sha256").hexdigest()
            _fd_observation = {"platform": _fd_sys.platform, "checks": dict(_fd_module._sdk_checks),
                "nativeReference": \(reference.raw), "ownerToken": _fd_runtime._state.owner_token,
                "helperSHA256": _fd_digest, "bridgeBuiltin": _fd_native.__spec__.origin == "built-in"}
            """)
            let json = try self.native.runScript(reference, "_fd_json.dumps(_fd_observation)")
            guard let data = json.data(using: .utf8),
                  let observation = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  observation["platform"] as? String == "ios",
                  let checks = observation["checks"] as? [String: Bool], checks["actual_ios_fd_paths"] == true else {
                throw ClientHarnessFailure(description: "actual iOS FD operations did not complete")
            }
            self.lock.lock()
            self.fdProbeScriptCalls += 2
            self.fdPaths.append(observation)
            self.lock.unlock()
        }
        return result''')
        return replace_once(text, '            "allDestroyed": !self.created.isEmpty && self.created == self.destroyed]',
            '            "allDestroyed": !self.created.isEmpty && self.created == self.destroyed,\n'
            '            "fdProbeScriptCalls": self.fdProbeScriptCalls, "fdPaths": self.fdPaths]')
    change(engine, engine_join)
    change(UI + 'Sources/ClientHarnessScenarios.swift', lambda text: replace_once(text,
        '        guard let runtime = self.runtime else { throw ClientHarnessFailure(description: "native runtime missing") }',
        '        guard let runtime = self.runtime else { throw ClientHarnessFailure(description: "native runtime missing") }\n'
        '        try self.loadDomainSourceEvidence()'))

    def input_join(text):
        text = replace_once(text, "    'tools/runtime/client_ui_harness_map.py',",
            "    'tools/runtime/client_ui_harness_map.py', 'tools/runtime/native_fd_evidence.py',")
        return replace_once(text, "    for name in TOOLS:\n        inputs[name] = digest(ROOT / name)", '''    # The bundled trusted helper and the one copied plugin method must match
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
        inputs[name] = digest(ROOT / name)''')
    change('tools/runtime/client_ui_harness_inputs.py', input_join)
    def validation_join(text):
        text = replace_once(text, 'from client_ui_harness_map import MAP_SCENARIOS, validate_map, map_recording_evidence',
            'from client_ui_harness_map import MAP_SCENARIOS, validate_map, map_recording_evidence\n'
            'from native_fd_evidence import validate_ios_fd_observations')
        return replace_once(text, '            raise ValueError("Reload did not use fresh observed C/Host epochs")',
            '            raise ValueError("Reload did not use fresh observed C/Host epochs")\n'
            '        validate_ios_fd_observations(engine, epochs, check_manifest(state.get("facts", {}).get("domainSources", {})))')
    change('tools/runtime/client_ui_harness.py', validation_join)
    patch = ''
    for name, text in after.items():
        patch += ''.join(difflib.unified_diff(before.get(name, '').splitlines(keepends=True), text.splitlines(keepends=True),
            fromfile='a/' + name if name in before else '/dev/null', tofile='b/' + name))
    sha = lambda data: hashlib.sha256(data).hexdigest()
    selectors = [{'path': name, 'line': number, 'source': line.strip()}
                 for name in ('python/exteraless_runtime/_audit_paths.py', 'python/exteraless_runtime/_archives.py')
                 for number, line in enumerate(read(name).splitlines(), 1)
                 if 'sys.platform in ("darwin", "ios")' in line]
    if len(selectors) != 3:
        raise ValueError('Review the changed Darwin/iOS platform-selector source contract')
    receipt = {'applied': False, 'target_scenario': 'sdk-ui', 'actual_ui_plugin_id': 'clientUIFixture',
        'existing_verify_services_used': False, 'first_mac_child_flag': 'darwin_family_fd_paths',
        'required_ios_flag': 'actual_ios_fd_paths', 'new_scene_count': 0, 'new_interpreters': 0, 'process_seconds': 30,
        'native_execution_verified': False, 'method_source_sha256': sha(method_source.encode()),
        'source_inputs': {name: sha((root / name).read_bytes()) for name in (HELPER, WAVE,
            'python/exteraless_runtime/_audit_paths.py', 'python/exteraless_runtime/_archives.py')},
        'platform_selector_sites': selectors,
        'hunk_inputs': {name: sha((root / name).read_bytes()) for name in before},
        'hunk_outputs': {name: sha(text.encode()) for name,text in after.items()},
        'patch_sha256': sha(patch.encode())}
    return patch, receipt, after


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    patch, receipt, _ = build_packet()
    (args.output / 'client-ui-ios-fd-coordinator.patch').write_text(patch, encoding='utf-8', newline='\n')
    (args.output / 'source-contract.json').write_text(json.dumps(receipt, indent=2, sort_keys=True)+'\n', encoding='utf-8', newline='\n')


if __name__ == '__main__':
    main()
