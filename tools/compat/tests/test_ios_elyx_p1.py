"""ARCH-01/02/03 owned regression witnesses; no external archives or network.

Portable cases inspect code objects and exercise the real source-owner audit.
POSIX cases use actual dir_fd/openat operations and actual rename/symlink barriers;
they are deliberately not emulated by the Windows source-service fixture.
"""

import hashlib
import importlib.util
import io
import json
import os
import operator
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import CodeType, SimpleNamespace

ROOT = Path(__file__).resolve().parents[3]
CASES = ("cached_source", "snapshot_mutations", "audit_owner", "backend", "fd_extract_swap",
         "fd_cleanup_swap", "fd_replacements", "raw_os_paths", "two_owners")
POSIX = {"fd_extract_swap", "fd_cleanup_swap", "fd_replacements", "raw_os_paths", "two_owners"}


def fixtures():
    spec = importlib.util.spec_from_file_location("_elyx_fixture_support", Path(__file__).with_name("test_ios_elyx_archives.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def source_bootstrap(directory, plugin_id="writer", shared=None):
    support = fixtures()
    if shared is None:
        return support.bootstrap(directory, plugin_id, "source")
    # Each process has a separate real SDK registry, owner and service double;
    # the configured native filesystem layout is the intentionally shared input.
    spec = importlib.util.spec_from_file_location("_ios_runtime_fixture_support", Path(__file__).with_name("test_ios_runtime.py"))
    base = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(base)
    runtime, host, bridge = base.bootstrap(directory, plugin_id, configure=False)
    host.root, host.plugins, host.settings = shared, shared / "plugins", shared / "settings"
    previous = host.call

    def call(request):
        request = dict(request)
        assert request.pop("ownerToken", None) in (None, host.owner_token)
        if request["op"] == "member_kind": return "unknown"
        return previous(request)

    host.call = call
    runtime.configure(plugin_id, host.plugins, host.settings)
    runtime.bind_owner_json(json.dumps("owner-" + plugin_id))
    return runtime, host, bridge


def cached_bytecode(source):
    from importlib._bootstrap_external import _code_to_hash_pyc
    code = compile(source, "unowned-build/main.py", "exec")
    constants = tuple(value.replace(co_filename="unowned-build/forged_callback.py")
                      if type(value) is CodeType else value for value in code.co_consts)
    return bytes(_code_to_hash_pyc(code.replace(co_consts=constants), b"12345678", checked=False))


def walk_codes(code):
    yield code
    for value in code.co_consts:
        if type(value) is CodeType:
            yield from walk_codes(value)


def image_fixture(directory, extras=()):
    support = fixtures()
    from exteraless_runtime import _archives as archives
    source = 'VALUE = "APPROVED"\ndef callback():\n    return VALUE\n'
    injected = 'VALUE = "INJECTED"\ndef callback():\n    return VALUE\n'
    cache_name = Path(importlib.util.cache_from_source("main.py")).as_posix()
    entries = [("refmap.json", '{"main":"main.py"}'), ("metainfo.json", '{"id":"victim","name":"Owned"}'),
               ("main.py", source), (cache_name, cached_bytecode(injected)),
               ("lazy.py", 'VALUE = "CAPTURED"\n'), ("data.json", '{"value":"CAPTURED"}'),
               ("pkg/__init__.py", 'VALUE = "PACKAGE"\n'), *extras]
    path = directory / "owned.elyx"
    path.write_bytes(support.zipped(entries))
    snapshot = archives.inspect_archive(path)
    root = directory / "cache" / "victim" / "elyx" / ("a" * 64) / (snapshot.digest + "-" + "b" * 32)
    # Owned helper materialization, NOT the production POSIX backend. Windows
    # witnesses below inspect get_code only; they do not claim FD acceptance.
    for name, data in snapshot.members.items():
        target = root / "contents" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    return archives, snapshot, archives._Image(snapshot, str(root)), root


def case_cached_source(directory):
    from importlib.machinery import SourceFileLoader, SourcelessFileLoader
    archives, snapshot, image, root = image_fixture(directory)
    path = str(root / "contents/main.py")
    vulnerable = SourceFileLoader("main", path).get_code("main")
    assert vulnerable.co_filename == path
    assert any(code.co_filename == "unowned-build/forged_callback.py" for code in walk_codes(vulnerable)), "review control must still reproduce"
    sdk = archives._sdk()
    previous_exec = sdk.module_exec
    previous_adapter = getattr(sdk, "active_adapter", None)
    sdk.active_adapter = SimpleNamespace(image=image, _check=lambda: None)
    captured = []
    sdk.module_exec = lambda loader, module: captured.append(loader._real.get_code(module.__name__))
    try:
        wrapper = SimpleNamespace(_real=SourceFileLoader("main", path))
        archives._owned_module_exec(wrapper, SimpleNamespace(__name__="main"))
        fixed = captured.pop()
        assert "APPROVED" in fixed.co_consts and "INJECTED" not in fixed.co_consts
        assert all(code.co_filename == path for code in walk_codes(fixed))
        # Explicit bytecode keeps its admitted bytes, but every nested code label
        # (including a different forged label) must be recursively rebound.
        pyc = str(root / "contents" / Path(importlib.util.cache_from_source("main.py")))
        archives._owned_module_exec(SimpleNamespace(_real=SourcelessFileLoader("cached", pyc)), SimpleNamespace(__name__="cached"))
        assert all(code.co_filename == pyc for code in walk_codes(captured.pop()))
        deeply = compile("pass", "forged", "exec")
        for _ in range(40): deeply = deeply.replace(co_consts=(deeply,))
        fixtures().raises(archives.UnsupportedSurfaceError, lambda: archives._bind_code(deeply, path), "depth/node")
    finally:
        sdk.module_exec, sdk.active_adapter = previous_exec, previous_adapter


def case_snapshot_mutations(directory):
    archives, snapshot, image, root = image_fixture(directory, [("cafe\u0301.py", 'VALUE = "UNICODE"\n')])
    sdk = archives._sdk()
    sdk.active_adapter = SimpleNamespace(image=image, _check=lambda: None)
    namespace = SimpleNamespace(root_dir=str(root / "contents"), search_paths=[str(root / "contents")], prefix="ElyxPlugins.victim")
    finder = sdk.namespace._ElyxFinder()
    path = root / "contents/lazy.py"
    assert hashlib.sha256(path.read_bytes()).hexdigest() == snapshot.member_hashes["lazy.py"]
    path.write_text('VALUE = "MUTATED"\n')
    assert hashlib.sha256(path.read_bytes()).hexdigest() != snapshot.member_hashes["lazy.py"]
    spec = finder._submodule_spec(namespace, namespace.prefix + ".lazy", ["lazy"])
    code = spec.loader._real.get_code(spec.name)
    assert "CAPTURED" in code.co_consts and "MUTATED" not in code.co_consts
    replacement = directory / "replacement.py"
    replacement.write_text('VALUE = "REPLACED"\n')
    os.replace(replacement, path)
    assert "CAPTURED" in spec.loader._real.get_code(spec.name).co_consts
    if os.name == "posix":
        path.unlink()
        replacement.write_text('VALUE = "LINKED"\n')
        path.symlink_to(replacement)
        assert "CAPTURED" in spec.loader._real.get_code(spec.name).co_consts
    # Filesystem mutations cannot change resolution from a package to a source
    # or admit a new helper that was absent from the approved image.
    (root / "contents/injected.py").write_text("raise AssertionError('unapproved')\n")
    assert finder._submodule_spec(namespace, namespace.prefix + ".injected", ["injected"]) is None
    (root / "contents/pkg/__init__.py").unlink()
    package = finder._submodule_spec(namespace, namespace.prefix + ".pkg", ["pkg"])
    assert package.submodule_search_locations == [] and "PACKAGE" in package.loader._real.get_code(package.name).co_consts
    (root / "contents/data.json").write_text('{"value":"MUTATED"}')
    data = finder._submodule_spec(namespace, namespace.prefix + ".data", ["data"])
    module = data.loader.create_module(data)
    data.loader.exec_module(module)
    assert module.value == "CAPTURED"
    unicode_spec = finder._submodule_spec(namespace, namespace.prefix + ".caf\u00e9", ["caf\u00e9"])
    unicode_code = unicode_spec.loader._real.get_code(unicode_spec.name)
    assert unicode_code.co_filename == str(root / "contents/cafe\u0301.py")
    fixtures().raises(TypeError, lambda: operator.setitem(image.blobs, str(path), (b"bad", "bad")))


WRITER = '''__id__ = "writer"
__name__ = "Owned writer"
from base_plugin import BasePlugin
class Writer(BasePlugin):
    def attempt(self, operation, source, target=None):
        import os
        from pathlib import Path
        if operation == "write": Path(source).write_text("UNAPPROVED")
        elif operation == "replace": os.replace(source, target)
        elif operation == "rename": os.rename(source, target)
        elif operation == "link": os.link(source, target)
        elif operation == "symlink": os.symlink(source, target)
        elif operation == "fdwrite": os.write(source, b"UNAPPROVED")
        elif operation == "fdopen":
            with os.fdopen(source, "wb", closefd=False) as handle: handle.write(b"UNAPPROVED")
        elif operation == "dirfd":
            fd = os.open(target, os.O_WRONLY | os.O_TRUNC, dir_fd=source)
            os.close(fd)
'''


def audit_writer(directory, victim, shared=None):
    runtime, host, bridge = source_bootstrap(directory, shared=shared)
    host.permissions = {"ui", "files"}
    script = host.plugins / "writer.plugin"
    script.write_text(WRITER, encoding="utf-8")
    runtime.load_json(script)
    handle = bridge.xt_register_handle(runtime._state.loader.plugins["writer"].instance)

    def call(op, first, second=None):
        return runtime.invoke_handle_json(handle, "attempt", json.dumps([op, first, second]))

    code = victim / "contents/lazy.py"
    cache = victim / "contents/__pycache__/lazy.cpython-312.pyc"
    payload = host.files / "payload.txt"
    payload.write_text("UNAPPROVED")
    attempts = [("write", str(code), None), ("write", str(cache), None),
                ("replace", str(payload), str(code)), ("rename", str(victim), str(victim) + ".moved"),
                ("rename", str(victim.parent), str(victim.parent) + ".moved"),
                ("symlink", str(payload), str(code)), ("link", str(code), str(host.files / "alias.txt"))]
    for operation in attempts:
        fixtures().raises(PermissionError, lambda: call(*operation), "archive code")
    if os.name == "posix":
        fd = os.open(code, os.O_WRONLY)
        directory_fd = os.open(code.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            fixtures().raises(PermissionError, lambda: call("fdwrite", fd), "archive code")
            fixtures().raises(PermissionError, lambda: call("fdopen", fd), "archive code")
            fixtures().raises(PermissionError, lambda: call("dirfd", directory_fd, "lazy.py"), "archive code")
        finally:
            os.close(fd)
            os.close(directory_fd)
    asset = victim / "contents/assets/data.txt"
    call("write", str(asset))
    assert asset.read_text() == "UNAPPROVED", "ordinary file assets still obey explicit files consent"
    assert code.read_text() == 'VALUE = "CAPTURED"\n'
    runtime.unload()
    assert not bridge.xt_handle_count()


def case_audit_owner(directory):
    victim = directory / "cache/victim/elyx" / ("a" * 64) / ("b" * 64 + "-" + "c" * 32)
    (victim / "contents/assets").mkdir(parents=True)
    (victim / "contents/lazy.py").write_text('VALUE = "CAPTURED"\n')
    (victim / "contents/assets/data.txt").write_text("asset")
    audit_writer(directory, victim)
    from exteraless_runtime import _audit_paths
    policy = _audit_paths.ArchiveCodePaths(str(directory / "cache/writer"))
    assert policy.reason(str(victim / "contents/lazy.py"))
    assert policy.reason(str(victim / "contents/lazy.py").upper()), "filesystem case aliases must not bypass code protection"
    assert policy.reason(str(victim.parent), structural=True)


def case_backend(directory):
    import exteraless_runtime as runtime
    from exteraless_runtime import _archives
    if os.name == "posix":
        _archives._posix_backend()
        return
    runtime, host, _ = fixtures().bootstrap(directory)
    path = fixtures().write(host.plugins / "owned.elyx")
    assert json.loads(runtime.metadata_json(path))["id"] == host.plugin_id
    fixtures().raises(runtime.UnsupportedSurfaceError, lambda: runtime.load_json(path), "POSIX directory-FD")
    assert not list(host.cache.glob("elyx/*"))


def fd_adapter(directory, hook=None):
    from exteraless_runtime import _archives as archives
    path = fixtures().write(directory / "owned.elyx")
    snapshot = archives.inspect_archive(path)
    cache = directory / "cache/victim"
    cache.mkdir(parents=True)
    recorded = {}
    platform = SimpleNamespace(plugin_id=snapshot.metadata["id"], plugins_dir=str(directory),
        check_plugin=lambda value: None,
        loader=SimpleNamespace(_register_owner=lambda path, owner: recorded.setdefault(path, owner)))
    adapter = archives.ArchiveAdapter(platform)
    adapter.snapshot = snapshot
    adapter.relative = "elyx/" + "a" * 64 + "/" + snapshot.digest + "-" + "b" * 32
    adapter.extraction = archives._Extraction(str(cache), adapter.relative, hook)
    adapter.cache = adapter.extraction.cache.path
    adapter.root = os.path.join(adapter.cache, *adapter.relative.split("/"))
    adapter.image = archives._Image(snapshot, adapter.root, adapter.extraction.verify)
    return adapter, path


def case_fd_extract_swap(directory):
    outside = directory / "outside"
    outside.mkdir()
    swapped = []

    def barrier(point, held, name):
        if point != "before_file_open" or swapped: return
        # This point is AFTER the real directory verification, immediately before
        # the real openat. Retain the OS inode and then swap the named ancestor.
        owner = held.parent.parent
        saved = Path(owner.path + ".saved")
        before = os.fstat(held.fd)
        os.rename(owner.path, saved)
        os.symlink(outside, owner.path, target_is_directory=True)
        assert (os.fstat(held.fd).st_dev, os.fstat(held.fd).st_ino) == (before.st_dev, before.st_ino)
        swapped.append(saved)

    adapter, path = fd_adapter(directory, barrier)
    try:
        fixtures().raises(Exception, lambda: adapter._extract(path, str(directory), adapter.platform.plugin_id))
        assert swapped and not list(outside.iterdir()), "a held FD must not reopen the swapped ancestor"
    finally:
        adapter.extraction.close()


def case_fd_cleanup_swap(directory):
    adapter, path = fd_adapter(directory)
    adapter._extract(path, str(directory), adapter.platform.plugin_id)
    original = Path(adapter.root)
    owner = original.parent
    saved = Path(str(owner) + ".saved")
    outside = directory / "outside"
    outside_load = outside / original.name
    (outside_load / "contents").mkdir(parents=True)
    marker = outside_load / "contents/keep.txt"
    marker.write_text("outside generation")
    swapped = []

    def barrier(point, held, name):
        if point != "before_unlink" or swapped: return
        os.rename(owner, saved)
        os.symlink(outside, owner, target_is_directory=True)
        swapped.append(True)

    adapter.extraction.root.hook = barrier
    try:
        fixtures().raises(Exception, adapter.extraction.cleanup)
        assert swapped and marker.read_text() == "outside generation"
        assert (saved / original.name / "contents/entry/main.py").exists()
    finally:
        adapter.extraction.close()


def case_fd_replacements(directory):
    adapter, path = fd_adapter(directory)
    adapter._extract(path, str(directory), adapter.platform.plugin_id)
    target = Path(adapter.root) / "contents/entry/helpers.py"
    replacement = directory / "replacement.py"
    replacement.write_text('VALUE = "REPLACEMENT"\n')
    os.replace(replacement, target)
    try:
        from exteraless_runtime import _archives
        code = _archives._SnapshotLoader("helpers", str(target), "source", adapter.image).get_code("helpers")
        assert "first" in code.co_consts and "REPLACEMENT" not in code.co_consts
        fixtures().raises(_archives.ArchiveValidationError, adapter.extraction.cleanup, "replacement inode")
        assert target.read_text() == 'VALUE = "REPLACEMENT"\n'
    finally:
        adapter.extraction.close()


def case_raw_os_paths(directory):
    from exteraless_runtime import _archives
    # Do not resolve the path before handing it to the production walker. /tmp
    # is a real OS alias on Darwin and an ordinary OS directory on Linux.
    with tempfile.TemporaryDirectory(prefix="owned-elyx-fd-", dir="/tmp") as raw:
        cache = Path(raw) / "cache"
        cache.mkdir()
        extraction = _archives._Extraction(str(cache), "elyx/" + "a" * 64 + "/" + "b" * 64 + "-" + "c" * 32)
        try:
            root = extraction.create()
            extraction.write("contents/own.txt", b"owned")
            assert Path(root, "contents/own.txt").read_bytes() == b"owned"
            extraction.cleanup()
            assert not Path(root).exists()
        finally:
            extraction.close()


LATE_ENTRY = '''from base_plugin import BasePlugin
class Victim(BasePlugin):
    def lazy_value(self):
        import lazy
        return lazy.VALUE
    def read_forbidden(self, path):
        return open(path, "r").read()
    def network_audit(self):
        import sys
        sys.audit("socket.getaddrinfo", "never-resolved.invalid", 443, 0, 0, 0)
'''


def case_two_owners(directory):
    runtime, host, bridge = fixtures().bootstrap(directory, "victim")
    cache_name = Path(importlib.util.cache_from_source("main.py")).as_posix()
    members = [("refmap.json", '{"main":"main.py","assets":"assets"}'),
               ("metainfo.json", '{"id":"victim","name":"Victim"}'), ("main.py", LATE_ENTRY),
               (cache_name, cached_bytecode(LATE_ENTRY)), ("lazy.py", 'VALUE = "CAPTURED"\n'),
               ("assets/data.txt", "asset")]
    archive = host.plugins / "victim.elyx"
    archive.write_bytes(fixtures().zipped(members))
    runtime.load_json(archive)
    victim = Path(runtime._state.archives.root)
    request = directory / "peer.json"
    request.write_text(json.dumps({"shared": str(host.root), "victim": str(victim)}))
    peer = subprocess.run([sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), "peer", str(request), sys.argv[3]],
                          capture_output=True, text=True, timeout=10)
    assert peer.returncode == 0, peer.stdout + peer.stderr
    assert "OWNED_PEER_OK" in peer.stdout
    record = runtime._state.loader.plugins[host.plugin_id]
    for method in ("lazy_value", "read_forbidden", "network_audit"):
        filename = getattr(record.instance, method).__code__.co_filename
        assert filename == record.module.__file__ and runtime._state.loader._resolve_owner(filename) == host.plugin_id
    handle = bridge.xt_register_handle(record.instance)
    assert json.loads(runtime.invoke_handle_json(handle, "lazy_value", "[]")) == "CAPTURED"
    forbidden = directory / "foreign.txt"
    forbidden.write_text("not granted")
    fixtures().raises(PermissionError, lambda: runtime.invoke_handle_json(handle, "read_forbidden", json.dumps([str(forbidden)])), "files")
    import socket
    fixtures().raises((PermissionError, socket.gaierror), lambda: runtime.invoke_handle_json(handle, "network_audit", "[]"), "network")
    runtime.unload()
    assert not victim.exists() and not bridge.xt_handle_count()


def worker(case, directory, packages):
    assert sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode
    sys.path[:0] = [str(ROOT / "python"), packages]
    if case == "peer":
        request = json.loads(Path(directory).read_text())
        shared = Path(request["shared"])
        audit_writer(shared / "writer-bootstrap", Path(request["victim"]), shared=shared)
        print("OWNED_PEER_OK")
        return
    globals()["case_" + case](Path(directory))
    print("ELYX_P1_OK " + case)


if __name__ == "__main__":
    worker(*sys.argv[1:4])
else:
    import pytest

    @pytest.mark.parametrize("case", CASES)
    def test_elyx_p1(case, tmp_path):
        if case in POSIX and os.name != "posix":
            pytest.skip("requires real POSIX dir_fd/openat; no Windows fallback")
        yaml = importlib.util.find_spec("yaml")
        assert yaml is not None
        packages = str(Path(yaml.origin).parent.parent)
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), case, str(tmp_path), packages],
                                cwd=tmp_path, text=True, encoding="utf-8", errors="replace", capture_output=True, timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "ELYX_P1_OK " + case in result.stdout
