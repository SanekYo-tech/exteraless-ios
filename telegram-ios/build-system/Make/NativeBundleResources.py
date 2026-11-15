"""Common Make/harness source and IPA checks for pinned Font/Monet resources."""

import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import zipfile

CONTRACT = 'build-system/exteraless/native-bundle-resources.json'


def source_resources(telegram):
    telegram = Path(telegram)
    data = (telegram / CONTRACT).read_bytes()
    contract = json.loads(data)
    if contract.get('schema') != 1:
        raise ValueError('Unknown native resource contract')
    for resources in contract['groups'].values():
        for record in resources:
            path = PurePosixPath(record['source'])
            if path.is_absolute() or '..' in path.parts or '\\' in record['source']:
                raise ValueError('Invalid native resource source path')
            source = telegram / record['source']
            if (not source.is_file() or source.stat().st_size != record['size']
                    or hashlib.sha256(source.read_bytes()).hexdigest() != record['sha256']):
                raise ValueError('Native resource source pin differs: ' + record['source'])
    return contract, hashlib.sha256(data).hexdigest()


def verify_archive(ipa, contract, selection):
    expected = {}
    bundles = contract['archives'][selection]
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate native resource archive entries')
        for bundle, groups in bundles.items():
            info = plistlib.loads(archive.read(bundle + '/Info.plist'))
            registered = {PurePosixPath(name).name for name in info.get('UIAppFonts', [])}
            for group in groups:
                for record in contract['groups'][group]:
                    name = PurePosixPath(record['source']).name
                    path = bundle + '/' + name
                    if name.endswith('.ttf') and name in registered:
                        raise ValueError('Roboto must use explicit Display registration, not UIAppFonts')
                    if path not in names or archive.getinfo(path).file_size != record['size']:
                        raise ValueError('Native resource missing or not at its process bundle root: ' + path)
                    if hashlib.sha256(archive.read(path)).hexdigest() != record['sha256']:
                        raise ValueError('Native bundled resource hash differs: ' + path)
                    expected[path] = record['sha256']
        basenames = {PurePosixPath(path).name for path in expected}
        actual = {name for name in names if not name.endswith('/') and PurePosixPath(name).name in basenames}
        if actual != set(expected):
            raise ValueError('Unexpected duplicate/nested native resource placement')
    return {'selection': selection, 'files': expected, 'bundles': list(bundles), 'status': 'verified'}


def verify_native_bundle_resources(ipa, telegram, selection):
    contract, sha = source_resources(telegram)
    return dict(verify_archive(ipa, contract, selection), contract_sha256=sha)
