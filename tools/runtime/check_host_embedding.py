"""Compile/run the actual C embedding probe against a local CPython 3.12.

The build driver can use a different Python (with setuptools installed).
Run one short-lived process with a hard timeout; never execute plugins.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--probe', choices=['runtime', 'engine'], default='runtime')
    parser.add_argument('--debug-memory', action='store_true', help='Enable CPython allocator diagnostics in the engine')
    parser.add_argument('--fault-injection', action='store_true', help='Test both GIL rollback states on simulated creation failure')
    args = parser.parse_args()
    if sys.platform != 'win32':
        parser.error('This local driver uses MSVC; Apple probes are built by validate_runtime.sh')
    from setuptools._distutils.ccompiler import new_compiler
    code = "import json,sys,sysconfig; print(json.dumps(dict(version=list(sys.version_info[:2]), home=sys.base_prefix, include=sysconfig.get_path('include'))))"
    config = json.loads(subprocess.check_output([str(args.python), '-c', code], text=True, encoding='utf-8'))
    if config['version'] != [3, 12]:
        raise SystemExit('A CPython 3.12 installation is required')
    args.output.mkdir(parents=True, exist_ok=True)
    native = ROOT / 'python/runtime'
    compiler = new_compiler(compiler='msvc')
    compiler.define_macro('EXL_{}_PROBE_MAIN'.format(args.probe.upper()), '1')
    if args.debug_memory:
        compiler.define_macro('EXL_ENGINE_DEBUG_MEMORY', '1')
    if args.fault_injection:
        if args.probe != 'engine':
            parser.error('--fault-injection requires --probe engine')
        compiler.define_macro('EXL_ENGINE_FAULT_INJECTION', '1')
    sources = [ROOT / 'python/bridge/_exteraless_bridge.c', native / 'register_bridge.c']
    if args.probe == 'engine':
        sources.extend([native / 'engine.c', native / 'cpython312_compat.c'])
    sources.append(native / ('smoke/{}_probe.c'.format(args.probe)))
    objects = compiler.compile(
        [str(source) for source in sources],
        output_dir=str(args.output / 'obj'),
        include_dirs=[config['include'], str(native / 'include'), str(native / 'smoke')],
        extra_postargs=['/std:c11', '/O2', '/utf-8'],
    )
    executable = args.output / '{}-probe.exe'.format(args.probe)
    compiler.link_executable(objects, str(executable), libraries=['python312'],
                             library_dirs=[str(Path(config['home']) / 'libs')])
    env = dict(os.environ, PYTHONUTF8='1')
    env['PATH'] = config['home'] + os.pathsep + env.get('PATH', '')
    report = args.output / '{}-smoke.json'.format(args.probe)
    result = subprocess.run([str(executable), str(report), config['home']], env=env, timeout=30)
    if result.returncode != 0:
        raise SystemExit('Native embedding probe failed with exit code {}'.format(result.returncode))
    payload = json.loads(report.read_text(encoding='utf-8'))
    if payload.get('ok') is not True or payload.get('own_gil_interpreters') != 2:
        raise SystemExit('Native probe did not complete all checks')
    print(json.dumps(payload, indent=2))


if __name__ == '__main__':
    main()
