"""Join explicit new witness batches with the retained base-eight receipt."""

import argparse
import json
from pathlib import Path
import uuid

from client_ui_harness_domains import check_manifest
from client_ui_harness_supplements import SUPPLEMENT_BATCHES, SUPPLEMENT_SCENARIOS, check_sources
from client_ui_harness_map import (MAP_SCENARIOS, MAP_BATCH, MAP_BOUNDARY, check_map_recording_summary,
                                    verify_map_recording)
from native_test_plan import digest, verify_native_results
from verify_client_ui_batches import verify_batch


def verify_supplements(build, native, base, reports, identities, devices, native_sha):
    identity = build['acceptanceIdentity']
    if (base.get('status') != 'recorded-awaiting-visual-review' or base.get('semanticPassed') is not True
            or base.get('acceptanceIdentity') != identity or base.get('ipaSha256') != identity['ipaSha256']):
        raise ValueError('The unchanged base-eight recording receipt must pass for this same IPA')
    evidence = verify_native_results(native, build['nativeTestPlan'], identity)
    sources = check_manifest(build['domainSources'])
    check_sources(sources, SUPPLEMENT_SCENARIOS)
    count = len(SUPPLEMENT_BATCHES)
    if len(reports) != count or len(identities) != count or len(devices) != count:
        raise ValueError('Four Reset batches, secondary-trust and Map attribution are mandatory')
    if base.get('nativeResultsSha256') != native_sha:
        raise ValueError('Base and supplement native execution evidence differs')
    base_devices = base.get('simulatorIds', [])
    if len(base_devices) != 3:
        raise ValueError('The base-eight receipt must retain its three simulator identities')
    identifiers = [str(uuid.UUID(value)) for value in base_devices]
    identifiers.extend(str(uuid.UUID(device['udid'])) for device in devices)
    if len(set(identifiers)) != 3 + count:
        raise ValueError('Every base and supplemental invocation requires a distinct fresh simulator')
    for report, receipt, (_, name, scenarios) in zip(reports, identities, SUPPLEMENT_BATCHES):
        verify_batch(report, scenarios, build['packaging'], name)
        if (receipt.get('schema') != 1 or receipt.get('acceptanceIdentity') != identity
                or receipt.get('nativeResultsSha256') != native_sha or receipt.get('nativeEvidence') != evidence
                or receipt.get('batch') != name or receipt.get('requestedScenarios') != list(scenarios)
                or receipt.get('driverSha256') != build['driverSha256']
                or check_manifest(report.get('domainSources', {})) != sources
                or check_manifest(receipt.get('domainSources', {})) != sources):
            raise ValueError('Supplement source/driver/native identity differs from the compiled cohort')
        if scenarios == MAP_SCENARIOS:
            check_map_recording_summary(report['recordings'][0], sources)
    return {'status': 'recorded-awaiting-visual-review', 'semanticPassed': True,
            'visualReview': 'pending-recorded-frame-review', 'acceptanceIdentity': identity,
            'nativeEvidence': evidence, 'baseSceneCount': 8, 'resetSceneCount': 10, 'trustSecondarySceneCount': 1,
            'mapAttributionSceneCount': 1, 'sceneCount': 8 + len(SUPPLEMENT_SCENARIOS),
            'resetPlusBaseSceneCount': 18, 'processDeadlineSeconds': 30,
            'nativeResultsSha256': native_sha, 'domainSourceSha256': sources['sha256'],
            'mapNetworkBoundary': MAP_BOUNDARY,
            'baseBatches': base['batches'], 'supplementBatches': [
                {'directory': directory, 'batch': name, 'scenarios': list(scenarios)}
                for directory, name, scenarios in SUPPLEMENT_BATCHES], 'simulatorIds': identifiers}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('build-report', 'native-tests', 'base-batches', 'supplements', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    read = lambda path: json.loads(path.read_text(encoding='utf-8'))
    folders = [args.supplements / name for name, _, _ in SUPPLEMENT_BATCHES]
    build = read(args.build_report)
    reports = [read(folder / 'acceptance.json') for folder in folders]
    report = verify_supplements(build, read(args.native_tests), read(args.base_batches), reports,
        [read(folder / 'batch-identity.json') for folder in folders],
        [read(folder / 'owned-device.json') for folder in folders], digest(args.native_tests))
    map_index = SUPPLEMENT_BATCHES.index(MAP_BATCH)
    verify_map_recording(folders[map_index] / MAP_SCENARIOS[0], build['domainSources'], reports[map_index]['recordings'][0])
    with args.output.open('x', encoding='utf-8') as stream:
        stream.write(json.dumps(report, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
