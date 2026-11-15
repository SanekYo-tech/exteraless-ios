"""Check resource-bearing XCTest hosts without changing production Make contracts."""

import json
from pathlib import Path
import plistlib
import zipfile

from native_bundle_resources import source_resources, verify_archive
from native_test_plan import digest


def verify_test_host_resources(telegram, plan):
    telegram = Path(telegram)
    contract, contract_sha = source_resources(telegram)
    hosts = {target['host']: target['host_bundle_id'] for target in plan['targets']}
    if not hosts:
        raise ValueError('Native test plan has no resource-bearing hosts')
    reports = {}
    for label, bundle_id in sorted(hosts.items()):
        package, name = label[2:].split(':', 1)
        archive = telegram / 'bazel-bin' / package / (name + '.ipa')
        root = 'Payload/' + name + '.app'
        # The shared production groups stay pinned; this adds the Composer test
        # host selection only to this read-only invocation's local contract.
        selection = dict(contract, archives={name: {root: ['fonts', 'monet']}})
        resources = verify_archive(archive, selection, name)
        with zipfile.ZipFile(archive) as bundle:
            info = plistlib.loads(bundle.read(root + '/Info.plist'))
            if info.get('CFBundleIdentifier') != bundle_id:
                raise ValueError('Native test host bundle identity differs: ' + label)
            required = ('PresentationStrings.data', 'en.lproj/Localizable.strings', 'Assets.car')
            for resource in required:
                if bundle.getinfo(root + '/' + resource).file_size <= 0:
                    raise ValueError('Empty native host asset/string resource: ' + resource)
        reports[label] = {'bundle_id': bundle_id, 'ipa_sha256': digest(archive),
                          'contract_sha256': contract_sha, 'resources': resources,
                          'asset_paths': list(required)}
    return reports
