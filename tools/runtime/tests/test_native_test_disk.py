"""Owned temporary file fixtures; no Apple/Bazel/native tests or user cache cleanup."""

import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
import native_test_disk as disk
import run_native_integration_tests as native
from client_ui_harness_workspace import claim_workspace, write_generation


class NativeDiskTests(unittest.TestCase):
    def setUp(self):
        parent = Path(os.environ['LOCALAPPDATA']) / 'Temp/opencode' if os.name == 'nt' else None
        self.temporary = tempfile.TemporaryDirectory(prefix='native-disk-fixture-', dir=parent)
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.owned = self.base / 'owned'
        self.repo, self.generation = 'fixture/native', 'disk-1'
        claim_workspace(self.owned, self.repo)
        (self.owned / 'telegram-ios').mkdir()
        (self.owned / 'telegram-ios/versions.json').write_text('{"bazel":"9.2.0:fixture"}')
        self.bazel_root = self.owned / 'bazel-user-root'; self.bazel_root.mkdir()
        self.bazel_output = self.bazel_root / 'owned-output-base'; self.bazel_output.mkdir()
        self.runs = self.base / 'runs'; self.runs.mkdir()
        self.run = self.runs / 'current/native-tests'; self.run.mkdir(parents=True)
        self.cache = self.base / 'cache-parent/exteraless-bazel-disk'; self.cache.parent.mkdir()
        self.cache.mkdir()
        self.addCleanup(patch.stopall)
        patch.object(disk, 'TRUSTED_CACHE', self.cache).start()
        patch.dict(os.environ, {'BAZEL_DISK_CACHE': str(self.cache), 'RUNNER_TEMP': str(self.runs)}).start()
        self.ready()
        self.entries = []
        for index in range(3):
            name = hashlib.sha256(str(index).encode()).hexdigest()
            p = self.cache / 'cas' / name[:2] / name
            p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(bytes([index]) * 64)
            os.utime(p, ns=(1_000_000_000 * (index + 1), 1_000_000_000 * (index + 1)))
            self.entries.append(p)
        self.retained = [self.owned / 'telegram-ios/source.swift', self.bazel_output / 'materialized.o',
                         self.run.parent / 'ClientUIHarness.ipa', self.base / 'sibling-user-data']
        for p in self.retained: p.write_bytes(b'retain actual fixture bytes')
        disk.claim_cache(self.owned, self.repo, self.generation, self.cache)
        self.free = 0
        self.idle = Mock(return_value={'status': 'test-only owned server quiescence'})
        self.limits = disk.Limits(minimum_free=80, target_free=100, maximum_cache=128,
                                  phase_seconds=5, scan_entries=100, delete_entries=100, delete_bytes=1024)

    def ready(self, generation=None):
        write_generation(self.owned, {'schema': 1, 'repository': self.repo,
            'generation': generation or self.generation, 'ready': True})

    def usage(self, path):
        total = 1024 ** 3
        return SimpleNamespace(total=total, used=total-self.free, free=self.free)

    def add_blob(self, name, size, modified_ns, *, store='cas'):
        digest = hashlib.sha256(name.encode()).hexdigest()
        path = self.cache / store / digest[:2] / digest
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'x' * size)
        os.utime(path, ns=(modified_ns, modified_ns))
        self.entries.append(path)
        return path

    def directory_link(self, link, target):
        try:
            link.symlink_to(target, target_is_directory=True)
        except OSError as error:
            if os.name != 'nt':
                raise
            result = subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/J', str(link), str(target)],
                                    capture_output=True, timeout=3)
            if result.returncode:
                self.skipTest('Symlink/junction creation unavailable: ' + str(error))

    def fixture_unlink(self, cache, item):
        # Windows policy tests use real disposable files with an explicitly
        # injected leaf operation. POSIX dirfd deletion has its own test below.
        path = cache.joinpath(*item['parts'])
        self.assertIn(path, self.entries)
        self.assertFalse(path.is_symlink())
        path.unlink(); self.free += item['size']
        return True

    def recover(self, **options):
        with contextlib.redirect_stdout(io.StringIO()):
            return disk.recover_capacity(self.owned, self.repo, self.generation, self.cache,
                self.bazel_root, self.bazel_output, self.run, quiesce=self.idle,
                limits=options.pop('limits', self.limits), usage=self.usage,
                _unlink=options.pop('_unlink', self.fixture_unlink), **options)

    def test_adequate_free_space_keeps_cache_and_never_quiesces_or_deletes(self):
        self.free = 200
        unlink = Mock(side_effect=AssertionError('must not delete'))
        report = self.recover(_unlink=unlink)
        self.assertEqual(report['status'], 'sufficient-no-deletion')
        self.assertEqual(report['deletedFiles'], 0)
        self.idle.assert_not_called(); unlink.assert_not_called()
        self.assertTrue(all(p.exists() for p in self.entries + self.retained))

    def test_capacity_receipt_records_the_effective_read_only_cache_mode(self):
        from native_test_cache import MODE, cache_flags
        self.free = 200
        mode = {'mode': MODE, 'readOnly': True, 'nativeCacheFlags': cache_flags('http://127.0.0.1:43217')}
        report = self.recover(cache_configuration=mode)
        self.assertEqual(report['readOnlyCache'], mode)
        self.assertEqual(report['nativeCacheFlags'], mode['nativeCacheFlags'])
        persisted = json.loads((self.run / 'disk-capacity.json').read_text())
        self.assertEqual(persisted['readOnlyCache']['mode'], MODE)
        self.assertEqual(persisted['deletedFiles'], 0)
        self.idle.assert_not_called()

    def test_pressure_equal_allocation_size_ties_keep_lru_and_preserve_retained_files(self):
        report = self.recover()
        self.assertEqual(report['status'], 'recovered')
        self.assertEqual(report['deletedFiles'], 2)
        self.assertEqual(report['deletedBytes'], 128)
        self.assertEqual(report['keptCacheBytes'], 64)
        self.assertEqual(report['selectionPolicy'], disk.SELECTION_POLICY)
        self.assertEqual(report['pressureDeletedFiles'], 2)
        self.assertEqual(report['lruDeletedFiles'], 0)
        self.assertFalse(self.entries[0].exists()); self.assertFalse(self.entries[1].exists())
        self.assertTrue(self.entries[2].exists())
        for path in self.retained: self.assertEqual(path.read_bytes(), b'retain actual fixture bytes')
        self.assertTrue((self.cache / disk.CACHE_MARKER).is_file())
        self.idle.assert_called_once()

    def test_pressure_reaches_floor_in_three_unlinks_ahead_of_thousands_of_old_metadata_files(self):
        mib = 1024 ** 2
        tiny = [self.add_blob('old-metadata-' + str(i), 1, 100_000_000, store='ac') for i in range(2000)]
        large = [self.add_blob('new-large-' + str(i), mib, (i + 10) * 1_000_000_000) for i in range(3)]
        selected, measured = [], []
        original_usage = self.usage
        def observed_usage(path):
            measured.append(self.free)
            return original_usage(path)
        self.usage = observed_usage
        def unlink_with_stat_allocation(cache, entry):
            path = cache.joinpath(*entry['parts'])
            info = path.lstat()
            allocated = getattr(info, 'st_blocks', (info.st_size + 511) // 512) * 512
            self.assertEqual(entry['allocated'], allocated)
            path.unlink()
            self.free += allocated
            selected.append(path)
            return True
        limits = disk.Limits(minimum_free=2 * mib + mib // 2, target_free=64 * mib,
            maximum_cache=mib, phase_seconds=5, scan_entries=10000, delete_entries=3, delete_bytes=4 * mib)
        report = self.recover(limits=limits, _unlink=unlink_with_stat_allocation)
        self.assertEqual(selected, large)
        self.assertEqual(report['status'], 'recovered')
        self.assertEqual(report['deletedFiles'], 3)
        self.assertEqual(report['pressureDeletedFiles'], 3)
        self.assertEqual(report['lruDeletedFiles'], 0)
        self.assertGreaterEqual(report['capacity']['bazelOutput']['free'], limits.minimum_free)
        self.assertLessEqual(report['keptCacheBytes'], limits.maximum_cache)
        self.assertFalse(report['targetFreeReached'])
        self.assertFalse(report['targetEstimatedReachableAfterInventory'])
        self.assertEqual(report['stopReason'], 'minimum-and-cache-cap-met-target-not-estimated-reachable')
        self.assertNotIn('cutoff', report)
        self.assertEqual(report['selectionThresholds']['pressureBelowFreeBytes'], limits.minimum_free)
        self.assertTrue({mib, 2 * mib, 3 * mib} <= set(measured))
        self.assertTrue(all(path.exists() for path in tiny))
        for path in self.retained:
            self.assertEqual(path.read_bytes(), b'retain actual fixture bytes')
        persisted = json.loads((self.run / 'disk-capacity.json').read_text())
        self.assertEqual(persisted['selectionPolicy'], disk.SELECTION_POLICY)
        self.assertFalse(persisted['targetFreeReached'])

    def test_after_floor_selection_returns_to_lru_for_the_reachable_goal(self):
        smaller = self.add_blob('new-smaller', 8192, 10_000_000_000)
        largest = self.add_blob('new-largest', 16384, 11_000_000_000)
        selected = []
        def unlink(cache, entry):
            selected.append(cache.joinpath(*entry['parts']))
            return self.fixture_unlink(cache, entry)
        limits = disk.Limits(minimum_free=8192, target_free=16384 + 64, maximum_cache=10240,
                             phase_seconds=5, scan_entries=100, delete_entries=3, delete_bytes=32768)
        report = self.recover(limits=limits, _unlink=unlink)
        self.assertEqual(selected, [largest, self.entries[0]])
        self.assertEqual(report['pressureDeletedFiles'], 1)
        self.assertEqual(report['lruDeletedFiles'], 1)
        self.assertTrue(report['targetFreeReached'])
        self.assertTrue(smaller.exists())

    def test_changed_large_pressure_candidate_is_kept_and_not_retried(self):
        changed = self.add_blob('changed-large', 8192, 10_000_000_000)
        attempts = []
        def unlink(cache, entry):
            path = cache.joinpath(*entry['parts'])
            attempts.append(path)
            if path == changed:
                path.write_bytes(b'new cache version')
                return False  # The FD identity guard rejects this changed leaf.
            return self.fixture_unlink(cache, entry)
        limits = disk.Limits(minimum_free=80, target_free=100, maximum_cache=16384,
                             phase_seconds=5, scan_entries=100, delete_entries=3, delete_bytes=32768)
        report = self.recover(limits=limits, _unlink=unlink)
        self.assertEqual(report['status'], 'recovered')
        self.assertEqual(attempts.count(changed), 1)
        self.assertEqual(report['skippedChangedOrLinked'], 1)
        self.assertEqual(changed.read_bytes(), b'new cache version')

    def test_file_quota_failure_keeps_actual_counts_and_never_claims_capacity(self):
        limits = disk.Limits(minimum_free=80, target_free=100, maximum_cache=128,
                             phase_seconds=5, scan_entries=100, delete_entries=1, delete_bytes=1024)
        with self.assertRaises(disk.DiskCapacityError): self.recover(limits=limits)
        report = json.loads((self.run / 'disk-capacity.json').read_text())
        self.assertEqual(report['status'], 'failed-before-compile')
        self.assertEqual(report['deletedFiles'], 1)
        self.assertEqual(report['capacity']['bazelOutput']['free'], 64)
        self.assertEqual(report['keptCacheBytes'], 128)
        self.assertIn('quota', report['cutoff'])

    def test_scan_quota_refuses_partial_inventory_before_any_deletion(self):
        limits = disk.Limits(minimum_free=80, target_free=100, maximum_cache=128,
                             phase_seconds=5, scan_entries=1)
        unlink = Mock()
        with self.assertRaisesRegex(disk.DiskCapacityError, 'inventory cutoff'):
            self.recover(limits=limits, _unlink=unlink)
        unlink.assert_not_called()
        self.assertTrue(all(p.exists() for p in self.entries))

    def test_no_fake_space_from_deleted_byte_count(self):
        def remove_without_free(cache, item):
            cache.joinpath(*item['parts']).unlink()
            return True  # Simulate APFS snapshots retaining allocation.
        with self.assertRaisesRegex(disk.DiskCapacityError, 'free=0'):
            self.recover(_unlink=remove_without_free)
        report = json.loads((self.run / 'disk-capacity.json').read_text())
        self.assertEqual(report['deletedBytes'], 192)
        self.assertEqual(report['capacity']['bazelOutput']['free'], 0)
        self.assertEqual(report['status'], 'failed-before-compile')

    def test_stale_generation_rejects_before_query_shutdown_or_reclaim(self):
        self.ready('disk-2')
        unlink = Mock()
        with self.assertRaisesRegex(ValueError, 'generation'):
            self.recover(_unlink=unlink)
        self.idle.assert_not_called(); unlink.assert_not_called()
        args = SimpleNamespace(owned_root=self.owned, repository=self.repo, generation=self.generation,
                               bazel_root=self.bazel_root)
        with patch.object(native, 'output') as command, self.assertRaisesRegex(ValueError, 'generation'):
            native.prepare_native_disk(args, ['unused-bazel'])
        command.assert_not_called()

    def test_arbitrary_cache_path_and_foreign_marker_are_refused(self):
        other = self.base / 'user-cache'; other.mkdir()
        with self.assertRaisesRegex(ValueError, 'fixed CI'):
            disk.claim_cache(self.owned, self.repo, self.generation, other)
        marker = self.cache / disk.CACHE_MARKER
        value = json.loads(marker.read_text()); value['repository'] = 'other/repository'
        marker.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, 'marker'):
            self.recover()
        self.idle.assert_not_called()

    def test_symlink_shard_cannot_reach_unrelated_tree(self):
        target = self.base / 'unrelated-tree'; target.mkdir()
        protected = target / ('f' * 64); protected.write_bytes(b'unrelated')
        link = self.cache / 'cas/ff'
        self.directory_link(link, target)
        unlink = Mock()
        with self.assertRaisesRegex(ValueError, 'symlinked cache shard'):
            self.recover(_unlink=unlink)
        unlink.assert_not_called()
        self.assertEqual(protected.read_bytes(), b'unrelated')

    def test_replaced_cache_root_symlink_or_junction_is_refused(self):
        moved = self.base / 'original-cache'
        self.cache.rename(moved)
        self.directory_link(self.cache, moved)
        with self.assertRaisesRegex(ValueError, 'symlink/reparse'):
            self.recover()
        self.idle.assert_not_called()
        self.assertEqual(len(list(moved.glob('cas/*/*'))), 3)

    def test_hardlinked_cache_blob_is_kept_with_its_unrelated_reference(self):
        link = self.base / 'retained-hardlink'
        os.link(self.entries[0], link)
        report = self.recover()
        self.assertEqual(report['skippedChangedOrLinked'], 1)
        self.assertTrue(self.entries[0].exists())
        self.assertEqual(link.read_bytes(), bytes([0]) * 64)

    def test_time_cutoff_after_quiescence_preserves_every_cache_file(self):
        now = [0.0]
        self.idle.side_effect = lambda timeout: now.__setitem__(0, 2.0)
        limits = disk.Limits(minimum_free=80, target_free=100, maximum_cache=128, phase_seconds=1)
        unlink = Mock()
        with self.assertRaisesRegex(disk.DiskCapacityError, 'inventory cutoff'):
            self.recover(limits=limits, clock=lambda: now[0], _unlink=unlink)
        unlink.assert_not_called()
        self.assertTrue(all(p.exists() for p in self.entries + self.retained))

    def test_busy_owned_bazel_stops_recovery_before_deletion(self):
        self.idle.side_effect = RuntimeError('owned Bazel server is busy')
        unlink = Mock()
        with self.assertRaisesRegex(RuntimeError, 'busy'):
            self.recover(_unlink=unlink)
        unlink.assert_not_called()
        self.assertTrue(all(p.exists() for p in self.entries))

    def test_native_query_build_and_run_only_keep_effective_cache_override(self):
        source = (ROOT / 'tools/runtime/run_native_integration_tests.py').read_text()
        self.assertEqual(disk.NATIVE_CACHE_FLAGS, ('--disk_cache=', '--remote_upload_local_results=false'))
        self.assertIn('query = native_args(line, line.get_unsigned_test_preflight_arguments(labels), cache)', source)
        self.assertIn("native_args(line, line.get_test_arguments(labels, build_only=True), cache) + ['--keep_going']", source)
        self.assertIn('test_timeout=270, streamed=True), cache)', source)
        self.assertLess(source.index('validate_runtime_actions(graph, staging)'), source.index('bazel_output = prepare_native_disk'))
        self.assertLess(source.index('bazel_output = prepare_native_disk'), source.index('line.get_test_arguments(labels, build_only=True)'))

    @unittest.skipUnless(os.name == 'posix' and os.open in os.supports_dir_fd, 'Actual dirfd unlink runs on the POSIX CI platform')
    def test_posix_dirfd_unlinks_only_unchanged_verified_leaf(self):
        entries, _ = disk._cache_entries(self.cache, self.limits, disk.time.monotonic()+2, disk.time.monotonic)
        first = entries[0]
        path = self.cache.joinpath(*first['parts'])
        os.utime(path, None)
        self.assertFalse(disk._unlink_entry(self.cache, first))
        entries, _ = disk._cache_entries(self.cache, self.limits, disk.time.monotonic()+2, disk.time.monotonic)
        candidate = entries[0]
        self.assertTrue(disk._unlink_entry(self.cache, candidate))
        self.assertFalse(self.cache.joinpath(*candidate['parts']).exists())
        self.assertTrue(all(p.exists() for p in self.retained))


if __name__ == '__main__':
    unittest.main()
