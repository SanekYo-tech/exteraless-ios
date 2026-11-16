"""Phase-owned read-only HTTP view of the claimed Bazel 9.2 SHA-256 AC/CAS.

There is no standalone server command or configurable bind/cache root. The native
runner owns this context from aquery through the last XCTest class. Only the
existing fixed-root/generation claim authorizes reads; cache misses are HTTP 404.
"""

from contextlib import contextmanager
from dataclasses import dataclass
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import socketserver
import stat
import threading
import time

import native_test_disk as disk

MODE = 'claimed-bazel-ac-cas-complete-readonly-http-v2'
ROUTE = re.compile(r'/(ac|cas)/([0-9a-f]{64})\Z')
CHUNK_BYTES = 256 * 1024
MAX_CONNECTIONS = 8


@dataclass(frozen=True)
class HttpLimits:
    requests: int = 200000
    connections: int = MAX_CONNECTIONS
    header_bytes: int = 8192
    request_seconds: float = 30
    shutdown_seconds: float = 5
    action_bytes: int = 16 * 1024 * 1024
    tree_bytes: int = 16 * 1024 * 1024
    metadata_bytes: int = 32 * 1024 * 1024
    closure_fields: int = 262144
    closure_references: int = 65536
    closure_directories: int = 8192
    closure_depth: int = 128
    closure_seconds: float = 5


def cache_flags(endpoint):
    if not re.fullmatch(r'http://127\.0\.0\.1:[1-9][0-9]{0,4}', endpoint):
        raise ValueError('Native cache endpoint must be the owned IPv4 loopback listener')
    if not 1 <= int(endpoint.rsplit(':', 1)[1]) <= 65535:
        raise ValueError('Invalid native cache port')
    # RemoteModule.computeActionExecutionSalt: both disk and HTTP modes set the
    # same isRemoteCacheEnabled bit. The URL, port and upload switch are not salted.
    # HTTP uses the same ActionKey/CAS digest strings as DiskCacheClient.toPath.
    return [*disk.NATIVE_CACHE_FLAGS, '--remote_cache=' + endpoint,
            '--remote_executor=', '--remote_instance_name=', '--remote_accept_cached=true',
            '--remote_verify_downloads=true', '--remote_download_outputs=all',
            '--remote_max_connections=' + str(MAX_CONNECTIONS), '--remote_timeout=30s', '--remote_retries=0']


def _identity(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def _check_leaf(info):
    if disk._is_link(info) or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise PermissionError(errno.EACCES, 'Cache leaf must be a regular single-link digest file')


class IncompleteActionResult(Exception):
    """An ineligible AC record is a cache miss, never a fatal service error."""

    def __init__(self, reason):
        self.reason = reason
        super().__init__(reason)


# Bazel 9.2.0 third_party/remoteapis/build/bazel/remote/execution/v2/remote_execution.proto.
# Numbers are protobuf field tags, not JSON names. Unknown fields/encodings miss
# closed until reviewed. Opaque bytes (logs/Any.value) have no CAS references.
# A list marks a repeated field; every other field is singular.
_SCHEMAS = {
    'Digest': {1: 'text', 2: 'int'},
    'Timestamp': {1: 'int', 2: 'int'},
    'UInt32': {1: 'int'},
    'Any': {1: 'text', 2: 'bytes'},
    'NodeProperty': {1: 'text', 2: 'text'},
    'NodeProperties': {1: ['NodeProperty'], 2: 'Timestamp', 3: 'UInt32'},
    'FileNode': {1: 'text', 2: 'Digest', 4: 'bool', 6: 'NodeProperties'},
    'DirectoryNode': {1: 'text', 2: 'Digest'},
    'Symlink': {1: 'text', 2: 'text', 4: 'NodeProperties'},
    'Directory': {1: ['FileNode'], 2: ['DirectoryNode'], 3: ['Symlink'], 5: 'NodeProperties'},
    'Tree': {1: 'Directory', 2: ['Directory']},
    'OutputFile': {1: 'text', 2: 'Digest', 4: 'bool', 5: 'bytes', 7: 'NodeProperties'},
    'OutputDirectory': {1: 'text', 3: 'Digest', 4: 'bool', 5: 'Digest'},
    'Metadata': {1: 'text', **{i: 'Timestamp' for i in range(2, 11)}, 11: ['Any'], 12: 'Timestamp'},
    'ActionResult': {2: ['OutputFile'], 3: ['OutputDirectory'], 4: 'int', 5: 'bytes',
                     6: 'Digest', 7: 'bytes', 8: 'Digest', 9: 'Metadata',
                     10: ['Symlink'], 11: ['Symlink'], 12: ['Symlink']},
}
_EMPTY_HASH = hashlib.sha256(b'').hexdigest()


class _ClosureBudget:
    def __init__(self, limits, deadline):
        self.limits = limits
        self.deadline = min(deadline, time.monotonic() + limits.closure_seconds)
        self.fields = self.metadata_bytes = self.directories = 0
        self.checked = set()

    def tick(self):
        if time.monotonic() >= self.deadline:
            raise IncompleteActionResult('budget')


def _varint(data, position):
    value = 0
    for shift in range(0, 70, 7):
        if position >= len(data):
            raise IncompleteActionResult('malformed')
        byte = data[position]
        position += 1
        if shift == 63 and byte > 1:
            raise IncompleteActionResult('malformed')
        value |= (byte & 127) << shift
        if byte < 128:
            if shift and byte == 0:
                raise IncompleteActionResult('malformed')
            return value, position
    raise IncompleteActionResult('malformed')


def _wire_fields(data, budget):
    data = memoryview(data)
    position = 0
    while position < len(data):
        budget.tick()
        budget.fields += 1
        if budget.fields > budget.limits.closure_fields:
            raise IncompleteActionResult('budget')
        tag, position = _varint(data, position)
        number, wire = tag >> 3, tag & 7
        if not 1 <= number < (1 << 29) or wire not in (0, 2):
            raise IncompleteActionResult('malformed')
        value, position = _varint(data, position)
        if wire == 2:
            if value > len(data) - position:
                raise IncompleteActionResult('malformed')
            value, position = data[position:position + value], position + value
        yield number, wire, value


def _message(data, kind, budget, depth=0):
    if depth > 16:
        raise IncompleteActionResult('budget')
    result = {}
    for number, wire, value in _wire_fields(data, budget):
        rule = _SCHEMAS[kind].get(number)
        repeated = isinstance(rule, list)
        rule = rule[0] if repeated else rule
        if rule is None or (number in result and not repeated):
            raise IncompleteActionResult('malformed')
        if wire != (0 if rule in ('int', 'bool') else 2):
            raise IncompleteActionResult('malformed')
        if rule == 'bool' and value not in (0, 1):
            raise IncompleteActionResult('malformed')
        if rule == 'text':
            if len(value) > 16384:
                raise IncompleteActionResult('budget')
            try:
                value = bytes(value).decode('utf-8')
            except UnicodeError:
                raise IncompleteActionResult('malformed') from None
            if '\x00' in value:
                raise IncompleteActionResult('malformed')
        elif rule not in ('int', 'bool', 'bytes'):
            value = _message(value, rule, budget, depth + 1)
        if repeated:
            result.setdefault(number, []).append(value)
        else:
            result[number] = value
    return result


def _digest(message):
    if not isinstance(message, dict):
        raise IncompleteActionResult('malformed')
    value, size = message.get(1), message.get(2, 0)
    if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value) or not 0 <= size < (1 << 63):
        raise IncompleteActionResult('malformed')
    if size == 0 and value != _EMPTY_HASH:
        raise IncompleteActionResult('malformed')
    return value, size


def _output_path(value, *, node=False, empty=False):
    if not isinstance(value, str) or (not value and not empty) or value.startswith('/'):
        raise IncompleteActionResult('malformed')
    if value and (any(p in ('', '.', '..') for p in value.split('/')) or (node and '/' in value)):
        raise IncompleteActionResult('malformed')


def _read_metadata(fd, size, maximum, budget):
    budget.tick()
    if size > maximum or budget.metadata_bytes + size > budget.limits.metadata_bytes:
        raise IncompleteActionResult('budget')
    budget.metadata_bytes += size
    before = os.fstat(fd)
    data = bytearray(size)
    position = 0
    while position < size:
        budget.tick()
        chunk = os.read(fd, min(CHUNK_BYTES, size - position))
        if not chunk:
            raise IncompleteActionResult('malformed')
        data[position:position + len(chunk)] = chunk
        position += len(chunk)
    if _identity(os.fstat(fd)) != _identity(before):
        raise IncompleteActionResult('changed-metadata')
    return data


def _cas(reader, digest, budget, *, metadata=False):
    budget.tick()
    value, size = digest
    if digest not in budget.checked:
        if len(budget.checked) >= budget.limits.closure_references:
            raise IncompleteActionResult('budget')
        budget.checked.add(digest)
    elif not metadata:
        return None
    if size == 0:
        return bytearray() if metadata else None
    try:
        fd, info = reader._open_leaf('cas', value)
        try:
            if info.st_size != size:
                raise IncompleteActionResult('missing-cas')
            if metadata:
                data = _read_metadata(fd, size, budget.limits.tree_bytes, budget)
                if hashlib.sha256(data).hexdigest() != value:
                    raise IncompleteActionResult('malformed')
                return data
        finally:
            os.close(fd)
    except OSError:
        # Missing, denied, linked or replaced CAS is an AC miss. The direct CAS
        # route retains its existing no-follow/permission response behavior.
        raise IncompleteActionResult('missing-cas') from None


def _symlink(message, *, node=False):
    _output_path(message.get(1), node=node)
    if not message.get(2):
        raise IncompleteActionResult('malformed')
    # The target is REAPI metadata (including allowed absolute/.. targets).
    # Never follow it or use it to choose a local file.


def _directory_edges(reader, message, budget):
    budget.directories += 1
    if budget.directories > budget.limits.closure_directories:
        raise IncompleteActionResult('budget')
    names, edges = set(), []
    for field in (1, 2, 3):
        for node in message.get(field, []):
            name = node.get(1)
            _output_path(name, node=True)
            if name in names:
                raise IncompleteActionResult('malformed')
            names.add(name)
            if field == 1:
                _cas(reader, _digest(node.get(2)), budget)
            elif field == 2:
                edges.append(_digest(node.get(2)))
            else:
                _symlink(node, node=True)
    return edges


def _tree(reader, digest, expected_root, budget):
    data = _cas(reader, digest, budget, metadata=True)
    root, directories = None, {}
    # Preserve each serialized Directory to verify DirectoryNode -> Tree.children
    # links. Child directories need not also exist as standalone CAS blobs.
    for number, wire, payload in _wire_fields(data, budget):
        if number not in (1, 2) or wire != 2 or (number == 1 and root is not None):
            raise IncompleteActionResult('malformed')
        key = hashlib.sha256(payload).hexdigest(), len(payload)
        if number == 1:
            root = key
        if key not in directories:
            message = _message(payload, 'Directory', budget)
            directories[key] = _directory_edges(reader, message, budget)
    if root is None:
        if data:
            raise IncompleteActionResult('malformed')
        root = (_EMPTY_HASH, 0)
        directories[root] = []
    if expected_root is not None and root != expected_root:
        raise IncompleteActionResult('malformed')
    pending, seen = [(root, 0)], set()
    while pending:
        budget.tick()
        key, depth = pending.pop()
        if depth > budget.limits.closure_depth:
            raise IncompleteActionResult('budget')
        if key in seen:
            continue
        if key not in directories:
            raise IncompleteActionResult('missing-cas')
        seen.add(key)
        pending.extend((child, depth + 1) for child in directories[key])
    if len(seen) != len(directories):
        raise IncompleteActionResult('malformed')


def check_action_result(reader, fd, size, limits, deadline):
    """Admit complete REAPI ActionResult only, before sending an HTTP 200/HEAD.

    AC is keyed by Action digest, NOT the hash of these serialized result bytes.
    Ordinary CAS payloads are checked for existence/size here; Bazel verifies
    their content hashes while downloading. Only bounded metadata is read here.
    """
    budget = _ClosureBudget(limits, deadline)
    data = _read_metadata(fd, size, limits.action_bytes, budget)
    action = _message(data, 'ActionResult', budget)
    if action.get(4, 0) != 0:
        raise IncompleteActionResult('malformed')
    for output in action.get(2, []):
        _output_path(output.get(1))
        digest = _digest(output.get(2))
        _cas(reader, digest, budget)
        if 5 in output and (len(output[5]) != digest[1] or hashlib.sha256(output[5]).hexdigest() != digest[0]):
            raise IncompleteActionResult('malformed')
    for output in action.get(3, []):
        _output_path(output.get(1, ''), empty=True)
        # Bazel 9.2 consumes Tree, not the newer root-directory-only encoding.
        # Unsupported encodings are misses rather than falsely complete hits.
        _tree(reader, _digest(output.get(3)), _digest(output[5]) if 5 in output else None, budget)
    for field in (6, 8):
        if field in action:
            digest = _digest(action[field])
            _cas(reader, digest, budget)
            raw = action.get(field - 1)
            if raw is not None and (len(raw) != digest[1] or hashlib.sha256(raw).hexdigest() != digest[0]):
                raise IncompleteActionResult('malformed')
    for field in (10, 11, 12):
        for link in action.get(field, []):
            _symlink(link)
    budget.tick()
    os.lseek(fd, 0, os.SEEK_SET)
    return len(budget.checked)


class ClaimedCacheReader:
    """Hold the claimed root FD; every shard and leaf open is relative/no-follow."""

    def __init__(self, owned, repository, generation, cache):
        self.owned, self.repository, self.generation = Path(owned), repository, generation
        self.cache = disk._cache_path(cache)
        self.root_fd = None
        disk._verify_claim(self.owned, repository, generation, self.cache)
        if disk._json_file(self.owned / 'telegram-ios/versions.json').get('bazel', '').split(':', 1)[0] != '9.2.0':
            raise ValueError('Reverify HTTP/disk key and salt equivalence for the changed Bazel version')
        self.root_fd = self._open_root()
        try:
            self.verify()
        except BaseException:
            self.close()
            raise

    def _open_root(self):
        return disk._open_directory_fd(self.cache)

    def verify(self):
        disk._verify_claim(self.owned, self.repository, self.generation, self.cache)
        actual = os.fstat(self.root_fd)
        expected = self.cache.lstat()
        if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
            raise ValueError('Read-only cache root FD no longer matches the generation claim')

    def _open_leaf(self, store, digest):
        parent = os.dup(self.root_fd)
        leaf = None
        try:
            for name in (store, digest[:2]):
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                os.close(parent)
                parent = child
            before = os.stat(digest, dir_fd=parent, follow_symlinks=False)
            _check_leaf(before)
            leaf = os.open(digest, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            actual = os.fstat(leaf)
            _check_leaf(actual)
            if _identity(actual) != _identity(before):
                raise PermissionError(errno.EACCES, 'Cache leaf changed while opening')
            result, leaf = leaf, None
            return result, actual
        finally:
            os.close(parent)
            if leaf is not None:
                os.close(leaf)

    @contextmanager
    def blob(self, store, digest):
        if store not in ('ac', 'cas') or not re.fullmatch('[0-9a-f]{64}', digest):
            raise PermissionError(errno.EACCES, 'Invalid AC/CAS digest route')
        try:
            self.verify()
        except (OSError, ValueError) as error:
            raise ValueError('Read-only cache ownership/generation is no longer valid') from error
        fd, before = self._open_leaf(store, digest)
        try:
            yield fd, before.st_size
            if _identity(os.fstat(fd)) != _identity(before):
                raise ValueError('Cache leaf changed while streaming')
        finally:
            os.close(fd)

    def close(self):
        if self.root_fd is not None:
            os.close(self.root_fd)
            self.root_fd = None


class _RequestError(Exception):
    def __init__(self, status):
        self.status = status


def _remaining(deadline):
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        raise TimeoutError('Read-only cache request deadline exceeded')
    return seconds


def _headers(connection, limits, deadline, owner):
    data = bytearray()
    while b'\r\n\r\n' not in data:
        if len(data) >= limits.header_bytes:
            raise _RequestError(431)
        if owner.stopping:
            raise ConnectionAbortedError('Native cache phase is closing')
        connection.settimeout(min(0.25, _remaining(deadline)))
        try:
            chunk = connection.recv(min(4096, limits.header_bytes - len(data)))
        except socket.timeout:
            continue
        if not chunk:
            raise _RequestError(400)
        data.extend(chunk)
    lines = bytes(data).split(b'\r\n\r\n', 1)[0].split(b'\r\n')
    if len(lines) > 33 or len(lines[0]) > 1024:
        raise _RequestError(431)
    try:
        method, path, version = lines[0].decode('ascii').split(' ')
        headers = {}
        for line in lines[1:]:
            name, value = line.decode('ascii').split(':', 1)
            if not re.fullmatch('[A-Za-z0-9-]+', name) or name.lower() in headers:
                raise ValueError('Invalid/duplicate header')
            headers[name.lower()] = value.strip()
    except (UnicodeError, ValueError):
        raise _RequestError(400) from None
    if version not in ('HTTP/1.0', 'HTTP/1.1'):
        raise _RequestError(400)
    if method not in ('GET', 'HEAD'):
        raise _RequestError(405)
    if headers.get('content-length', '0') != '0' or 'transfer-encoding' in headers:
        raise _RequestError(400)
    return method, path, headers


def _respond(connection, status, length=0):
    reason = {200: 'OK', 400: 'Bad Request', 403: 'Forbidden', 404: 'Not Found',
              405: 'Method Not Allowed', 429: 'Too Many Requests',
              431: 'Request Header Fields Too Large', 503: 'Service Unavailable'}[status]
    headers = f'HTTP/1.1 {status} {reason}\r\nContent-Length: {length}\r\nConnection: close\r\n'
    if status == 200:
        headers += 'Content-Type: application/octet-stream\r\n'
    if status == 405:
        headers += 'Allow: GET, HEAD\r\n'
    connection.sendall((headers + '\r\n').encode('ascii'))


class _Handler(socketserver.BaseRequestHandler):
    def handle(self):
        owner = self.server.owner
        deadline = time.monotonic() + owner.limits.request_seconds
        sent = False
        try:
            method, path, headers = _headers(self.request, owner.limits, deadline, owner)
            if headers.get('host') != owner.endpoint.removeprefix('http://'):
                raise _RequestError(403)
            route = ROUTE.fullmatch(path)
            if route is None:
                raise _RequestError(400)
            if not owner.reads_enabled.is_set():
                raise _RequestError(404)  # aquery/GC: keep the cache bit, but admit no disk readers.
            with owner.reader.blob(*route.groups()) as (fd, size):
                if route.group(1) == 'ac':
                    owner.count('acChecked')
                    references = check_action_result(owner.reader, fd, size, owner.limits, deadline)
                    owner.count('acReferencesChecked', references)
                self.request.settimeout(_remaining(deadline))
                _respond(self.request, 200, size)
                sent = True
                owner.count('hits')
                if method == 'GET':
                    remaining = size
                    while remaining:
                        self.request.settimeout(_remaining(deadline))
                        chunk = os.read(fd, min(CHUNK_BYTES, remaining))
                        if not chunk:
                            raise ValueError('Truncated claimed cache blob')
                        self.request.sendall(chunk)
                        remaining -= len(chunk)
                        owner.count('bytesSent', len(chunk))
        except IncompleteActionResult as error:
            owner.count('misses')
            owner.count('acMisses')
            with owner.lock:
                owner.ac_miss_reasons[error.reason] = owner.ac_miss_reasons.get(error.reason, 0) + 1
            if not sent:
                _respond(self.request, 404)
        except _RequestError as error:
            owner.count('misses' if error.status == 404 else 'rejected')
            if not sent:
                _respond(self.request, error.status)
        except FileNotFoundError:
            owner.count('misses')
            if not sent:
                _respond(self.request, 404)
        except OSError as error:
            if error.errno in (errno.ELOOP, errno.ENOTDIR, errno.EACCES, errno.EPERM):
                owner.count('rejected')
                if not sent:
                    _respond(self.request, 403)
            else:
                owner.count('aborted')  # Disconnected/slow clients never retain a worker or leaf FD.
        except ValueError:
            owner.fail('Cache claim/generation or blob identity validation failed')
            if not sent:
                _respond(self.request, 503)


class _Server(socketserver.TCPServer):
    allow_reuse_address = True
    request_queue_size = MAX_CONNECTIONS
    timeout = 0.05

    def __init__(self, owner):
        self.owner = owner
        super().__init__(('127.0.0.1', 0), _Handler)

    def process_request(self, request, client_address):
        owner = self.owner
        with owner.lock:
            status = None
            if client_address[0] != '127.0.0.1' or owner.stopping:
                status = 403
            elif owner.stats['requests'] >= owner.limits.requests:
                status = 429
                owner.failure = 'Read-only cache request quota exhausted'
            elif len(owner.connections) >= owner.limits.connections:
                status = 503
            if status is None:
                owner.stats['requests'] += 1
                owner.connections.add(request)
                thread = threading.Thread(target=self._worker, args=(request, client_address),
                                          name='native-cache-request', daemon=True)
                owner.workers.add(thread)
                thread.start()
                return
            owner.stats['rejected'] += 1
        try:
            request.settimeout(0.1)
            _respond(request, status)
        except OSError:
            pass
        finally:
            self._finish_connection(request)

    def _finish_connection(self, request):
        # A rejected request can still have headers/a small body in flight.
        # Half-close and boundedly drain so an unread-data TCP reset does not
        # discard the 405/429. Nothing drained is parsed, stored or logged.
        try:
            request.shutdown(socket.SHUT_WR)
            left = self.owner.limits.header_bytes
            deadline = time.monotonic() + 0.1
            while left and not self.owner.stopping:
                request.settimeout(_remaining(deadline))
                chunk = request.recv(min(4096, left))
                if not chunk:
                    break
                left -= len(chunk)
        except OSError:
            pass
        self.close_request(request)

    def _worker(self, request, address):
        try:
            self.finish_request(request, address)
        except OSError:
            self.owner.count('aborted')
        except Exception:
            self.owner.fail('Read-only cache request handler failed')
        finally:
            self._finish_connection(request)
            with self.owner.lock:
                self.owner.connections.discard(request)
                self.owner.workers.discard(threading.current_thread())


class ReadOnlyCache:
    def __init__(self, owned, repository, generation, cache, *, report=None, limits=HttpLimits(),
                 _reader_factory=ClaimedCacheReader):
        self.owned, self.repository, self.generation, self.cache = owned, repository, generation, cache
        self.report, self.limits, self.reader_factory = report, limits, _reader_factory
        self.lock = threading.Lock()
        self.reads_enabled = threading.Event()
        self.connections, self.workers = set(), set()
        self.stats = dict(requests=0, hits=0, misses=0, rejected=0, aborted=0, bytesSent=0,
                          acChecked=0, acReferencesChecked=0, acMisses=0)
        self.ac_miss_reasons = {}
        self.failure = None
        self.stopping = False
        self.reader = self.server = self.thread = None
        self.endpoint = None
        self.status = 'not-started'

    @property
    def flags(self):
        return cache_flags(self.endpoint)

    def configuration(self):
        return {'mode': MODE, 'endpoint': self.endpoint, 'cacheKey': disk.CACHE_KEY,
                'readOnly': True, 'cacheEnabledSaltBit': True, 'nativeCacheFlags': self.flags,
                'saltEquivalenceEvidence': 'Bazel 9.2.0 source; Apple compile pending',
                'requestLimit': self.limits.requests, 'connectionLimit': self.limits.connections,
                'headerLimitBytes': self.limits.header_bytes, 'chunkBytes': CHUNK_BYTES,
                'requestSeconds': self.limits.request_seconds, 'shutdownSeconds': self.limits.shutdown_seconds,
                'actionResultCompleteness': 'REAPI files/tree-children/stdout/stderr closure; incomplete=404',
                'casValidation': 'single-link regular file and exact size; content hashes verified by Bazel',
                'actionResultBytes': self.limits.action_bytes, 'treeBytes': self.limits.tree_bytes,
                'closureMetadataBytes': self.limits.metadata_bytes, 'closureReferences': self.limits.closure_references,
                'closureFields': self.limits.closure_fields, 'closureDirectories': self.limits.closure_directories,
                'closureDepth': self.limits.closure_depth, 'closureSeconds': self.limits.closure_seconds}

    def count(self, key, amount=1):
        with self.lock:
            self.stats[key] += amount

    def fail(self, reason):
        with self.lock:
            self.failure = self.failure or reason

    def publish(self):
        with self.lock:
            value = dict(self.configuration(), status=self.status, generation=self.generation,
                          counters=dict(self.stats), activeConnections=len(self.connections),
                          acMissReasons=dict(self.ac_miss_reasons),
                         activeWorkers=len(self.workers), rootDescriptorOpen=self.reader is not None
                         and self.reader.root_fd is not None, error=self.failure, nativeExecutionVerified=False)
        if self.report is not None:
            disk._write_json(Path(self.report), value)
        print('NATIVE_READONLY_CACHE ' + json.dumps(value, sort_keys=True), flush=True)
        return value

    def enable_reads(self):
        self.check()
        self.reads_enabled.set()
        self.status = 'serving-after-capacity-gate'
        self.publish()

    def check(self):
        self.reader.verify()
        if self.failure is not None:
            raise RuntimeError(self.failure)

    def _serve(self):
        try:
            while not self.stopping:
                self.server.handle_request()
        except Exception:
            if not self.stopping:
                self.fail('Read-only cache listener failed')

    def __enter__(self):
        # The reader verifies the fixed path/marker/generation BEFORE binding.
        self.reader = self.reader_factory(self.owned, self.repository, self.generation, self.cache)
        try:
            self.server = _Server(self)
            self.endpoint = 'http://127.0.0.1:' + str(self.server.server_address[1])
            self.thread = threading.Thread(target=self._serve, name='native-cache-listener', daemon=True)
            self.thread.start()
            self.status = 'listening-reads-paused-for-preflight-and-gc'
            self.publish()
            return self
        except BaseException:
            self.close()
            raise

    def close(self):
        self.stopping = True
        self.reads_enabled.clear()
        deadline = time.monotonic() + self.limits.shutdown_seconds
        if self.server is not None:
            if self.thread is not None and self.thread.is_alive():
                self.thread.join(timeout=max(0, deadline - time.monotonic()))
                if self.thread.is_alive():
                    self.fail('Read-only cache listener shutdown deadline exceeded')
            self.server.server_close()
        with self.lock:
            connections, workers = list(self.connections), list(self.workers)
        for connection in connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()
        for worker in workers:
            worker.join(timeout=max(0, deadline - time.monotonic()))
        if any(worker.is_alive() for worker in workers):
            self.fail('Read-only cache worker shutdown deadline exceeded')
        elif self.reader is not None:
            self.reader.close()
        self.status = 'stopped' if self.failure is None else 'stopped-with-error'

    def __exit__(self, exc_type, exc_value, traceback):
        try:
            if exc_type is None:
                try:
                    self.check()
                except Exception:
                    self.fail('Read-only cache failed its final claim/health check')
            self.close()
            self.publish()
            if exc_type is None and self.failure is not None:
                raise RuntimeError(self.failure)
        except Exception:
            if exc_type is None:
                raise
