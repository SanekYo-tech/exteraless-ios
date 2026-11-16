"""OWNED ZIP fixtures only; each SDK/adapter child has a hard 20-second limit.

Native services are strict test doubles. SDK lifecycle, parsing, namespace,
assets, settings and filesystem operations are real. No corpus or HTTP access.
--emit-fixtures DIR writes these same tiny inputs for the native Mac handoff.
"""

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
from types import SimpleNamespace
import warnings
import zipfile
import zlib


ROOT = Path(__file__).resolve().parents[3]
CASES = ("metadata", "literal_lifecycle", "yaml_lifecycle", "source_signature", "reload_wheels",
         "providers", "paths", "budgets", "ids", "owner_cleanup", "symlink_cache", "failure_cleanup", "bytecode_owner")

ENTRY = '''from base_plugin import BasePlugin
from elyx import assets, metainfo, refmap, settings, strings
import helpers
import values
import flags
import note
import ownlib
class ArchiveProbe(BasePlugin):
    def on_plugin_load(self):
        self.set_setting("loads", self.get_setting("loads", 0) + 1)
        self.set_setting("seen", [helpers.VALUE, ownlib.VALUE, values.flag, values.optional,
            flags.number, note.content, strings.title, assets["hello.txt"].content_string(), metainfo["id"]])
        settings.set("elyx_setting", [True, None, 7])
        self.asset = assets["hello.txt"]
        if self.get_setting("fail_load", False): raise RuntimeError("owned load failure")
        if self.get_setting("exit_load", False): raise SystemExit(7)
    def on_plugin_unload(self):
        self.set_setting("unloads", self.get_setting("unloads", 0) + 1)
        if self.get_setting("fail_unload", False): raise RuntimeError("owned unload failure")
    def create_settings(self):
        from ui.settings import Header, Switch
        return [Header(text="Archive"), Switch(key="toggle", text="Toggle", default=True)]
    def on_app_event(self, event_type):
        self.set_setting("event", str(event_type))
'''


def zipped(entries, compression=zipfile.ZIP_DEFLATED):
    output = io.BytesIO()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)  # deliberately malformed duplicate fixtures
        with zipfile.ZipFile(output, "w", compression=compression) as archive:
            for name, data in entries:
                info = name if isinstance(name, zipfile.ZipInfo) else zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
                if isinstance(name, str): info.filename = name  # retain bad backslashes on Windows
                info.compress_type = compression
                archive.writestr(info, data)
    return output.getvalue()


def wheel(value="first", extra=(), requirements=(), native=False):
    return zipped([
        ("ownlib/__init__.py", "VALUE = " + repr(value) + "\n"),
        ("ownlib-1.0.dist-info/WHEEL", "Wheel-Version: 1.0\nRoot-Is-Purelib: " + ("false" if native else "true")
            + "\nTag: " + ("cp312-cp312-linux_aarch64" if native else "py3-none-any") + "\n"),
        ("ownlib-1.0.dist-info/METADATA", "Metadata-Version: 2.1\nName: ownlib\nVersion: 1.0\n"
            + "".join("Requires-Dist: " + item + "\n" for item in requirements)),
        *extra,
    ])


def entries(plugin_id="7_archive", *, value="first", metadata_kind="json", metadata=None, wheel_data=None, entry=ENTRY, main="entry/main.py"):
    meta = {"id": plugin_id, "name": "Owned archive", "version": "1.0", "description": "{title}", "permissions": []}
    meta.update(metadata or {})
    if metadata_kind == "py":
        meta_data = "\n".join(key + " = " + repr(value) for key, value in meta.items()) + "\n"
        locale_name, locale_data = "locales/ui_en.py", 'title = "Owned title"\nvalues = (True, None, {"number": 3})\n'
    elif metadata_kind == "yaml":
        import yaml
        meta_data = yaml.safe_dump(meta)
        locale_name, locale_data = "locales/ui_en.yml", 'title: "Owned title"\n'
    else:
        meta_data = json.dumps(meta)
        locale_name, locale_data = "locales/ui_en.json", '{"title":"Owned title"}'
    mapping = {"main": main, "metainfo": "meta/info." + metadata_kind,
               "strings": "locales", "assets": "assets", "wheels": "wheels"}
    return [("refmap.json", json.dumps(mapping)), (mapping["metainfo"], meta_data),
            (mapping["main"], entry), ("entry/helpers.py", "VALUE = " + repr(value) + "\n"),
            ("values.json", '{"flag":true,"optional":null}'), ("flags.yaml", "number: 42\n"),
            ("note.txt", "plain text"), (locale_name, locale_data), ("assets/hello.txt", "asset text"),
            ("wheels/ownlib-1.0-py3-none-any.whl", wheel_data if wheel_data is not None else wheel(value))]


def write(path, **kwargs):
    path.write_bytes(zipped(entries(**kwargs)))
    return str(path)


def raises(kind, operation, contains=None):
    try:
        operation()
    except kind as error:
        if contains: assert contains in str(error), str(error)
        return error
    raise AssertionError(f"did not raise {kind}")


def bootstrap(directory, plugin_id="7_archive", plugin_format="elyx", provider=None):
    directory = directory.resolve()  # same canonical path contract as native storage
    spec = importlib.util.spec_from_file_location("_ios_runtime_fixture_support", Path(__file__).with_name("test_ios_runtime.py"))
    support = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(support)
    runtime, host, bridge = support.bootstrap(directory, plugin_id, configure=False, dependency_provider=provider)
    original = host.call

    def call(request):
        request = dict(request)
        token = request.pop("ownerToken", None)
        assert token in (None, host.owner_token)
        if request["op"] == "member_kind": return "unknown"
        return original(request)

    host.call = call
    host.permissions = {"ui"}
    runtime.configure(plugin_id, host.plugins, host.settings, plugin_format=plugin_format)
    runtime.bind_owner_json(json.dumps("owned-archive-native-token"))
    return runtime, host, bridge


def case_metadata(directory):
    import exteraless_runtime as runtime
    from exteraless_runtime import _archives as archives
    path = directory / "inspect.elyx"
    meta = json.loads(runtime.metadata_json(write(path)))
    assert meta["id"] == "7_archive" and meta["description"] == "Owned title"
    assert meta["permissions_declared"] is True and meta["permissions"] == []
    assert "extera_utils.plugin_loader" not in sys.modules and "_exteraless_bridge" not in sys.modules
    assert not any(name.startswith("ElyxPlugins") for name in sys.modules)
    assert list(directory.iterdir()) == [path]
    import elyx_runtime
    assert elyx_runtime.read_metadata(path) == meta
    marker = directory / "must-not-exist"
    for target in ("meta/info.py", "locales/ui_en.py"):
        values = entries(metadata_kind="py")
        values = [(name, content + f'\nopen({str(marker)!r}, "w").write("executed")\n' if name == target else content) for name, content in values]
        path.write_bytes(zipped(values))
        raises(runtime.UnsupportedSurfaceError, lambda: runtime.metadata_json(path), "non-literal Python metadata/localization")
        assert not marker.exists()
    path.write_bytes(zipped(entries(metadata={"requires": {"_lib (2.1)": "https://example.invalid/never-fetch.eaf", "99": None}})))
    meta = json.loads(runtime.metadata_json(path))
    assert meta["requires"] == {"_lib": {"min_version": "2.1", "url": "https://example.invalid/never-fetch.eaf"},
                                "99": {"min_version": None, "url": None}}
    bad = directory / "source.plugin"
    bad.write_text('__id__ = "source_probe"\n__name__ = "Static"\nraise RuntimeError("must not run")\n', encoding="utf-8")
    assert json.loads(runtime.metadata_json(bad))["id"] == "source_probe"
    assert "source_probe" not in sys.modules
    for data in (b"a: &a [*a]\n", b"a: 1\na: 2\n", b"a: !!python/object/apply:os.system ['must-not-run']\n"):
        raises(Exception, lambda: archives.parse_mapping_file("meta.yaml", data))
    raises(archives.ArchiveValidationError, lambda: archives.parse_mapping_file("meta.json", b'{"a":1,"a":2}'), "duplicate")


def lifecycle(directory, metadata_kind):
    runtime, host, bridge = bootstrap(directory, "_archive", "eaf")
    path = write(host.plugins / "same-name.eaf", plugin_id=host.plugin_id, metadata_kind=metadata_kind)
    loaded = json.loads(runtime.load_json(path))
    import elyx_runtime
    from extera_utils import plugin_loader as loader
    state = elyx_runtime.get_state(host.plugin_id)
    record = loader.plugins[host.plugin_id]
    assert loaded["metadata"]["id"] == host.plugin_id and loaded["has_settings"] is True
    assert loaded["handles"]["app_event"] is True
    assert record.module.__name__ == f"ElyxPlugins.{host.plugin_id}.entry.main"
    assert Path(state.extract_dir).is_relative_to(host.cache)
    assert state.digest in state.extract_dir
    assert host.value("seen") == ["first", "first", True, None, 42, "plain text", "Owned title", "asset text", host.plugin_id]
    assert host.value("elyx_setting") == [True, None, 7]
    import file_utils
    with loader.plugin_context(host.plugin_id):
        assert Path(file_utils.get_plugin_dir()) == host.files
        assert not file_utils._is_own_path(host.plugin_id, host.plugins / ".data" / host.plugin_id / "legacy-alias")
    assert loader._resolve_owner(record.module.__file__) == host.plugin_id
    rows = json.loads(runtime.settings_json())
    assert [row["type"] for row in rows] == ["header", "switch"]
    runtime.setting_changed_json("toggle", "false")
    assert host.value("toggle") is False
    runtime.dispatch_json("on_app_event", '{"event_type":"app_pause"}')
    assert host.value("event") == "PAUSE"
    root = Path(state.extract_dir).parent
    runtime.unload()
    assert host.value("unloads") == 1 and not root.exists()
    assert not loader.plugins and not loader._owner_files and not bridge.xt_handle_count()
    assert elyx_runtime.get_state(host.plugin_id) is None
    assert not any(name == host.plugin_id or name.startswith(f"ElyxPlugins.{host.plugin_id}") for name in sys.modules)
    runtime.unload()
    assert host.value("unloads") == 1


def case_literal_lifecycle(directory):
    lifecycle(directory, "py")


def case_yaml_lifecycle(directory):
    lifecycle(directory, "yaml")


def case_source_signature(directory):
    import inspect
    runtime, host, bridge = bootstrap(directory, "source_probe", "source")
    path = host.plugins / "source.plugin"
    path.write_text('__id__ = "source_probe"\n__name__ = "Source"\nfrom base_plugin import BasePlugin\n'
                    'class Probe(BasePlugin):\n    def on_plugin_load(self): self.set_setting("source", True)\n', encoding="utf-8")
    runtime.load_json(path)
    assert host.value("source") is True
    runtime.unload()
    from extera_utils import plugin_loader as loader
    original_load = loader.load_plugin
    path = write(host.plugins / "upper.ELYX", plugin_id=host.plugin_id)
    runtime.load_json(path)
    assert host.value("loads") == 1
    assert loader.load_plugin is original_load
    assert list(inspect.signature(loader.load_plugin).parameters) == ["path", "plugin_id"]
    assert Path(loader.load_plugin.__code__.co_filename) == ROOT / "python/sdk/extera_utils/plugin_loader.py"
    original_elyx = runtime._state.archives.original_load
    assert list(inspect.signature(original_elyx).parameters) == ["record", "path"]
    assert Path(original_elyx.__code__.co_filename) == ROOT / "python/sdk/elyx_runtime/loader.py"
    runtime.unload()
    assert not bridge.xt_handle_count()


def case_reload_wheels(directory):
    runtime, host, _ = bootstrap(directory)
    path = host.plugins / "same-name.elyx"
    write(path)
    stamp = path.stat()
    runtime.load_json(path)
    import elyx_runtime
    from extera_utils import plugin_loader as loader
    old = elyx_runtime.get_state(host.plugin_id)
    old_module = loader.plugins[host.plugin_id].module
    # A completion marker and modified extraction cannot influence the next load.
    Path(old.extract_dir, ".elyx_complete").write_text(old.digest)
    Path(old.wheel_dirs[0], "ownlib/__init__.py").write_text('VALUE = "stale"\n')
    write(path, value="later")
    os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
    runtime.load_json(path)
    fresh = elyx_runtime.get_state(host.plugin_id)
    assert fresh.digest != old.digest and fresh.extract_dir != old.extract_dir
    assert fresh.wheel_dirs != old.wheel_dirs and not Path(old.extract_dir).exists()
    assert loader.plugins[host.plugin_id].module is not old_module
    assert host.value("seen")[:2] == ["later", "later"]
    assert host.value("loads") == 2 and host.value("unloads") == 1
    # Same file/wheel name changing to a native payload must be re-validated.
    write(path, wheel_data=wheel(native=True))
    raises(runtime.UnsupportedSurfaceError, lambda: runtime.load_json(path), "pure-Python")
    assert elyx_runtime.get_state(host.plugin_id) is fresh
    runtime.unload()
    assert not Path(fresh.extract_dir).exists()


def case_providers(directory):
    from email.message import Message
    from exteraless_runtime import _dependencies
    meta = Message()
    meta["Name"], meta["Requires-Python"] = "cachetools", ">=3.11"
    provider = _dependencies.ProvidedDependencies({"cachetools": SimpleNamespace(version="8.0.0", metadata=meta, requires=[])})
    runtime, host, bridge = bootstrap(directory, provider=provider)
    path = host.plugins / "provided.elyx"
    write(path, metadata={"requirements": ["cachetools>=8"]}, wheel_data=wheel(requirements=["cachetools>=8"]))
    runtime.load_json(path)
    assert host.value("loads") == 1
    runtime.unload()
    for requirements, reason in [(["cachetools<8"], "provided cachetools==8.0.0"), (["missing_owned_fixture>=1"], "missing provided"),
                                  (["cachetools @ https://example.invalid/no.whl"], "URL requirement")]:
        write(path, metadata={"requirements": requirements})
        raises(runtime.PluginLoadError, lambda: runtime.load_json(path), reason)
        assert host.value("loads") == 1
    write(path, wheel_data=wheel(requirements=["missing_owned_fixture"]))
    raises(runtime.PluginLoadError, lambda: runtime.load_json(path), "missing provided")
    neighbour = host.plugins / "neighbour.py"
    neighbour.write_text('raise RuntimeError("NEIGHBOUR WAS EXECUTED")\n')
    write(path, metadata={"requires": {"neighbour(2)": "https://example.invalid/no.elyx"}})
    raises(runtime.PluginLoadError, lambda: runtime.load_json(path), "cross-owner module provider")
    write(path, entry="import neighbour\n" + ENTRY)
    raises(runtime.PluginLoadError, lambda: runtime.load_json(path), "cross-plugin import 'neighbour'")
    assert "neighbour" not in sys.modules and not bridge.xt_handle_count()
    assert not runtime._state.loader.plugins and host.value("loads") == 1
    assert not list(host.cache.glob("elyx/*/*"))
    runtime.unload()


def case_paths(directory):
    import exteraless_runtime as runtime
    from exteraless_runtime import _archives as archives
    path = directory / "bad.elyx"
    bad_sets = [[(name, b"x")] for name in ("../out", "/absolute", "C:/drive", "a\\b", "a/./b", "a//b", "nul.txt", "a:stream", "a./b")]
    bad_sets += [[("dup", b"a"), ("dup", b"b")], [("Dir/a", b"a"), ("dir/b", b"b")],
                 [("caf\u00e9", b"a"), ("cafe\u0301", b"b")], [("a", b"x"), ("a/b", b"y")]]
    link = zipfile.ZipInfo("link")
    link.create_system, link.external_attr = 3, (stat.S_IFLNK | 0o777) << 16
    bad_sets.append([(link, b"../out")])
    for bad in bad_sets:
        path.write_bytes(zipped(entries() + bad))
        raises(archives.ArchiveValidationError, lambda: runtime.metadata_json(path))
        assert list(directory.iterdir()) == [path]
    for extra in ([('native.so', b"plain")], [('asset.bin', b"\x7fELFnever loaded")]):
        path.write_bytes(zipped(entries() + extra))
        raises(runtime.UnsupportedSurfaceError, lambda: runtime.metadata_json(path), "native")
    path.write_bytes(zipped(entries(wheel_data=wheel(extra=[("../out", b"bad")]))))
    raises(archives.ArchiveValidationError, lambda: runtime.metadata_json(path), "unsafe")
    bad = entries()
    bad[0] = ("refmap.json", '{"main":"../main.py","metainfo":"meta/info.json"}')
    path.write_bytes(zipped(bad))
    raises(archives.ArchiveValidationError, lambda: runtime.metadata_json(path), "unsafe")
    path.write_text("not zip")
    raises(archives.ArchiveValidationError, lambda: runtime.metadata_json(path), "ZIP signature")
    # A lying central size plus a matching prefix CRC must not hide expansion;
    # ZipExtFile alone truncates its output to the advertised file_size.
    data = bytearray(zipped([("body.txt", b"ab")]))
    central = data.index(b"PK\x01\x02")
    struct.pack_into("<L", data, central + 24, 1)
    struct.pack_into("<L", data, central + 16, zlib.crc32(b"a"))
    path.write_bytes(data)
    raises(archives.ArchiveValidationError, lambda: runtime.metadata_json(path), "expanded size")
    data = bytearray(zipped([("body.txt", b"correct crc")]))
    central = data.index(b"PK\x01\x02")
    struct.pack_into("<L", data, central + 16, 0)
    path.write_bytes(data)
    raises(archives.ArchiveValidationError, lambda: runtime.metadata_json(path), "CRC")


def case_budgets(directory):
    import exteraless_runtime as runtime
    from exteraless_runtime import _archives as archives
    path = directory / "budget.elyx"
    data = zipped(entries())
    for key, value, reason in [("MAX_ARCHIVE_BYTES", len(data) - 1, "byte"), ("MAX_FILE_BYTES", 24, "per-file"),
                               ("MAX_TOTAL_BYTES", 32, "total"), ("MAX_ENTRIES", 2, "entry count"),
                               ("MAX_MAPPING_BYTES", 12, "byte"), ("MAX_MAPPING_TOTAL_BYTES", 50, "aggregate")]:
        path.write_bytes(data)
        previous = getattr(archives, key)
        setattr(archives, key, value)
        try: raises(archives.ArchiveValidationError, lambda: runtime.metadata_json(path), reason)
        finally: setattr(archives, key, previous)
    path.write_bytes(zipped(entries() + [("bomb.txt", b"0" * 100000)]))
    raises(archives.ArchiveValidationError, lambda: runtime.metadata_json(path), "compression ratio")
    # The aggregate expanded budget includes the nested wheel, not only its ZIP bytes.
    data = zipped(entries(wheel_data=wheel(extra=[("padding.txt", os.urandom(4000))])))
    path.write_bytes(data)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        total = sum(info.file_size for info in archive.infolist())
    previous = archives.MAX_TOTAL_BYTES
    archives.MAX_TOTAL_BYTES = total + 10
    try: raises(archives.ArchiveValidationError, lambda: runtime.metadata_json(path), "total expanded")
    finally: archives.MAX_TOTAL_BYTES = previous
    data = bytearray(data)
    end = data.rfind(b"PK\x05\x06")
    struct.pack_into("<2H", data, end + 8, 1, 1)
    path.write_bytes(data)
    raises(archives.ArchiveValidationError, lambda: runtime.metadata_json(path), "entry count")
    raises(archives.ArchiveValidationError, lambda: archives.parse_mapping_file("meta.json", b"[" * 40 + b"0" + b"]" * 40), "depth")
    # A tiny description can multiply a bounded locale value many times. This
    # must fail while resolving placeholders, before allocating the expansion.
    values = entries(metadata={"description": "{title}" * 8})
    locale = json.dumps({"title": os.urandom(80000).hex()})
    values = [(name, locale if name == "locales/ui_en.json" else content) for name, content in values]
    path.write_bytes(zipped(values))
    raises(archives.ArchiveValidationError, lambda: runtime.metadata_json(path), "placeholder expansion")
    assert list(directory.iterdir()) == [path]


def case_ids(directory):
    import exteraless_runtime as runtime
    from exteraless_runtime import _archives as archives
    path = directory / "ids.eaf"
    for plugin_id in ("12", "_p", "__", "os", "a" * 32, "Case", "case"):
        assert json.loads(runtime.metadata_json(write(path, plugin_id=plugin_id)))["id"] == plugin_id
        assert archives.validate_plugin_id(plugin_id, "eaf") == plugin_id
    for plugin_id in ("a", "a" * 33, "a-b", "../a", "éé", "a.b"):
        raises(Exception, lambda: runtime.metadata_json(write(path, plugin_id=plugin_id)))
    for plugin_id in ("exteralessMetadataInspector", "EXTERALESSMETADATAINSPECTOR"):
        raises(runtime.UnsupportedSurfaceError, lambda: runtime.metadata_json(write(path, plugin_id=plugin_id)), "reserved")
    runtime, host, _ = bootstrap(directory / "stdlib-owner", "os", "eaf")
    runtime.load_json(write(host.plugins / "stdlib.eaf", plugin_id="os"))
    assert sys.modules["os"] is os and host.value("seen")[-1] == "os"
    runtime.unload()


def case_owner_cleanup(directory):
    runtime, host, _ = bootstrap(directory)
    runtime.load_json(write(host.plugins / "owned.elyx"))
    adapter = runtime._state.archives
    old_root = Path(adapter.root)
    other_owner = hashlib.sha256((host.plugin_id + "\0replacement-native-token").encode()).hexdigest()
    replacement = host.cache / "elyx" / other_owner / (adapter.snapshot.digest + "-replacement")
    replacement.mkdir(parents=True)
    marker = replacement / "keep.txt"
    marker.write_text("replacement archive resource")
    runtime.unload()
    assert not old_root.exists() and marker.read_text() == "replacement archive resource"
    adapter._purge(str(host.plugins), host.plugin_id)  # delayed old SDK purge is owner-local/idempotent
    assert marker.exists()
    raises(runtime.RuntimeStateError, lambda: adapter._purge(str(host.plugins), "foreign"), "belongs")


def case_symlink_cache(directory):
    runtime, host, _ = bootstrap(directory)
    path = write(host.plugins / "owned.elyx")
    outside = directory / "outside"
    outside.mkdir()
    target = host.cache / "elyx"
    try:
        os.symlink(outside, target, target_is_directory=True)
    except OSError as error:
        if os.name != "nt" or getattr(error, "winerror", None) not in (50, 1314): raise
        print("ELYX_SYMLINK_FIXTURE_UNAVAILABLE " + str(error))
        return
    raises(runtime.PluginLoadError, lambda: runtime.load_json(path), "symbolic link")
    assert list(outside.iterdir()) == []
    target.unlink()
    runtime.load_json(path)
    # A member symlink inserted after load is unlinked, not followed, at teardown.
    os.symlink(outside, Path(runtime._state.archives.root) / "outside-link", target_is_directory=True)
    (outside / "keep").write_text("keep")
    runtime.unload()
    assert (outside / "keep").read_text() == "keep"


def case_failure_cleanup(directory):
    runtime, host, bridge = bootstrap(directory)
    path = write(host.plugins / "failure.elyx")
    from extera_utils import plugin_loader as loader
    import elyx_runtime
    for key, expected in (("fail_load", runtime.PluginLoadError), ("exit_load", SystemExit)):
        host.seed(key, True)
        raises(expected, lambda: runtime.load_json(path))
        assert not loader.plugins and not loader._owner_files and not bridge.xt_handle_count()
        assert elyx_runtime.get_state(host.plugin_id) is None
        assert not list(host.cache.glob("elyx/*/*"))
        host.seed(key, False)
    runtime.load_json(path)
    root = Path(runtime._state.archives.root)
    host.seed("fail_unload", True)
    raises(RuntimeError, runtime.unload, "owned unload failure")
    assert not root.exists() and not loader.plugins and not loader._owner_files
    assert not bridge.xt_handle_count()


def case_bytecode_owner(directory):
    from importlib._bootstrap_external import _code_to_timestamp_pyc
    runtime, host, _ = bootstrap(directory)
    code = compile(ENTRY, "unowned-build-machine/main.py", "exec")
    data = bytes(_code_to_timestamp_pyc(code, 0, len(ENTRY)))
    path = write(host.plugins / "bytecode.elyx", entry=data, main="entry/main.pyc")
    runtime.load_json(path)
    record = runtime._state.loader.plugins[host.plugin_id]
    assert record.instance.on_plugin_load.__code__.co_filename == record.module.__file__
    assert runtime._state.loader._resolve_owner(record.instance.on_plugin_load.__code__.co_filename) == host.plugin_id
    assert host.value("seen")[0] == "first"
    runtime.unload()
    invalid = b"bad!" + data[4:]
    path = write(host.plugins / "wrong-version.elyx", entry=invalid, main="entry/main.pyc")
    raises(runtime.UnsupportedSurfaceError, lambda: runtime.metadata_json(path), "match this CPython")


def worker(case, directory, packages):
    assert sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode
    sys.path[:0] = [str(ROOT / "python"), packages]
    counts = {}
    sdk = ROOT / "python/sdk"

    def profile(frame, event, _):
        if event == "call" and frame.f_code.co_name in {"load_plugin", "_load_elyx_plugin", "load_plugin_record", "_teardown"}:
            filename = Path(frame.f_code.co_filename)
            if filename.is_relative_to(sdk):
                name = str(filename.relative_to(sdk)) + ":" + frame.f_code.co_name
                counts[name] = counts.get(name, 0) + 1

    sys.setprofile(profile)
    try: globals()["case_" + case](Path(directory))
    finally: sys.setprofile(None)
    print("IOS_ELYX_ARCHIVE_OK " + json.dumps({"case": case, "sdk_executed": counts}, sort_keys=True))


def emit_fixtures(directory):
    directory.mkdir(parents=True, exist_ok=True)
    if any(directory.iterdir()):
        raise ValueError("owned fixture output directory must be empty")
    for name, options in [("owned.elyx", {}), ("owned-next.elyx", {"value": "later", "metadata": {"version": "2.0"}}),
                          ("literal.eaf", {"plugin_id": "_archive", "metadata_kind": "py"}),
                          ("requires.elyx", {"metadata": {"requires": {"neighbour(2)": "https://example.invalid/no.elyx"}}})]:
        write(directory / name, **options)
    (directory / "source.plugin").write_text('__id__ = "source_probe"\n__name__ = "Source"\nfrom base_plugin import BasePlugin\nclass Probe(BasePlugin): pass\n')
    print(json.dumps({path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(directory.iterdir())}, sort_keys=True))


if __name__ == "__main__":
    if sys.argv[1] == "--emit-fixtures": emit_fixtures(Path(sys.argv[2]))
    else: worker(sys.argv[1], sys.argv[2], sys.argv[3])
elif __name__ != "_elyx_fixture_support":
    import pytest

    @pytest.mark.parametrize("case", CASES)
    def test_ios_elyx_archive(case, tmp_path):
        if os.name != "posix" and case not in ("metadata", "paths", "budgets"):
            pytest.skip("positive archive lifecycle needs the real POSIX directory-FD backend")
        yaml = importlib.util.find_spec("yaml")
        assert yaml is not None, "these owned unit fixtures use the host's pre-existing PyYAML"
        packages = str(Path(yaml.origin).parent.parent)
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), case, str(tmp_path), packages],
                                cwd=tmp_path, text=True, encoding="utf-8", errors="replace", capture_output=True, timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
        unavailable = next((line for line in result.stdout.splitlines() if line.startswith("ELYX_SYMLINK_FIXTURE_UNAVAILABLE ")), None)
        if unavailable: pytest.skip(unavailable)
        summary = next((line for line in result.stdout.splitlines() if line.startswith("IOS_ELYX_ARCHIVE_OK ")), None)
        assert summary is not None, result.stdout
        print(summary)
