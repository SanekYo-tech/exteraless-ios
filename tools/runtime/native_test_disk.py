"""Bounded recovery of the one CI Bazel action cache before native test compilation.

Only ac/cas digest files in the explicitly claimed fixed cache are disposable.
Output bases, source, retained IPA, results, simulators and toolchains are never
deletion candidates. Production deletion requires POSIX dirfd/O_NOFOLLOW.
"""

import argparse
from dataclasses import dataclass
import errno
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import time
import uuid

from client_ui_harness_workspace import read_generation, verify_workspace

GIB = 1024 ** 3
TRUSTED_CACHE = Path('/Users/runner/Library/Caches/exteraless-bazel-disk')
CACHE_MARKER = '.exteraless-native-action-cache.json'
CLAIM_MARKER = '.native-test-cache-claim.json'
CACHE_KEY = 'exteraless-bazel-9.2.0-sha256-actions-v1'
# Bazel 9.2 RemoteExecutionService.getWriteCachePolicy ignores
# remote_upload_local_results for disk writes. Empty disk_cache actually disables
# DiskCacheClient (CombinedCacheClientFactory.isDiskCache). Use the same mode for
# native aquery/build/run-only; the preceding app build keeps its existing cache.
NATIVE_CACHE_FLAGS = ('--disk_cache=', '--remote_upload_local_results=false')


@dataclass(frozen=True)
class Limits:
    minimum_free: int = 20 * GIB
    target_free: int = 30 * GIB
    maximum_cache: int = 8 * GIB
    phase_seconds: float = 60
    scan_entries: int = 200000
    delete_entries: int = 100000
    delete_bytes: int = 64 * GIB


class DiskCapacityError(RuntimeError):
    pass


def _is_link(info):
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, 'st_file_attributes', 0) & 0x400)


def _directory(path):
    """Validate every component without resolving a user-controlled symlink."""
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('Expected an absolute, non-traversing disk path')
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        info = current.lstat()
        if _is_link(info) or not stat.S_ISDIR(info.st_mode):
            raise ValueError('Disk path contains a symlink/reparse point or non-directory: ' + str(current))
    return path


def _json_file(path):
    before = path.lstat()
    if _is_link(before) or not stat.S_ISREG(before.st_mode) or before.st_size > 4096:
        raise ValueError('Invalid disk ownership metadata: ' + str(path))
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    try:
        actual = os.fstat(fd)
        if (actual.st_dev, actual.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError('Disk ownership metadata changed while opening')
        value = json.loads(os.read(fd, 4097))
        if not isinstance(value, dict):
            raise ValueError('Disk ownership metadata must be an object')
        return value
    finally:
        os.close(fd)


def _write_json(path, value):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex)
    try:
        with temporary.open('x', encoding='utf-8') as stream:
            json.dump(value, stream, sort_keys=True, indent=2)
            stream.write('\n')
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def checked_workspace(owned_root, repository, generation, bazel_root=None):
    owned = _directory(owned_root)
    verify_workspace(owned, repository)
    state = read_generation(owned, repository)
    if state['generation'] != generation or state['ready'] is not True:
        raise ValueError('Stale/unready workspace generation; disk recovery refused')
    if bazel_root is not None and _directory(bazel_root) != owned / 'bazel-user-root':
        raise ValueError('Disk recovery requires the exact owned Bazel user root')
    return owned


def _cache_path(cache):
    cache = Path(cache)
    if cache != TRUSTED_CACHE or not cache.is_absolute() or '..' in cache.parts:
        raise ValueError('Only the fixed CI Bazel disk action cache may be claimed/reclaimed')
    configured = os.environ.get('BAZEL_DISK_CACHE')
    if configured is not None and Path(configured) != cache:
        raise ValueError('Cache argument differs from BAZEL_DISK_CACHE')
    _directory(cache.parent)
    return cache


def _expected_marker(cache, repository):
    return {'schema': 1, 'kind': 'exteraless-native-action-cache', 'repository': repository,
            'cache': str(cache), 'cache_key': CACHE_KEY}


def _check_cache_layout(cache):
    for item in cache.iterdir():
        info = item.lstat()
        if _is_link(info):
            raise ValueError('Refusing a symlink/reparse point in the action cache root')
        if item.name not in ('ac', 'cas', 'tmp', 'gc', CACHE_MARKER):
            raise ValueError('Unrecognized content in fixed action-cache root: ' + item.name)
        if item.name != CACHE_MARKER and not stat.S_ISDIR(info.st_mode):
            raise ValueError('Action-cache store is not a directory: ' + item.name)


def claim_cache(owned_root, repository, generation, cache):
    """Run after source staging/cache restore, before the app build. Never deletes."""
    owned = checked_workspace(owned_root, repository, generation)
    version = _json_file(owned / 'telegram-ios/versions.json').get('bazel', '').split(':', 1)[0]
    if version != '9.2.0':
        raise ValueError('Review disk layout/cache-mode semantics for the changed Bazel version')
    cache = _cache_path(cache)
    cache.mkdir(mode=0o700, exist_ok=True)
    _directory(cache)
    _check_cache_layout(cache)
    expected = _expected_marker(cache, repository)
    marker = cache / CACHE_MARKER
    if marker.exists() or marker.is_symlink():
        if _json_file(marker) != expected:
            raise ValueError('Action cache belongs to another namespace/repository')
    else:
        fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
        try:
            os.write(fd, (json.dumps(expected, sort_keys=True) + '\n').encode())
        finally:
            os.close(fd)
    info = cache.lstat()
    claim = dict(expected, generation=generation, workspace=str(owned), device=info.st_dev, inode=info.st_ino)
    checked_workspace(owned, repository, generation)
    _write_json(owned / CLAIM_MARKER, claim)
    return claim


def _verify_claim(owned, repository, generation, cache):
    checked_workspace(owned, repository, generation)
    cache = _directory(_cache_path(cache))
    _check_cache_layout(cache)
    expected = _expected_marker(cache, repository)
    if _json_file(cache / CACHE_MARKER) != expected:
        raise ValueError('Unverified action cache marker')
    claim = _json_file(owned / CLAIM_MARKER)
    info = cache.lstat()
    if claim != dict(expected, generation=generation, workspace=str(owned), device=info.st_dev, inode=info.st_ino):
        raise ValueError('Action cache was not claimed for this source generation/inode')


def tree_stats(path, *, seconds=2, maximum_entries=20000, clock=time.monotonic):
    """Bounded du-like lower bound; symlinks/junctions are counted, never traversed."""
    start = clock()
    result = {'path': str(path), 'entries': 0, 'files': 0, 'logicalBytes': 0,
              'allocatedBytes': 0, 'symlinksSkipped': 0, 'complete': True}
    stack = [(Path(path), 0)]
    while stack:
        directory, depth = stack.pop()
        if clock() - start >= seconds or result['entries'] >= maximum_entries:
            result['complete'] = False
            break
        try:
            info = directory.lstat()
            if _is_link(info):
                result['symlinksSkipped'] += 1
                continue
            with os.scandir(directory) as items:
                for item in items:
                    if clock() - start >= seconds or result['entries'] >= maximum_entries:
                        result['complete'] = False
                        return result
                    info = item.stat(follow_symlinks=False)
                    result['entries'] += 1
                    if _is_link(info):
                        result['symlinksSkipped'] += 1
                    elif stat.S_ISREG(info.st_mode):
                        result['files'] += 1
                        result['logicalBytes'] += info.st_size
                        result['allocatedBytes'] += getattr(info, 'st_blocks', (info.st_size + 511) // 512) * 512
                    elif stat.S_ISDIR(info.st_mode):
                        if depth < 16:
                            stack.append((Path(item.path), depth + 1))
                        else:
                            result['complete'] = False
        except OSError as error:
            result.update(complete=False, error=str(error))
    return result


def _capacity(paths, usage):
    result = {}
    for name, path in paths.items():
        value = usage(path)
        result[name] = {'path': str(path), 'device': path.stat().st_dev,
                        'total': value.total, 'used': value.used, 'free': value.free}
    return result


def _cache_entries(cache, limits, deadline, clock):
    """Admit only Bazel 9 SHA-256 AC/CAS leaves; leave tmp/gc/markers intact."""
    result, count, retained = [], 0, 0
    for store in ('ac', 'cas'):
        directory = cache / store
        try:
            store_info = directory.lstat()
        except FileNotFoundError:
            continue
        if _is_link(store_info) or not stat.S_ISDIR(store_info.st_mode):
            raise ValueError('Malformed/symlinked cache store; refusing recovery')
        _directory(directory)
        with os.scandir(directory) as shards:
            for shard in shards:
                count += 1
                if clock() >= deadline or count > limits.scan_entries:
                    raise DiskCapacityError('Cache inventory cutoff; no partial inventory deletion permitted')
                info = shard.stat(follow_symlinks=False)
                if _is_link(info) or not stat.S_ISDIR(info.st_mode) or not re.fullmatch('[0-9a-f]{2}', shard.name):
                    raise ValueError('Malformed/symlinked cache shard; refusing recovery')
                with os.scandir(shard.path) as entries:
                    for entry in entries:
                        count += 1
                        if clock() >= deadline or count > limits.scan_entries:
                            raise DiskCapacityError('Cache inventory cutoff; no partial inventory deletion permitted')
                        # Windows DirEntry.stat may omit inode/link information;
                        # take an actual lstat for the retained deletion identity.
                        info = Path(entry.path).lstat()
                        if (_is_link(info) or not stat.S_ISREG(info.st_mode)
                                or not re.fullmatch('[0-9a-f]{64}', entry.name) or not entry.name.startswith(shard.name)):
                            raise ValueError('Malformed/symlinked cache digest; refusing recovery')
                        allocated = getattr(info, 'st_blocks', (info.st_size + 511) // 512) * 512
                        retained += info.st_size
                        result.append({'parts': (store, shard.name, entry.name), 'device': info.st_dev,
                            'inode': info.st_ino, 'size': info.st_size, 'mtime': info.st_mtime_ns,
                            'allocated': allocated, 'links': info.st_nlink})
    return sorted(result, key=lambda item: (item['mtime'], item['parts'])), retained


def _open_directory_fd(path):
    if os.name != 'posix' or not hasattr(os, 'O_NOFOLLOW') or os.open not in os.supports_dir_fd:
        raise ValueError('Actual cache deletion requires POSIX dirfd/O_NOFOLLOW support')
    path = _directory(path)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open(path.anchor, flags)
    try:
        for part in path.parts[1:]:
            child = os.open(part, flags, dir_fd=fd)
            os.close(fd); fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def _unlink_entry(cache, entry):
    """Open each parent relative to a no-follow directory FD; unlink one leaf."""
    fd = _open_directory_fd(cache)
    try:
        for name in entry['parts'][:-1]:
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = child
        name = entry['parts'][-1]
        try:
            actual = os.stat(name, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            return False
        if (not stat.S_ISREG(actual.st_mode) or actual.st_nlink != 1
                or (actual.st_dev, actual.st_ino, actual.st_size, actual.st_mtime_ns)
                != (entry['device'], entry['inode'], entry['size'], entry['mtime'])):
            return False
        os.unlink(name, dir_fd=fd)  # A last-moment replacement symlink itself is unlinked, never followed.
        return True
    finally:
        os.close(fd)


def _publish(path, report):
    print('NATIVE_DISK ' + json.dumps({key: report[key] for key in (
        'status', 'minimumFreeBytes', 'targetFreeBytes', 'deletedFiles', 'deletedBytes', 'keptCacheBytes',
        'cutoff', 'error', 'capacity') if key in report}, sort_keys=True), flush=True)
    try:
        _write_json(path, report)
    except OSError as error:
        if error.errno != errno.ENOSPC:
            raise
        print('NATIVE_DISK receipt write failed: ENOSPC; measurements above are live', flush=True)


def recover_capacity(owned_root, repository, generation, cache, bazel_root, bazel_output, run_output,
                     *, quiesce, limits=Limits(), usage=shutil.disk_usage, clock=time.monotonic,
                     _unlink=_unlink_entry):
    started = clock(); deadline = started + limits.phase_seconds
    owned = checked_workspace(owned_root, repository, generation, bazel_root)
    cache = _directory(_cache_path(cache))
    _verify_claim(owned, repository, generation, cache)
    bazel_output = _directory(bazel_output)
    if not bazel_output.is_relative_to(Path(bazel_root)) or bazel_output == Path(bazel_root):
        raise ValueError('Bazel output base is outside the exact owned user root')
    run_output = _directory(run_output)
    runner_temp = os.environ.get('RUNNER_TEMP')
    if not (run_output.is_relative_to(owned) or (runner_temp and run_output.is_relative_to(_directory(runner_temp)))):
        raise ValueError('Native run output is outside the owned workspace/explicit RUNNER_TEMP')
    if cache.is_relative_to(owned) or owned.is_relative_to(cache) or run_output.is_relative_to(cache):
        raise ValueError('Disposable action cache overlaps retained native inputs/outputs')
    paths = {'ownedRoot': owned, 'bazelOutput': bazel_output, 'diskActionCache': cache, 'runOutput': run_output}
    report_path = run_output / 'disk-capacity.json'
    report = {'schema': 1, 'status': 'measuring', 'generation': generation, 'cacheKey': CACHE_KEY,
        'minimumFreeBytes': limits.minimum_free, 'targetFreeBytes': limits.target_free,
        'maximumCacheBytes': limits.maximum_cache, 'phaseLimitSeconds': limits.phase_seconds,
        'deletedFiles': 0, 'deletedBytes': 0, 'deletedAllocatedBytes': 0, 'skippedChangedOrLinked': 0,
        'nativeCacheFlags': list(NATIVE_CACHE_FLAGS), 'nativeExecutionVerified': False}
    try:
        report['capacity'] = _capacity(paths, usage)
        report['before'] = report['capacity']
        _publish(report_path, report)
        if sys_platform_is_posix():
            df = subprocess.run(['/bin/df', '-kP', *map(str, paths.values())], capture_output=True, text=True,
                                timeout=min(5, max(0.1, deadline - clock())))
            report['df'] = {'exitCode': df.returncode, 'stdout': df.stdout[-16384:], 'stderr': df.stderr[-4096:]}
        report['trees'] = {name: tree_stats(path, seconds=min(2, max(0, deadline - clock())), clock=clock)
                           for name, path in paths.items()}
        print('NATIVE_DISK_TREES ' + json.dumps(report['trees'], sort_keys=True), flush=True)
        target_names = ('ownedRoot', 'bazelOutput', 'runOutput')
        free = lambda: min(report['capacity'][name]['free'] for name in target_names)
        if free() >= limits.minimum_free:
            report['status'] = 'sufficient-no-deletion'
            return report
        deficient_devices = {report['capacity'][name]['device'] for name in target_names
                             if report['capacity'][name]['free'] < limits.minimum_free}
        if deficient_devices - {cache.stat().st_dev}:
            raise DiskCapacityError('Deficient output volume is not the cache volume; cache reclamation cannot provide capacity')
        report['status'] = 'quiescing-owned-bazel'
        _publish(report_path, report)
        if clock() >= deadline:
            raise DiskCapacityError('Disk recovery time budget exhausted before reclamation')
        report['bazelQuiescence'] = quiesce(max(0.1, min(15, deadline - clock())))
        _verify_claim(owned, repository, generation, cache)
        entries, kept = _cache_entries(cache, limits, deadline, clock)
        report['eligibleCacheBytesBefore'] = kept
        report['keptCacheBytes'] = kept
        report['cacheCapScope'] = 'verified SHA-256 AC/CAS leaves; tmp/gc/ownership metadata retained'
        report['status'] = 'reclaiming-cache-lru'
        _publish(report_path, report)
        for entry in entries:
            if free() >= limits.target_free and kept <= limits.maximum_cache:
                break
            if (clock() >= deadline or report['deletedFiles'] >= limits.delete_entries
                    or report['deletedBytes'] + entry['size'] > limits.delete_bytes):
                report['cutoff'] = 'time/file/byte reclamation quota reached'
                break
            _verify_claim(owned, repository, generation, cache)
            if entry['links'] != 1 or not _unlink(cache, entry):
                report['skippedChangedOrLinked'] += 1
                continue
            report['deletedFiles'] += 1
            report['deletedBytes'] += entry['size']
            report['deletedAllocatedBytes'] += entry['allocated']
            kept -= entry['size']; report['keptCacheBytes'] = kept
            # Gate on actual filesystem free space, never on estimated reclaimed bytes.
            report['capacity'] = _capacity(paths, usage)
            if report['deletedFiles'] % 128 == 0:
                _publish(report_path, report)
        report['capacity'] = _capacity(paths, usage)
        if free() < limits.minimum_free or kept > limits.maximum_cache:
            raise DiskCapacityError('Native compile capacity insufficient: free={} bytes, minimum={} bytes, kept cache={} bytes; '
                                    'only verified AC/CAS leaves were reclaimable'.format(free(), limits.minimum_free, kept))
        report['status'] = 'recovered'
        report['targetFreeReached'] = free() >= limits.target_free
        return report
    except BaseException as error:
        report.update(status='failed-before-compile', error=str(error),
            fallback='Provision free space on the reported output/run volume; retained outputs/source/IPA/results are not reclaimable by this helper.')
        report['deficitBytesByPath'] = {name: max(0, limits.minimum_free - value['free'])
                                      for name, value in report.get('capacity', {}).items() if name != 'diskActionCache'}
        raise
    finally:
        report['elapsedSeconds'] = round(clock() - started, 3)
        _publish(report_path, report)


def sys_platform_is_posix():
    return os.name == 'posix'


def observe_after_compile(owned_root, repository, generation, cache, bazel_root, bazel_output, run_output):
    """Small read-only sizing receipt, also emitted when compiler output hits ENOSPC."""
    owned = checked_workspace(owned_root, repository, generation, bazel_root)
    _verify_claim(owned, repository, generation, cache)
    paths = {'ownedRoot': owned, 'bazelOutput': _directory(bazel_output),
             'diskActionCache': _directory(cache), 'runOutput': _directory(run_output)}
    report = {'status': 'after-native-compile', 'deletedFiles': 0, 'deletedBytes': 0,
              'capacity': _capacity(paths, shutil.disk_usage),
              'trees': {name: tree_stats(path, seconds=0.5, maximum_entries=5000) for name, path in paths.items()},
              'fallback': 'If output materialization exceeds free space, enlarge the owned output/run volume; do not delete retained IPA/source/results.'}
    print('NATIVE_DISK_TREES ' + json.dumps(report['trees'], sort_keys=True), flush=True)
    _publish(Path(run_output) / 'disk-after-compile.json', report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('claim',))
    parser.add_argument('--owned-root', type=Path, required=True)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--generation', required=True)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = claim_cache(args.owned_root, args.repository, args.generation, args.cache)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    _write_json(args.output, report)
    print('NATIVE_DISK_CACHE_CLAIM ' + json.dumps(report, sort_keys=True), flush=True)


if __name__ == '__main__':
    main()
