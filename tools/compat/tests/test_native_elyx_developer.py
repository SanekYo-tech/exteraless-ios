"""Owned <=20 s SDK/C-script fixtures for the native Elyx command seam.

The FD-authority interfaces are explicit contract recorders until the archive P1
owner provides them. Tests never implement them using extraction/cache paths.
Native ZIP/Host/protocol fixtures are separate Swift sources (not run on Windows).
"""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def support(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@contextlib.contextmanager
def configured(directory, bridge):
    sys.path.insert(0, str(ROOT / "python"))
    direct = support("_direct_hook_fixture_support", "test_sdk_direct_hooks.py")
    archive = support("_elyx_fixture_support", "test_ios_elyx_archives.py")
    import exteraless_runtime as runtime
    original_configure = runtime.configure

    def archive_configure(plugin_id, plugins_dir, settings_dir, **kwargs):
        return original_configure(plugin_id, plugins_dir, settings_dir, plugin_format="elyx")

    # Reuse the existing real C dispatcher/binding fixture, with the format
    # selected by this owned test. No Java class or SDK helper is reconstructed.
    with patch.object(runtime, "configure", archive_configure):
        with direct.configured(directory, bridge) as (runtime, host, native, raises, evidence):
            from exteraless_runtime import _elyx_developer as helper
            helper.install(runtime._state)  # same two-line coordinator install seam
            path = host.plugins / "owned.elyx"
            archive.write(path, plugin_id=host.plugin_id)
            yield runtime, host, native, raises, helper, path, evidence


def disk(directory):
    return {p.relative_to(directory).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in directory.rglob("*") if p.is_file()}


def script(helper, name, *values):
    # Exact fixed-function/quoted-string form emitted by PluginRuntimeScript.
    source = "_exteraless_runtime._elyx_developer." + name + "(" + ", ".join(json.dumps(v) for v in values) + ")"
    import exteraless_runtime as runtime
    return json.loads(eval(compile(source, "<native-elyx-owned-script>", "eval"), {"_exteraless_runtime": runtime}))


def worker(case, storage, directory, packages, bridge=None):
    assert sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode
    sys.path[:0] = [str(ROOT / "python"), packages]
    root = Path(directory)
    with configured(root, bridge) as (runtime, host, native, raises, helper, path, evidence):
        from exteraless_runtime import _archives, RuntimeStateError, UnsupportedSurfaceError
        # Missing inspection/load source authority must fail BEFORE any load,
        # staging, metadata execution or an accidental path-only fallback.
        with patch.object(_archives, "verified_developer_load", None, create=True):
            raises(UnsupportedSurfaceError, lambda: helper.load_verified_json(str(path), "{}"), "verified_developer_load")
        with patch.object(_archives, "inspect_developer_descriptor", None, create=True):
            before = disk(root)
            raises(UnsupportedSurfaceError, lambda: helper.inspect_fd_json("{}"), "inspect_developer_descriptor")
            raises(ValueError, lambda: helper.inspect_fd_json(" " * 4097), "4096")
            assert disk(root) == before
        if storage == "archive":
            runtime.load_json(str(path))
        else:
            # Read-only protocol model fixture, not archive extraction evidence.
            # Use the real source loader for a finite owner and the actual SDK
            # ElyxPluginState for list/ping. No POSIX gate is mocked or relaxed.
            source = host.plugins / "state-owner.plugin"
            source.write_text("__id__ = " + repr(host.plugin_id) + "\n__name__ = 'Owned read-state fixture'\n"
                "from base_plugin import BasePlugin\nclass Probe(BasePlugin):\n"
                "    def on_plugin_load(self): self.set_setting('loads', 1)\n", encoding="utf-8")
            runtime.load_json(str(source))
            from elyx_runtime.loader import ElyxPluginState, _states
            from elyx_runtime.namespace import PluginNamespace
            display_root = str(root / "nonmaterialized-state")
            _states[host.plugin_id] = ElyxPluginState(host.plugin_id, str(path), str(host.plugins),
                hashlib.sha256(path.read_bytes()).hexdigest(), display_root, [], {},
                {"id": host.plugin_id, "name": "Owned in-memory state", "version": "1.0"},
                PluginNamespace(host.plugin_id, display_root, []), {})
        from elyx_runtime import dev_commands, loader
        import client_utils
        import dev_server

        calls = []

        def profile(frame, event, argument):
            if event == "call" and frame.f_code is dev_commands.handle_dev_command.__code__:
                calls.append((frame.f_locals["command"], dict(frame.f_locals["params"] or {}), client_utils.get_hook_account()))

        sys.setprofile(profile)
        try:
            before = disk(root)
            if case == "read":
                result = script(helper, "read_json", host.plugin_id, runtime._state.owner_token, "3")
                assert result["ok"] is True and result["plugin"]["id"] == host.plugin_id
                assert result["plugin"]["archive_path"] == str(path)
                assert calls == [("elyx_ping", {}, 3), ("get_elyx_plugins", {}, 3)]
                assert not {"token", "ownerToken", "descriptor", "files"}.intersection(result)
                assert script(helper, "ping_json")["elyx"] is True
                raises(RuntimeStateError, lambda: helper.read_json("differentOwnId", runtime._state.owner_token, "3"), "worker belongs")
                raises(RuntimeStateError, lambda: helper.read_json(host.plugin_id, "retired-owner", "3"), "owner epoch")
                for account in ("true", "-1", "2147483648", '"3"'):
                    raises(ValueError, lambda: helper.read_json(host.plugin_id, runtime._state.owner_token, account), "Int32")
            elif case == "manifest":
                image = path.read_bytes()
                digest = hashlib.sha256(image).hexdigest()
                with zipfile.ZipFile(io.BytesIO(image)) as archive:
                    hashes = {name: hashlib.sha256(archive.read(name)).hexdigest() for name in archive.namelist() if not name.endswith("/")}
                with patch.object(runtime._state.archives, "developer_manifest", None, create=True):
                    raises(UnsupportedSurfaceError, lambda: helper.manifest_json(host.plugin_id, runtime._state.owner_token, digest, "3"), "FD/source-byte")
                seen = []

                def manifest(*, expected_source_digest):
                    # CONTRACT RECORDER: immutable OWNED emitted bytes, not the
                    # retired ArchiveAdapter.snapshot or mutable extracted files.
                    assert client_utils.get_hook_account() == 3
                    seen.append(expected_source_digest)
                    if expected_source_digest != digest:
                        raise RuntimeStateError("native source version retired")
                    return {"source_digest": digest, "files": hashes}

                with patch.object(runtime._state.archives, "developer_manifest", manifest, create=True):
                    result = script(helper, "manifest_json", host.plugin_id, runtime._state.owner_token, digest, "3")
                    assert result == {"ok": True, "source_digest": digest, "files": hashes}
                    raises(RuntimeStateError, lambda: helper.manifest_json(host.plugin_id, runtime._state.owner_token, "0" * 64, "3"), "source version retired")
                    assert seen == [digest, "0" * 64]
                for invalid in ({"source_digest": digest, "files": {}, "token": "not-a-credential"},
                                {"source_digest": "0" * 64, "files": hashes},
                                {"source_digest": digest, "files": []}):
                    with patch.object(runtime._state.archives, "developer_manifest", lambda **kw: invalid, create=True):
                        raises(RuntimeStateError, lambda: helper.manifest_json(host.plugin_id, runtime._state.owner_token, digest, "3"), "manifest")
                assert not calls, "manifest does not call Original's unbounded folder walk or mutator"
            else:
                # Direct SDK auth stays outside the handler; neither a correct
                # local token nor guessed descriptor permits native publication.
                dev_server._token = "owned-local-token-not-native-auth"
                request = {"@": "elyx_changes", "#": 7, "plugin_id": host.plugin_id,
                           "changes": [{"#": "modified", "path": "entry/helpers.py", "content": "eD0x"}]}
                wrong = dev_server.dispatch(dict(request, token="wrong"))
                assert wrong["ok"] is False and wrong["error"] == "bad or missing token"
                result = dev_server.dispatch(dict(request, token=dev_server._token))
                assert result["ok"] is False and result["reloaded"] is False
                assert "authenticated native archive transaction" in result["errors"][0]
                raises(RuntimeStateError, lambda: helper.load_verified_json(str(path), "{}"), "local reload is forbidden")
                assert not calls and runtime._state.loader.is_loaded(host.plugin_id)
                assert len(loader._states) == 1 and host.value("loads") == 1
            assert client_utils.get_hook_account() is None
            assert disk(root) == before, "read/refusal wrote source, extraction, settings or staging"
        finally:
            sys.setprofile(None)
            runtime.unload()
            if storage == "state": loader._states.pop(host.plugin_id, None)
        assert native.xt_handle_count() == 0
        print("NATIVE_ELYX_SDK_OK " + json.dumps({"case": case, "storage": storage, **evidence, "writes_during_read_or_refusal": 0,
              "fd_authority": "contract-only; production join pending"}, sort_keys=True))


def emit(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    fixture = support("_elyx_fixture_support", "test_ios_elyx_archives.py")
    source = fixture.zipped([*fixture.entries(), ("obsolete.txt", "remove me")])
    (directory / "owned.elyx").write_bytes(source)
    import base64
    changes = [
        {"#": "modified", "path": "entry/helpers.py", "content": base64.b64encode(b"VALUE = 'native-later'\n").decode()},
        {"#": "modified", "path": "assets/hello.txt", "content": base64.b64encode(b"native resource").decode()},
        {"#": "created", "path": "extra", "is_directory": True},
        {"#": "created", "path": "extra/one.txt", "content": base64.b64encode(b"new resource").decode()},
        {"#": "moved", "path": "extra", "dest_path": "renamed"},
        {"#": "deleted", "path": "obsolete.txt"},
    ]
    command = {"@": "elyx_changes", "plugin_id": "7_archive", "changes": changes}
    (directory / "changes.json").write_text(json.dumps(command), encoding="utf-8")
    # These expected bodies are independent constants; the test does not copy
    # the native change-set implementation into Python.
    expected = {"entry/helpers.py": "VALUE = 'native-later'\n", "assets/hello.txt": "native resource", "renamed/one.txt": "new resource"}
    (directory / "expected.json").write_text(json.dumps(expected), encoding="utf-8")
    print("NATIVE_ELYX_FIXTURES " + json.dumps({"source_sha256": hashlib.sha256(source).hexdigest(), "directory": str(directory)}))


if __name__ == "__main__":
    if sys.argv[1] == "--emit-fixtures": emit(sys.argv[2])
    else: worker(*sys.argv[1:])
else:
    import pytest

    @pytest.mark.parametrize("case", ("read", "manifest", "refuse"))
    @pytest.mark.parametrize("transport", ("unit", "C"))
    @pytest.mark.parametrize("storage", ("state", "archive"))
    def test_native_elyx_sdk_seam(case, transport, storage, tmp_path):
        if storage == "archive" and os.name != "posix":
            pytest.skip("archive execution requires the real POSIX directory-FD/O_NOFOLLOW backend")
        yaml = importlib.util.find_spec("yaml")
        assert yaml is not None, "owned archive fixture requires the existing host PyYAML"
        bridge = os.environ.get("EXTERALESS_ELYX_C_BRIDGE") if transport == "C" else None
        if transport == "C" and not bridge:
            pytest.skip("set EXTERALESS_ELYX_C_BRIDGE to a built current dispatcher/owner ABI")
        command = [sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), case, storage, str(tmp_path), str(Path(yaml.origin).parent.parent)]
        if bridge: command.append(bridge)
        result = subprocess.run(command, cwd=tmp_path, capture_output=True, text=True, encoding="utf-8", timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
        receipt = [line for line in result.stdout.splitlines() if line.startswith("NATIVE_ELYX_SDK_OK ")]
        assert len(receipt) == 1
        print(receipt[0])
