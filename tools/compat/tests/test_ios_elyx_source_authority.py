"""Bounded interoperability tests for the native-source descriptor ABI.

The registry below is an explicit FD-backed contract recorder, NOT production
native authorization. The production hooks require the new built-in C gate and
the native developer owner's registered authority. No raw-fd JSON is accepted.
"""

import base64
from contextlib import contextmanager
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
CASES = ("static_fd", "malformed", "native_refusal", "manifest", "verified_context", "namespace_replace", "verified_sdk")


def fixture_support():
    spec = importlib.util.spec_from_file_location("_elyx_fixture_support", Path(__file__).with_name("test_ios_elyx_archives.py"))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


class IssuerRecorder:
    """Owned read-only fd plus strict simulated native issuance/version checks."""
    def __init__(self, path, *, purpose="inspect", owner=None):
        from exteraless_runtime._archives import SOURCE_ABI
        self.path = path
        self.file = path.open("rb")
        self.namespace = self.stamp(path.parent.stat())[:2]
        self.original = self.file.read()
        self.file.seek(0)
        self.initial = self.stamp(os.fstat(self.file.fileno()))
        self.named_initial = self.stamp(path.stat())
        assert self.initial[:3] == self.named_initial[:3]
        self.descriptor = {"abi": SOURCE_ABI, "schema": 1, "capability": "1" * 64, "purpose": purpose,
            "plugin_id": "7_archive", "owner_token": owner, "format": "elyx", "byte_length": len(self.original),
            "source_sha256": hashlib.sha256(self.original).hexdigest(), "source_namespace": "2" * 64, "source_nonce": "3" * 64}
        self.ticket = "4" * 64
        self.claimed = self.released = False
        self.calls = []
        self.before_read = None

    @staticmethod
    def stamp(value):
        return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns

    def current(self):
        opened, named, parent = self.stamp(os.fstat(self.file.fileno())), self.stamp(self.path.stat()), self.stamp(self.path.parent.stat())[:2]
        if opened != self.initial or named != self.named_initial or parent != self.namespace:
            raise RuntimeError(f"native source namespace/version retired: {self.initial!r} / {opened!r} / {self.named_initial!r} / {named!r}")

    def gate(self, operation, payload_json):
        from exteraless_runtime._archives import SOURCE_ABI
        assert len(payload_json.encode()) <= 4096
        payload = json.loads(payload_json)
        self.calls.append(operation)
        if operation == "release":
            assert payload == {"abi": SOURCE_ABI, "read_id": self.ticket}
            before = not self.released
            self.released = True
            return {"released": before}
        self.current()
        if operation in ("claim", "manifest"):
            if self.claimed: raise RuntimeError("native capability already claimed")
            if operation == "claim" and payload != self.descriptor: raise RuntimeError("native capability not issued")
            if operation == "manifest" and payload != {"abi": SOURCE_ABI, "expected_source_sha256": self.descriptor["source_sha256"]}:
                raise RuntimeError("native source digest differs")
            self.claimed = True
            return {"abi": SOURCE_ABI, "read_id": self.ticket, "descriptor": dict(self.descriptor), "read_only": True, "load_reader_abi": 1}
        assert self.claimed and not self.released and payload["read_id"] == self.ticket
        if operation == "check":
            return {"read_id": self.ticket, "descriptor": dict(self.descriptor), "current": True}
        assert operation == "read"
        if self.before_read: self.before_read()
        self.current()
        assert 0 < payload["count"] <= 65536
        self.file.seek(payload["offset"])
        data = self.file.read(payload["count"])
        self.current()
        return {"offset": payload["offset"], "data_base64": base64.b64encode(data).decode()}

    def close(self):
        self.file.close()


@contextmanager
def issuer(directory, *, purpose="inspect", owner=None, metadata_kind="json"):
    support = fixture_support()
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / (purpose + ".elyx")
    support.write(path, metadata_kind=metadata_kind)
    value = IssuerRecorder(path, purpose=purpose, owner=owner)
    try:
        yield value
    finally:
        value.close()


def fake_platform(owner="native-owner", gate=None):
    from exteraless_runtime import _archives
    def check_id(value):
        if value != "7_archive": raise RuntimeError("different owner")
    platform = SimpleNamespace(plugin_id="7_archive", plugin_format="elyx", owner_token=owner,
        plugins_dir="unused", callbacks=SimpleNamespace(active=False), loader=SimpleNamespace(is_loaded=lambda _: False),
        check_worker=lambda: None, check_plugin=check_id)
    platform.archives = _archives.ArchiveAdapter(platform)
    platform.archives.source_gate = gate  # explicitly injected contract recorder
    return platform


def case_static_fd(directory):
    from exteraless_runtime import _archives, _elyx_developer
    with issuer(directory, metadata_kind="py") as native:
        before = {path.name: path.read_bytes() for path in directory.iterdir() if path.is_file()}
        with patch.object(_archives, "_native_source_gate", lambda: native.gate):
            metadata = json.loads(_elyx_developer.inspect_fd_json(json.dumps(native.descriptor)))
        assert metadata["id"] == "7_archive" and metadata["description"] == "Owned title"
        assert native.released and "read" in native.calls
        assert {path.name: path.read_bytes() for path in directory.iterdir() if path.is_file()} == before
        assert not any(name.startswith("ElyxPlugins.") for name in sys.modules)
        assert "extera_utils.plugin_loader" not in sys.modules
    # A Python mapping with a side effect is still rejected on the FD branch.
    support = fixture_support()
    bad = directory / "bad.elyx"
    members = support.entries(metadata_kind="py")
    members = [(name, body + '\nraise RuntimeError("must not execute")\n' if name == "meta/info.py" else body) for name, body in members]
    bad.write_bytes(support.zipped(members))
    native = IssuerRecorder(bad)
    try:
        with patch.object(_archives, "_native_source_gate", lambda: native.gate):
            support.raises(_archives.UnsupportedSurfaceError, lambda: _archives.inspect_developer_descriptor(native.descriptor), "non-literal")
        assert native.released, native.calls
    finally: native.close()


def case_malformed(directory):
    from exteraless_runtime import _archives
    support = fixture_support()
    for value in ({"fd": 1, "path": "ignored"}, {}, {"validated": True}):
        support.raises(_archives.ArchiveValidationError, lambda: _archives.inspect_developer_descriptor(value), "bare fd/path")
    with issuer(directory) as native:
        for key, value in (("byte_length", True), ("byte_length", 2 ** 32), ("schema", True),
                           ("source_nonce", "guessed"), ("owner_token", "wrong-inspector-owner")):
            descriptor = dict(native.descriptor, **{key: value})
            support.raises(Exception, lambda: _archives.inspect_developer_descriptor(descriptor))
        assert not native.calls
        support.raises(_archives.UnsupportedSurfaceError, lambda: _archives.inspect_developer_descriptor(native.descriptor), "C-gated")


def case_native_refusal(directory):
    from exteraless_runtime import _archives
    support = fixture_support()
    with issuer(directory) as native:
        with patch.object(_archives, "_native_source_gate", lambda: native.gate):
            forged = dict(native.descriptor, capability="f" * 64)
            support.raises(RuntimeError, lambda: _archives.inspect_developer_descriptor(forged), "not issued")
            assert not native.claimed
            native.path.write_bytes(native.original + b"changed source version")
            support.raises(RuntimeError, lambda: _archives.inspect_developer_descriptor(native.descriptor), "namespace/version")
    with issuer(directory / "read-race") as native:
        original = native.original
        def change():
            native.path.write_bytes(original + b"changed")
        native.before_read = change
        with patch.object(_archives, "_native_source_gate", lambda: native.gate):
            error = support.raises(RuntimeError, lambda: _archives.inspect_developer_descriptor(native.descriptor), "namespace/version")
        assert native.released, (native.calls, str(error))


def case_namespace_replace(directory):
    from exteraless_runtime import _archives
    with issuer(directory) as native:
        # Same bytes at the same filename are a different namespace/inode. The
        # original read-only fd remains held throughout this actual POSIX swap.
        replacement = directory / "replacement.elyx"
        replacement.write_bytes(native.original)
        os.replace(replacement, native.path)
        with patch.object(_archives, "_native_source_gate", lambda: native.gate):
            fixture_support().raises(RuntimeError, lambda: _archives.inspect_developer_descriptor(native.descriptor), "namespace/version")
        assert not native.claimed


def case_manifest(directory):
    from exteraless_runtime import _archives
    with issuer(directory, purpose="manifest", owner="native-owner") as native:
        platform = fake_platform(gate=native.gate)
        platform.loader.is_loaded = lambda _: True
        platform.archives.image = SimpleNamespace(active=True)
        platform.archives.snapshot = SimpleNamespace(data=b"untrusted cached snapshot")
        platform.archives.root = "does-not-exist-and-must-not-be-walked"
        expected = native.descriptor["source_sha256"]
        manifest = platform.archives.developer_manifest(expected_source_digest=expected)
        import zipfile
        with zipfile.ZipFile(io.BytesIO(native.original)) as zf:
            hashes = {name: hashlib.sha256(zf.read(name)).hexdigest() for name in zf.namelist() if not name.endswith("/")}
        assert manifest == {"source_digest": expected, "files": hashes}
        assert native.released and native.calls[0] == "manifest"


def case_verified_context(directory):
    from exteraless_runtime import _archives
    support = fixture_support()
    with issuer(directory, purpose="load", owner="native-owner") as native:
        platform = fake_platform(gate=native.gate)
        label = str(directory / "not-an-input.elyx")
        with patch.object(_archives, "_read_file", side_effect=AssertionError("verified load reopened a path")):
            with _archives.verified_developer_load(platform, label, native.descriptor):
                snapshot = _archives.snapshot_for_load(platform, label)
                assert snapshot.data == native.original and snapshot.path == label
                support.raises(_archives.RuntimeStateError, lambda: _archives.snapshot_for_load(platform, label), "another load invocation")
        assert native.released and platform.archives.verified_source is None
        support.raises(RuntimeError, lambda: native.gate("claim", json.dumps(native.descriptor)), "already claimed")


def case_verified_sdk(directory):
    from exteraless_runtime import _archives, _elyx_developer
    runtime, host, bridge = fixture_support().bootstrap(directory)
    issued = directory / "issued"
    issued.mkdir()
    with issuer(issued, purpose="load", owner=host.owner_token) as native:
        runtime._state.archives.source_gate = native.gate
        # The installed path label is deliberately absent. Only the issued
        # native descriptor may provide bytes through this exact SDK wrapper.
        path = str(host.plugins / "absent.elyx")
        with patch.object(_archives, "_read_file", side_effect=AssertionError("verified load reopened a path")):
            result = json.loads(_elyx_developer.load_verified_json(path, json.dumps(native.descriptor)))
        assert result["metadata"]["id"] == host.plugin_id and host.value("loads") == 1
        assert native.released and not Path(path).exists()
        runtime.unload()
        assert not bridge.xt_handle_count()


def worker(case, directory, packages):
    assert sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode
    sys.path[:0] = [str(ROOT / "python"), packages]
    globals()["case_" + case](Path(directory))
    print("ELYX_SOURCE_ABI_OK " + case)


if __name__ == "__main__":
    worker(*sys.argv[1:4])
else:
    import pytest

    @pytest.mark.parametrize("case", CASES)
    def test_source_authority(case, tmp_path):
        if case in ("namespace_replace", "verified_sdk") and os.name != "posix":
            pytest.skip("verified SDK execution needs the actual POSIX extraction backend")
        yaml = importlib.util.find_spec("yaml")
        assert yaml is not None
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), case,
                                 str(tmp_path), str(Path(yaml.origin).parent.parent)],
                                cwd=tmp_path, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "ELYX_SOURCE_ABI_OK " + case in result.stdout
