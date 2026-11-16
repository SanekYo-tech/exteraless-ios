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
CASES = ("static_fd", "malformed", "native_refusal", "manifest", "verified_context", "namespace_replace", "verified_sdk",
         "load_policy_requires", "load_policy_python", "load_policy_dependencies")


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


def policy_candidate(path, *, requires=None, python_spec=None, requirements=(), wheel_requirements=(), native_member=False):
    support = fixture_support()
    refmap = {"main": "main.py", "metainfo": "meta.json"}
    metadata = {"id": "7_archive", "name": "Owned load-policy candidate", "requires": requires or {}, "requirements": list(requirements)}
    members = [("main.py", 'raise AssertionError("entry execution is forbidden in policy inspection")\n')]
    if python_spec is not None or wheel_requirements:
        refmap["wheels"] = "wheels"
        wheel_meta = "Metadata-Version: 2.1\nName: own\nVersion: 1.0\n"
        if python_spec is not None:
            wheel_meta += "Requires-Python: " + python_spec + "\n"
        wheel_meta += "".join("Requires-Dist: " + value + "\n" for value in wheel_requirements)
        members.append(("wheels/own-1.0-py3-none-any.whl", support.zipped([
            ("own/__init__.py", 'raise AssertionError("wheel modules must not be imported by preflight")\n'),
            ("own-1.0.dist-info/WHEEL", "Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n"),
            ("own-1.0.dist-info/METADATA", wheel_meta),
        ])))
    if native_member:
        members.append(("library.so", b"owned rejection control"))
    path.write_bytes(support.zipped([("refmap.json", json.dumps(refmap)), ("meta.json", json.dumps(metadata)), *members]))


def policy_roundtrip(directory, *, expected_error=None, provider=None, **candidate):
    import exteraless_runtime as runtime
    from exteraless_runtime import _archives, _dependencies, _elyx_developer
    support = fixture_support()
    directory.mkdir(parents=True)
    path = directory / "candidate.elyx"
    policy_candidate(path, **candidate)
    assert path.stat().st_size < 4096, "policy witnesses must stay tiny"
    # These existing-owner/publication receipt inputs are never given to the
    # reader. Candidate rejection must leave their bytes and the directory intact.
    (directory / "installed.elyx").write_bytes(b"unchanged owned installed receipt")
    (directory / "old-owner.json").write_text('{"owner":"unchanged","published":false}')
    before = {p.name: p.read_bytes() for p in directory.iterdir()}
    if candidate.get("native_member"):
        inspection = None
    else:
        # The existing fourth native child's ordinary metadata preview/install
        # path remains inspectable, even when enable would refuse this candidate.
        preview = json.loads(runtime.metadata_json(path))
        assert preview["id"] == "7_archive"
        inspection = _archives.inspect_archive(path)
    provider = provider or _dependencies.ProvidedDependencies({})
    native = IssuerRecorder(path)
    try:
        with patch.object(_archives, "_native_source_gate", lambda: native.gate), \
                patch.object(_dependencies, "create_provider", lambda: provider), \
                patch.object(_archives, "_read_file", side_effect=AssertionError("FD policy inspection reopened a pathname")):
            call = lambda: _elyx_developer.inspect_fd_json(json.dumps(native.descriptor))
            if expected_error:
                error = support.raises(_archives.UnsupportedSurfaceError, call, expected_error)
            else:
                accepted = json.loads(call())
                assert accepted["id"] == "7_archive" and accepted["requires"] == {}
        assert native.claimed and native.released
        assert set(native.calls) <= {"claim", "check", "read", "release"}
        assert {p.name: p.read_bytes() for p in directory.iterdir()} == before
        assert not any(name.startswith("ElyxPlugins.") for name in sys.modules)
        assert "own" not in sys.modules and "extera_utils.plugin_loader" not in sys.modules
        if inspection is not None:
            platform = fake_platform()
            platform.dependencies = provider
            adapter = platform.archives
            adapter.snapshot = inspection
            delegated = []
            adapter.original_load = lambda record, source: delegated.append(source)
            if expected_error:
                load_error = support.raises(_archives.UnsupportedSurfaceError, lambda: adapter._load_record(object(), str(path)), expected_error)
                assert str(load_error) == str(error)
                assert not delegated, "known policy failure reached the SDK entry pipeline"
            else:
                adapter._load_record(object(), str(path))
                assert delegated == [str(path)]
                # The shared check itself must not restore paths or discover a
                # provider. It consumes the explicitly supplied metadata snapshot.
                with patch.object(provider, "restore_path", side_effect=AssertionError("preflight mutated import paths")), \
                        patch.object(_dependencies, "create_provider", side_effect=AssertionError("preflight discovered dependencies")):
                    _archives._preflight_load_policy(inspection, provider)
    finally:
        native.close()


def case_load_policy_requires(directory):
    policy_roundtrip(directory / "requires", requires={"other_archive": None}, expected_error="cross-owner module provider: other_archive")
    policy_roundtrip(directory / "empty", requires={})
    policy_roundtrip(directory / "native", native_member=True, expected_error="unverified native archive member")


def case_load_policy_python(directory):
    policy_roundtrip(directory / "incompatible", python_spec=">=99", expected_error="local wheel requires Python >=99")
    policy_roundtrip(directory / "invalid", python_spec=">>>3", expected_error="invalid local wheel Requires-Python")
    policy_roundtrip(directory / "compatible", python_spec=">=3.0")


def case_load_policy_dependencies(directory):
    from email.message import Message
    from exteraless_runtime import _dependencies
    metadata = Message()
    metadata["Name"], metadata["Requires-Python"] = "cachetools", ">=3.0"
    provider = _dependencies.ProvidedDependencies({"cachetools": SimpleNamespace(version="8.0.0", metadata=metadata, requires=[])})
    policy_roundtrip(directory / "provided", provider=provider, requirements=["cachetools>=8"], wheel_requirements=["cachetools>=8"])
    policy_roundtrip(directory / "mismatch", provider=provider, requirements=["cachetools<8"], expected_error="provided cachetools==8.0.0")
    policy_roundtrip(directory / "wheel-missing", provider=provider, wheel_requirements=["missing_owned_dependency"], expected_error="missing provided distribution")
    policy_roundtrip(directory / "url", provider=provider, requirements=["cachetools @ https://example.invalid/not-fetched.whl"], expected_error="URL requirement is unsupported")


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
