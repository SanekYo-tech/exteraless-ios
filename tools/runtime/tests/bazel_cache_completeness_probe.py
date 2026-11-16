"""Small real Bazel 9.2 Linux proof; exclusively fresh sentinel-owned toy files.

No native execution claim. Keep every materialized output. The only deleted file
is one identified toy CAS blob, between read-only server lifetimes, to model GC.
"""

import argparse
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
import native_test_cache as fixed
import native_test_disk as disk
from client_ui_harness_workspace import claim_workspace, write_generation

BAZEL_SHA256 = '7668a95db1250f12c40407251e4e203b4ec8bf39bc495d2f485b2d8c99048694'
BEFORE_SHA256 = 'b9fe9ae16e56d1cfdea1467296ff7eb117857f229def509b5044995a353732b1'
PRODUCED = b'CACHE-PRODUCER-V1\n'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bazel', type=Path, required=True)
    parser.add_argument('--before-cache-module', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    require(sys.platform == 'linux', 'This proof is Linux-only and has no Apple entry point')
    require(sha(args.bazel) == BAZEL_SHA256, 'Unexpected real Bazel binary')
    require(sha(args.before_cache_module) == BEFORE_SHA256, 'Unexpected historical HTTP adapter')
    args.output.mkdir(parents=True, exist_ok=False)
    work = Path(tempfile.mkdtemp(prefix='native-cache-toy-', dir=os.environ['RUNNER_TEMP'])).resolve()
    write(work / '.owned-bazel-cache-proof.json', {'kind': 'native-cache-bazel-9.2-toy', 'work': str(work)})
    owned, cache_root, workspace = work / 'owned', work / 'action-cache', work / 'workspace'
    repository, generation = 'fixture/cache-proof', 'bazel-9.2-toy'
    claim_workspace(owned, repository)
    (owned / 'telegram-ios').mkdir()
    (owned / 'telegram-ios/versions.json').write_text('{"bazel":"9.2.0:toy"}')
    write_generation(owned, {'schema': 1, 'repository': repository, 'generation': generation, 'ready': True})
    workspace.mkdir()
    trace = work / 'executions.txt'
    trace.write_text('')
    (workspace / 'MODULE.bazel').write_text('module(name = "native_cache_toy")\n')
    seed = workspace / 'seed.txt'
    seed.write_bytes(b'CONSUMER-V1\n')
    producer = "printf 'CACHE-PRODUCER-V1\\n' > $@ && printf 'producer\\n' >> " + shlex.quote(str(trace))
    consumer = 'cat $(location :producer) $(location seed.txt) > $@ && printf \'consumer\\n\' >> ' + shlex.quote(str(trace))
    build = ('genrule(name="producer", outs=["produced.txt"], cmd=' + json.dumps(producer)
             + ', tags=["no-sandbox", "no-remote-exec"])\n'
             + 'genrule(name="consumer", srcs=[":producer", "seed.txt"], outs=["consumed.txt"], cmd='
             + json.dumps(consumer) + ', tags=["no-sandbox", "no-remote-exec"])\n')
    (workspace / 'BUILD.bazel').write_text(build)
    build_sha = sha(workspace / 'BUILD.bazel')
    spec = importlib.util.spec_from_file_location('native_cache_historical_b06', args.before_cache_module)
    before = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = before
    spec.loader.exec_module(before)
    deadline = time.monotonic() + 200
    report = {'schema': 1, 'status': 'running', 'fixture_only': True, 'native_execution_verified': False,
              'bazel_sha256': BAZEL_SHA256, 'historical_adapter_sha256': BEFORE_SHA256,
              'fixed_adapter_sha256': sha(Path(fixed.__file__)), 'cases': [], 'work': str(work)}

    def executions():
        return trace.read_text().splitlines()

    def run(name, base, target, flags):
        seconds = min(65 if not report['cases'] else 35, deadline - time.monotonic())
        require(seconds > 0, 'Toy proof exceeded its 200-second envelope')
        command = [str(args.bazel), '--batch', '--nosystem_rc', '--nohome_rc', '--noworkspace_rc',
                   '--output_user_root=' + str(work / 'bazel-user'), '--output_base=' + str(work / base),
                   '--host_jvm_args=-Xmx512m', 'build', target, '--jobs=2', '--spawn_strategy=local',
                   '--experimental_remote_cache_eviction_retries=0', *flags]
        started = time.monotonic()
        with (args.output / (name + '.log')).open('wb') as log:
            process = subprocess.run(command, cwd=workspace, stdout=log, stderr=subprocess.STDOUT, timeout=seconds)
        log = (args.output / (name + '.log')).read_text(errors='replace')
        require(len(log) < 2 * 1024 * 1024, 'Toy log exceeded its bound')
        output = (workspace / 'bazel-bin').resolve()
        require(output.is_relative_to(work), 'Toy output escaped its owned root')
        item = {'name': name, 'command': command, 'exit_code': process.returncode,
                'seconds': round(time.monotonic() - started, 3), 'executions': executions(),
                'log_sha256': sha(args.output / (name + '.log')), 'output': str(output)}
        report['cases'].append(item)
        write(args.output / 'probe.json', report)
        print('BAZEL_CACHE_PROBE ' + json.dumps(item, sort_keys=True), flush=True)
        return item, log, output

    def response(server, method, path):
        client = http.client.HTTPConnection('127.0.0.1', server.server.server_address[1], timeout=2)
        try:
            client.request(method, path)
            result = client.getresponse()
            data = result.read(1024 * 1024)
            return result.status, data
        finally:
            client.close()

    def service(module, name):
        return module.ReadOnlyCache(owned, repository, generation, cache_root,
                                    report=args.output / (name + '-http.json'))

    try:
        with patch.object(disk, 'TRUSTED_CACHE', cache_root), patch.dict(os.environ, {'BAZEL_DISK_CACHE': str(cache_root)}):
            disk.claim_cache(owned, repository, generation, cache_root)
            item, _, app_out = run('01-seed-disk', 'app-output', '//:consumer', ['--disk_cache=' + str(cache_root)])
            require(item['exit_code'] == 0 and executions() == ['producer', 'consumer'], 'Disk seed must execute both real genrules')
            app_producer = app_out / 'produced.txt'
            app_stat = app_producer.stat()
            require(app_producer.read_bytes() == PRODUCED, 'Unexpected seeded producer bytes')
            digest = hashlib.sha256(PRODUCED).hexdigest()
            blob = cache_root / 'cas' / digest[:2] / digest
            require(blob.is_file() and sha(blob) == digest, 'Bazel did not seed the expected CAS blob')
            candidates = list((cache_root / 'ac').glob('*/*'))
            require(len(candidates) < 100, 'Toy AC inventory exceeded its bound')
            actions = [p for p in candidates if p.stat().st_size < 1024 * 1024 and digest.encode() in p.read_bytes()]
            require(len(actions) == 1, 'Expected exactly one real producer ActionResult')
            action = actions[0]
            action_sha = sha(action)
            report['producer_action_key'] = action.name
            report['producer_action_result_sha256'] = action_sha

            with service(fixed, '02-warm-kept') as server:
                server.enable_reads()
                item, _, _ = run('02-warm-kept', 'app-output', '//:consumer', server.flags)
                require(item['exit_code'] == 0 and executions() == ['producer', 'consumer'], 'App disk -> HTTP salt invalidated kept outputs')
                require((app_producer.stat().st_ino, app_producer.stat().st_mtime_ns) == (app_stat.st_ino, app_stat.st_mtime_ns), 'Kept output was rewritten')

            with service(fixed, '03-warm-http') as server:
                server.enable_reads()
                require(response(server, 'GET', '/ac/' + action.name) == (200, action.read_bytes()), 'Complete AC GET must return exact protobuf')
                require(response(server, 'HEAD', '/ac/' + action.name) == (200, b''), 'Complete AC HEAD failed')
                item, log, warm_out = run('03-warm-http', 'warm-output', '//:consumer', [*server.flags, '--experimental_remote_require_cached'])
                require(item['exit_code'] == 0 and executions() == ['producer', 'consumer'], 'Valid HTTP cache did not reuse producer/consumer')
                require('remote cache hit' in log and server.stats['acChecked'] > 0, 'No actual HTTP action-cache hit')
                warm_producer = warm_out / 'produced.txt'
                require(warm_producer.read_bytes() == PRODUCED, 'All mode must materialize the intermediate producer')
                warm_stat = warm_producer.stat()

            with service(before, '04-old-toplevel-warm') as server:
                server.enable_reads()
                item, _, old_out = run('04-old-toplevel-warm', 'old-metadata-output', '//:consumer', server.flags)
                require(item['exit_code'] == 0 and executions() == ['producer', 'consumer'], 'Historical warm cache failed unexpectedly')
                report['old_toplevel_producer_materialized'] = (old_out / 'produced.txt').exists()

            blob.write_bytes(b'X' * len(PRODUCED))  # Owned negative fixture; same key/size, wrong content hash.
            with service(fixed, '05-wrong-hash') as server:
                server.enable_reads()
                require(response(server, 'HEAD', '/ac/' + action.name)[0] == 200, 'Completeness is size/existence, not a claim of payload hashing')
                item, log, _ = run('05-wrong-hash', 'wrong-hash-output', '//:producer', [*server.flags, '--experimental_remote_require_cached'])
                require(item['exit_code'] != 0 and executions() == ['producer', 'consumer'], 'Wrong CAS bytes were accepted as a successful action')
                require(re.search(r'digest.*(mismatch|expected|match)|expected.*(hash|digest)', log, re.I), 'Bazel did not report digest rejection')

            require(blob.parent.parent == cache_root / 'cas' and blob.name == digest, 'Refusing non-fixture deletion')
            blob.unlink()  # One toy CAS leaf; no output/source removal and no server is active.
            require(action.is_file() and sha(action) == action_sha, 'Orphan control must retain the identical AC')
            seed.write_bytes(b'CONSUMER-V2\n')  # Invalidate only the toy consumer, preserving the producer action key.
            with service(before, '06-orphan-before') as server:
                server.enable_reads()
                require(response(server, 'HEAD', '/ac/' + action.name)[0] == 200, 'Historical adapter must expose its orphan hit')
                require(response(server, 'GET', '/cas/' + digest)[0] == 404, 'Historical missing CAS control failed')
                item, log, _ = run('06-orphan-before', 'old-metadata-output', '//:consumer', server.flags)
                require(item['exit_code'] != 0 and 'Lost inputs no longer available remotely' in log, 'Historical lost-input defect did not reproduce')

            trace_before = executions()
            with service(fixed, '07-orphan-fixed') as server:
                server.enable_reads()
                for method in ('GET', 'HEAD'):
                    require(response(server, method, '/ac/' + action.name) == (404, b''), 'Incomplete AC must be a transparent miss')
                item, log, repaired_out = run('07-orphan-fixed', 'missing-output', '//:consumer', server.flags)
                require(item['exit_code'] == 0 and 'Lost inputs' not in log, 'Complete-miss fallback did not build successfully')
                require(executions() == trace_before + ['producer', 'consumer'], 'A miss must execute the real producer and consumer')
                require((repaired_out / 'consumed.txt').read_bytes() == PRODUCED + b'CONSUMER-V2\n', 'Fallback result bytes differ')
                require(server.stats['acMisses'] > 0, 'No incomplete-AC miss was observed')
            require(not blob.exists() and sha(action) == action_sha, 'Read-only fallback wrote a new cache copy')

            trace_before = executions()
            with service(fixed, '08-kept-output-after-gc') as server:
                server.enable_reads()
                item, log, _ = run('08-kept-output-after-gc', 'warm-output', '//:consumer', server.flags)
                require(item['exit_code'] == 0 and 'Lost inputs' not in log, 'Kept local outputs failed after toy GC')
                require(executions() == trace_before + ['consumer'], 'Kept materialized producer should not reexecute')
                require((warm_producer.stat().st_ino, warm_producer.stat().st_mtime_ns) == (warm_stat.st_ino, warm_stat.st_mtime_ns), 'Kept producer was replaced')
            require(app_producer.read_bytes() == PRODUCED and sha(workspace / 'BUILD.bazel') == build_sha, 'Proof modified retained app output or rules')
            report.update(status='passed-small-bazel-proof', wrong_hash_rejected=True,
                          orphan_action_missed=True, local_fallback_executed=True,
                          kept_local_output_reused=True, salt_stable=True,
                          cache_writes_disabled=True, native_execution_verified=False)
    except BaseException as error:
        report.update(status='failed-small-bazel-proof', error=str(error))
        raise
    finally:
        write(args.output / 'probe.json', report)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
