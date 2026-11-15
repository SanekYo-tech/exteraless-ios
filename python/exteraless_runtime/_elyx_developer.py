"""Read-only owner-worker seam for the authenticated native Elyx developer path.

Native code owns comparison, ZIP candidates, inspection, publication and reload.
No listener credential or publication capability is accepted/returned here.
The archive adapter's already validated, immutable load snapshot is the source.
"""

import json

from . import _archives
from ._platform import RuntimeStateError, UnsupportedSurfaceError


MAX_REPLY_BYTES = 2 * 1024 * 1024


def _json(value):
    result = json.dumps(value, ensure_ascii=False, allow_nan=False)
    if len(result.encode("utf-8")) > MAX_REPLY_BYTES:
        raise RuntimeStateError("Elyx developer snapshot exceeds 2 MiB")
    return result


def ping_json():
    """Also valid in the existing data-only metadata inspector, without a plugin."""
    from . import _sdk_module
    return _json(_sdk_module("elyx_runtime").handle_dev_command("elyx_ping", {}))


def _owner(plugin_id, owner_token, account_json):
    from . import _runtime, _settings_account

    platform = _runtime(loaded=True)
    platform.check_plugin(plugin_id)
    if not isinstance(owner_token, str) or not owner_token or owner_token != platform.owner_token:
        raise RuntimeStateError("Elyx developer read belongs to a different owner epoch")
    if platform.plugin_format not in ("elyx", "eaf"):
        raise RuntimeStateError("Elyx developer command requires a loaded archive")
    return platform, _settings_account(json.loads(account_json))


def read_json(plugin_id, owner_token, account_json):
    """Native invocation selects its owner before scheduling this fixed entrypoint.

    The epoch comparison here detects a misrouted call; C/Host is the authority.
    A direct Python caller can read its own state, never publish/reload anything.
    Cache mutations are not source changes: the installed archive is authoritative.
    """
    from . import _scope, _sdk_module

    platform, account = _owner(plugin_id, owner_token, account_json)
    sdk = _sdk_module("elyx_runtime")
    states = _sdk_module("elyx_runtime.loader")._states
    if set(states) != {plugin_id}:
        raise RuntimeStateError("Elyx worker state is not exclusively owned by the selected plugin")
    with _scope(platform, account):
        # These are the preserved Original handlers, with their actual name and
        # params signature. The mutating Original handler is never called.
        ping = sdk.handle_dev_command("elyx_ping", {})
        listed = sdk.handle_dev_command("get_elyx_plugins", {})
        if ping.get("ok") is not True or listed.get("ok") is not True:
            raise RuntimeStateError("Original Elyx read command failed")
        entries = listed.get("plugins")
        if not isinstance(entries, list) or len(entries) != 1 or entries[0].get("id") != plugin_id:
            raise RuntimeStateError("Original Elyx list returned a different plugin")
        return _json({"ok": True, "plugin": entries[0], "version": ping["version"]})


def manifest_json(plugin_id, owner_token, source_digest, account_json):
    """Required archive-owner API: immutable, FD/source-byte verified manifest.

    Do not fall back to ArchiveAdapter.snapshot, os.walk(extract_dir), or cached
    .pyc hashes. That path is being retired by the archive P1 remediation.
    """
    from . import _scope
    platform, account = _owner(plugin_id, owner_token, account_json)
    provider = getattr(platform.archives, "developer_manifest", None)
    if not callable(provider):
        raise UnsupportedSurfaceError("FD/source-byte verified ArchiveAdapter.developer_manifest is not installed")
    with _scope(platform, account):
        value = provider(expected_source_digest=source_digest)
        if (not isinstance(value, dict) or set(value) != {"source_digest", "files"}
                or value["source_digest"] != source_digest or not isinstance(value["files"], dict)
                or len(value["files"]) > _archives.MAX_ENTRIES):
            raise RuntimeStateError("verified archive manifest does not match the native source lease")
        return _json({"ok": True, **value})


def inspect_fd_json(descriptor_json):
    """Data-only inspector hook supplied by the archive FD-authority owner."""
    if len(descriptor_json.encode("utf-8")) > 4096:
        raise ValueError("Elyx descriptor exceeds 4096 bytes")
    provider = getattr(_archives, "inspect_developer_descriptor", None)
    if not callable(provider):
        raise UnsupportedSurfaceError("FD/source-byte verified inspect_developer_descriptor is not installed")
    return _json(provider(json.loads(descriptor_json)))


def load_verified_json(path, descriptor_json):
    """Only Host's newly created owner may consume a prepared descriptor.

    The archive owner supplies the context which pins verified bytes throughout
    the existing load_json pipeline. It must not reopen a mutable cache/source
    filename. The native invocation retains the descriptor until actual finish.
    """
    from . import _runtime, load_json
    platform = _runtime()
    if platform.plugin_format not in ("elyx", "eaf") or not platform.owner_token:
        raise RuntimeStateError("verified Elyx load requires the bound native archive owner")
    if platform.callbacks.active or platform.loader.is_loaded(platform.plugin_id):
        raise RuntimeStateError("verified Elyx load requires a fresh Host-created owner; local reload is forbidden")
    if len(descriptor_json.encode("utf-8")) > 4096:
        raise ValueError("Elyx descriptor exceeds 4096 bytes")
    provider = getattr(_archives, "verified_developer_load", None)
    if not callable(provider):
        raise UnsupportedSurfaceError("FD/source-byte verified verified_developer_load is not installed")
    with provider(platform, path, json.loads(descriptor_json)):
        return load_json(path)


def install(platform):
    import dev_server

    previous = dev_server._cmd_elyx

    def local_command(request):
        if request.get("@") == "elyx_changes":
            return {"ok": False, "reloaded": False, "errors": [
                "elyx_changes requires the authenticated native archive transaction; "
                "direct Python dispatch cannot publish source or create a Host generation"]}
        return previous(request)

    dev_server._cmd_elyx = local_command
