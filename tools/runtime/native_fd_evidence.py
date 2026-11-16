"""iOS evidence from real owner-worker FD operations; a Mac flag cannot satisfy it."""

import hashlib
import re

IOS_FD_HELPER = 'telegram-ios/Tests/ExteralessHarness/Fixtures/native_plugin_probe.py'


def verify_ios_fd_helper_bundle(archive, app_root, manifest):
    expected = manifest.get('files', {}).get(IOS_FD_HELPER)
    if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
        raise ValueError('Missing compiled iOS FD helper source identity')
    path = app_root + '/native_plugin_probe.py'
    if not 0 < archive.getinfo(path).file_size <= 8 * 1024 * 1024:
        raise ValueError('Missing/unbounded bundled iOS FD helper')
    actual = hashlib.sha256(archive.read(path)).hexdigest()
    if actual != expected:
        raise ValueError('Bundled iOS FD helper differs from the compiled source hash')
    return actual


def validate_ios_fd_observations(engine, epochs, manifest):
    expected = manifest.get('files', {}).get(IOS_FD_HELPER)
    if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
        raise ValueError('Missing compiled iOS FD helper source identity')
    if engine.get('initializations') != 1 or engine.get('finalizations') != 1:
        raise ValueError('iOS FD evidence is accepted only after actual CPython process cleanup')
    rows = engine.get('fdPaths', [])
    if (len(rows) != 2 or engine.get('fdProbeScriptCalls') != 4 or len(set(epochs)) != 2
            or [row.get('ownerToken') for row in rows] != list(epochs)):
        raise ValueError('Both actual iOS SDK owner lifetimes require their own bounded FD observation')
    references = [row.get('nativeReference') for row in rows]
    if (any(type(value) is not int for value in references) or len(set(references)) != 2
            or not set(references) <= set(engine.get('created', []))
            or not set(references) <= set(engine.get('destroyed', []))):
        raise ValueError('iOS FD evidence belongs to a missing/reused native interpreter')
    for row in rows:
        if row.get('error') or row.get('errors') or row.get('problems'):
            raise ValueError('Native iOS FD failure must not be replaced by a successful observation')
        if (row.get('platform') != 'ios' or row.get('bridgeBuiltin') is not True
                or row.get('helperSHA256') != expected
                or row.get('checks', {}).get('actual_ios_fd_paths') is not True
                or row.get('checks', {}).get('darwin_family_fd_paths') is not True):
            raise ValueError('Actual iOS FD operations did not pass; Mac/source-only FD evidence is insufficient')
