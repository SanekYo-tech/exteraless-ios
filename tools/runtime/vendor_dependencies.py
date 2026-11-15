"""Stage checksum-pinned Python packages without pip or importing them.

The builder uses only the standard library. It validates the fixed lock's numeric
version constraints and optional-extra-only markers, then compares wheel metadata
to that lock. General plugin PEP 508 requirements are handled by packaging in the
iOS adapter, not by a build-time dependency resolver.
"""

import argparse
import base64
import csv
from email.parser import BytesParser
import hashlib
import io
import json
import operator
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[2]
LOCK_PATH = ROOT / "python/runtime/dependency-lock.json"
MANIFEST_NAME = "exteraless-dependencies.json"
GENERATOR = "exteraless-pure-python-dependencies-v1"
IMPORT_ROOTS = {
    "packaging": ["packaging"], "requests": ["requests"], "urllib3": ["urllib3"],
    "idna": ["idna"], "certifi": ["certifi"], "charset-normalizer": ["charset_normalizer"],
    "cachetools": ["cachetools"], "typing-extensions": ["typing_extensions"],
    "beautifulsoup4": ["bs4"], "soupsieve": ["soupsieve"],
    "pyyaml": ["yaml", "_yaml"], "debugpy": ["debugpy"],
}
SOURCE_PROJECTIONS = {
    "pyyaml": ("pyyaml-pure", "lib"),
    "debugpy": ("debugpy-python", "src"),
}
CHUNK = 64 * 1024
MAX_LOCK_BYTES = 256 * 1024
MAX_WHEEL_BYTES = 2 * 1024 * 1024
MAX_DOWNLOAD_BYTES = 8 * 1024 * 1024
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_EXTRACTED_BYTES = 32 * 1024 * 1024
MAX_ENTRIES = 10000
MAX_METADATA_BYTES = 256 * 1024
MAX_MANIFEST_BYTES = 2 * 1024 * 1024
_BINARY_SUFFIX = re.compile(r"\.(?:so|pyd|dll|dylib|exe|a|o|obj|lib|wasm|class|jar|dex|pyc|pyo|fwork)(?:\.|$)", re.I)
_NATIVE_MAGIC = {b"\x7fELF", b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
                  b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
_SOURCE_ONLY_SUFFIXES = {".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".pyx", ".pxd", ".pxi"}


def canonical_name(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(CHUNK), b""):
            result.update(block)
    return result.hexdigest()


def _json_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _numeric_version(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,3}", value):
        raise ValueError(f"Lock needs a numeric stable version, received {value!r}")
    numbers = tuple(int(part) for part in value.split("."))
    return numbers + (0,) * (4 - len(numbers))


def _specifier_parts(specifier):
    if not isinstance(specifier, str) or not specifier:
        raise ValueError(f"Invalid fixed-lock specifier: {specifier!r}")
    for part in specifier.split(","):
        match = re.fullmatch(r"\s*(>=|<=|==|!=|>|<)\s*(\d+(?:\.\d+){0,3})\s*", part)
        if not match:
            raise ValueError(f"Unsupported fixed-lock specifier: {specifier!r}")
        yield match[1], _numeric_version(match[2])


def _satisfies(version, specifier):
    """Deliberately limited to the pinned metadata; unsupported syntax fails."""
    version = _numeric_version(version)
    comparisons = {">=": operator.ge, ">": operator.gt, "<=": operator.le,
                   "<": operator.lt, "==": operator.eq, "!=": operator.ne}
    return all([comparisons[op](version, required) for op, required in _specifier_parts(specifier)])


def _locked_requirement(raw, provided_extras):
    requirement, separator, marker = raw.partition(";")
    match = re.fullmatch(r"\s*([A-Za-z0-9][A-Za-z0-9_.-]*)([^;]*)", requirement)
    if not match:
        raise ValueError(f"Invalid fixed-lock dependency: {raw}")
    name, specifier = canonical_name(match[1]), match[2].strip()
    if specifier.startswith("(") and specifier.endswith(")"):
        specifier = specifier[1:-1].strip()
    if specifier:
        list(_specifier_parts(specifier))
    normalized_marker = None
    if separator:
        # The fixed bundle selects no extras. Only a conjunction ending in an
        # extra equality is supported, and is necessarily false for extra="".
        # Normalize PyPI's quotes and redundant parentheses around one comparison
        # without removing grouping from a general boolean marker expression.
        terms = marker.strip().split(" and ")
        extra = re.fullmatch(r'''extra\s*==\s*(["'])([A-Za-z0-9_.-]+)\1''', terms[-1].strip())
        if len(terms) not in (1, 2) or not extra or extra[2] not in provided_extras:
            raise ValueError(f"Unsupported fixed-lock dependency marker: {raw}")
        comparison = None
        if len(terms) == 2:
            text = terms[0].strip()
            if text.startswith("(") and text.endswith(")"):
                text = text[1:-1].strip()
            condition = re.fullmatch(
                r'''(platform_python_implementation|python_version)\s*(==|!=|<=|>=|<|>)\s*(["'])([A-Za-z0-9_.-]+)\3''', text)
            if not condition:
                raise ValueError(f"Unsupported fixed-lock dependency marker: {raw}")
            comparison = (condition[1], condition[2], condition[4])
        normalized_marker = (comparison, extra[2])
    return name, specifier, normalized_marker


def _requirement_identity(raw, provided_extras):
    name, specifier, marker = _locked_requirement(raw, provided_extras)
    return name, tuple(sorted(_specifier_parts(specifier))) if specifier else (), marker


def _base_requirements(package):
    for raw in package["requires_dist"]:
        name, specifier, marker = _locked_requirement(raw, package["provides_extra"])
        if marker is None:
            yield name, specifier


def _url(url, host):
    if not isinstance(url, str):
        raise ValueError(f"Expected an HTTPS {host} URL")
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != "https" or parsed.netloc != host or parsed.query or parsed.fragment
            or parsed.username or parsed.password):
        raise ValueError(f"Expected an HTTPS {host} URL: {url!r}")
    return parsed


def validate_lock(lock):
    if not isinstance(lock, dict) or lock.get("schema") != 1 or lock.get("python") != "3.12":
        raise ValueError("Unsupported dependency lock schema/Python target")
    packages = lock.get("packages")
    if not isinstance(packages, list) or len(packages) != len(IMPORT_ROOTS):
        raise ValueError("Dependency lock must contain the agreed package set")
    by_name = {}
    for package in packages:
        if not isinstance(package, dict):
            raise ValueError("Locked packages must be JSON objects")
        name = package.get("name")
        if not isinstance(name, str) or name not in IMPORT_ROOTS or name in by_name:
            raise ValueError(f"Unexpected or duplicate locked package: {name!r}")
        version = package.get("version")
        _numeric_version(version)
        source = package.get("artifact_kind") == "sdist-python"
        if package.get("artifact_kind", "wheel") not in ("wheel", "sdist-python"):
            raise ValueError(f"{name}: unsupported artifact kind")
        if source and (name not in SOURCE_PROJECTIONS or package.get("projection") != SOURCE_PROJECTIONS[name][0]):
            raise ValueError(f"{name}: unsupported source projection")
        expected_file = (f"{name}-{version}.tar.gz" if source else
                         f"{name.replace('-', '_')}-{version}-py3-none-any.whl")
        if package.get("filename") != expected_file:
            raise ValueError(f"{name}: expected the locked universal wheel or reviewed source archive")
        if not isinstance(package.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", package["sha256"]):
            raise ValueError(f"{name}: missing/invalid SHA-256")
        size = package.get("size")
        if type(size) is not int or not 0 < size <= MAX_WHEEL_BYTES:
            raise ValueError(f"{name}: invalid/oversized wheel size")
        source = _url(package.get("url", ""), "files.pythonhosted.org")
        if PurePosixPath(source.path).name != expected_file:
            raise ValueError(f"{name}: wheel URL/filename mismatch")
        metadata = _url(package.get("pypi_json", ""), "pypi.org")
        if metadata.path != f"/pypi/{name}/{version}/json":
            raise ValueError(f"{name}: expected the version-specific PyPI JSON URL")
        if package.get("import_roots") != IMPORT_ROOTS[name]:
            raise ValueError(f"{name}: unexpected import roots / stdlib shadowing")
        if set(package["import_roots"]) & (sys.stdlib_module_names | set(sys.builtin_module_names)):
            raise ValueError(f"{name}: a wheel must not shadow the standard library")
        if not _satisfies("3.12.0", package.get("requires_python", "")):
            raise ValueError(f"{name}: Requires-Python excludes Python 3.12")
        for field in ("requires_dist", "provides_extra"):
            if not isinstance(package.get(field), list) or any(not isinstance(item, str) for item in package[field]):
                raise ValueError(f"{name}: invalid {field}")
        by_name[name] = package
    if sum(package["size"] for package in packages) > MAX_DOWNLOAD_BYTES:
        raise ValueError("Dependency bundle exceeds the total download size limit")
    for package in packages:
        for name, specifier in _base_requirements(package):
            if name not in by_name or (specifier and not _satisfies(by_name[name]["version"], specifier)):
                raise ValueError(f"{package['name']}: unsatisfied locked dependency {name}{specifier}")
    return lock


def read_lock(path=LOCK_PATH):
    path = Path(path)
    if path.stat().st_size > MAX_LOCK_BYTES:
        raise ValueError("Dependency lock is too large")
    return validate_lock(json.loads(path.read_text(encoding="utf-8")))


def verify_wheel(path, package):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size != package["size"]:
        raise ValueError(f"{package['filename']}: wheel size/type mismatch")
    if digest(path) != package["sha256"]:
        raise ValueError(f"{package['filename']}: SHA-256 checksum mismatch")


class _WheelRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        _url(newurl, "files.pythonhosted.org")
        return super().redirect_request(request, fp, code, message, headers, newurl)


def download(package, cache, *, offline=False):
    cache = Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / package["filename"]
    if target.exists() or target.is_symlink():
        verify_wheel(target, package)
        return target
    if offline:
        raise ValueError(f"Wheel is not cached: {target.name}")
    _url(package["url"], "files.pythonhosted.org")
    fd, name = tempfile.mkstemp(prefix=target.name + ".", suffix=".download", dir=cache)
    temporary = Path(name)
    try:
        request = urllib.request.Request(package["url"], headers={"User-Agent": GENERATOR, "Accept-Encoding": "identity"})
        deadline = time.monotonic() + 60
        with os.fdopen(fd, "wb") as output, urllib.request.build_opener(_WheelRedirect()).open(request, timeout=15) as response:
            _url(response.geturl(), "files.pythonhosted.org")
            length = response.headers.get("Content-Length")
            if length is not None and int(length) != package["size"]:
                raise ValueError(f"{target.name}: download Content-Length mismatch")
            total = 0
            while block := response.read(CHUNK):
                total += len(block)
                if total > package["size"] or time.monotonic() > deadline:
                    raise ValueError(f"{target.name}: download size/time limit exceeded")
                output.write(block)
        verify_wheel(temporary, package)
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target


def safe_member(info):
    name = info.orig_filename
    if not name or "\0" in name or "\\" in name or name.startswith("/"):
        raise ValueError(f"Unsafe wheel ZIP path: {name!r}")
    parts = name.rstrip("/").split("/")
    for part in parts:
        if (not part or part in (".", "..") or ":" in part or part.endswith((".", " "))
                or re.fullmatch(r"(?i)(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?", part)):
            raise ValueError(f"Unsafe wheel ZIP path: {name!r}")
    mode = stat.S_IFMT(info.external_attr >> 16)
    if mode not in (0, stat.S_IFREG, stat.S_IFDIR):
        raise ValueError(f"Wheel ZIP symlink/special file is unsupported: {name}")
    if info.flag_bits & 1 or info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
        raise ValueError(f"Unsupported wheel ZIP encoding: {name}")
    if _BINARY_SUFFIX.search(name) or name.lower().endswith((".pth", ".egg-link")) or "__pycache__" in parts:
        raise ValueError(f"Native/binary/bootstrap file refused in pure wheel: {name}")
    if info.file_size > MAX_FILE_BYTES:
        raise ValueError(f"Wheel file exceeds extraction limit: {name}")
    return PurePosixPath(*parts)


def _metadata(archive, name):
    info = archive.getinfo(name)
    if info.file_size > MAX_METADATA_BYTES:
        raise ValueError(f"Oversized wheel metadata: {name}")
    return BytesParser().parsebytes(archive.read(info))


def _validate_metadata(metadata, package, filename):
    if (canonical_name(metadata["Name"] or "") != package["name"]
            or metadata["Version"] != package["version"]
            or metadata["Requires-Python"] != package["requires_python"]
            or {_requirement_identity(raw, package["provides_extra"]) for raw in metadata.get_all("Requires-Dist", [])}
            != {_requirement_identity(raw, package["provides_extra"]) for raw in package["requires_dist"]}
            or sorted(metadata.get_all("Provides-Extra", [])) != sorted(package["provides_extra"])):
        raise ValueError(f"{filename}: package METADATA disagrees with the PyPI lock")


def extract_wheel(path, package, output, files):
    """Extract data only into a private staging directory; never import a wheel."""
    verify_wheel(path, package)
    filename = package["filename"]
    if not filename.endswith("-py3-none-any.whl"):
        raise ValueError("Only universal py3-none-any wheels may be extracted")
    dist_info = filename.removesuffix("-py3-none-any.whl") + ".dist-info"
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > MAX_ENTRIES:
            raise ValueError(f"{filename}: too many ZIP entries")
        if sum(info.file_size for info in entries) + sum(item["size"] for item in files.values()) > MAX_EXTRACTED_BYTES:
            raise ValueError("Dependency bundle exceeds the extraction size limit")
        seen = {name.casefold() for name in files}
        regular = []
        for info in entries:
            relative = safe_member(info)
            root = relative.parts[0]
            if root not in package["import_roots"] + [name + ".py" for name in package["import_roots"]] + [dist_info]:
                raise ValueError(f"Unexpected import root / wheel .data layout: {relative}")
            if info.is_dir():
                continue
            if relative.as_posix().casefold() in seen:
                raise ValueError(f"Duplicate/case-colliding wheel path: {relative}")
            seen.add(relative.as_posix().casefold())
            regular.append((info, relative))
        metadata = _metadata(archive, dist_info + "/METADATA")
        wheel = _metadata(archive, dist_info + "/WHEEL")
        _validate_metadata(metadata, package, filename)
        if (wheel["Root-Is-Purelib"] != "true" or wheel.get_all("Tag") != ["py3-none-any"]
                or wheel["Wheel-Version"] != "1.0"):
            raise ValueError(f"{filename}: native or unsupported WHEEL metadata")
        if dist_info + "/RECORD" not in {relative.as_posix() for _, relative in regular}:
            raise ValueError(f"{filename}: missing wheel RECORD")
        for root in package["import_roots"]:
            if not any(relative.as_posix() in (root + ".py", root + "/__init__.py") for _, relative in regular):
                raise ValueError(f"{filename}: missing import root {root}")
        for info, relative in regular:
            target = Path(output).joinpath(*relative.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            size, sha256 = 0, hashlib.sha256()
            with archive.open(info) as source, target.open("xb") as destination:
                while block := source.read(CHUNK):
                    if size == 0 and (block[:4] in _NATIVE_MAGIC or block[:2] == b"MZ"):
                        raise ValueError(f"Native binary content refused: {relative}")
                    size += len(block)
                    if size > info.file_size or size > MAX_FILE_BYTES:
                        raise ValueError(f"ZIP expansion limit exceeded: {relative}")
                    destination.write(block)
                    sha256.update(block)
            if size != info.file_size:
                raise ValueError(f"ZIP file size mismatch: {relative}")
            files[relative.as_posix()] = {"size": size, "sha256": sha256.hexdigest()}
    return dict(package, dist_info=dist_info)


def extract_source_package(path, package, output, files):
    """Install the upstream Python implementation from a reviewed sdist layout.

    PyYAML's lib/ is its documented --without-libyaml implementation. debugpy's
    src/ contains its Python debugger; compiled accelerators/PID-attach helpers
    are excluded BEFORE sealing. No setup.py, compiler, pip or wheel code runs.
    The generated .dist-info records exactly the installed source projection.
    """
    verify_wheel(path, package)
    name, version = package['name'], package['version']
    projection, source_dir = SOURCE_PROJECTIONS[name]
    if package.get('projection') != projection:
        raise ValueError('Source projection does not match the lock')
    prefix = name + '-' + version
    dist_info = name.replace('-', '_') + '-' + version + '.dist-info'
    own_files = {}
    output = Path(output)

    def store(relative, source, size):
        key = relative.as_posix()
        if key.casefold() in {item.casefold() for item in files}:
            raise ValueError('Duplicate/case-colliding source package path: ' + key)
        if size > MAX_FILE_BYTES or sum(item['size'] for item in files.values()) + size > MAX_EXTRACTED_BYTES:
            raise ValueError('Source package exceeds extraction size limit')
        target = output.joinpath(*relative.parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        sha, count = hashlib.sha256(), 0
        with target.open('xb') as destination:
            while block := source.read(CHUNK):
                if count == 0 and (block[:4] in _NATIVE_MAGIC or block[:2] == b'MZ'):
                    raise ValueError('Native binary content refused: ' + key)
                count += len(block)
                if count > size:
                    raise ValueError('Source package expansion limit exceeded')
                destination.write(block)
                sha.update(block)
        if count != size:
            raise ValueError('Source package file size mismatch')
        files[key] = own_files[key] = {'size': size, 'sha256': sha.hexdigest()}

    with tarfile.open(path, 'r:gz') as archive:
        members = archive.getmembers()
        if len(members) > MAX_ENTRIES:
            raise ValueError('Source package has too many entries')
        seen, selected, metadata_bytes = set(), [], None
        for member in members:
            # Reuse the path validator, with regular-file metadata only. Reject
            # links explicitly before creating any projected output files.
            if not (member.isdir() or member.isfile()):
                raise ValueError('Source package contains a link or special file')
            info = zipfile.ZipInfo(member.name)
            info.orig_filename = member.name
            relative = PurePosixPath(member.name)
            if (relative.is_absolute() or '..' in relative.parts or '\\' in member.name
                    or not relative.parts or relative.parts[0] != prefix):
                raise ValueError('Unsafe source package path: ' + member.name)
            if member.isdir():
                continue
            if member.name.casefold() in seen:
                raise ValueError('Duplicate/case-colliding source archive path')
            seen.add(member.name.casefold())
            local = PurePosixPath(*relative.parts[1:])
            if local.as_posix() == 'PKG-INFO':
                if member.size > MAX_METADATA_BYTES:
                    raise ValueError('Source package metadata is too large')
                metadata_bytes = archive.extractfile(member).read()
                continue
            if len(local.parts) >= 3 and local.parts[0] == source_dir and local.parts[1] in package['import_roots']:
                projected = PurePosixPath(*local.parts[1:])
                if (projected.suffix.lower() in _SOURCE_ONLY_SUFFIXES or _BINARY_SUFFIX.search(str(projected))
                        or '__pycache__' in projected.parts):
                    continue
                safe_member(zipfile.ZipInfo(projected.as_posix()))
                selected.append((member, projected))
            elif len(local.parts) == 1 and local.name.startswith(('LICENSE', 'NOTICE')):
                selected.append((member, PurePosixPath(dist_info, 'licenses', local.name)))
        if metadata_bytes is None:
            raise ValueError('Source package is missing PKG-INFO')
        _validate_metadata(BytesParser().parsebytes(metadata_bytes), package, str(path))
        for root in package['import_roots']:
            if not any(str(relative) == root + '/__init__.py' for _, relative in selected):
                raise ValueError('Source package is missing import root: ' + root)
        for member, relative in selected:
            with archive.extractfile(member) as stream:
                store(relative, stream, member.size)
        wheel = b'Wheel-Version: 1.0\nGenerator: exteraless-source-projection-v1\nRoot-Is-Purelib: true\nTag: py3-none-any\n'
        for leaf, data in (('METADATA', metadata_bytes), ('WHEEL', wheel), ('INSTALLER', b'exteraless-vendor\n')):
            store(PurePosixPath(dist_info, leaf), io.BytesIO(data), len(data))
        records = io.StringIO(newline='')
        writer = csv.writer(records, lineterminator='\n')
        for relative, record in sorted(own_files.items()):
            sha = base64.urlsafe_b64encode(bytes.fromhex(record['sha256'])).rstrip(b'=').decode('ascii')
            writer.writerow((relative, 'sha256=' + sha, record['size']))
        writer.writerow((dist_info + '/RECORD', '', ''))
        data = records.getvalue().encode('utf-8')
        store(PurePosixPath(dist_info, 'RECORD'), io.BytesIO(data), len(data))
    return dict(package, dist_info=dist_info)


def bundle_hash(lock_sha256, files):
    return hashlib.sha256(_json_bytes({"lock_sha256": lock_sha256, "files": files})).hexdigest()


def verify_bundle(output, lock_sha256):
    """Verify the sealed file inventory, including a copy made by an app packager."""
    output = Path(output)
    marker = output / MANIFEST_NAME
    if not marker.is_file() or marker.is_symlink() or marker.stat().st_size > MAX_MANIFEST_BYTES:
        raise ValueError("Nonempty output is not a managed dependency bundle")
    manifest = json.loads(marker.read_text(encoding="utf-8"))
    if manifest.get("generator") != GENERATOR or manifest.get("lock_sha256") != lock_sha256:
        raise ValueError("Output uses a different dependency lock; select a fresh output directory")
    files = manifest["files"]
    if manifest.get("bundle_sha256") != bundle_hash(lock_sha256, files):
        raise ValueError("Existing dependency manifest hash mismatch")
    actual = set()
    for index, path in enumerate(output.rglob("*")):
        if index > MAX_ENTRIES * len(IMPORT_ROOTS) or path.is_symlink():
            raise ValueError("Existing dependency bundle contains excessive entries or symlinks")
        if path.is_file():
            actual.add(path.relative_to(output).as_posix())
    if actual != set(files) | {MANIFEST_NAME}:
        raise ValueError("Existing dependency bundle file inventory mismatch")
    for name, record in files.items():
        path = output / name
        if path.is_symlink() or path.stat().st_size != record["size"] or digest(path) != record["sha256"]:
            raise ValueError(f"Existing dependency bundle checksum mismatch: {name}")
    return manifest


def vendor(cache, output, *, lock_path=LOCK_PATH, offline=False):
    lock = read_lock(lock_path)
    lock_sha256 = digest(lock_path)
    output = Path(output).absolute()
    if output.is_symlink():
        raise ValueError("Dependency output must not be a symlink")
    if output.exists() and any(output.iterdir()):
        return verify_bundle(output, lock_sha256)
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".vendor-dependencies-", dir=output.parent))
    try:
        files, packages = {}, []
        for package in lock["packages"]:
            wheel = download(package, cache, offline=offline)
            extract = extract_source_package if package.get('artifact_kind') == 'sdist-python' else extract_wheel
            packages.append(extract(wheel, package, stage, files))
        manifest = {
            "schema": 1, "generator": GENERATOR, "python": lock["python"],
            "lock_sha256": lock_sha256, "bundle_sha256": bundle_hash(lock_sha256, files),
            "packages": packages, "files": files,
            "download_bytes": sum(package["size"] for package in packages),
            "installed_bytes": sum(record["size"] for record in files.values()),
        }
        (stage / MANIFEST_NAME).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        if output.exists():
            output.rmdir()  # Only an empty directory may be replaced.
        stage.replace(output)
        return manifest
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=LOCK_PATH)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="site-packages directory, staged as App.app/python/vendor")
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--offline", action="store_true", help="verify and use cached wheels only")
    args = parser.parse_args()
    if args.report.resolve().is_relative_to(args.output.resolve()):
        parser.error("--report must be outside --output (the bundle has a sealed inventory)")
    report = vendor(args.cache, args.output, lock_path=args.lock, offline=args.offline)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(dict(report, output=str(args.output.resolve()),
                                         wheel_code_executed=False), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Verified {len(report['packages'])} pinned Python packages: {report['download_bytes']} download bytes, "
          f"{report['installed_bytes']} installed bytes; output={args.output}; sha256={report['bundle_sha256']}")


if __name__ == "__main__":
    main()
