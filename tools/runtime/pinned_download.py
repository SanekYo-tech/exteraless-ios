"""Bounded, checksum-verified build downloads; never import downloaded code."""

import hashlib
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request


CHUNK = 1024 * 1024


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(CHUNK), b''):
            value.update(block)
    return value.hexdigest()


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme != 'https':
            raise ValueError('A pinned download redirected away from HTTPS')
        return super().redirect_request(request, fp, code, message, headers, newurl)


def fetch(artifact, cache, *, offline=False, maximum=96 * 1024 * 1024, transport='urllib'):
    """Fetch one artifact at a time, checking cached files as well as new ones.

    Anaconda's signed object-store redirects are accepted over HTTPS; the
    independently pinned SHA-256 remains mandatory after every redirect.
    """
    filename, expected = artifact['filename'], artifact['sha256']
    url = urllib.parse.urlsplit(artifact['url'])
    if (Path(filename).name != filename or '/' in filename or '\\' in filename
            or not re.fullmatch(r'[0-9a-f]{64}', expected)
            or url.scheme != 'https' or url.username or url.password):
        raise ValueError('Invalid pinned artifact identity')
    size = artifact.get('size')
    if size is not None and (type(size) is not int or not 0 < size <= maximum):
        raise ValueError('Pinned artifact exceeds the download limit')
    cache = Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / filename

    def verify(candidate):
        if candidate.is_symlink() or not candidate.is_file() or candidate.stat().st_size > maximum:
            raise ValueError('Invalid cached artifact: ' + filename)
        if size is not None and candidate.stat().st_size != size:
            raise ValueError('Pinned artifact size mismatch: ' + filename)
        if digest(candidate) != expected:
            raise ValueError('Pinned artifact SHA-256 mismatch: ' + filename)

    if path.exists() or path.is_symlink():
        verify(path)
        return path
    if offline:
        raise ValueError('Pinned artifact is not cached: ' + filename)
    if transport not in ('urllib', 'curl'):
        raise ValueError('Unsupported pinned download transport')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=filename + '.', suffix='.download', dir=cache, delete=False) as output:
            temporary = Path(output.name)
        if transport == 'curl':
            subprocess.run([
                'curl', '--fail', '--silent', '--show-error', '--location',
                '--proto', '=https', '--proto-redir', '=https',
                '--max-time', '120', '--max-filesize', str(size or maximum),
                '--output', str(temporary), artifact['url'],
            ], check=True, timeout=125)
        else:
            request = urllib.request.Request(artifact['url'], headers={
                'User-Agent': 'exteraless-dependencies-build', 'Accept-Encoding': 'identity',
            })
            deadline, total = time.monotonic() + 120, 0
            with temporary.open('wb') as output, urllib.request.build_opener(HTTPSRedirect()).open(request, timeout=30) as response:
                while block := response.read(CHUNK):
                    total += len(block)
                    if total > (size or maximum) or time.monotonic() > deadline:
                        raise ValueError('Pinned download exceeded its size/time limit: ' + filename)
                    output.write(block)
        verify(temporary)
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return path
