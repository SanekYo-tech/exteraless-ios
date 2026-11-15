"""Narrow data-only wheel tests. Synthetic modules fail if accidentally imported."""

import copy
import hashlib
import importlib.metadata
import importlib.util
import io
import json
from pathlib import Path
import stat
import sys
import tarfile
import zipfile

import pytest


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("vendor_dependencies", ROOT / "tools/runtime/vendor_dependencies.py")
vendor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(vendor)


def make_wheel(directory, package, *, extra=(), pure=True, tag="py3-none-any"):
    package = copy.deepcopy(package)
    dist_info = package["filename"].removesuffix("-py3-none-any.whl") + ".dist-info"
    metadata = ["Metadata-Version: 2.4", "Name: " + package["name"],
                "Version: " + package["version"], "Requires-Python: " + package["requires_python"]]
    metadata += ["Requires-Dist: " + item for item in package["requires_dist"]]
    metadata += ["Provides-Extra: " + item for item in package["provides_extra"]]
    root = package["import_roots"][0]
    module = root + ".py" if root == "typing_extensions" else root + "/__init__.py"
    entries = [(module, b'raise AssertionError("wheel code must never execute during preparation")\n'),
               (dist_info + "/METADATA", ("\n".join(metadata) + "\n\nSynthetic metadata fixture\n").encode()),
               (dist_info + "/WHEEL", f"Wheel-Version: 1.0\nRoot-Is-Purelib: {str(pure).lower()}\nTag: {tag}\n".encode()),
               (dist_info + "/RECORD", b""), *extra]
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / package["filename"]
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in entries:
            if isinstance(name, str):
                info = zipfile.ZipInfo(name)
                # Windows ZipInfo normalizes backslashes; retain the deliberately
                # hostile raw archive name instead of accidentally testing '/'.
                info.filename = name
                info.compress_type = zipfile.ZIP_DEFLATED
                name = info
            archive.writestr(name, data)
    package["size"] = path.stat().st_size
    package["sha256"] = vendor.digest(path)
    return path, package


def make_source(directory, package, *, extra=()):
    package = copy.deepcopy(package)
    prefix = package['name'] + '-' + package['version']
    source_dir = vendor.SOURCE_PROJECTIONS[package['name']][1]
    metadata = ('Metadata-Version: 2.4\nName: ' + package['name'] + '\nVersion: ' + package['version'] +
                '\nRequires-Python: ' + package['requires_python'] + '\n\nSource fixture\n').encode()
    entries = [('PKG-INFO', metadata), ('LICENSE', b'fixture license')]
    entries.extend((source_dir + '/' + root + '/__init__.py', b'raise AssertionError("source package must not execute")\n')
                   for root in package['import_roots'])
    entries.extend(extra)
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / package['filename']
    with tarfile.open(path, 'w:gz') as archive:
        for name, data in entries:
            info = tarfile.TarInfo(prefix + '/' + name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    package.update(size=path.stat().st_size, sha256=vendor.digest(path))
    return path, package


@pytest.fixture
def packaging_spec():
    return copy.deepcopy(vendor.read_lock()["packages"][0])


@pytest.fixture
def tiny_bundle(tmp_path):
    lock = copy.deepcopy(vendor.read_lock())
    cache = tmp_path / "cache"
    lock["packages"] = [(make_source if package.get('artifact_kind') == 'sdist-python' else make_wheel)(cache, package)[1]
                        for package in lock["packages"]]
    lock_path = tmp_path / "dependency-lock.json"
    lock_path.write_text(json.dumps(lock), encoding="utf-8")
    return cache, lock_path


def test_lock_is_small_universal_and_dependency_closed():
    lock = vendor.read_lock()
    assert {package["name"] for package in lock["packages"]} == set(vendor.IMPORT_ROOTS)
    assert sum(package["size"] for package in lock["packages"]) < vendor.MAX_DOWNLOAD_BYTES
    assert {p['name'] for p in lock['packages'] if p.get('artifact_kind') == 'sdist-python'} == {'pyyaml', 'debugpy'}
    assert all(package["filename"].endswith("-py3-none-any.whl") for package in lock["packages"]
               if package.get('artifact_kind', 'wheel') == 'wheel')
    assert list(vendor._base_requirements(lock["packages"][1])) == [
        ("charset-normalizer", "<4,>=2"), ("idna", "<4,>=2.5"),
        ("urllib3", "<3,>=1.26"), ("certifi", ">=2023.5.7")]


@pytest.mark.parametrize("lock", [None, [], {}, {"schema": 1, "python": "3.12", "packages": []}])
def test_malformed_lock_is_rejected(lock):
    with pytest.raises(ValueError):
        vendor.validate_lock(lock)


@pytest.mark.parametrize("field,value", [
    ("sha256", "missing"), ("size", vendor.MAX_WHEEL_BYTES + 1),
    ("filename", "packaging-26.3-cp312-cp312-ios.whl"),
    ("requires_python", ">=3.13"), ("import_roots", ["os"]),
    ("url", "http://files.pythonhosted.org/packaging.whl"),
])
def test_lock_rejects_invalid_identity_bounds_and_python(field, value):
    lock = copy.deepcopy(vendor.read_lock())
    lock["packages"][0][field] = value
    with pytest.raises(ValueError):
        vendor.validate_lock(lock)


def test_lock_rejects_missing_or_conflicting_transitive_dependencies():
    lock = copy.deepcopy(vendor.read_lock())
    lock["packages"][1]["requires_dist"] = ["urllib3<2"]
    with pytest.raises(ValueError, match="unsatisfied locked dependency urllib3"):
        vendor.validate_lock(lock)
    lock["packages"][1]["requires_dist"] = ["not-bundled>=1"]
    with pytest.raises(ValueError, match="not-bundled"):
        vendor.validate_lock(lock)


def test_pypi_and_wheel_marker_formatting_has_the_same_meaning():
    pypi = 'brotli>=1.2.0; platform_python_implementation == "CPython" and extra == "brotli"'
    wheel = "brotli (>=1.2.0); (platform_python_implementation == 'CPython') and extra == 'brotli'"
    assert vendor._requirement_identity(pypi, ["brotli"]) == vendor._requirement_identity(wheel, ["brotli"])
    with pytest.raises(ValueError, match="marker"):
        vendor._requirement_identity(pypi.replace(" and ", " or "), ["brotli"])


def test_checksum_mismatch_is_rejected_without_replacing_cache(tmp_path, packaging_spec):
    path, package = make_wheel(tmp_path / "cache", packaging_spec)
    original = path.read_bytes()
    package["sha256"] = "0" * 64
    with pytest.raises(ValueError, match="checksum mismatch"):
        vendor.download(package, path.parent, offline=True)
    assert path.read_bytes() == original


@pytest.mark.parametrize("name", ["../escape.py", "/absolute.py", "packaging/../../escape.py",
                                 "packaging\\escape.py", "C:/escape.py", "packaging/code.py:stream",
                                 "packaging/code.py.", "packaging/CON"])
def test_unsafe_zip_paths_are_rejected_before_extraction(tmp_path, packaging_spec, name):
    path, package = make_wheel(tmp_path / "cache", packaging_spec, extra=[(name, b"escape")])
    output = tmp_path / "out"
    with pytest.raises(ValueError, match="Unsafe wheel ZIP path"):
        vendor.extract_wheel(path, package, output, {})
    assert not output.exists()
    assert not (tmp_path / "escape.py").exists()


def test_zip_symlinks_and_case_collisions_are_rejected(tmp_path, packaging_spec):
    link = zipfile.ZipInfo("packaging/link")
    link.create_system = 3
    link.external_attr = (stat.S_IFLNK | 0o777) << 16
    path, package = make_wheel(tmp_path / "cache", packaging_spec, extra=[(link, b"../../escape")])
    with pytest.raises(ValueError, match="symlink"):
        vendor.extract_wheel(path, package, tmp_path / "out", {})
    path, package = make_wheel(tmp_path / "cache", packaging_spec,
                               extra=[("packaging/module.py", b"a"), ("packaging/MODULE.py", b"b")])
    with pytest.raises(ValueError, match="case-colliding"):
        vendor.extract_wheel(path, package, tmp_path / "out", {})


@pytest.mark.parametrize("name,content", [("packaging/native.so", b"binary"),
                                         ("packaging/module.pyd", b"binary"),
                                         ("packaging/import.pth", b"import unsafe"),
                                         ("packaging/native.dat", b"\x7fELFxxxx")])
def test_native_or_bootstrap_content_is_not_a_pure_wheel(tmp_path, packaging_spec, name, content):
    path, package = make_wheel(tmp_path / "cache", packaging_spec, extra=[(name, content)])
    with pytest.raises(ValueError, match="(?i)native|binary|bootstrap"):
        vendor.extract_wheel(path, package, tmp_path / "out", {})


@pytest.mark.parametrize("pure,tag", [(False, "py3-none-any"), (True, "cp312-cp312-ios")])
def test_wheel_metadata_cannot_disguise_native_wheel(tmp_path, packaging_spec, pure, tag):
    path, package = make_wheel(tmp_path / "cache", packaging_spec, pure=pure, tag=tag)
    with pytest.raises(ValueError, match="WHEEL metadata"):
        vendor.extract_wheel(path, package, tmp_path / "out", {})


def test_streaming_download_is_bounded_and_checksummed(tmp_path, packaging_spec, monkeypatch):
    body = b"x" * (vendor.CHUNK * 2 + 19)
    package = dict(packaging_spec, size=len(body), sha256=hashlib.sha256(body).hexdigest())

    class Response(io.BytesIO):
        headers = {"Content-Length": str(len(body))}

        def geturl(self):
            return package["url"]

        def read(self, size=-1):
            assert 0 < size <= vendor.CHUNK, "unbounded download read"
            return super().read(size)

    class Opener:
        def open(self, request, timeout):
            assert timeout <= 15
            return Response(body)

    monkeypatch.setattr(vendor.urllib.request, "build_opener", lambda *args: Opener())
    result = vendor.download(package, tmp_path / "cache")
    assert result.stat().st_size == len(body) and vendor.digest(result) == package["sha256"]
    assert not list(result.parent.glob("*.download"))


def test_offline_bundle_preserves_metadata_and_never_executes_modules(tmp_path, tiny_bundle):
    cache, lock = tiny_bundle
    output = tmp_path / "vendor"
    imported = {name: sys.modules.get(name) for roots in vendor.IMPORT_ROOTS.values() for name in roots}
    manifest = vendor.vendor(cache, output, lock_path=lock, offline=True)
    assert manifest["bundle_sha256"] == vendor.bundle_hash(vendor.digest(lock), manifest["files"])
    assert len(manifest["packages"]) == 12
    found = {vendor.canonical_name(dist.metadata["Name"]): dist.version
             for dist in importlib.metadata.distributions(path=[str(output)])}
    assert found == {entry["name"]: entry["version"] for entry in manifest["packages"]}
    assert all(sys.modules.get(name) is module for name, module in imported.items())
    assert vendor.vendor(cache, output, lock_path=lock, offline=True) == manifest
    (output / "typing_extensions.py").write_bytes(b"changed")
    with pytest.raises(ValueError, match="checksum mismatch"):
        vendor.vendor(cache, output, lock_path=lock, offline=True)


def test_invalid_wheel_never_publishes_partial_output(tmp_path, tiny_bundle):
    cache, lock_path = tiny_bundle
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    index = next(i for i, p in enumerate(lock['packages']) if p['name'] == 'typing-extensions')
    package = lock["packages"][index]
    _, lock["packages"][index] = make_wheel(cache, package, extra=[("typing_extensions.so", b"bad")])
    lock_path.write_text(json.dumps(lock), encoding="utf-8")
    output = tmp_path / "vendor"
    with pytest.raises(ValueError, match="binary"):
        vendor.vendor(cache, output, lock_path=lock_path, offline=True)
    assert not output.exists() and not list(tmp_path.glob(".vendor-dependencies-*"))


def test_runtime_provider_reads_distinfo_and_adds_only_vendor_after_sdk(tmp_path, tiny_bundle, monkeypatch):
    cache, lock = tiny_bundle
    python_root = tmp_path / "python"
    python_root.mkdir()
    output = python_root / "vendor"
    vendor.vendor(cache, output, lock_path=lock, offline=True)
    monkeypatch.syspath_prepend(str(ROOT / "python"))
    from exteraless_runtime import _dependencies
    sdk = str(python_root / "sdk" / ".." / "sdk")
    monkeypatch.setattr(sys, "path", [sdk, str(tmp_path / "plugins"), str(output), *sys.path, str(output)])
    provider = _dependencies.create_provider(python_root)
    assert sys.path.index(str(output)) == sys.path.index(sdk) + 1
    assert sys.path.count(str(output)) == 1
    assert provider.is_provided("typing_extensions") and not provider.is_provided("os")
    assert len(provider.installed_packages()) == 12
    provider.remove_requirements("fixture_plugin")
    assert (output / "requests-2.34.2.dist-info/METADATA").is_file()
    (output / "os.py").write_text('raise AssertionError("stdlib shadow")\n')
    with pytest.raises(_dependencies.UnsupportedSurfaceError, match="shadowing"):
        _dependencies.create_provider(python_root)
    (output / "os.py").unlink()
    (output / "requests-2.34.2.dist-info/METADATA").write_text("Name: requests\nVersion: 99\n")
    with pytest.raises(_dependencies.UnsupportedSurfaceError, match="checksum mismatch"):
        _dependencies.create_provider(python_root)


def test_source_projection_is_sealed_after_excluding_native_build_inputs(tmp_path):
    package = next(p for p in vendor.read_lock()['packages'] if p['name'] == 'debugpy')
    archive, package = make_source(tmp_path / 'cache', package, extra=[
        ('src/debugpy/accelerator.c', b'/* build only */'),
        ('src/debugpy/accelerator.so', b'\x7fELFnative'),
        ('src/debugpy/config.json', b'{"real_data":true}'),
    ])
    files = {}
    result = vendor.extract_source_package(archive, package, tmp_path / 'out', files)
    assert 'debugpy/config.json' in files
    assert not any(name.endswith(('.so', '.c')) for name in files)
    assert (tmp_path / 'out' / result['dist_info'] / 'METADATA').is_file()
    record = (tmp_path / 'out' / result['dist_info'] / 'RECORD').read_text()
    assert 'debugpy/config.json,sha256=' in record and 'accelerator' not in record


def test_source_projection_refuses_disguised_native_data(tmp_path):
    package = next(p for p in vendor.read_lock()['packages'] if p['name'] == 'pyyaml')
    archive, package = make_source(tmp_path / 'cache', package, extra=[('lib/yaml/data.dat', b'\x7fELFnative')])
    with pytest.raises(ValueError, match='Native binary content'):
        vendor.extract_source_package(archive, package, tmp_path / 'out', {})
