"""Prepare the pinned Telegram client sources; optionally prove a clean-base replay.

The shared implementation lives inside telegram-ios so Make and relocated CI
copies use the same code without copying outer Git metadata or configuration.
--prove-clean-base reads only three git-show blobs into a disposable gitless tree.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'telegram-ios/build-system/Make'))
from ClientSourcePatches import load_contract, prepare_client_sources, sha256, verify_client_sources


def prove_clean_base(telegram_root):
    root, contract, _, inputs = load_contract(telegram_root)
    repository = root / contract['repository']
    before = {}
    for name, spec in contract['files'].items():
        data = subprocess.check_output(['git', '-C', str(repository), 'show', contract['base_commit'] + ':' + name], timeout=10)
        if sha256(data) != spec['preimage_sha256'] or len(data) != spec['preimage_size']:
            raise ValueError('Pinned git-show base differs: ' + name)
        before[name] = data
    preferred = Path(os.environ.get('LOCALAPPDATA', '')) / 'Temp/opencode'
    with tempfile.TemporaryDirectory(prefix='client-patch-clean-base-', dir=preferred if preferred.is_dir() else None) as folder:
        fixture = Path(folder)
        for name in inputs:
            target = fixture / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / name, target)
        for name, data in before.items():
            target = fixture / contract['repository'] / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        first = prepare_client_sources(fixture)
        paths = [fixture / contract['repository'] / name for name in before]
        postimages = {path: path.read_bytes() for path in paths}
        timestamps = {path: path.stat().st_mtime_ns for path in paths}
        if prepare_client_sources(fixture) != first or any(path.stat().st_mtime_ns != stamp for path, stamp in timestamps.items()):
            raise ValueError('Postimage replay is not read-only/idempotent')
        for path in paths:
            path.write_bytes(postimages[path] + b'// tampered\n')
            snapshot = {item: item.read_bytes() for item in paths}
            try:
                prepare_client_sources(fixture)
            except ValueError:
                pass
            else:
                raise ValueError('Tampered source was admitted')
            if any(item.read_bytes() != data for item, data in snapshot.items()):
                raise ValueError('Rejected source state was mutated')
            path.write_bytes(postimages[path])
        paths[0].write_bytes(next(iter(before.values())))
        try:
            prepare_client_sources(fixture)
        except ValueError:
            pass
        else:
            raise ValueError('Mixed preimage/postimage state was admitted')
    return {'ok': True, 'fixture': 'three raw git-show blobs; no Git metadata',
            'base_commit': contract['base_commit'], 'files': len(before),
            'idempotent_without_writes': True, 'tamper_rejected': len(before),
            'mixed_state_rejected': True, 'source_fingerprint': first['source_fingerprint']}


def run_rust_tests(root, report_path, source_report):
    """The supported native Rust fixture entrypoint always prepares sources first."""
    if verify_client_sources(root) != source_report:
        raise ValueError('Rust fixture source provenance differs before compilation')
    if sys.platform not in ('darwin', 'linux'):
        raise ValueError('Native Rust fixture execution requires the Linux/macOS runner')
    from check_swift_components import run_phase
    output = report_path.parent
    repository = root / source_report['repository']
    log = output / 'rust-build.log'
    run_phase(['cargo', 'test', '--manifest-path', str(repository / 'Cargo.toml'), '--locked',
               '-p', 'mtproto-engine', '--lib', '--no-run', '--message-format=json'], output, 'rust-build', 300)
    executables = []
    for line in log.read_text(encoding='utf-8').splitlines():
        if line.startswith('{'):
            entry = json.loads(line)
            if entry.get('reason') == 'compiler-artifact' and entry.get('executable'):
                executables.append(entry['executable'])
    if len(executables) != 1 or verify_client_sources(root) != source_report:
        raise ValueError('Rust fixture executable/source identity is ambiguous')
    run_phase([executables[0], 'app_resolver_', '--test-threads=1'], output, 'rust-test', 30)
    if 'test result: ok. 2 passed; 0 failed;' not in (output / 'rust-test.log').read_text(encoding='utf-8'):
        raise ValueError('Both native Rust resolver fixtures must execute')
    if verify_client_sources(root) != source_report:
        raise ValueError('Rust sources changed during native tests')
    return {'ok': True, 'tests': 2, 'executable_sha256': sha256(Path(executables[0]).read_bytes())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--telegram-root', type=Path, default=ROOT / 'telegram-ios')
    parser.add_argument('--report', type=Path)
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--prove-clean-base', action='store_true')
    parser.add_argument('--rust-tests', action='store_true')
    args = parser.parse_args()
    if args.rust_tests and args.report is None:
        parser.error('--rust-tests requires --report for compiler/test evidence')
    result = {'ok': False, 'native_execution_verified': False}
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(result) + '\n', encoding='utf-8')
    try:
        if args.prove_clean_base:
            result['clean_base_proof'] = prove_clean_base(args.telegram_root)
        result['client_source_patches'] = prepare_client_sources(args.telegram_root, apply=not args.verify_only)
        if args.rust_tests:
            result['rust_tests'] = run_rust_tests(args.telegram_root.resolve(), args.report, result['client_source_patches'])
            result['native_execution_verified'] = True
        result['ok'] = True
    except Exception as error:
        result['error'] = str(error)
        raise
    finally:
        if args.report:
            args.report.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
