"""Read-only runtime paths for the real SDK audit hook on embedded CPython.

Frozen os need not have __file__. Capture trusted locations before entering any
plugin instead of asking the SDK to infer trust lazily from mutable sys.path.
"""

import builtins
import importlib
import os
from pathlib import Path, PurePosixPath
import stat
import sys
import sysconfig
import unicodedata

from ._platform import RuntimeStateError


def _real(path):
    try:
        value = os.fsdecode(os.fspath(path))
        if not value or "\0" in value or value.startswith("<"):
            return None
        return os.path.normcase(os.path.realpath(value))
    except (OSError, TypeError, ValueError):
        return None


def _within(path, root):
    return path == root or path.startswith(root + os.sep)


class RuntimePaths:
    def __init__(self, directories=(), files=(), excluded=()):
        self.excluded = tuple(sorted({path for item in excluded if (path := _real(item))}))

        def acceptable(path):
            # An over-broad prefix must not turn plugin/settings/storage trees
            # into runtime files, including when a home/path is misconfigured.
            return path and not any(_within(path, root) or _within(root, path) for root in self.excluded)

        self.directories = tuple(sorted({path for item in directories
                                         if acceptable(path := _real(item))}))
        self.files = frozenset(path for item in files if acceptable(path := _real(item)))

    def contains(self, path):
        path = _real(path)
        if path is None or any(_within(path, root) for root in self.excluded):
            return False
        return path in self.files or any(_within(path, root) for root in self.directories)

    def runtime_paths(self):
        return self.directories

    def touches(self, path):
        """Mutating an ancestor can remove/replace a protected runtime subtree."""
        path = _real(path)
        return path is not None and (self.contains(path) or any(
            _within(root, path) for root in (*self.directories, *self.files)))


def _stdlib_directories():
    candidates = [getattr(sys, "_stdlib_dir", None)]
    # These source-backed standard-library anchors also work when frozen os and
    # an explicitly configured module_search_paths leave os.__file__ absent.
    for module in (importlib, sys.modules.get("encodings")):
        filename = getattr(module, "__file__", None)
        if filename:
            candidates.append(Path(filename).parent.parent)
    filename = getattr(os, "__file__", None)
    if filename:
        candidates.append(Path(filename).parent)
    for name in ("stdlib", "platstdlib"):
        try:
            candidates.append(sysconfig.get_path(name))
        except (ImportError, KeyError, AttributeError, TypeError):
            pass
    try:
        candidates.append(sysconfig.get_config_var("DESTSHARED"))
    except (ImportError, KeyError, AttributeError, TypeError):
        pass
    for prefix in (sys.prefix, sys.base_prefix, sys.exec_prefix, sys.base_exec_prefix):
        if prefix:
            candidates.append(Path(prefix) / "DLLs")  # Windows extension directory, not the whole prefix.
    return tuple(sorted({path for item in candidates
                         if (path := _real(item)) and os.path.isdir(path)}))


def _framework_directories(python_root, stdlib_directories):
    """Only Python and the frameworks named by the stdlib's .fwork markers.

    TelegramUI and the rest of App.app/Frameworks are not implicitly trusted.
    This reads small loader marker files, never loads a framework or Python code.
    """
    app = Path(python_root).parent
    if not app.name.endswith(".app"):
        return ()
    frameworks = app / "Frameworks"
    result = set()
    python = frameworks / "Python.framework"
    if (python / "Python").is_file():
        result.add(python)
    for stdlib in stdlib_directories:
        base = Path(stdlib)
        if not base.is_relative_to(app):
            continue
        dynload = base if base.name == "lib-dynload" else base / "lib-dynload"
        if not dynload.is_dir():
            continue
        for index, marker in enumerate(dynload.glob("*.fwork")):
            if index >= 256:
                raise RuntimeStateError("too many embedded Python framework markers")
            if marker.stat().st_size > 4096:
                raise RuntimeStateError(f"oversized Python framework marker: {marker.name}")
            name = marker.name.split(".", 1)[0]
            relative = PurePosixPath(marker.read_text(encoding="utf-8").strip())
            if not name.isidentifier() or relative.parts != ("Frameworks", name + ".framework", name):
                raise RuntimeStateError(f"unexpected Python framework marker: {marker.name}")
            binary = app.joinpath(*relative.parts)
            if not binary.resolve().is_relative_to(frameworks.resolve()) or not binary.is_file():
                raise RuntimeStateError(f"missing/escaping Python framework: {marker.name}")
            result.add(binary.parent)
    return tuple(result)


def capture(platform, loader, dependencies, own_files, own_cache):
    python_root = Path(__file__).resolve().parent.parent
    sdk = Path(loader._SRC_DIR).resolve()
    code = [sdk, Path(__file__).resolve().parent, python_root / "virtualjava"]
    if dependencies.vendor_dir is not None:
        code.append(dependencies.vendor_dir)
    stdlib = _stdlib_directories()
    directories = [*code, *stdlib, *_framework_directories(python_root, stdlib)]
    files = [python_root / "compat-manifest.json", python_root / "tl-schema.json"]
    version = f"python{sys.version_info.major}{sys.version_info.minor}.zip"
    dll = f"python{sys.version_info.major}{sys.version_info.minor}.dll"
    for prefix in (sys.prefix, sys.base_prefix, sys.exec_prefix, sys.base_exec_prefix):
        if not prefix:
            continue
        for candidate in (Path(prefix) / version, Path(prefix) / "lib" / version,
                          Path(prefix) / "Python", Path(prefix) / dll):
            if candidate.is_file():
                files.append(candidate)
    try:
        libdir, library = sysconfig.get_config_var("LIBDIR"), sysconfig.get_config_var("LDLIBRARY")
        if libdir and library and os.path.basename(library) == library:
            binary = Path(libdir) / library
            if binary.is_file():
                files.append(binary)
    except (ImportError, KeyError, AttributeError, TypeError):
        pass
    paths = RuntimePaths(directories, files, excluded=(
        platform.plugins_dir, platform.settings_dir, own_files, own_cache))
    if any(not paths.contains(path) for path in code):
        raise RuntimeStateError("plugin storage overlaps a trusted runtime package")
    return paths


def _read_mode(mode):
    return isinstance(mode, str) and mode.startswith("r") and not any(flag in mode for flag in "wax+")


def _lexical(path):
    try:
        path = os.fsdecode(os.fspath(path))
        if not path or "\0" in path:
            return None
        path = os.path.normcase(os.path.abspath(path))
        # Match the native OS-root aliases without resolving any untrusted leaf.
        if sys.platform == "darwin":
            for name in ("var", "tmp", "etc"):
                prefix = "/" + name
                if _within(path, prefix):
                    path = "/private" + path
                    break
        return path
    except (OSError, ValueError, TypeError):
        return None


def _descriptor_path(fd):
    """OS-provided name of an already-open inode, including Darwin/iOS F_GETPATH."""
    if type(fd) is not int or fd < 0:
        return None
    try:
        if sys.platform == "darwin":
            import fcntl
            return os.fsdecode(fcntl.fcntl(fd, fcntl.F_GETPATH, bytes(1024)).split(b"\0", 1)[0])
        if sys.platform.startswith("linux"):
            return os.readlink(f"/proc/self/fd/{fd}")
    except (OSError, ValueError):
        return None
    return None


def _code_path(path):
    path = _lexical(path)
    return unicodedata.normalize("NFC", path).casefold() if path is not None else None


class ArchiveCodePaths:
    """Every interpreter protects the shared archive layout, even before A loads.

    A per-owner-only list would leave files-capable interpreter B unaware of A's
    executable cache. Ordinary asset file contents remain filesystem data; code
    files and archive directory topology require native installation/cleanup.
    """
    code_suffixes = (".py", ".pyc", ".pyo", ".pyw", ".pth", ".whl", ".so", ".dylib", ".dll", ".pyd", ".fwork", ".elyx", ".eaf")

    def __init__(self, own_cache):
        self.own_cache = _code_path(own_cache)
        self.shared_cache = _code_path(os.path.dirname(own_cache))
        if self.own_cache is None or self.shared_cache is None:
            raise RuntimeStateError("archive cache protection has no native anchor")
        self.protected_code_roots = {}

    def bind_image(self, root, members):
        root = _code_path(root)
        if root is None or not _within(root, self.own_cache + os.sep + "elyx"):
            raise RuntimeStateError("archive code image belongs to another native cache")
        self.protected_code_roots[root] = frozenset(_code_path(path) for path in members if path.lower().endswith(self.code_suffixes))

    def unbind_image(self, root):
        self.protected_code_roots.pop(_code_path(root), None)

    def reason(self, path, structural=False):
        # Lexical protection still applies when a malicious link points OUT of
        # the tree; resolved protection catches aliases pointing INTO the tree.
        resolved = _real(path)
        for target in {_code_path(path), _code_path(resolved) if resolved else None} - {None}:
            root = self.shared_cache
            if _within(root, target):
                return "archive code ancestors"
            if not _within(target, root):
                continue
            parts = os.path.relpath(target, root).split(os.sep)
            if len(parts) == 1:
                return "archive code ancestors"
            if parts[1] != "elyx":
                continue
            if len(parts) <= 4 or structural or "__pycache__" in parts or target.lower().endswith(self.code_suffixes):
                return "immutable archive code/topology"
        return None

    def check_path(self, path, structural=False):
        reason = self.reason(path, structural)
        if reason:
            raise PermissionError(f"{reason} is read-only; replace the archive through the native Host")

    def fd_path(self, fd):
        path = _descriptor_path(fd)
        if path:
            return path
        try:
            mode = os.fstat(fd).st_mode
        except (OSError, TypeError, ValueError):
            return None  # the syscall will report its invalid descriptor
        if stat.S_ISREG(mode) or stat.S_ISDIR(mode):
            raise PermissionError("cannot verify a filesystem descriptor for archive code protection")
        return None  # pipes/sockets are governed by their existing SDK policies

    def target(self, path, fd=None):
        if type(path) is int:
            return self.fd_path(path)
        if not isinstance(path, (str, bytes, os.PathLike)):
            return None
        path = os.fsdecode(path)
        if os.path.isabs(path) or fd is None or fd == -1:
            return path
        parent = self.fd_path(fd)
        if parent is None:
            raise PermissionError("cannot verify a dir_fd for archive code protection")
        return os.path.join(parent, path)

    def check(self, event, args, audit):
        arg = lambda index: audit._arg(args, index)
        if event == "open":
            mode, flags = arg(1), arg(2)
            if not ((isinstance(mode, str) and any(char in mode for char in "wax+"))
                    or (type(flags) is int and flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND))):
                return
            targets = [self.target(arg(0))]
        elif event in ("os.rename", "os.link"):
            targets = [self.target(arg(0), arg(2)), self.target(arg(1), arg(3))]
        elif event == "os.symlink":
            targets = [self.target(arg(1), arg(2))]
        elif event in ("os.remove", "os.rmdir"):
            targets = [self.target(arg(0), arg(1))]
        elif event in ("os.mkdir", "os.chmod"):
            targets = [self.target(arg(0), arg(2))]
        elif event in ("os.chown", "os.utime"):
            targets = [self.target(arg(0), arg(3))]
        else:
            targets = [self.target(arg(index)) for index in audit._WRITE_TARGETS.get(event, ())]
        structural = event in ("os.rmdir", "os.mkdir", "os.symlink", "shutil.rmtree", "shutil.copytree", "shutil.unpack_archive")
        for path in targets:
            if path is not None:
                # No following lookup is used to authorize an operation. A
                # directory or symlink mutation is conservatively structural.
                try: structural |= stat.S_IFMT(os.lstat(path).st_mode) in (stat.S_IFDIR, stat.S_IFLNK)
                except OSError: pass
        for path in targets:
            if path is not None:
                self.check_path(path, structural)


def _install_archive_fd_guards(loader, paths):
    # CPython's os.open audit event omits dir_fd. Resolve that argument here,
    # while retaining the real audit event and permission/owner attribution.
    original_open = os.open

    def open_file(path, flags, mode=0o777, *, dir_fd=None):
        if loader.plugin_frame_owner() is not None and flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND):
            target = paths.target(path, dir_fd)
            if target is not None:
                paths.check_path(target)
        return original_open(path, flags, mode, dir_fd=dir_fd)

    os.open = open_file
    # These descriptor writes do not emit a CPython open event. Do not let a
    # files-only owner mutate a code inode through an existing fd or dup2 alias.
    for name in ("write", "writev", "pwrite", "pwritev", "ftruncate", "fchmod", "fchown", "dup2"):
        original = getattr(os, name, None)
        if original is None: continue

        def guarded(*args, _original=original, _name=name, **kwargs):
            if loader.plugin_frame_owner() is not None:
                fds = [args[0] if args else kwargs.get("fd")]
                if _name == "dup2":
                    fds.append(args[1] if len(args) > 1 else kwargs.get("fd2"))
                for fd in fds:
                    path = paths.fd_path(fd)
                    if path is not None:
                        paths.check_path(path, _name == "dup2" or os.path.isdir(path))
            return _original(*args, **kwargs)

        setattr(os, name, guarded)


def install(platform, loader, dependencies, files):
    audit = importlib.import_module("extera_utils.audit_gate")
    own_files = _real(platform.getFilesDir())
    own_cache = _real(platform.getCacheDir())
    if own_files is None or own_cache is None:
        raise RuntimeStateError("native plugin files/cache paths cannot be resolved")
    paths = capture(platform, loader, dependencies, own_files, own_cache)
    platform.audit_paths = paths
    archive_paths = ArchiveCodePaths(platform.getCacheDir())
    platform.archive_code_paths = archive_paths
    protected_native_directories = ()

    def refresh_protected_paths():
        nonlocal protected_native_directories
        raw = platform.call("getProtectedPaths")
        if not isinstance(raw, list) or len(raw) > 64:
            raise RuntimeStateError("getProtectedPaths must return at most 64 absolute paths")
        native_directories = set()
        for name in raw:
            if not isinstance(name, str) or not os.path.isabs(name) or "\0" in name or len(name) > 4096:
                raise RuntimeStateError("native protected path must be absolute")
            path = _real(name)
            if not path:
                raise RuntimeStateError("native protected path cannot be resolved")
            native_directories.add(path)
        protected_native_directories = tuple(native_directories)

    platform.refresh_protected_paths = refresh_protected_paths

    # iOS native directories are already per-plugin. The SDK's Android fallback
    # would additionally own all TMPDIR and infer a wrong filesDir/plugins root.
    plugin_data = Path(platform.plugins_dir) / ".data" / platform.plugin_id
    # The host creates this scoped SDK directory before plugin execution, so a
    # plugin without files/hooks need not create the shared .data parent itself.
    plugin_data.mkdir(parents=True, exist_ok=True)
    own_roots = (own_files, own_cache, _real(plugin_data))

    def plugin_roots(plugin_id):
        platform.check_plugin(plugin_id)
        return list(own_roots)

    files._own_roots = plugin_roots
    files._own_roots_cache.clear()
    audit._storage_roots = ((_real(platform.settings_dir),), _real(platform.plugins_dir))
    audit._storage_paths = lambda: audit._storage_roots
    audit._runtime_prefixes = paths.directories
    audit._runtime_paths = paths.runtime_paths
    audit._is_runtime_file = paths.contains

    previous_protected_write = audit._check_protected_write
    previous_protected_reason = audit._protected_reason
    audit._protected_reason = lambda plugin_id, path: archive_paths.reason(path) or previous_protected_reason(plugin_id, path)
    write_flags = os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND

    def protected_write(event, args, plugin_id, active_loader):
        try:
            archive_paths.check(event, args, audit)
        except PermissionError as error:
            raise audit._denial(error)
        targets = audit._write_targets(event, args)
        if event == "open":
            mode, flags = audit._arg(args, 1), audit._arg(args, 2)
            writes = (isinstance(mode, str) and any(flag in mode for flag in "wax+")) \
                or (type(flags) is int and flags & write_flags)
            if not writes:
                targets = ()
        if event == "os.link":
            # A hard link into writable plugin data would alias a runtime inode.
            targets = (*targets, audit._arg(args, 0))
        for target in targets:
            if paths.touches(target):
                raise audit._denial(PermissionError(f"plugin {plugin_id!r}: bundled runtime is read-only: {target}"))
            resolved = _real(target)
            sealed = resolved is not None and (
                any(_within(resolved, path) or _within(path, resolved) for path in protected_native_directories))
            if sealed and not active_loader.has_permission("hooks", plugin_id):
                raise audit._denial(PermissionError(
                    f"plugin {plugin_id!r}: native app settings are protected; use setClientSetting or grant hooks"))
        return previous_protected_write(event, args, plugin_id, active_loader)

    audit._check_protected_write = protected_write
    _install_archive_fd_guards(loader, archive_paths)

    previous_open = builtins.open

    def runtime_open(file, mode="r", *args, **kwargs):
        if _read_mode(mode) and paths.contains(file):
            # Go to the original C open, which still emits the real audit event.
            # The SDK builtins wrapper otherwise requires files even for a
            # direct read of certifi's immutable bundled CA data.
            return loader._original_open(file, mode, *args, **kwargs)
        return previous_open(file, mode, *args, **kwargs)

    builtins.open = runtime_open
    previous_require_files = files._require_files

    def require_files(path, what):
        if what in ("read a file", "list a directory") and paths.contains(path):
            return
        return previous_require_files(path, what)

    files._require_files = require_files
    return paths
