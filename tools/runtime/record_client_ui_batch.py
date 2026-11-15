"""Bind one frozen recording-driver invocation to the compiled acceptance cohort."""

import argparse
import json
from pathlib import Path
import subprocess
import sys

import client_ui_harness as driver
from client_ui_harness_domains import batch_name, selected_scenarios
from client_ui_harness_inputs import harness_inputs, require_build_identity
from native_test_plan import build_plan, digest, verify_native_results
from verify_client_ui_batches import verify_batch


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('ipa', 'staging-manifest', 'telegram-root', 'output', 'build-report', 'native-tests'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--scenario', action='append', required=True)
    args = parser.parse_args()
    selected = selected_scenarios(args.scenario, driver.SCENARIOS)
    telegram = args.telegram_root.resolve()
    staging_path = telegram / 'build-input/exteraless/runtime-staging.json'
    if args.staging_manifest.resolve() != staging_path:
        parser.error('Use the staged runtime from the claimed acceptance workspace')
    read = lambda path: json.loads(path.read_text(encoding='utf-8'))
    build, native = read(args.build_report), read(args.native_tests)
    staging = driver.load_packaging(telegram).load_staging_manifest(telegram)
    plan, _ = build_plan(telegram)
    identity = require_build_identity(build, plan, harness_inputs(telegram), staging, args.ipa)
    evidence = verify_native_results(native, plan, identity)
    native_sha = digest(args.native_tests)
    command = [sys.executable, str(Path(driver.__file__).resolve()), '--ipa', str(args.ipa.resolve()),
               '--staging-manifest', str(staging_path), '--telegram-root', str(telegram),
               '--output', str(args.output.resolve())]
    for scenario in selected:
        command += ['--scenario', scenario]
    # The existing owned-exec 600s envelope owns this process group. The frozen
    # driver owns its single simulator and each sequential 30s app process.
    subprocess.run(command, check=True)
    require_build_identity(build, build_plan(telegram)[0], harness_inputs(telegram),
                           driver.load_packaging(telegram).load_staging_manifest(telegram), args.ipa)
    if digest(args.native_tests) != native_sha:
        raise ValueError('Native evidence changed during recording')
    report = read(args.output / 'acceptance.json')
    verify_batch(report, selected, build['packaging'], batch_name(selected, driver.SCENARIOS))
    receipt = {'schema': 1, 'acceptanceIdentity': identity, 'nativeResultsSha256': native_sha,
               'nativeEvidence': evidence, 'requestedScenarios': list(selected),
               'batch': batch_name(selected, driver.SCENARIOS), 'command': command,
               'driverSha256': digest(Path(driver.__file__)), 'domainSources': build['domainSources']}
    with (args.output / 'batch-identity.json').open('x', encoding='utf-8') as stream:
        stream.write(json.dumps(receipt, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
