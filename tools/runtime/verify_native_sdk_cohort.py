"""Require all five actual native SDK child reports, markers and source identities."""

import argparse
import hashlib
import json
import math
from pathlib import Path

import check_swift_plugin_embedding as embedding
from fixtures import elyx_developer_probe_driver as elyx_developer

CHILDREN = (
    ('initial-sdk', 'swift-plugin-smoke.json', 'swift-plugin-console.log', 'work_directory', 'EXTERALESS_SWIFT_PLUGIN_PROBE_OK'),
    ('tl-phase2', 'swift-sdk-tl-smoke.json', 'swift-sdk-tl-console.log', 'tl_work_directory', 'EXTERALESS_SWIFT_SDK_TL_PROBE_OK'),
    ('hns-remediation', 'swift-sdk-hns-smoke.json', 'swift-sdk-hns-console.log', 'hns_work_directory', 'EXTERALESS_SWIFT_SDK_HNS_PROBE_OK'),
    ('archive-lifecycle', 'swift-sdk-archive-smoke.json', 'swift-sdk-archive-console.log', 'archive_work_directory', 'EXTERALESS_SWIFT_SDK_ARCHIVE_PROBE_OK'),
    ('elyx-developer', 'swift-sdk-elyx-developer-smoke.json', 'swift-sdk-elyx-developer-console.log', 'elyx_work_directory', 'EXTERALESS_SWIFT_SDK_ELYX_DEVELOPER_PROBE_OK'),
)


def validate_summary(report):
    if (report.get('ok') is not True or report.get('phase') != 'complete'
            or type(report.get('native_children')) is not int or report['native_children'] != len(CHILDREN)
            or any(report.get(name) is not True for name in ('tl_phase2', 'hns_remediation', 'archive_lifecycle', 'elyx_developer'))):
        raise ValueError('A complete five-child result is required; four-child success is not acceptance')
    for key, name in (('tl_report', CHILDREN[1][1]), ('hns_report', CHILDREN[2][1]),
                      ('archive_report', CHILDREN[3][1]), ('elyx_report', CHILDREN[4][1])):
        if report.get(key) != name:
            raise ValueError('Native child report selection differs: ' + key)


def verify(directory):
    directory = Path(directory).resolve()
    read = lambda name: json.loads((directory / name).read_text(encoding='utf-8'))
    inputs = read('build-inputs.json')
    reports = [read(row[1]) for row in CHILDREN]
    validate_summary(reports[0])
    if inputs.get('native_children') != len(CHILDREN) or inputs.get('runtime_timeout_seconds') != 30:
        raise ValueError('Native build inputs do not declare five independent 30-second processes')
    if inputs.get('elyx_required_checks') != list(elyx_developer.REQUIRED_CHECKS):
        raise ValueError('Fifth-child semantic requirements differ from the current frozen reader')
    if inputs.get('first_child_required_sdk_observations') != list(embedding.REQUIRED_SDK_OBSERVATIONS):
        raise ValueError('Original SDK/actual Darwin FD observation requirements changed')
    work = [Path(inputs[row[3]]).resolve() for row in CHILDREN]
    if len(set(work)) != len(CHILDREN) or any(not path.is_relative_to(directory) or path == directory for path in work):
        raise ValueError('Each native child needs its own owned run directory')
    python_root = Path(inputs['python_root']).resolve()
    validators = (embedding.validate_report, embedding.validate_tl_report, embedding.validate_hns_report,
                  embedding.validate_archive_report, elyx_developer.validate_report)
    evidence = []
    for (name, report_file, log_file, _, marker), report, folder, validator in zip(CHILDREN, reports, work, validators):
        validator(report, python_root, folder)
        seconds = report.get('native_process_seconds')
        if (report.get('runtime_timeout_seconds') != 30 or type(seconds) not in (float, int)
                or not math.isfinite(seconds) or not 0 < seconds <= 30):
            raise ValueError('Native child exceeded its process budget: ' + name)
        if marker not in (directory / log_file).read_text(encoding='utf-8').splitlines():
            raise ValueError('Missing actual native child completion marker: ' + name)
        evidence.append({'child': name, 'report': report_file, 'sha256': embedding.digest(directory / report_file),
                         'console': log_file, 'marker': marker, 'process_seconds': seconds})
    # Source and actual staged copies are checked after all native readers too.
    embedding.validate_cohort_inputs(inputs.get('source_sha256', {}))
    copies = inputs.get('staged_copies', [])
    if len(copies) != 9 or any(inputs['source_sha256'].get(row['source']) != row.get('sha256')
                                or inputs['source_sha256'].get(row['staged']) != row.get('sha256') for row in copies):
        raise ValueError('An actual native child helper/plugin copy is absent from the input seal')
    return {'status': 'five-native-children-passed', 'native_children': len(CHILDREN),
            'native_execution_verified': True, 'uikit_execution_verified': False,
            'children': evidence, 'read_tickets': reports[-1]['read_tickets'],
            'build_inputs_sha256': embedding.digest(directory / 'build-inputs.json'),
            'source_inputs': len(inputs['source_sha256']),
            'source_sha256': hashlib.sha256(json.dumps(inputs['source_sha256'], sort_keys=True).encode()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args()
    report = verify(args.directory)
    with (args.directory / 'five-child-acceptance.json').open('x', encoding='utf-8') as stream:
        stream.write(json.dumps(report, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
