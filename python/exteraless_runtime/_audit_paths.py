"""Read-only runtime paths for the real SDK audit hook on embedded CPython.

Frozen os need not have __file__. Capture trusted locations before entering any
plugin instead of asking the SDK to infer trust lazily from mutable sys.path.
"""

import builtins
import importlib
import os
from pathlib import Path, PurePosixPath
import sys
import sysconfig

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


def install(platform, loader, dependencies, files):
    audit = importlib.import_module("extera_utils.audit_gate")
    own_files = _real(platform.getFilesDir())
    own_cache = _real(platform.getCacheDir())
    if own_files is None or own_cache is None:
        raise RuntimeStateError("native plugin files/cache paths cannot be resolved")
    paths = capture(platform, loader, dependencies, own_files, own_cache)
    platform.audit_paths = paths
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
    write_flags = os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND

    def protected_write(event, args, plugin_id, active_loader):
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
