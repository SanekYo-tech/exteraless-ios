"""Compile the Swift adapter with the real C engine and run a bounded macOS probe.

The ordinary SwiftPM tests deliberately have no Python dependency. This probe
links the setup-python CPython 3.12 library, so canImport cannot hide adapter
compile errors and lifecycle checks execute the actual native engine.
"""

import argparse
import json
from pathlib import Path
import subprocess
import sys

from support import ROOT


def run(*args, timeout=180, **kwargs):
    print('Swift embedding:', ' '.join(str(arg) for arg in args), flush=True)
    return subprocess.run([str(arg) for arg in args], check=True, timeout=timeout, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python', type=Path, default=Path(sys.executable))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('The Swift embedding driver requires macOS and Xcode')
    if args.output.exists() and any(args.output.iterdir()):
        parser.error('Output must be empty to avoid stale native results')
    args.output.mkdir(parents=True, exist_ok=True)
    query = (
        "import json,sys,sysconfig; "
        "print(json.dumps(dict(version=list(sys.version_info[:2]), home=sys.base_prefix, "
        "include=sysconfig.get_path('include'), stdlib=sysconfig.get_path('stdlib'), "
        "libdir=sysconfig.get_config_var('LIBDIR'), library=sysconfig.get_config_var('LDLIBRARY'))))"
    )
    config = json.loads(subprocess.check_output([str(args.python), '-c', query], text=True))
    if config['version'] != [3, 12]:
        raise RuntimeError('The native engine requires a CPython 3.12 build interpreter')
    home = Path(config['home'])
    library_candidates = [
        Path(config['libdir'] or home / 'lib') / (config['library'] or 'libpython3.12.dylib'),
        home / 'lib/libpython3.12.dylib',
        home / 'Python',  # A framework-style host installation.
    ]
    library = next((path.resolve() for path in library_candidates if path.is_file()), None)
    if library is None:
        raise RuntimeError('Cannot locate the host CPython library: {}'.format(library_candidates))
    (args.output / 'host-python.json').write_text(json.dumps(config, indent=2), encoding='utf-8')

    native = ROOT / 'python/runtime'
    shims = ROOT / 'swift/PluginHost/Sources/CPluginHostShims'
    objects = []
    for source in (ROOT / 'python/bridge/_exteraless_bridge.c', native / 'register_bridge.c',
                   native / 'engine.c', native / 'cpython312_compat.c', shims / 'ph_atomic.c'):
        obj = args.output / (source.stem + '.o')
        run('xcrun', '--sdk', 'macosx', 'clang', '-std=c11', '-O1',
            '-Werror=implicit-function-declaration', '-I', config['include'],
            '-I', native / 'include', '-I', shims / 'include', '-c', source, '-o', obj)
        objects.append(obj)
    # SwiftPM normally supplies this module map. The direct compiler probe uses
    # the same public C header without altering the package or its dependencies.
    modules = args.output / 'CPluginHostShims'
    modules.mkdir()
    (modules / 'module.modulemap').write_text(
        'module CPluginHostShims {\n  header ' + json.dumps(str(shims / 'include/ph_atomic.h')) + '\n  export *\n}\n',
        encoding='utf-8')
    executable = args.output / 'swift-engine-probe'
    sources = sorted((ROOT / 'swift/PluginHost/Sources/PluginHost').glob('*.swift'))
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    run('xcrun', '--sdk', 'macosx', 'swiftc', '-swift-version', '6', '-parse-as-library',
        '-module-name', 'PluginHostNativeProbe', '-sdk', sdk,
        '-I', native / 'include', '-I', modules,
        *sources, native / 'smoke/swift_engine_probe.swift', *objects,
        '-Xlinker', library, '-Xlinker', '-rpath', '-Xlinker', library.parent,
        '-o', executable, timeout=240)
    report_path = args.output / 'swift-engine-smoke.json'
    with (args.output / 'swift-engine-console.log').open('w', encoding='utf-8') as log:
        run(executable, report_path, home, config['stdlib'], Path(config['stdlib']) / 'lib-dynload',
            timeout=30, stdout=log, stderr=subprocess.STDOUT)
    report = json.loads(report_path.read_text(encoding='utf-8'))
    required = ['ok', 'builtin_bridge', 'isolated_globals', 'isolated_handles', 'utf8_and_nul_results',
                'exception_recovery', 'bootstrap_failure_cleaned', 'finalized']
    if any(report.get(key) is not True for key in required) or report.get('native_workers') != 2:
        raise RuntimeError('The Swift native probe did not complete: {}'.format(report))
    report['execution_platform'] = 'macOS host CPython (not iOS)'
    report_path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print('Swift adapter + native engine: two workers, bootstrap cleanup, exception recovery and finalization passed')


if __name__ == '__main__':
    main()
