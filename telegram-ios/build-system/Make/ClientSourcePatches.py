"""Pinned outer-repository patches for source-only, possibly gitless Telegram copies.

Exactly two whole-tree states are accepted: all preimages, or all postimages.
No fuzzy application, line-ending normalization of hashes, git reset or network
operation is performed. A partial/unknown state fails before writing any file.
"""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tempfile


MANIFEST = 'build-system/exteraless-patches/manifest.json'
HELPER = 'build-system/Make/ClientSourcePatches.py'
GENERATOR = 'exteraless-client-source-patches-v1'
BASE_COMMIT = 'da4b2170210aab0430c4ff18c032991f3030cf45'
HUNK = re.compile(rb'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@[^\n]*\n')


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def checked_file(root, name, maximum=2 * 1024 * 1024):
    relative = PurePosixPath(name)
    if (not name or relative.is_absolute() or any(part in ('.', '..') for part in name.split('/'))
            or '\\' in name or ':' in name):
        raise ValueError('Invalid client patch path: ' + name)
    path = root
    for part in relative.parts:
        path = path / part
        if path.is_symlink() or (hasattr(path, 'is_junction') and path.is_junction()):
            raise ValueError('Symlink/junction in client patch input: ' + name)
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > maximum:
        raise ValueError('Client patch input is not a bounded regular file: ' + name)
    return path


def parse_patch(data):
    if b'\r' in data or not data.endswith(b'\n'):
        raise ValueError('Canonical client patch must contain exact LF bytes')
    lines = data.splitlines(keepends=True)
    index, result = 0, {}
    while index < len(lines):
        header = re.fullmatch(rb'diff --git a/(\S+) b/(\S+)\n', lines[index])
        if not header or header[1] != header[2]:
            raise ValueError('Only same-path source updates are supported')
        name = header[1].decode('utf-8')
        if name in result or index + 4 >= len(lines):
            raise ValueError('Duplicate or truncated client patch section')
        if (not re.fullmatch(rb'index [0-9a-f]{40}\.\.[0-9a-f]{40} 100644\n', lines[index + 1])
                or lines[index + 2] != b'--- a/' + header[1] + b'\n'
                or lines[index + 3] != b'+++ b/' + header[1] + b'\n'):
            raise ValueError('Invalid client patch file headers')
        index += 4
        hunks = []
        while index < len(lines) and not lines[index].startswith(b'diff --git '):
            match = HUNK.fullmatch(lines[index])
            if not match:
                raise ValueError('Invalid client patch hunk')
            old_start, old_count, new_start, new_count = [int(value) if value is not None else 1 for value in match.groups()]
            old, new = [], []
            index += 1
            while index < len(lines) and lines[index][:1] in (b' ', b'-', b'+'):
                line = lines[index]
                if line[:1] in (b' ', b'-'):
                    old.append(line[1:])
                if line[:1] in (b' ', b'+'):
                    new.append(line[1:])
                index += 1
            if len(old) != old_count or len(new) != new_count:
                raise ValueError('Client patch hunk counts differ')
            hunks.append((old_start, old_count, new_start, new_count, old, new))
        if not hunks:
            raise ValueError('Empty client patch section')
        result[name] = hunks
    return result


def encode_postimage_lines(lines, spec):
    output = list(lines)
    previous = 0
    for start, end in spec['postimage_crlf_ranges']:
        if type(start) is not int or type(end) is not int or not previous < start <= end <= len(output):
            raise ValueError('Invalid exact postimage line-ending map')
        for index in range(start - 1, end):
            if not output[index].endswith(b'\n'):
                raise ValueError('CRLF map references an unterminated line')
            output[index] = output[index][:-1] + b'\r\n'
        previous = end
    return b''.join(output)


def render_postimage(before, hunks, spec):
    # Git's diff describes LF source lines. The explicit ranges reproduce the
    # author's mixed CRLF/LF raw snapshot; the final RAW hash is still mandatory.
    if b'\r' in before:
        raise ValueError('Pinned preimage is the raw LF git blob')
    lines = before.splitlines(keepends=True)
    output, cursor = [], 0
    for old_start, old_count, new_start, new_count, old, new in hunks:
        start = old_start - 1 if old_count else old_start
        if start < cursor or start > len(lines) or lines[start:start + old_count] != old:
            raise ValueError('Client patch context/position mismatch')
        output.extend(lines[cursor:start])
        if len(output) != (new_start - 1 if new_count else new_start):
            raise ValueError('Client patch postimage position mismatch')
        output.extend(new)
        cursor = start + old_count
    output.extend(lines[cursor:])
    result = encode_postimage_lines(output, spec)
    if len(result) != spec['postimage_size'] or sha256(result) != spec['postimage_sha256']:
        raise ValueError('Client patch produced an unexpected raw postimage')
    return result


def load_contract(telegram_root):
    root = Path(telegram_root).resolve()
    manifest_path = checked_file(root, MANIFEST, 64 * 1024)
    metadata = manifest_path.read_bytes()
    contract = json.loads(metadata)
    if (type(contract.get('schema')) is not int or contract.get('schema') != 1
            or contract.get('repository') != 'third-party/mtproto-engine'
            or contract.get('base_commit') != BASE_COMMIT
            or contract.get('format') != 'git-unified-lf-with-exact-postimage-crlf-ranges'
            or set(contract.get('files', {})) != {
                'crates/mtproto-engine/src/resolver.rs', 'crates/mtproto-engine/src/session_runtime.rs',
                'crates/mtproto-engine/src/worker.rs'}):
        raise ValueError('Unexpected client patch contract')
    patch_name = 'build-system/exteraless-patches/' + contract['patch']
    data = checked_file(root, patch_name, 512 * 1024).read_bytes()
    if sha256(data) != contract['patch_sha256']:
        raise ValueError('Client patch SHA-256 mismatch')
    hunks = parse_patch(data)
    if set(hunks) != set(contract['files']):
        raise ValueError('Client patch paths differ from pinned images')
    for spec in contract['files'].values():
        for state in ('preimage', 'postimage'):
            if (not re.fullmatch(r'[0-9a-f]{64}', spec.get(state + '_sha256', ''))
                    or type(spec.get(state + '_size')) is not int
                    or not 0 < spec[state + '_size'] <= 2 * 1024 * 1024):
                raise ValueError('Invalid raw client image pin')
    inputs = {MANIFEST: sha256(metadata), patch_name: sha256(data),
              HELPER: sha256(checked_file(root, HELPER).read_bytes())}
    return root, contract, hunks, inputs


def prepare_client_sources(telegram_root, *, apply=True):
    root, contract, hunks, inputs = load_contract(telegram_root)
    repository = root / contract['repository']
    if (repository / '.git').exists():
        head = subprocess.check_output(['git', '-C', str(repository), 'rev-parse', 'HEAD'], timeout=10).decode().strip()
        if head != contract['base_commit']:
            raise ValueError('Client patch requires the pinned mtproto-engine base commit')
    files, images, states = {}, {}, set()
    for name, spec in contract['files'].items():
        relative = contract['repository'] + '/' + name
        path = checked_file(root, relative)
        data = path.read_bytes()
        fingerprint = sha256(data)
        state = next((value for value in ('preimage', 'postimage')
                      if len(data) == spec[value + '_size'] and fingerprint == spec[value + '_sha256']), None)
        if state is None:
            raise ValueError('Unknown client source image (third state): ' + relative)
        if state == 'postimage' and encode_postimage_lines(data.replace(b'\r\n', b'\n').splitlines(keepends=True), spec) != data:
            raise ValueError('Pinned postimage line-ending map differs: ' + relative)
        files[name], images[name] = path, data
        states.add(state)
    if len(states) != 1:
        raise ValueError('Partially applied client patch (mixed source images)')
    if states == {'preimage'}:
        if not apply:
            raise ValueError('Client source patch has not been prepared')
        results = {name: render_postimage(images[name], hunks[name], spec) for name, spec in contract['files'].items()}
        if any(path.read_bytes() != images[name] for name, path in files.items()):
            raise ValueError('Client source changed during patch preparation')
        temporary = []
        try:
            for name, path in files.items():
                with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.exl-patch-', delete=False) as stream:
                    tmp = Path(stream.name)
                    temporary.append((tmp, path))
                    stream.write(results[name])
                os.chmod(tmp, stat.S_IMODE(path.stat().st_mode))
            if any(path.read_bytes() != images[name] for name, path in files.items()):
                raise ValueError('Client source changed before patch publication')
            for tmp, path in temporary:
                os.replace(tmp, path)
        finally:
            for tmp, _ in temporary:
                tmp.unlink(missing_ok=True)
    postimages = {}
    for name, path in files.items():
        actual = sha256(path.read_bytes())
        if actual != contract['files'][name]['postimage_sha256']:
            raise ValueError('Client postimage changed during preparation: ' + name)
        postimages[contract['repository'] + '/' + name] = actual
    report = {'schema': 1, 'generator': GENERATOR, 'base_commit': contract['base_commit'],
              'repository': contract['repository'], 'input_sha256': inputs, 'postimage_sha256': postimages}
    report['source_fingerprint'] = sha256(json.dumps(report, sort_keys=True, separators=(',', ':')).encode())
    return report


def validate_patch_provenance(report):
    if (not isinstance(report, dict) or type(report.get('schema')) is not int or report.get('schema') != 1
            or report.get('generator') != GENERATOR
            or report.get('base_commit') != BASE_COMMIT or report.get('repository') != 'third-party/mtproto-engine'):
        raise ValueError('Missing or stale client source patch provenance')
    inputs = report.get('input_sha256', {})
    outputs = report.get('postimage_sha256', {})
    if (not isinstance(inputs, dict) or not isinstance(outputs, dict)
            or set(inputs) != {MANIFEST, HELPER, 'build-system/exteraless-patches/mtproto-engine-native-dns.patch'}
            or set(outputs) != {'third-party/mtproto-engine/crates/mtproto-engine/src/' + name + '.rs'
                                for name in ('resolver', 'session_runtime', 'worker')}
            or any(not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{64}', value)
                   for value in [*inputs.values(), *outputs.values()])):
        raise ValueError('Incomplete client source patch fingerprint')
    payload = {key: value for key, value in report.items() if key != 'source_fingerprint'}
    if sha256(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()) != report.get('source_fingerprint'):
        raise ValueError('Client source patch fingerprint mismatch')
    return report


def verify_client_sources(telegram_root):
    return prepare_client_sources(telegram_root, apply=False)


def prepare_client_source_copy(source, destination):
    report = prepare_client_sources(source)
    if Path(source).resolve() != Path(destination).resolve():
        _, _, _, inputs = load_contract(destination)
        if inputs != report['input_sha256']:
            raise ValueError('Relocated client patch inputs differ from the source checkout')
        if prepare_client_sources(destination) != report:
            raise ValueError('Relocated client postimages differ from the source checkout')
    return report
