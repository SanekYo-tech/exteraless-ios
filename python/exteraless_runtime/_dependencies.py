"""Read-only provided dependencies; never resolve/download/install a package.

All state is interpreter-local. Distribution lookup is restricted to the app's
vendor manifest, rather than arbitrary sys.path entries or virtualjava proxies.
"""

import hashlib
import importlib
import json
from pathlib import Path
import re
import sys

from ._platform import UnsupportedSurfaceError


MANIFEST_NAME = "exteraless-dependencies.json"
GENERATOR = "exteraless-pure-python-dependencies-v1"
PROVIDED_ROOTS = {
    "packaging": ["packaging"], "requests": ["requests"], "urllib3": ["urllib3"],
    "idna": ["idna"], "certifi": ["certifi"], "charset-normalizer": ["charset_normalizer"],
    "cachetools": ["cachetools"], "typing-extensions": ["typing_extensions"],
}


def _name(value):
    return re.sub(r"[-_.]+", "-", value).lower()


def _error(detail):
    return UnsupportedSurfaceError(f"iOS __requirements__: {detail}; runtime pip/downloads are disabled")


class ProvidedDependencies:
    def __init__(self, distributions, vendor_dir=None):
        # Injection of distribution metadata is useful to unit-test resolution
        # without executing any downloaded wheel code. Production uses .dist-info.
        if set(distributions) - PROVIDED_ROOTS.keys():
            raise _error("unexpected package in the provided inventory")
        self.distributions = dict(distributions)
        self.vendor_dir = Path(vendor_dir) if vendor_dir is not None else None

    def restore_path(self):
        if self.vendor_dir is None:
            return
        vendor = self.vendor_dir.resolve()
        sdk = (self.vendor_dir.parent / "sdk").resolve()

        def resolved(entry):
            try:
                return Path(entry).resolve()
            except (OSError, TypeError, ValueError):
                return None

        # Native iOS paths may use either /var/... or /private/var/.... Keep one
        # vendor entry, ahead of plugin helper directories, after the actual SDK.
        paths = [entry for entry in sys.path if resolved(entry) != vendor]
        index = next((index + 1 for index, entry in enumerate(paths) if resolved(entry) == sdk), len(paths))
        paths.insert(index, str(vendor))
        if paths != sys.path:
            sys.path[:] = paths
            importlib.invalidate_caches()

    def is_provided(self, name):
        return _name(name) in self.distributions

    def bundled_version(self, name):
        distribution = self.distributions.get(_name(name))
        if distribution is None:
            return None
        from packaging.version import Version
        return Version(distribution.version)

    def installed_packages(self):
        return {name: {"version": distribution.version,
                       "path": str(self.vendor_dir) if self.vendor_dir is not None else None,
                       "provided": True, "plugins": []}
                for name, distribution in self.distributions.items()}

    def remove_requirements(self, plugin_id):
        # Bundled distributions belong to the app, not a plugin/refcount. SDK
        # uninstall may call here, but must not remove files from the app bundle.
        return None

    def ensure_requirements(self, plugin_id, requirements):
        if not requirements:
            return None
        try:
            from packaging.markers import default_environment
            from packaging.requirements import Requirement
            from packaging.specifiers import SpecifierSet
            from packaging.version import Version
        except ImportError as error:
            raise _error(f"cannot check {requirements!r}: bundled packaging is unavailable") from error

        environment = default_environment()  # actual interpreter/OS, not build-host markers
        visited = set()

        def check(raw, extras=("",), parent=None):
            try:
                requirement = Requirement(raw)
            except Exception as error:
                raise _error(f"invalid requirement {raw!r}: {error}") from error
            label = str(requirement)
            if parent:
                label = f"{parent} -> {label}"
            if requirement.url is not None:
                raise _error(f"URL requirement is unsupported: {label}")
            try:
                active = requirement.marker is None or any(
                    requirement.marker.evaluate(dict(environment, extra=extra)) for extra in extras)
            except Exception as error:
                raise _error(f"cannot evaluate marker for {label}: {error}") from error
            if not active:
                return
            name = _name(requirement.name)
            distribution = self.distributions.get(name)
            if distribution is None:
                raise _error(f"missing provided distribution {name!r}, required by {label}")
            try:
                version = Version(distribution.version)
                if not SpecifierSet(str(requirement.specifier)).contains(version):
                    raise _error(f"{label} is incompatible with provided {name}=={version}")
                metadata = distribution.metadata
                requires_python = metadata.get("Requires-Python")
                if requires_python and not SpecifierSet(requires_python).contains(environment["python_full_version"]):
                    raise _error(f"{name}=={version} requires Python {requires_python}, running {environment['python_full_version']}")
            except UnsupportedSurfaceError:
                raise
            except Exception as error:
                raise _error(f"invalid installed metadata for {name!r}: {error}") from error
            requested_extras = {_name(extra) for extra in requirement.extras}
            declared_extras = {_name(extra) for extra in metadata.get_all("Provides-Extra", [])}
            if requested_extras - declared_extras:
                raise _error(f"{name} does not provide extras {sorted(requested_extras - declared_extras)}")
            key = (name, frozenset(requested_extras))
            if key in visited:
                return
            visited.add(key)
            for dependency in distribution.requires or ():
                check(dependency, ("", *sorted(requested_extras)), parent=label)

        for raw in requirements:
            check(raw)
        return None


def create_provider(python_root=None):
    """Validate the inventory and expose App.app/python/vendor after the SDK."""
    from importlib.metadata import Distribution

    root = Path(python_root) if python_root is not None else Path(__file__).resolve().parent.parent
    vendor = root / "vendor"
    if not vendor.exists():
        return ProvidedDependencies({})
    marker = vendor / MANIFEST_NAME
    if vendor.is_symlink() or not marker.is_file() or marker.stat().st_size > 2 * 1024 * 1024:
        raise _error(f"invalid provided dependency manifest in {vendor}")
    try:
        manifest = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise _error(f"cannot read provided dependency manifest: {error}") from error
    if (manifest.get("schema") != 1 or manifest.get("generator") != GENERATOR
            or manifest.get("python") != "3.12"):
        raise _error("unsupported provided dependency manifest")
    lock_hash = manifest.get("lock_sha256", "")
    if not re.fullmatch(r"[0-9a-f]{64}", lock_hash):
        raise _error("provided dependency lock hash is missing")
    inventory = manifest.get("files", {})
    content = json.dumps({"lock_sha256": lock_hash, "files": inventory}, sort_keys=True,
                         separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if hashlib.sha256(content).hexdigest() != manifest.get("bundle_sha256"):
        raise _error("provided dependency inventory hash mismatch")
    distributions = {}
    allowed_roots = {MANIFEST_NAME}
    for package in manifest.get("packages", []):
        name, version = package.get("name"), package.get("version")
        if (name not in PROVIDED_ROOTS or name in distributions
                or package.get("import_roots") != PROVIDED_ROOTS[name]
                or not isinstance(version, str) or not re.fullmatch(r"\d+(?:\.\d+){0,3}", version)):
            raise _error(f"invalid provided package identity {name!r}")
        dist_info = f"{name.replace('-', '_')}-{version}.dist-info"
        if package.get("dist_info") != dist_info:
            raise _error(f"invalid .dist-info path for {name}")
        allowed_roots.add(dist_info)
        for module in PROVIDED_ROOTS[name]:
            allowed_roots.update((module, module + ".py"))
            if not ((vendor / module / "__init__.py").is_file() or (vendor / (module + ".py")).is_file()):
                raise _error(f"{name}: provided import root {module!r} is absent")
        path = vendor / dist_info / "METADATA"
        record = inventory.get(dist_info + "/METADATA", {})
        if (not path.is_file() or not path.resolve().is_relative_to(vendor.resolve())
                or path.stat().st_size > 256 * 1024
                or path.stat().st_size != record.get("size")
                or hashlib.sha256(path.read_bytes()).hexdigest() != record.get("sha256")):
            raise _error(f"{name}: provided .dist-info checksum mismatch")
        distribution = Distribution.at(vendor / dist_info)
        if _name(distribution.metadata["Name"] or "") != name or distribution.version != version:
            raise _error(f"{name}: provided .dist-info version/name mismatch")
        distributions[name] = distribution
    if distributions.keys() != PROVIDED_ROOTS.keys():
        raise _error("provided dependency manifest does not contain the eight agreed packages")
    for path in vendor.iterdir():
        if path.name not in allowed_roots or path.is_symlink():
            raise _error(f"unexpected top-level vendor entry / module shadowing: {path.name}")
    provider = ProvidedDependencies(distributions, vendor)
    provider.restore_path()
    return provider
