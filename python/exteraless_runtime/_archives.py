"""Bounded Elyx format seams for the unmodified SDK, not another plugin loader.

Inspection is data-only. A load pins the inspected ZIP bytes, validates every
member (including local pure-Python wheels), then lets the SDK create its
namespace, environment, record and BasePlugin. Disk artifacts are disposable,
content-addressed and scoped to the native callback owner and a single load.
"""

import ast
import base64
import hashlib
import importlib
import importlib.util
import io
import json
import math
import marshal
import os
import re
import stat
import struct
import sys
import unicodedata
import uuid
import weakref
import zipfile
import zlib
from email.parser import BytesParser
from contextlib import contextmanager
from types import BuiltinFunctionType, CodeType, MappingProxyType, SimpleNamespace

from ._platform import RuntimeStateError, UnsupportedSurfaceError


MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
MAX_TOTAL_BYTES = 64 * 1024 * 1024  # outer members PLUS expanded wheels
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_ENTRIES = 2048                 # outer entries PLUS wheel entries
MAX_CENTRAL_BYTES = 2 * 1024 * 1024
MAX_COMPRESSION_RATIO = 200
MAX_PATH_BYTES = 512
MAX_PATH_DEPTH = 16
MAX_MAPPING_BYTES = 256 * 1024
MAX_MAPPING_TOTAL_BYTES = 2 * 1024 * 1024
MAX_METADATA_BYTES = 1024 * 1024
MAX_LOCALE_FILES = 64
MAX_DATA_BYTES = 1024 * 1024
MAX_VALUE_NODES = 16384
MAX_VALUE_DEPTH = 32
MAX_CLEANUP_ENTRIES = MAX_ENTRIES * (MAX_PATH_DEPTH + 2)

_ID = re.compile(r"[A-Za-z0-9_]{2,32}\Z")
_NATIVE_NAME = re.compile(r"\.(?:so|pyd|dylib|dll|a|o|fwork)(?:\.|$)", re.I)
_NATIVE_MAGIC = (b"\x7fELF", b"MZ", b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
                 b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")
_parts = None
SOURCE_ABI = "exteraless.elyx.source.v1"
_HEX = re.compile(r"[0-9a-f]{64}\Z")
_HAS_POSIX_FDS = (os.name == "posix" and all(hasattr(os, name) for name in ("O_DIRECTORY", "O_NOFOLLOW", "O_CLOEXEC"))
    and {os.open, os.mkdir, os.stat, os.unlink, os.rmdir}.issubset(os.supports_dir_fd)
    and os.stat in os.supports_follow_symlinks and os.scandir in os.supports_fd)


class ArchiveValidationError(ValueError):
    """An invalid or over-budget archive; no plugin code has been executed."""


def is_archive(path):
    return os.fspath(path).lower().endswith((".elyx", ".eaf"))


def validate_plugin_id(plugin_id, plugin_format):
    if plugin_format not in ("source", "elyx", "eaf"):
        raise UnsupportedSurfaceError(f"unknown plugin format {plugin_format!r}")
    if isinstance(plugin_id, str) and plugin_id.lower() == "exteralessmetadatainspector":
        raise UnsupportedSurfaceError("plugin id is reserved for the native metadata inspector")
    if plugin_format == "source":
        from . import _sdk_module
        return _sdk_module("extera_utils.metadata_parser")._validate_plugin_id(plugin_id)
    if not isinstance(plugin_id, str) or not _ID.fullmatch(plugin_id):
        raise ArchiveValidationError("Elyx id must contain 2...32 ASCII letters, digits or underscores")
    return plugin_id


def _member_path(name):
    if not isinstance(name, str) or not name or len(name.encode("utf-8")) > MAX_PATH_BYTES:
        raise ArchiveValidationError("archive path exceeds the 512-byte limit or is empty")
    parts = (name[:-1] if name.endswith("/") else name).split("/")
    devices = {"con", "prn", "aux", "nul", *(f"com{i}" for i in range(1, 10)), *(f"lpt{i}" for i in range(1, 10))}
    if (len(parts) > MAX_PATH_DEPTH or any(part in ("", ".", "..") for part in parts)
            or any(len(part.encode("utf-8")) > 255 for part in parts)
            or any(ord(char) < 32 or char in '\\:<>"|?*' for char in name)
            or any(part.endswith((".", " ")) or part.split(".")[0].lower() in devices for part in parts)):
        raise ArchiveValidationError(f"unsafe or ambiguous archive path: {name!r}")
    return "/".join(parts)


def _read_file(path, limit):
    # Input paths may have native /var aliases. Do not resolve the whole path;
    # reject a redirected leaf and inspect the opened regular file descriptor.
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or getattr(before, "st_file_attributes", 0) & 0x400:
        raise ArchiveValidationError("archive/data input must be a regular file, not a symbolic link")
    if before.st_size > limit:
        raise ArchiveValidationError(f"archive/data input exceeds {limit} byte compressed/read limit")
    def opener(name, flags):
        return os.open(name, flags | getattr(os, "O_NOFOLLOW", 0))
    # Keep the filename on CPython's real open audit event. fdopen would present
    # an anonymous fd and correctly be denied by the SDK's file permission gate.
    with open(path, "rb", opener=opener) as stream:
        opened = os.fstat(stream.fileno())
        if not stat.S_ISREG(opened.st_mode) or opened.st_size > limit:
            raise ArchiveValidationError("archive/data input is not a bounded regular file")
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise ArchiveValidationError(f"archive/data input exceeds {limit} byte compressed/read limit")
        return data


def _preflight_zip(data):
    if len(data) > MAX_ARCHIVE_BYTES:
        raise ArchiveValidationError("archive exceeds compressed byte limit")
    end = data.rfind(b"PK\x05\x06", max(0, len(data) - 65557))
    if end < 0 or len(data) - end < 22:
        raise ArchiveValidationError("not a ZIP/Elyx archive (missing ZIP signature)")
    _, disk, central_disk, disk_count, count, size, offset, comment = struct.unpack_from("<4s4H2LH", data, end)
    if disk or central_disk or disk_count != count or count == 65535 or offset == 0xffffffff or size == 0xffffffff:
        raise UnsupportedSurfaceError("Elyx multi-disk/ZIP64 archives are unsupported")
    if end + 22 + comment != len(data) or offset + size != end or size > MAX_CENTRAL_BYTES:
        raise ArchiveValidationError("invalid or oversized ZIP central directory")
    if count > MAX_ENTRIES:
        raise ArchiveValidationError("archive exceeds entry count limit")
    # ZipFile scans by directory SIZE, not EOCD count. Check the real count
    # before letting it allocate ZipInfo objects, even if EOCD lies about it.
    cursor, actual = offset, 0
    while cursor < end:
        if cursor + 46 > end or data[cursor:cursor + 4] != b"PK\x01\x02":
            raise ArchiveValidationError("invalid ZIP central directory entry")
        names, extra, comments = struct.unpack_from("<3H", data, cursor + 28)
        cursor += 46 + names + extra + comments
        actual += 1
        if actual > MAX_ENTRIES or cursor > end:
            raise ArchiveValidationError("archive exceeds entry count/directory limit")
    if actual != count:
        raise ArchiveValidationError("ZIP entry count disagrees with its directory")
    return offset


class _Budget:
    def __init__(self):
        self.entries = self.bytes = 0

    def add(self, info):
        self.entries += 1
        self.bytes += info.file_size
        if self.entries > MAX_ENTRIES:
            raise ArchiveValidationError("archive and wheels exceed entry count limit")
        if info.file_size > MAX_FILE_BYTES:
            raise ArchiveValidationError("archive member exceeds per-file byte limit")
        if self.bytes > MAX_TOTAL_BYTES:
            raise ArchiveValidationError("archive and wheels exceed total expanded byte limit")
        if info.file_size > max(1, info.compress_size) * MAX_COMPRESSION_RATIO:
            raise ArchiveValidationError("archive member exceeds compression ratio limit")


class _CheckedZip(zipfile.ZipFile):
    def __init__(self, data, budget=None):
        central = _preflight_zip(data)
        super().__init__(io.BytesIO(data), "r")
        try:
            budget = budget or _Budget()
            spellings, explicit, ranges, bodies = {}, set(), [], {}
            for info in self.infolist():
                name = _member_path(info.orig_filename)
                if info.orig_filename != info.filename or info.filename in explicit:
                    raise ArchiveValidationError("duplicate or NUL-truncated archive entry")
                explicit.add(info.filename)
                parts = name.split("/")
                for index in range(1, len(parts) + 1):
                    spelling = "/".join(parts[:index])
                    key = unicodedata.normalize("NFC", spelling).casefold()
                    kind = "dir" if index < len(parts) or info.is_dir() else "file"
                    if key in spellings and spellings[key] != (spelling, kind):
                        raise ArchiveValidationError("archive contains a case/Unicode alias or file/directory collision")
                    spellings[key] = (spelling, kind)
                mode = stat.S_IFMT(info.external_attr >> 16)
                if mode not in (0, stat.S_IFDIR if info.is_dir() else stat.S_IFREG) or info.external_attr & 0x400:
                    raise ArchiveValidationError("archive symlinks, reparse points and special files are forbidden")
                if info.is_dir() and info.file_size:
                    raise ArchiveValidationError("archive directory has file content")
                if info.flag_bits & ~(0x800 | 8 | 6) or info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                    raise UnsupportedSurfaceError("Elyx supports unencrypted stored/deflated ZIP entries only")
                if _NATIVE_NAME.search(name) or any(part.lower().endswith(".framework") for part in parts):
                    raise UnsupportedSurfaceError(f"unverified native archive member {name!r}; use an app-bundled native provider")
                budget.add(info)
                start = info.header_offset
                if start < 0 or start + 30 > central or data[start:start + 4] != b"PK\x03\x04":
                    raise ArchiveValidationError("invalid ZIP local header")
                names, extra = struct.unpack_from("<2H", data, start + 26)
                finish = start + 30 + names + extra + info.compress_size
                if finish > central:
                    raise ArchiveValidationError("ZIP entry overlaps the central directory")
                ranges.append((start, finish))
                bodies[info.filename] = (start + 30 + names + extra, finish)
            ranges.sort()
            if any(left[1] > right[0] for left, right in zip(ranges, ranges[1:])):
                raise ArchiveValidationError("overlapping ZIP members (zip bomb)")
            # All headers/paths/budgets passed before the first decompression.
            self.members = {}
            for info in self.infolist():
                with self.open(info):
                    pass  # stdlib checks local filename/flags against the directory
                start, finish = bodies[info.filename]
                compressed = memoryview(data)[start:finish]
                if info.compress_type == zipfile.ZIP_STORED:
                    if len(compressed) != info.file_size:
                        raise ArchiveValidationError("stored ZIP member disagrees with its size")
                    content = bytes(compressed)
                else:
                    inflater = zlib.decompressobj(-15)
                    content = inflater.decompress(compressed, info.file_size + 1)
                    if (len(content) != info.file_size or not inflater.eof
                            or inflater.unused_data or inflater.unconsumed_tail):
                        raise ArchiveValidationError("deflated ZIP member disagrees with its expanded size")
                if zlib.crc32(content) & 0xffffffff != info.CRC:
                    raise ArchiveValidationError("ZIP member CRC mismatch")
                if content.startswith(_NATIVE_MAGIC):
                    raise UnsupportedSurfaceError(f"unverified native binary in {info.filename!r}; app-bundled provider required")
                if info.filename.lower().endswith(".pyc") and (len(content) < 16 or content[:4] != importlib.util.MAGIC_NUMBER):
                    raise UnsupportedSurfaceError("Elyx bytecode must match this CPython interpreter")
                self.members[info.filename] = content
        except BaseException:
            self.close()
            raise


def open_archive(path):
    return _CheckedZip(_read_file(os.fspath(path), MAX_ARCHIVE_BYTES))


def _plain_values(value):
    stack, count = [(value, 0)], 0
    while stack:
        node, depth = stack.pop()
        count += 1
        if depth > MAX_VALUE_DEPTH or count > MAX_VALUE_NODES:
            raise ArchiveValidationError("mapping exceeds value depth/node limit")
        if type(node) is dict:
            stack.extend((part, depth + 1) for pair in node.items() for part in pair)
        elif type(node) in (list, tuple):
            stack.extend((part, depth + 1) for part in node)
        elif type(node) is float and not math.isfinite(node):
            raise ArchiveValidationError("non-finite mapping values are unsupported")
        elif type(node) is int and node.bit_length() > 1024:
            raise ArchiveValidationError("mapping integer exceeds 1024 bits")
        elif node is not None and type(node) not in (str, int, float, bool):
            raise UnsupportedSurfaceError(f"non-literal mapping value {type(node).__name__} is unsupported")
    return value


def _literal_mapping(name, text):
    tree = ast.parse(text, filename=name)
    stack, count = [(tree, 0)], 0
    while stack:
        node, depth = stack.pop()
        count += 1
        if depth > MAX_VALUE_DEPTH or count > MAX_VALUE_NODES:
            raise ArchiveValidationError("Python mapping exceeds AST depth/node limit")
        stack.extend((child, depth + 1) for child in ast.iter_child_nodes(node))
    result = {}
    for node in tree.body:
        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
            continue  # docstring, no evaluation
        if isinstance(node, ast.Assign) and all(isinstance(target, ast.Name) for target in node.targets):
            targets, value = node.targets, node.value
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.value is not None:
            if not (isinstance(node.annotation, ast.Name) and node.annotation.id in {"str", "int", "float", "bool", "list", "tuple", "dict"}):
                raise UnsupportedSurfaceError(f"non-literal Python metadata/localization annotation in {name!r}")
            targets, value = [node.target], node.value
        else:
            raise UnsupportedSurfaceError(f"non-literal Python metadata/localization in {name!r}; only literal assignments are supported")
        try:
            parsed = _plain_values(ast.literal_eval(value))
        except (TypeError, ValueError, SyntaxError) as error:
            raise UnsupportedSurfaceError(f"non-literal Python metadata/localization in {name!r}: {error}") from error
        for target in targets:
            if not target.id.startswith("_"):  # matches Original's public-values collection
                result[target.id] = parsed
    return result


def _json_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ArchiveValidationError(f"duplicate JSON mapping key {key!r}")
        result[key] = value
    return result


def _parse_data(name, data, limit=None):
    limit = MAX_MAPPING_BYTES if limit is None else limit
    if len(data) > limit:
        raise ArchiveValidationError(f"mapping {name!r} exceeds {limit} byte limit")
    text = data.decode("utf-8")
    if name.lower().endswith(".py"):
        parsed = _literal_mapping(name, text)
    elif name.lower().endswith(".json"):
        # Bound JSON nesting before the stdlib decoder enters its recursive parser.
        depth, quoted, escaped = 0, False, False
        for char in text:
            if quoted:
                if escaped: escaped = False
                elif char == "\\": escaped = True
                elif char == '"': quoted = False
            elif char == '"': quoted = True
            elif char in "[{":
                depth += 1
                if depth > MAX_VALUE_DEPTH: raise ArchiveValidationError("JSON exceeds value depth limit")
            elif char in "]}": depth -= 1
        parsed = json.loads(text, object_pairs_hook=_json_pairs)
    else:
        import yaml

        class BoundedLoader(yaml.SafeLoader):
            def __init__(self, stream):
                super().__init__(stream)
                self.depth = self.nodes = 0

            def compose_node(self, parent, index):
                event = self.peek_event()
                if isinstance(event, yaml.AliasEvent) or getattr(event, "anchor", None) is not None:
                    raise UnsupportedSurfaceError("YAML anchors/aliases are unsupported in Elyx data")
                self.nodes += 1
                self.depth += 1
                try:
                    if self.nodes > MAX_VALUE_NODES or self.depth > MAX_VALUE_DEPTH:
                        raise ArchiveValidationError("YAML exceeds value depth/node limit")
                    return super().compose_node(parent, index)
                finally:
                    self.depth -= 1

            def construct_mapping(self, node, deep=False):
                keys = set()
                for key_node, _ in node.value:
                    if key_node.tag == "tag:yaml.org,2002:merge":
                        raise UnsupportedSurfaceError("YAML merge keys are unsupported in Elyx data")
                    key = self.construct_object(key_node, deep=deep)
                    if key in keys: raise ArchiveValidationError("duplicate YAML mapping key")
                    keys.add(key)
                return super().construct_mapping(node, deep=deep)

        parsed = yaml.load(text, Loader=BoundedLoader)
    return _plain_values(parsed)


def parse_mapping_file(name, data, *, what="metainfo"):
    parsed = _parse_data(name, data)
    if not isinstance(parsed, dict) or not parsed:
        raise ArchiveValidationError(f"{what} file {name!r} must contain a non-empty mapping")
    return parsed


def parse_refmap(name, data):
    return {str(key): str(value) for key, value in parse_mapping_file(name, data, what="refmap").items() if value is not None}


def _data_module_exec(loader, module):
    raw = _active_image().member(loader._path)
    if len(raw) > MAX_DATA_BYTES:
        raise ArchiveValidationError("imported data module exceeds byte limit")
    if loader._ext == ".txt":
        module.content = raw.decode("utf-8")
        return
    from elyx_runtime.utils import lazy_wrap
    data = _parse_data(loader._path, raw, MAX_DATA_BYTES)
    module.content = lazy_wrap(data)
    if isinstance(data, dict):
        for key, value in data.items():
            setattr(module, str(key), lazy_wrap(value))


def _bind_code(code, filename):
    """Bind ALL code, including nested constants, before it can become a frame."""
    remaining, visiting, memo = MAX_VALUE_NODES, set(), {}

    def bind(value, depth=0):
        nonlocal remaining
        remaining -= 1
        if remaining < 0 or depth > MAX_VALUE_DEPTH:
            raise UnsupportedSurfaceError("Elyx code graph exceeds depth/node limit")
        if type(value) not in (CodeType, tuple, frozenset):
            if value is None or value is Ellipsis or type(value) in (bool, int, float, complex, str, bytes):
                return value
            raise UnsupportedSurfaceError("Elyx bytecode contains a mutable/unsupported constant")
        key = id(value)
        if key in visiting:
            raise UnsupportedSurfaceError("Elyx bytecode contains a cyclic code graph")
        if key in memo:
            return memo[key]
        visiting.add(key)
        if type(value) is CodeType:
            result = value.replace(co_filename=filename, co_consts=bind(value.co_consts, depth + 1))
        else:
            if len(value) > remaining:
                raise UnsupportedSurfaceError("Elyx code graph exceeds depth/node limit")
            result = type(value)(bind(child, depth + 1) for child in value)
        visiting.remove(key)
        memo[key] = result
        return result

    if type(code) is not CodeType:
        raise ArchiveValidationError("Elyx bytecode did not contain a code object")
    return bind(code)


def _image_key(path):
    return unicodedata.normalize("NFC", os.path.normpath(os.fspath(path)))


def _receipt_key(path):
    # APFS may expose canonically equivalent/case-alias names at enumeration.
    # Never misclassify a replaced original inode as an unrecorded extra file.
    return unicodedata.normalize("NFC", path).casefold()


class _Image:
    """Immutable execution manifest. Disk files are never an import authority."""
    def __init__(self, snapshot, root, verify=lambda: None):
        self.root, self.verify, self.active = root, verify, True
        blobs, labels, directories = {}, {}, {root}

        def add(base, members, hashes):
            directories.add(base)
            for name, data in members.items():
                path = os.path.join(base, *_member_path(name).split("/"))
                parent = path if name.endswith("/") else os.path.dirname(path)
                while parent != root:
                    directories.add(parent)
                    parent = os.path.dirname(parent)
                if not name.endswith("/"):
                    expected = hashes[name]
                    if type(data) is not bytes or hashlib.sha256(data).hexdigest() != expected:
                        raise ArchiveValidationError("captured archive member digest mismatch")
                    blobs[_image_key(path)] = (data, expected)
                    labels[_image_key(path)] = path

        add(os.path.join(root, "contents"), snapshot.members, snapshot.member_hashes)
        for wheel in snapshot.wheels:
            add(os.path.join(root, "wheels", wheel.digest), wheel.members, wheel.member_hashes)
        self.blobs = MappingProxyType(blobs)
        self.labels = MappingProxyType(labels)
        self.directories = frozenset(_image_key(path) for path in directories)

    def check(self):
        if not self.active:
            raise RuntimeStateError("archive execution image has been retired")
        self.verify()

    def member(self, path):
        self.check()
        try:
            data, digest = self.blobs[_image_key(path)]
        except KeyError:
            raise ArchiveValidationError("module is absent from the approved archive manifest") from None
        if hashlib.sha256(data).hexdigest() != digest:
            raise ArchiveValidationError("captured archive member digest mismatch")
        return data


def _active_image():
    adapter = getattr(_parts, "active_adapter", None)
    if adapter is None or adapter.image is None:
        raise RuntimeStateError("Elyx module execution requires an active owned archive image")
    adapter._check()
    adapter.image.check()
    return adapter.image


class _SnapshotLoader:
    def __init__(self, name, path, kind, image=None):
        self.image = image if image is not None else _active_image()
        try: label = self.image.labels[_image_key(path)]
        except KeyError: raise ArchiveValidationError("code path is absent from the approved manifest") from None
        self.name, self.path, self.kind = name, label, kind

    def create_module(self, spec):
        spec.origin, spec.has_location = self.path, True
        return None

    def get_filename(self, fullname):
        if fullname != self.name:
            raise ImportError("archive loader module identity does not match")
        return self.path

    def get_data(self, path):
        return self.image.member(path)

    def get_source(self, fullname):
        self.get_filename(fullname)
        return importlib.util.decode_source(self.get_data(self.path)) if self.kind == "source" else None

    def get_code(self, fullname):
        filename = self.get_filename(fullname)
        raw = self.get_data(filename)
        if self.kind == "source":
            # SourceFileLoader must NEVER inspect an injected unchecked-hash
            # __pycache__. Compile the approved source bytes, including on reload.
            code = compile(raw, filename, "exec", dont_inherit=True)
        else:
            if len(raw) < 16 or raw[:4] != importlib.util.MAGIC_NUMBER or int.from_bytes(raw[4:8], "little") & ~3:
                raise ArchiveValidationError("invalid or incompatible Elyx bytecode header")
            code = marshal.loads(raw[16:])  # owner/watchdog only, never inspection
        return _bind_code(code, filename)

    def exec_module(self, module):
        exec(self.get_code(module.__name__), module.__dict__)


def _owned_module_exec(loader, module):
    # Also cover callers constructing the preserved SDK wrapper explicitly.
    if not isinstance(loader._real, _SnapshotLoader):
        kind = "source" if isinstance(loader._real, importlib.machinery.SourceFileLoader) else "bytecode"
        if not isinstance(loader._real, (importlib.machinery.SourceFileLoader, importlib.machinery.SourcelessFileLoader)):
            raise UnsupportedSurfaceError("unsupported archive code loader")
        loader._real = _SnapshotLoader(module.__name__, loader._real.path, kind)
    return _parts.module_exec(loader, module)


class _ManifestPaths:
    """Keep the SDK finder/alias rules, replace just its filesystem predicates."""
    def __getattr__(self, name):
        return getattr(os.path, name)

    def isfile(self, path):
        return _image_key(path) in _active_image().blobs

    def isdir(self, path):
        return _image_key(path) in _active_image().directories

    def exists(self, path):
        image = _active_image()
        return _image_key(path) in image.blobs or _image_key(path) in image.directories

    def samefile(self, first, second):
        return _image_key(first) == _image_key(second)


def _resolve_placeholders(text, lookup):
    used = len(text.encode("utf-8"))
    if used > MAX_METADATA_BYTES:
        raise ArchiveValidationError("rendered metadata exceeds byte limit")

    def limited(key):
        nonlocal used
        value = lookup(key)
        rendered = key if value is None else str(value)
        used += len(rendered.encode("utf-8"))
        if used > MAX_METADATA_BYTES:
            raise ArchiveValidationError("rendered metadata placeholder expansion exceeds byte limit")
        return rendered

    # Charge the unexpanded text plus replacements conservatively, before re.sub
    # can join them. Small literal locale files must not expand into gigabytes.
    return _parts.resolve_placeholders(text, limited if lookup is not None else None)


def _build_metadata(raw, string_lookup=None):
    result = _parts.build_metadata(raw, string_lookup)
    if len(json.dumps(result, ensure_ascii=False, allow_nan=False).encode("utf-8")) > MAX_METADATA_BYTES:
        raise ArchiveValidationError("rendered metadata JSON exceeds byte limit")
    return result


def _sdk():
    global _parts
    if _parts is None:
        from . import _sdk_module
        try:
            package = _sdk_module("elyx_runtime")
        except ImportError as error:
            raise UnsupportedSurfaceError("Elyx needs the app's bundled PyYAML/SDK provider") from error
        _parts = SimpleNamespace(package=package, archive=importlib.import_module("elyx_runtime.archive"),
            metadata=importlib.import_module("elyx_runtime.metadata"), loader=importlib.import_module("elyx_runtime.loader"),
            namespace=importlib.import_module("elyx_runtime.namespace"), localization=importlib.import_module("elyx_runtime.localization"))
        _parts.archive.open_archive = _parts.metadata.open_archive = open_archive
        _parts.archive.parse_refmap = parse_refmap
        _parts.metadata.parse_mapping_file = parse_mapping_file
        _parts.metadata._exec_python_mapping = _literal_mapping
        _parts.resolve_placeholders = _parts.metadata.resolve_placeholders
        _parts.metadata.resolve_placeholders = _resolve_placeholders
        _parts.build_metadata = _parts.metadata.build_metadata
        _parts.metadata.build_metadata = _build_metadata
        _parts.metadata.read_metadata = _parts.package.read_metadata = read_metadata
        _parts.namespace._DataModuleLoader.exec_module = _data_module_exec
        _parts.module_exec = _parts.namespace._WrappingLoader.exec_module
        _parts.namespace._WrappingLoader.exec_module = _owned_module_exec
        # These are module-local views, not changes to global os/importlib.
        # The preserved finder selects packages/modules only from the manifest.
        _parts.namespace.os = SimpleNamespace(**dict(vars(os), path=_ManifestPaths()))
        machinery = SimpleNamespace(**dict(vars(importlib.machinery),
            SourceFileLoader=lambda name, path: _SnapshotLoader(name, path, "source"),
            SourcelessFileLoader=lambda name, path: _SnapshotLoader(name, path, "bytecode")))
        _parts.namespace.importlib = SimpleNamespace(**dict(vars(importlib), machinery=machinery))
    return _parts


def _header(data, name):
    if len(data) > MAX_MAPPING_BYTES:
        raise ArchiveValidationError(f"wheel {name} exceeds metadata byte limit")
    return BytesParser().parsebytes(data, headersonly=True)


def _wheel(data, budget):
    with _CheckedZip(data, budget) as zf:
        members = zf.members
        headers = [name for name in members if name.count("/") == 1 and name.endswith(".dist-info/WHEEL")]
        if len(headers) != 1:
            raise UnsupportedSurfaceError("local wheel must have exactly one .dist-info/WHEEL")
        header = _header(members[headers[0]], "WHEEL")
        tags = header.get_all("Tag", [])
        python = f"cp{sys.version_info.major}{sys.version_info.minor}"
        if (header.get("Root-Is-Purelib", "").lower() != "true" or not tags
                or any(not tag.endswith("-none-any") for tag in tags)
                or not any({"py3", python} & set(tag.split("-")[0].split(".")) for tag in tags)):
            raise UnsupportedSurfaceError("local wheels must be pure-Python, compatible none-any wheels; native wheels require an app-bundled provider")
        if any(name.lower().endswith((".whl", ".pth")) or ".data/" in name for name in members):
            raise UnsupportedSurfaceError("nested wheels, .pth and wheel .data installation are unsupported")
        metaname = headers[0].rsplit("/", 1)[0] + "/METADATA"
        if metaname not in members:
            raise ArchiveValidationError("local wheel is missing .dist-info/METADATA")
        meta = _header(members[metaname], "METADATA")
        requirements = meta.get_all("Requires-Dist", [])
        if len(requirements) > 128 or any(len(value) > 4096 for value in requirements):
            raise ArchiveValidationError("wheel requirements exceed metadata limits")
        return SimpleNamespace(digest=hashlib.sha256(data).hexdigest(), members=MappingProxyType(dict(members)),
                               member_hashes=MappingProxyType({name: hashlib.sha256(value).hexdigest() for name, value in members.items()}),
                               requirements=requirements, requires_python=meta.get("Requires-Python"))


def inspect_archive(path):
    path = os.path.abspath(os.fspath(path))
    data = _read_file(path, MAX_ARCHIVE_BYTES)
    return _inspect_archive_bytes(path, data)


def _inspect_archive_bytes(path, data):
    if type(data) is not bytes or len(data) > MAX_ARCHIVE_BYTES:
        raise ArchiveValidationError("archive source is not bounded immutable bytes")
    budget = _Budget()
    with _CheckedZip(data, budget) as zf:
        sdk = _sdk()
        refmap_member = sdk.archive.find_refmap_member(zf)
        refmap = parse_refmap(refmap_member, zf.members[refmap_member])
        for key in ("main", "metainfo", "strings", "locales", "assets", "wheels"):
            if refmap.get(key): refmap[key] = _member_path(refmap[key])
        metainfo_member = sdk.archive.find_metainfo_member(zf, refmap)
        raw_meta = parse_mapping_file(metainfo_member, zf.members[metainfo_member])
        strings = refmap.get("strings") or refmap.get("locales")
        locales = []
        if strings:
            locales = [name for name in zf.members if (name == strings or name.rpartition("/")[0] == strings)
                       and name.lower().endswith(sdk.localization.SUPPORTED_EXTENSIONS)]
        if len(locales) > MAX_LOCALE_FILES or sum(len(zf.members[name]) for name in [refmap_member, metainfo_member, *locales]) > MAX_MAPPING_TOTAL_BYTES:
            raise ArchiveValidationError("archive metadata/locales exceed count or aggregate byte limit")
        catalog = sdk.localization.load_strings_from_zip(zf, strings) if strings else None
        lookup = sdk.localization.Strings(catalog).get if catalog else None
        metadata = sdk.metadata.build_metadata(raw_meta, lookup)
        validate_plugin_id(metadata["id"], "elyx")
        main = refmap.get("main", "main.py")
        candidates = [main] if main.endswith((".py", ".pyc")) else [main + ".py", main + ".pyc"]
        if not any(name in zf.members for name in candidates):
            raise ArchiveValidationError("Elyx main must point to an existing Python source/compatible bytecode member")
        for key in ("assets", "wheels"):
            declared = refmap.get(key)
            if declared and not any(name.startswith(declared + "/") for name in zf.members):
                raise ArchiveValidationError(f"missing refmap {key} directory {declared!r}")
        wheels = []
        for name in sorted(zf.members):
            if not name.lower().endswith(".whl"): continue
            if name.rpartition("/")[0] != refmap.get("wheels"):
                raise UnsupportedSurfaceError("bundled wheels must be direct children of refmap.wheels")
            wheels.append(_wheel(zf.members[name], budget))
        return SimpleNamespace(path=path, data=data, digest=hashlib.sha256(data).hexdigest(), members=MappingProxyType(dict(zf.members)),
            member_hashes=MappingProxyType({name: hashlib.sha256(content).hexdigest() for name, content in zf.members.items()}),
            refmap=refmap, raw_metadata=raw_meta, metadata=metadata, catalog=catalog, wheels=tuple(wheels))


def read_metadata(path, string_lookup=None):
    snapshot = inspect_archive(path)
    return snapshot.metadata if string_lookup is None else _sdk().metadata.build_metadata(snapshot.raw_metadata, string_lookup)


def _source_json(value):
    result = json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
    if len(result.encode("utf-8")) > 4096:
        raise ArchiveValidationError("Elyx source descriptor exceeds 4096 bytes")
    return result


def _source_descriptor(value):
    keys = {"abi", "schema", "capability", "purpose", "plugin_id", "owner_token", "format",
            "source_sha256", "byte_length", "source_namespace", "source_nonce"}
    if type(value) is not dict or set(value) != keys:
        raise ArchiveValidationError("invalid native Elyx source descriptor fields (a bare fd/path is not authority)")
    _source_json(value)
    if value["abi"] != SOURCE_ABI or type(value["schema"]) is not int or value["schema"] != 1:
        raise UnsupportedSurfaceError("unsupported native Elyx source descriptor ABI")
    for name in ("capability", "source_sha256", "source_namespace", "source_nonce"):
        if type(value[name]) is not str or not _HEX.fullmatch(value[name]):
            raise ArchiveValidationError(f"invalid native source {name}")
    if value["purpose"] not in ("inspect", "load", "manifest") or value["format"] not in ("elyx", "eaf"):
        raise ArchiveValidationError("invalid native source purpose/format")
    validate_plugin_id(value["plugin_id"], value["format"])
    if type(value["byte_length"]) is not int or not 0 < value["byte_length"] <= MAX_ARCHIVE_BYTES:
        raise ArchiveValidationError("native Elyx source length exceeds the archive limit")
    owner = value["owner_token"]
    if value["purpose"] == "inspect":
        if owner is not None: raise ArchiveValidationError("inspection descriptor cannot carry a plugin owner token")
    elif type(owner) is not str or not 0 < len(owner.encode("utf-8")) <= 256 or "\0" in owner:
        raise ArchiveValidationError("load/manifest descriptor requires its exact native owner token")
    return dict(value)


def _native_source_gate(required=True):
    try: bridge = importlib.import_module("_exteraless_bridge")
    except ImportError: bridge = None
    gate = getattr(bridge, "xt_elyx_source", None)
    if (not isinstance(gate, BuiltinFunctionType) or getattr(gate, "__self__", None) is not bridge
            or getattr(gate, "__name__", None) != "xt_elyx_source"):
        if required:
            raise UnsupportedSurfaceError("native C-gated Elyx source capability reader ABI 1 is not installed")
        return None
    return gate


class _NativeSourceRead:
    """Read-only native ticket. FDs stay in the native authority, never in JSON.

    The C gate injects its immutable caller identity; the native registry owns
    issuance, descriptor/version checks and retained duplicate lifetime. This
    Python decoder does not turn envelope fields into native authority.
    """
    def __init__(self, gate, operation, payload, *, purpose, platform=None):
        self.gate, self.read_id = gate, None
        if gate is None:
            raise UnsupportedSurfaceError("native C-gated Elyx source capability reader ABI 1 is not installed")
        reply = gate(operation, _source_json(payload))
        if type(reply) is not dict or set(reply) != {"abi", "read_id", "descriptor", "read_only", "load_reader_abi"}:
            raise RuntimeStateError("native Elyx source claim returned an invalid proof")
        proof = _source_descriptor(reply["descriptor"])
        if (reply["abi"] != SOURCE_ABI or type(reply["read_id"]) is not str or not _HEX.fullmatch(reply["read_id"])
                or reply["read_only"] is not True or type(reply["load_reader_abi"]) is not int or reply["load_reader_abi"] != 1
                or proof["purpose"] != purpose):
            raise RuntimeStateError("native Elyx source claim has wrong purpose/readiness")
        if operation == "claim" and proof != payload:
            raise RuntimeStateError("native Elyx proof differs from its issued descriptor")
        if platform is not None:
            platform.check_plugin(proof["plugin_id"])
            if proof["owner_token"] != platform.owner_token or proof["format"] != platform.plugin_format:
                raise RuntimeStateError("native Elyx source belongs to a different owner/format")
        self.proof = MappingProxyType(proof)
        self.read_id = reply["read_id"]

    def request(self, **fields):
        return _source_json({"abi": SOURCE_ABI, "read_id": self.read_id, **fields})

    def check(self):
        reply = self.gate("check", self.request())
        if (type(reply) is not dict or set(reply) != {"read_id", "descriptor", "current"}
                or reply["read_id"] != self.read_id or reply["current"] is not True
                or _source_descriptor(reply["descriptor"]) != dict(self.proof)):
            raise RuntimeStateError("native Elyx source namespace/version was retired")

    def read(self):
        self.check()
        result = bytearray()
        while len(result) < self.proof["byte_length"]:
            count = min(65536, self.proof["byte_length"] - len(result))
            reply = self.gate("read", self.request(offset=len(result), count=count))
            if (type(reply) is not dict or set(reply) != {"offset", "data_base64"}
                    or type(reply["offset"]) is not int or reply["offset"] != len(result)
                    or type(reply["data_base64"]) is not str or len(reply["data_base64"]) > 4 * ((count + 2) // 3)):
                raise RuntimeStateError("invalid native Elyx source chunk")
            chunk = base64.b64decode(reply["data_base64"], validate=True)
            if len(chunk) != count:
                raise RuntimeStateError("native Elyx source chunk has wrong length")
            result.extend(chunk)
        data = bytes(result)
        if hashlib.sha256(data).hexdigest() != self.proof["source_sha256"]:
            raise ArchiveValidationError("native Elyx source content digest mismatch")
        self.check()
        return data

    def close(self):
        if self.read_id is not None:
            try:
                reply = self.gate("release", self.request())
                if type(reply) is not dict or set(reply) != {"released"} or type(reply["released"]) is not bool:
                    raise RuntimeStateError("invalid native Elyx source release receipt")
            finally:
                self.read_id = None


@contextmanager
def _native_source_read(gate, operation, payload, *, purpose, platform=None):
    reader = _NativeSourceRead(gate, operation, payload, purpose=purpose, platform=platform)
    try:
        yield reader
    finally:
        original_error = sys.exception()
        try: reader.close()
        except BaseException:
            if original_error is None: raise


def inspect_developer_descriptor(descriptor):
    descriptor = _source_descriptor(descriptor)
    if descriptor["purpose"] != "inspect":
        raise RuntimeStateError("Elyx static inspection requires an inspection capability")
    with _native_source_read(_native_source_gate(), "claim", descriptor, purpose="inspect") as reader:
        inspection = _inspect_archive_bytes("<native-elyx-inspection>." + descriptor["format"], reader.read())
        if inspection.metadata["id"] != descriptor["plugin_id"]:
            raise ArchiveValidationError("inspected native archive ID differs from its capability")
        reader.check()
        return inspection.metadata


@contextmanager
def verified_developer_load(platform, path, descriptor):
    platform.check_worker()
    descriptor = _source_descriptor(descriptor)
    if (descriptor["purpose"] != "load" or platform.callbacks.active or platform.loader.is_loaded(platform.plugin_id)
            or platform.archives.verified_source is not None):
        raise RuntimeStateError("verified Elyx load requires a fresh native owner and single-use capability")
    with _native_source_read(platform.archives.source_gate, "claim", descriptor, purpose="load", platform=platform) as reader:
        label = os.path.abspath(os.fspath(path))
        if not is_archive(label) or os.path.splitext(label)[1].lower() != "." + descriptor["format"]:
            raise RuntimeStateError("verified Elyx load label has the wrong container format")
        inspection = _inspect_archive_bytes(label, reader.read())
        if inspection.metadata["id"] != platform.plugin_id:
            raise ArchiveValidationError("verified archive ID differs from its native worker")
        source = SimpleNamespace(reader=reader, inspection=inspection, path=label, consumed=False)
        platform.archives.verified_source = source
        try:
            yield
            if not source.consumed:
                raise RuntimeStateError("verified load did not consume its native source")
            reader.check()
        finally:
            platform.archives.verified_source = None


def snapshot_for_load(platform, path):
    source = platform.archives.verified_source
    if source is None:
        return inspect_archive(path)
    platform.check_worker()
    if source.path != path or source.consumed:
        raise RuntimeStateError("native Elyx source belongs to another load invocation")
    source.reader.check()
    source.consumed = True
    return source.inspection


def _posix_backend():
    if not _HAS_POSIX_FDS:
        raise UnsupportedSurfaceError("Elyx extraction requires the POSIX directory-FD/O_NOFOLLOW backend")


def _identity(info):
    return info.st_dev, info.st_ino, stat.S_IFMT(info.st_mode)


def _component(name):
    if not name or name in (".", "..") or "/" in name or "\0" in name or len(os.fsencode(name)) > 255:
        raise ArchiveValidationError("invalid directory-FD component")
    return name


class _Directory:
    """Held directory chain, rooted at the OS / descriptor; never reopen a path."""
    def __init__(self, fd, path, parent=None, name=None, hook=None):
        self.fd, self.path, self.parent, self.name, self.hook = fd, path, parent, name, hook
        self.identity = _identity(os.fstat(fd))
        self.aliases = {}
        self.pool = parent.pool if parent is not None else weakref.WeakSet()
        self.pool.add(self)
        if self.identity[2] != stat.S_IFDIR:
            self.close()
            raise ArchiveValidationError("archive descriptor is not a directory")

    def close(self):
        fd, self.fd = self.fd, -1
        if fd >= 0:
            os.close(fd)

    def __del__(self):
        if getattr(self, "fd", -1) >= 0:
            self.close()

    @classmethod
    def open_native(cls, path, hook=None):
        _posix_backend()
        path = os.fspath(path)
        if not isinstance(path, str) or not path.startswith("/") or "\0" in path or len(os.fsencode(path)) > 4096:
            raise ArchiveValidationError("native archive anchor must be an absolute bounded path")
        parts = [_component(part) for part in path.split("/") if part]
        root = cls(os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW), "/", hook=hook)
        # Only documented aliases at the actual OS root may be followed. Their
        # link inode/value is pinned, and /private plus all descendants are opened
        # with openat(NO_FOLLOW). No arbitrary descendant symlink is canonicalized.
        if sys.platform == "darwin" and parts and parts[0] in ("var", "tmp", "etc"):
            name = parts[0]
            info = root.stat(name)
            if stat.S_ISLNK(info.st_mode):
                target = os.readlink(name, dir_fd=root.fd)
                if target not in ("private/" + name, "/private/" + name):
                    raise ArchiveValidationError("unexpected OS root alias")
                root.aliases[name] = (_identity(info), info.st_mtime_ns, info.st_ctime_ns, target)
                parts.insert(0, "private")
        current = root
        for part in parts:
            current = current.child(part)
        current.verify()
        return current

    def stat(self, name):
        return os.stat(_component(name), dir_fd=self.fd, follow_symlinks=False)

    def verify(self):
        chain, node = [], self
        while node is not None:
            chain.append(node)
            node = node.parent
        for node in reversed(chain):
            if node.fd < 0 or _identity(os.fstat(node.fd)) != node.identity:
                raise ArchiveValidationError("archive directory descriptor identity changed")
            if node.parent is not None and _identity(node.parent.stat(node.name)) != node.identity:
                raise ArchiveValidationError("archive directory binding changed (replacement or symbolic link)")
            for name, expected in node.aliases.items():
                value = node.stat(name)
                actual = (_identity(value), value.st_mtime_ns, value.st_ctime_ns, os.readlink(name, dir_fd=node.fd))
                if actual != expected:
                    raise ArchiveValidationError("OS root alias changed")

    def event(self, point, name=None):
        if self.hook is not None:
            self.hook(point, self, name)

    def child(self, name, create=False, exclusive=False):
        _component(name)
        self.verify()
        created = False
        if create:
            try:
                os.mkdir(name, 0o700, dir_fd=self.fd)
                created = True
            except FileExistsError:
                if exclusive: raise
        expected = _identity(self.stat(name))
        if expected[2] != stat.S_IFDIR:
            raise ArchiveValidationError("archive directory is a symbolic link or special file")
        self.event("before_directory_open", name)
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=self.fd)
        result = _Directory(fd, os.path.join(self.path, name), self, name, self.hook)
        result.created = created
        if result.identity != expected:
            result.close()
            raise ArchiveValidationError("archive directory entry was replaced while opening")
        result.verify()
        result.event("directory_opened")
        result.verify()
        return result

    def names(self, limit):
        self.verify()
        names = []
        # scandir(fd) is fd-relative too, and bounds the enumeration itself.
        with os.scandir(self.fd) as entries:
            for entry in entries:
                if len(names) >= limit:
                    raise ArchiveValidationError("archive cleanup entry count limit")
                names.append(_component(entry.name))
        self.verify()
        return sorted(names)


class _Extraction:
    def __init__(self, cache, relative, hook=None):
        self.cache = _Directory.open_native(cache, hook)
        self.relative = relative
        self.root = None
        self.records = {}

    def create(self):
        current = self.cache
        parts = self.relative.split("/")
        for index, part in enumerate(parts):
            current = current.child(part, create=True, exclusive=index == len(parts) - 1)
        self.root = current
        if current.names(1):
            raise ArchiveValidationError("new archive load directory is not empty")
        return current.path

    def verify(self):
        if self.root is None:
            self.cache.verify()
        else:
            self.root.verify()

    def directory(self, relative, create=False, expected=None):
        current, prefix = self.root, []
        if current is None:
            raise RuntimeStateError("archive extraction has not been created")
        for part in relative.split("/") if relative else ():
            prefix.append(_component(part))
            current = current.child(part, create=create)
            key = _receipt_key("/".join(prefix))
            known = (expected if expected is not None else self.records).get(key)
            if known is not None and current.identity != known:
                raise ArchiveValidationError("archive cleanup directory generation changed")
            if create:
                if known is None and not current.created:
                    raise ArchiveValidationError("unexpected unowned directory in archive extraction")
                self.records.setdefault(key, current.identity)
        return current

    def write(self, relative, content):
        parent, _, name = relative.rpartition("/")
        directory = self.directory(parent, create=True)
        directory.verify()
        directory.event("before_file_open", name)
        fd = os.open(_component(name), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                     0o600, dir_fd=directory.fd)
        try:
            identity = _identity(os.fstat(fd))
            if identity[2] != stat.S_IFREG or _identity(directory.stat(name)) != identity:
                raise ArchiveValidationError("new archive file identity changed")
            self.records[_receipt_key(relative)] = identity
            directory.verify()
            view = memoryview(content)
            while view:
                written = os.write(fd, view[:65536])
                if written <= 0: raise OSError("short archive write")
                view = view[written:]
            if _identity(os.fstat(fd)) != identity or _identity(directory.stat(name)) != identity:
                raise ArchiveValidationError("archive file identity changed while writing")
            directory.verify()
        finally:
            os.close(fd)

    def cleanup(self):
        if self.root is None: return
        try: self.root.verify()
        except FileNotFoundError: return  # a native purge already removed this generation
        captured = {}

        def collect(directory, prefix, depth):
            if depth > MAX_PATH_DEPTH + 4:
                raise ArchiveValidationError("archive cleanup depth limit")
            for name in directory.names(MAX_CLEANUP_ENTRIES - len(captured)):
                key = prefix + name
                identity = _identity(directory.stat(name))
                if _receipt_key(key) in self.records and identity != self.records[_receipt_key(key)]:
                    raise ArchiveValidationError("archive cleanup refuses a replacement inode")
                captured[key] = identity
                if identity[2] == stat.S_IFDIR:
                    collect(directory.child(name), key + "/", depth + 1)

        collect(self.root, "", 0)
        expected = {_receipt_key(path): identity for path, identity in captured.items()}
        # Only recorded inodes in the held load tree are removed. Every parent
        # traversal and unlink is fd-relative; a moved/replaced name fails closed.
        for key in sorted(captured, key=lambda item: item.count("/"), reverse=True):
            parent, _, name = key.rpartition("/")
            directory = self.directory(parent, expected=expected)
            directory.event("before_unlink", name)
            directory.verify()
            if _identity(directory.stat(name)) != captured[key]:
                raise ArchiveValidationError("archive cleanup refuses a replacement inode")
            if captured[key][2] == stat.S_IFDIR:
                os.rmdir(name, dir_fd=directory.fd)
            else:
                os.unlink(name, dir_fd=directory.fd)
            directory.verify()
        root = self.root
        root.verify()
        if _identity(root.parent.stat(root.name)) != root.identity:
            raise ArchiveValidationError("archive load generation changed before removal")
        os.rmdir(root.name, dir_fd=root.parent.fd)
        # Keep the tiny owner directory: another native generation may share its
        # parent. Native uninstall owns the broader cache cleanup lease.

    def close(self):
        if self.cache is not None:
            for directory in list(self.cache.pool):
                directory.close()
        self.root = self.cache = None


class ArchiveAdapter:
    def __init__(self, platform):
        self.platform = platform
        self.snapshot = None
        self.relative = self.cache = self.root = None
        self.extraction = self.image = None
        self.file_hook = None  # deterministic raw-OS barriers for owned fixtures
        self.verified_source = None
        self.source_gate = _native_source_gate(required=False)
        self.owned_files = []
        self.removed_paths = []
        self.installed = False

    def _check(self, plugins_dir=None, plugin_id=None):
        self.platform.check_plugin(self.platform.plugin_id if plugin_id is None else plugin_id)
        if plugins_dir is not None and os.path.abspath(plugins_dir) != os.path.abspath(self.platform.plugins_dir):
            raise RuntimeStateError("archive operation belongs to a different plugins directory")

    def activate(self, snapshot):
        self._check(plugin_id=snapshot.metadata["id"])
        _posix_backend()
        if not self.platform.owner_token:
            raise RuntimeStateError("archive extraction requires a bound native callback owner")
        if self.snapshot is not None:
            raise RuntimeStateError("archive load already owns a snapshot")
        self._install()
        self.snapshot = snapshot
        owner = hashlib.sha256((self.platform.plugin_id + "\0" + self.platform.owner_token).encode()).hexdigest()
        self.relative = "elyx/" + owner + "/" + snapshot.digest + "-" + uuid.uuid4().hex
        self.extraction = _Extraction(self.platform.getCacheDir(), self.relative, self.file_hook)
        self.cache = self.extraction.cache.path
        self.root = os.path.join(self.cache, *self.relative.split("/"))
        self.image = _Image(snapshot, self.root, self.extraction.verify)
        self.platform.archive_code_paths.bind_image(self.root, self.image.blobs)
        # An archive imports only its namespace and the actual SDK/providers.
        # Do not let PathFinder import a neighbouring plugin as an unowned module.
        for index, path in reversed(list(enumerate(sys.path))):
            if isinstance(path, str) and os.path.abspath(path) == os.path.abspath(self.platform.plugins_dir):
                self.removed_paths.append((index, sys.path.pop(index)))

    def _install(self):
        if self.installed: return
        sdk, platform = _sdk(), self.platform
        sdk.active_adapter = self
        self.original_load = sdk.loader.load_plugin_record
        sdk.package.load_plugin_record = sdk.loader.load_plugin_record = self._load_record
        sdk.archive.open_archive = self._open
        sdk.archive.extract_archive = self._extract
        sdk.archive.process_wheels = self._wheels
        sdk.archive.cleanup_stale_extractions = self._stale
        sdk.archive.reference_dir = self._reference
        sdk.archive._link_reference_dir = self._link_reference
        sdk.archive.purge_plugin_dirs = self._purge
        sdk.package.purge_plugin = sdk.loader.purge_plugin = self._purge
        sdk.archive._safe_extract = self._no_external_extract
        sdk.loader.os = SimpleNamespace(**dict(vars(os), path=_ManifestPaths()))
        sdk.loader.load_strings_from_dir = self._strings_from_snapshot
        from ._dependencies import PROVIDED_ROOTS
        roots = {root for values in PROVIDED_ROOTS.values() for root in values}
        roots.update({"extera_utils", "elyx_runtime", "exteraless_runtime", "virtualjava", "_exteraless_bridge",
                      "android_utils", "file_utils", "plugin_settings", "pip_controller", "javax", "dalvik", "kotlin"})
        roots.update(platform.loader._sdk_module_names())
        roots.update(platform.loader._JAVA_ROOT_PACKAGES)
        sdk.namespace.RESERVED_ROOTS |= roots
        # Metadata may have been inspected earlier in this interpreter. Refresh
        # the SDK's captured settings bridge rather than its desktop local store.
        from app.exteraless.plugins import PythonBridge
        importlib.import_module("elyx_runtime.settings").PythonBridge = PythonBridge
        files = importlib.import_module("file_utils")
        prior_directory, prior_roots = files.get_plugin_dir, files._own_roots
        native_files, native_cache = platform.getFilesDir(), platform.getCacheDir()
        native_roots = [os.path.normcase(os.path.abspath(path)) for path in (native_files, native_cache)]

        def plugin_directory(plugin_id=None):
            if self.snapshot is None: return prior_directory(plugin_id)
            self._check(plugin_id=plugin_id)
            return native_files

        def own_roots(plugin_id):
            if self.snapshot is None: return prior_roots(plugin_id)
            self._check(plugin_id=plugin_id)
            # Native components include the ID's UTF-8 hex suffix. The legacy
            # shared .data/<id> path would alias IDs differing only in case.
            return list(native_roots)

        files.get_plugin_dir, files._own_roots = plugin_directory, own_roots
        files._own_roots_cache.clear()
        original_neighbour = platform.loader._unloaded_neighbour

        def neighbour(name):
            if self.snapshot is not None and isinstance(name, str):
                root = name.partition(".")[0]
                if root != platform.plugin_id and root not in sdk.namespace.RESERVED_ROOTS and root not in sys.stdlib_module_names:
                    if os.path.isfile(os.path.join(platform.plugins_dir, root + ".py")):
                        raise UnsupportedSurfaceError(f"Elyx cross-plugin import {root!r} needs a cross-owner module provider; neighbour execution is unsupported")
            return original_neighbour(name)

        platform.loader._unloaded_neighbour = neighbour
        self.installed = True

    def _load_record(self, record, path):
        self._check()
        if self.snapshot is None or os.path.abspath(path) != self.snapshot.path:
            raise RuntimeStateError("Elyx SDK load requires the host's inspected archive snapshot")
        metadata = self.snapshot.metadata
        if metadata["requires"]:
            raise UnsupportedSurfaceError("Elyx requires cross-plugin imports have no iOS cross-owner module provider: "
                + ", ".join(metadata["requires"]) + "; dependency URLs are metadata only")
        provider = self.platform.dependencies
        provider.restore_path()
        provider.ensure_requirements(self.platform.plugin_id, metadata["requirements"])
        for wheel in self.snapshot.wheels:
            provider.ensure_requirements(self.platform.plugin_id, wheel.requirements)
            if wheel.requires_python:
                from packaging.specifiers import SpecifierSet
                if not SpecifierSet(wheel.requires_python).contains(".".join(map(str, sys.version_info[:3]))):
                    raise UnsupportedSurfaceError(f"local wheel requires Python {wheel.requires_python}")
        return self.original_load(record, path)

    def _open(self, path):
        self._check()
        if self.snapshot is None or os.path.abspath(path) != self.snapshot.path:
            raise RuntimeStateError("archive read does not match this owner's pinned snapshot")
        # Exact immutable bytes were already fully validated, including wheels.
        return zipfile.ZipFile(io.BytesIO(self.snapshot.data))

    def _strings_from_snapshot(self, path):
        self.image.check()
        declared = self.snapshot.refmap.get("strings") or self.snapshot.refmap.get("locales")
        if not declared or path != os.path.join(self.root, "contents", *declared.split("/")):
            raise RuntimeStateError("localization path is absent from this archive snapshot")
        return self.snapshot.catalog

    def _materialize(self, directory, members):
        prefix = os.path.relpath(directory, self.root).replace(os.sep, "/")
        if prefix not in ("contents",) and not prefix.startswith("wheels/"):
            raise RuntimeStateError("materialization is outside the owned load descriptor")
        self.extraction.directory(prefix, create=True)
        for name, content in members.items():
            relative = _member_path(name)
            if name.endswith("/"):
                self.extraction.directory(prefix + "/" + relative, create=True)
                continue
            dest = os.path.join(directory, *relative.split("/"))
            if self.image.member(dest) != content:
                raise ArchiveValidationError("materialization does not match the approved member")
            self.extraction.write(prefix + "/" + relative, content)
            if name.endswith((".py", ".pyc")):
                self.platform.loader._register_owner(dest, self.platform.plugin_id)
                self.owned_files.append(dest)

    def _extract(self, path, plugins_dir, plugin_id):
        self._check(plugins_dir, plugin_id)
        if self.snapshot is None or os.path.abspath(path) != self.snapshot.path:
            raise RuntimeStateError("extraction does not match the inspected archive")
        if self.extraction.create() != self.root:
            raise RuntimeStateError("archive descriptor path does not match the execution image")
        dest = os.path.join(self.root, "contents")
        self._materialize(dest, self.snapshot.members)
        self.extraction.verify()
        return self.snapshot.digest, dest

    def _wheels(self, extract_dir, refmap, plugins_dir, plugin_id):
        self._check(plugins_dir, plugin_id)
        if self.snapshot is None or extract_dir != os.path.join(self.root, "contents") or refmap != self.snapshot.refmap:
            raise RuntimeStateError("wheel extraction does not match this archive load")
        result = []
        for wheel in self.snapshot.wheels:
            dest = os.path.join(self.root, "wheels", wheel.digest)
            if dest in result: continue
            self._materialize(dest, wheel.members)
            result.append(dest)
        return result

    def _reference(self, plugins_dir, plugin_id):
        self._check(plugins_dir, plugin_id)
        if self.root is None: raise RuntimeStateError("archive has no active extraction")
        return os.path.join(self.root, "contents")

    def _link_reference(self, plugins_dir, plugin_id, dest):
        if dest != self._reference(plugins_dir, plugin_id):
            raise RuntimeStateError("archive reference must remain inside its native owner cache")

    def _stale(self, plugins_dir, plugin_id, keep_digest):
        self._check(plugins_dir, plugin_id)
        if self.snapshot is None or keep_digest != self.snapshot.digest:
            raise RuntimeStateError("archive cleanup digest does not match this owner")
        # Prior loads are deleted by their own cleanup, never by a plugin-id sweep.

    def _purge(self, plugins_dir, plugin_id):
        self._check(plugins_dir, plugin_id)
        self.cleanup()

    def developer_manifest(self, *, expected_source_digest):
        self._check()
        if self.image is None or not self.image.active or not self.platform.loader.is_loaded(self.platform.plugin_id):
            raise RuntimeStateError("developer manifest requires the active archive owner")
        if type(expected_source_digest) is not str or not _HEX.fullmatch(expected_source_digest):
            raise ArchiveValidationError("invalid expected native source digest")
        request = {"abi": SOURCE_ABI, "expected_source_sha256": expected_source_digest}
        with _native_source_read(self.source_gate, "manifest", request, purpose="manifest", platform=self.platform) as reader:
            if reader.proof["source_sha256"] != expected_source_digest:
                raise RuntimeStateError("native source receipt has a different digest")
            # Fresh native installed-source FD bytes, not this adapter's cached
            # snapshot, an extraction walk, or a caller-supplied filename.
            inspection = _inspect_archive_bytes("<native-elyx-manifest>." + reader.proof["format"], reader.read())
            if inspection.metadata["id"] != self.platform.plugin_id:
                raise ArchiveValidationError("native source ID differs from the active owner")
            reader.check()
            return {"source_digest": expected_source_digest,
                    "files": {name: digest for name, digest in inspection.member_hashes.items() if not name.endswith("/")}}

    @staticmethod
    def _no_external_extract(*args, **kwargs):
        raise UnsupportedSurfaceError("Elyx extraction is host-owned; use the native install/load route")

    def cleanup(self):
        self._check()
        if self.snapshot is None: return
        try:
            _sdk().loader._teardown(self.platform.plugin_id)
            for path in self.owned_files:
                self.platform.loader._forget_owner(path)
            if self.extraction is not None:
                self.extraction.cleanup()
        finally:
            if self.image is not None:
                self.image.active = False
            self.platform.archive_code_paths.unbind_image(self.root)
            if self.extraction is not None:
                self.extraction.close()
            self.extraction = self.image = None
            self.snapshot = None
            self.relative = self.cache = self.root = None
            self.owned_files.clear()
            for index, path in reversed(self.removed_paths):
                if path not in sys.path: sys.path.insert(index, path)
            self.removed_paths.clear()
