"""Real loopback HTTP and owned file fixtures; no Bazel/Apple builds or user cache."""

import ast
import contextlib
import errno
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
import native_test_cache as cache
import native_test_disk as disk
import run_native_integration_tests as native
from client_ui_harness_workspace import claim_workspace, write_generation


class _WindowsFixtureReader(cache.ClaimedCacheReader):
    """HTTP fixture IO only. Production readers require the actual POSIX dirfd API.

    Keep the same fixed-root/marker/generation and leaf identity guards while
    exercising HTTP on Windows. Mac executes the unmodified production reader.
    """

    def _open_root(self):
        return None

    def verify(self):
        disk._verify_claim(self.owned, self.repository, self.generation, self.cache)

    def _open_leaf(self, store, digest):
        path = self.cache / store / digest[:2] / digest
        try:
            disk._directory(path.parent)
        except ValueError as error:
            raise PermissionError(errno.EACCES, 'Fixture rejects reparse points') from error
        before = path.lstat()
        cache._check_leaf(before)
        fd = os.open(path, os.O_RDONLY | os.O_BINARY)
        try:
            actual = os.fstat(fd)
            cache._check_leaf(actual)
            if cache._identity(actual) != cache._identity(before):
                raise PermissionError(errno.EACCES, 'Fixture leaf changed while opening')
        except BaseException:
            os.close(fd)
            raise
        return fd, actual


class ReadOnlyCacheTests(unittest.TestCase):
    def setUp(self):
        parent = Path(os.environ['LOCALAPPDATA']) / 'Temp/opencode' if os.name == 'nt' else None
        self.temporary = tempfile.TemporaryDirectory(prefix='native-http-cache-', dir=parent)
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.owned = self.base / 'owned'
        self.repository, self.generation = 'fixture/native', 'http-cache-1'
        claim_workspace(self.owned, self.repository)
        (self.owned / 'telegram-ios').mkdir()
        (self.owned / 'telegram-ios/versions.json').write_text('{"bazel":"9.2.0:fixture"}')
        self.ready()
        self.cache_root = self.base / 'cache-parent/exteraless-bazel-disk'
        self.cache_root.mkdir(parents=True)
        self.patch_root = patch.object(disk, 'TRUSTED_CACHE', self.cache_root)
        self.patch_root.start(); self.addCleanup(self.patch_root.stop)
        self.patch_env = patch.dict(os.environ, {'BAZEL_DISK_CACHE': str(self.cache_root)})
        self.patch_env.start(); self.addCleanup(self.patch_env.stop)
        disk.claim_cache(self.owned, self.repository, self.generation, self.cache_root)
        self.content = bytes(range(256)) * (cache.CHUNK_BYTES // 256 * 3) + b'cache-body-not-for-logs'
        self.digest = hashlib.sha256(self.content).hexdigest()
        self.blob = self.put('cas', self.digest, self.content)
        self.action_key = hashlib.sha256(b'action-key-not-the-result-hash').hexdigest()
        self.action_content = b'\x18\x00\x2a\x05owned'
        self.action = self.put('ac', self.action_key, self.action_content)
        self.retained = [self.owned / 'telegram-ios/source.swift', self.base / 'materialized.o',
                         self.base / 'ClientUIHarness.ipa', self.base / 'unrelated-user-data']
        for path in self.retained:
            path.write_bytes(b'preserve fixture source/output/IPA/user bytes')
        self.baseline = self.snapshot([self.blob, self.action, *self.retained])
        self.console = io.StringIO()
        redirect = contextlib.redirect_stdout(self.console)
        redirect.__enter__(); self.addCleanup(redirect.__exit__, None, None, None)

    def ready(self, generation=None):
        write_generation(self.owned, {'schema': 1, 'repository': self.repository,
                                     'generation': generation or self.generation, 'ready': True})

    def put(self, store, digest, content):
        path = self.cache_root / store / digest[:2] / digest
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def snapshot(self, paths):
        return {str(p): (hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mtime_ns) for p in paths}

    def service(self, **options):
        reader = _WindowsFixtureReader if os.name == 'nt' else cache.ClaimedCacheReader
        return cache.ReadOnlyCache(self.owned, self.repository, self.generation, self.cache_root,
                                  report=self.base / 'readonly-cache.json', _reader_factory=reader, **options)

    def request(self, server, method, path, *, body=None, headers=None):
        connection = http.client.HTTPConnection('127.0.0.1', server.server.server_address[1], timeout=2)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            self.assertEqual(response.version, 11, 'Bazel HTTP cache requires HTTP/1.1 responses')
            return response.status, dict(response.getheaders()), response.read(len(self.content) + 8192)
        finally:
            connection.close()

    def directory_link(self, link, target):
        try:
            link.symlink_to(target, target_is_directory=True)
        except OSError:
            if os.name != 'nt':
                raise
            result = subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/J', str(link), str(target)],
                                    capture_output=True, timeout=3)
            self.assertEqual(result.returncode, 0, 'Fixture junction creation failed')

    def test_http_get_head_exact_ac_and_multichunk_cas_preserve_all_files(self):
        with self.service() as server:
            self.assertEqual(server.server.server_address[0], '127.0.0.1')
            self.assertEqual(self.request(server, 'GET', '/cas/' + self.digest)[0], 404)
            server.enable_reads()
            for store, digest, content in (('cas', self.digest, self.content), ('ac', self.action_key, self.action_content)):
                status, headers, body = self.request(server, 'GET', '/' + store + '/' + digest)
                self.assertEqual((status, body), (200, content))
                self.assertEqual(headers['Content-Length'], str(len(content)))
                status, headers, body = self.request(server, 'HEAD', '/' + store + '/' + digest)
                self.assertEqual((status, body, headers['Content-Length']), (200, b'', str(len(content))))
            self.assertNotEqual(self.action_key, hashlib.sha256(self.action_content).hexdigest())
        self.assertEqual(self.snapshot([self.blob, self.action, *self.retained]), self.baseline)
        report = json.loads((self.base / 'readonly-cache.json').read_text())
        self.assertEqual(report['status'], 'stopped')
        self.assertEqual(report['counters']['bytesSent'], len(self.content) + len(self.action_content))
        self.assertEqual(report['activeWorkers'], 0)
        self.assertFalse(report['rootDescriptorOpen'])
        self.assertNotIn('cache-body-not-for-logs', self.console.getvalue())

    def test_cache_misses_include_evicted_cas_of_a_remaining_action_result(self):
        with self.service() as server:
            server.enable_reads()
            self.assertEqual(self.request(server, 'GET', '/ac/' + self.action_key)[0], 200)
            self.blob.unlink()  # Only this disposable fixture simulates the completed pressure GC.
            for method, path in (('GET', '/cas/' + self.digest), ('HEAD', '/cas/' + self.digest),
                                 ('GET', '/ac/' + 'f' * 64)):
                self.assertEqual(self.request(server, method, path)[::2], (404, b''))
        self.assertEqual(self.snapshot(self.retained), {str(p): self.baseline[str(p)] for p in self.retained})

    def test_mutations_and_paths_outside_the_digest_protocol_are_rejected(self):
        with self.service() as server:
            server.enable_reads()
            for method in ('PUT', 'POST', 'DELETE', 'PATCH', 'OPTIONS'):
                self.assertEqual(self.request(server, method, '/cas/' + self.digest, body=b'never-write-this')[0], 405)
            for path in ('/../unrelated-user-data', '/cas/../unrelated-user-data', '/cas/%2e%2e/secret',
                         '//cas/' + self.digest, '/cas/' + self.digest + '?query=1',
                         '/cas/' + self.digest.upper(), '/cas/' + self.digest + '/extra',
                         'http://outside.invalid/cas/' + self.digest, '/' + disk.CACHE_MARKER):
                self.assertIn(self.request(server, 'GET', path)[0], (400, 403), path)
            self.assertEqual(self.request(server, 'GET', '/cas/' + self.digest,
                                          headers={'Host': 'outside.invalid'})[0], 403)
        self.assertEqual(self.snapshot([self.blob, self.action, *self.retained]), self.baseline)
        self.assertNotIn('never-write-this', self.console.getvalue())

    def test_symlink_or_junction_shard_and_hardlinked_leaf_cannot_read_outside(self):
        outside = self.base / 'outside'; outside.mkdir()
        key = 'e' * 64
        protected = outside / key; protected.write_bytes(b'outside-private-fixture')
        self.directory_link(self.cache_root / 'cas/ee', outside)
        linked = self.cache_root / 'cas/dd' / ('d' * 64); linked.parent.mkdir()
        os.link(self.retained[-1], linked)
        with self.service() as server:
            server.enable_reads()
            for digest in (key, 'd' * 64):
                status, _, body = self.request(server, 'GET', '/cas/' + digest)
                self.assertEqual((status, body), (403, b''))
        self.assertEqual(protected.read_bytes(), b'outside-private-fixture')
        self.assertEqual(self.snapshot(self.retained), {str(p): self.baseline[str(p)] for p in self.retained})

    def test_leaf_changed_between_stat_and_open_is_refused(self):
        original = os.open
        def changed_open(path, *args, **kwargs):
            if str(path) in (str(self.blob), self.digest):
                self.blob.write_bytes(b'changed cache leaf')
            return original(path, *args, **kwargs)
        with self.service() as server:
            server.enable_reads()
            with patch.object(cache.os, 'open', side_effect=changed_open):
                self.assertEqual(self.request(server, 'GET', '/cas/' + self.digest)[0], 403)

    def test_stale_generation_and_arbitrary_root_fail_before_bind(self):
        self.ready('new-generation')
        with patch.object(cache, '_Server') as bind, self.assertRaisesRegex(ValueError, 'generation'):
            with self.service():
                self.fail('must not bind')
        bind.assert_not_called()
        self.ready()
        service = self.service()
        service.cache = self.base
        with patch.object(cache, '_Server') as bind, self.assertRaisesRegex(ValueError, 'fixed CI'):
            with service:
                self.fail('must not adopt arbitrary file paths')
        bind.assert_not_called()

    def test_generation_change_after_start_refuses_reads_and_fails_phase_health(self):
        with self.assertRaises(RuntimeError):
            with self.service() as server:
                server.enable_reads()
                self.ready('new-generation')
                self.assertEqual(self.request(server, 'GET', '/cas/' + self.digest)[::2], (503, b''))
        self.assertFalse(server.thread.is_alive())
        self.assertEqual(self.snapshot([self.blob, self.action, *self.retained]), self.baseline)

    def test_request_quota_is_reported_and_stops_serving_files(self):
        with self.assertRaisesRegex(RuntimeError, 'quota'):
            with self.service(limits=cache.HttpLimits(requests=2)) as server:
                server.enable_reads()
                for _ in range(2):
                    self.assertEqual(self.request(server, 'HEAD', '/cas/' + self.digest)[0], 200)
                self.assertEqual(self.request(server, 'GET', '/cas/' + self.digest)[::2], (429, b''))
        report = json.loads((self.base / 'readonly-cache.json').read_text())
        self.assertEqual(report['counters']['requests'], 2)
        self.assertEqual(report['activeConnections'], 0)
        self.assertIn('quota', report['error'])

    def test_headers_and_stream_reads_are_bounded(self):
        reads = []
        original = os.read
        def bounded_read(fd, amount):
            self.assertLessEqual(amount, cache.CHUNK_BYTES)
            reads.append(amount)
            return original(fd, amount)
        with self.service() as server:
            server.enable_reads()
            self.assertEqual(self.request(server, 'GET', '/cas/' + self.digest,
                headers={'X-Oversized': 'x' * (server.limits.header_bytes + 1)})[0], 431)
            with patch.object(cache.os, 'read', side_effect=bounded_read):
                self.assertEqual(self.request(server, 'GET', '/cas/' + self.digest)[2], self.content)
        self.assertGreaterEqual(reads.count(cache.CHUNK_BYTES), 3)

    def test_concurrent_request_admission_is_bounded_while_one_header_is_stalled(self):
        with self.service(limits=cache.HttpLimits(connections=1)) as server:
            server.enable_reads()
            with socket.create_connection(server.server.server_address, timeout=2) as stalled:
                stalled.sendall(b'GET /cas/')
                deadline = time.monotonic() + 1
                while not server.connections and time.monotonic() < deadline:
                    time.sleep(0.005)
                self.assertEqual(len(server.connections), 1)
                self.assertEqual(self.request(server, 'HEAD', '/cas/' + self.digest)[0], 503)
                self.assertEqual(len(server.workers), 1)
                self.assertEqual(server.stats['requests'], 1)
        self.assertFalse(server.workers)

    def test_partial_header_request_has_a_total_deadline(self):
        with self.service(limits=cache.HttpLimits(request_seconds=0.15)) as server:
            started = time.monotonic()
            with socket.create_connection(server.server.server_address, timeout=2) as stalled:
                stalled.sendall(b'GET /cas/')
                self.assertEqual(stalled.recv(1024), b'')
            self.assertLess(time.monotonic() - started, 1)
        self.assertFalse(server.workers)

    def test_exception_cleanup_closes_stalled_request_thread_fds_and_releases_bind(self):
        stalled = None
        try:
            with self.assertRaisesRegex(RuntimeError, 'fixture compile failure'):
                with self.service() as server:
                    server.enable_reads()
                    address = server.server.server_address
                    self.assertEqual(self.request(server, 'HEAD', '/cas/' + self.digest)[0], 200)
                    stalled = socket.create_connection(address, timeout=2)
                    stalled.sendall(b'GET /cas/')
                    deadline = time.monotonic() + 1
                    while not server.connections and time.monotonic() < deadline:
                        time.sleep(0.005)
                    self.assertTrue(server.connections)
                    raise RuntimeError('fixture compile failure')
            self.assertFalse(server.thread.is_alive())
            self.assertEqual(server.server.socket.fileno(), -1)
            self.assertFalse(server.workers)
            self.assertFalse(server.connections)
            self.assertIsNone(server.reader.root_fd)
            with socket.socket() as rebound:
                rebound.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                rebound.bind(address)
        finally:
            if stalled is not None:
                stalled.close()

    @unittest.skipUnless(os.name == 'posix', 'Production O_NOFOLLOW/dirfd read path runs in the Mac gate')
    def test_posix_reader_holds_root_fd_and_rejects_leaf_symlink(self):
        self.blob.unlink()
        self.blob.symlink_to(self.retained[-1])
        with self.service() as server:
            root_fd = server.reader.root_fd
            self.assertGreaterEqual(root_fd, 0)
            server.enable_reads()
            self.assertEqual(self.request(server, 'GET', '/cas/' + self.digest)[::2], (403, b''))
        with self.assertRaises(OSError):
            os.fstat(root_fd)


class NativeCacheCommandTests(unittest.TestCase):
    def test_native_args_supply_one_cache_enabled_mode_after_the_app_disk_flag(self):
        from tools.ci.tests.test_native_test_workflow import NativeTestWorkflowChecks
        line = NativeTestWorkflowChecks().command_line()
        endpoint = 'http://127.0.0.1:43217'
        service = cache.ReadOnlyCache('/unused', 'fixture/native', 'generation', '/unused')
        service.endpoint = endpoint
        target = '//Tests/Exteraless:NativeUIContractsTests'
        commands = [line.get_unsigned_test_preflight_arguments([target]),
                    line.get_test_arguments([target], build_only=True),
                    line.get_test_arguments(target, run_only=True, test_timeout=270, streamed=True)]
        for command in commands:
            effective = native.native_args(line, command, service)
            self.assertEqual(effective[-len(service.flags):], service.flags)
            self.assertLess(effective.index('--disk_cache=/cache'), effective.index('--disk_cache='))
            self.assertIn('--remote_cache=' + endpoint, effective)
            self.assertIn('--remote_upload_local_results=false', effective)
            self.assertIn('--remote_accept_cached=true', effective)
            self.assertIn('--remote_executor=', effective)
            self.assertIn('--remote_instance_name=', effective)
            self.assertIn('--remote_verify_downloads=true', effective)
            self.assertFalse(any(flag.startswith('--remote_download_outputs=') for flag in service.flags))
        self.assertNotIn('--check_up_to_date', commands[1])
        self.assertIn('--check_up_to_date', commands[-1])
        self.assertIn('--cache_test_results=no', commands[-1])
        self.assertEqual([flag for flag in service.flags if not flag.startswith('--remote_cache=')],
                         [flag for flag in cache.cache_flags('http://127.0.0.1:43218') if not flag.startswith('--remote_cache=')])

    def test_non_loopback_or_credential_endpoints_are_never_command_inputs(self):
        for endpoint in ('http://0.0.0.0:123', 'http://localhost:123', 'http://127.0.0.1:0',
                         'http://127.0.0.1:99999', 'http://user:token@127.0.0.1:123',
                         'http://127.0.0.1:123/other', 'https://remote.example:123'):
            with self.assertRaises(ValueError):
                cache.cache_flags(endpoint)

    def test_all_native_commands_and_cleanup_are_inside_the_single_cache_context(self):
        tree = ast.parse((ROOT / 'tools/runtime/run_native_integration_tests.py').read_text())
        execute = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'execute')
        context = next(n for n in ast.walk(execute) if isinstance(n, ast.With) and any(
            isinstance(i.context_expr, ast.Call) and isinstance(i.context_expr.func, ast.Name)
            and i.context_expr.func.id == 'ReadOnlyCache' for i in n.items))
        calls = [n for n in ast.walk(context) if isinstance(n, ast.Call)]
        modes = []
        for call in calls:
            if isinstance(call.func, ast.Name) and call.func.id == 'native_args':
                self.assertEqual(call.args[-1].id, 'cache')
                modes.append(call.args[1].func.attr)
        self.assertEqual(sorted(modes), ['get_test_arguments', 'get_test_arguments', 'get_unsigned_test_preflight_arguments'])
        source = (ROOT / 'tools/runtime/run_native_integration_tests.py').read_text()
        self.assertLess(source.index('validate_runtime_actions(graph, staging)'), source.index('bazel_output = prepare_native_disk'))
        self.assertLess(source.index('bazel_output = prepare_native_disk'), source.index('cache.enable_reads()'))
        self.assertLess(source.index('cache.enable_reads()'), source.index('run_logged(native_args'))
        self.assertTrue(any(isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
                            and n.func.id == 'shutdown_device' for n in ast.walk(context)))


if __name__ == '__main__':
    unittest.main()
