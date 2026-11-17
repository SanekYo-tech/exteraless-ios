"""Explicit unsigned packaging for the pinned rules_apple, without keychains.

The six iOS packaging guards use the same approach as VoidGram's unsigned
build patch. Unsigned copy-only archives request Darwin copy-on-write clones.
The normal signed path is selected unless Make.py receives --unsigned. Work
on a disposable checkout/copy: the patch is applied to the submodule worktree,
not committed as a different upstream gitlink.
"""

import hashlib
import json
from pathlib import Path
import re
import subprocess


RULES_APPLE_REVISION = '485016eb5b0948cc17307064e7977a6d68e94046'
IOS_RULES_SHA256 = 'b6776b1c10a2c965f01259dd95ebe1b045afc5e22b3446b8ae81d44f11c3a7da'
IOS_RULES_PATCHED_SHA256 = '4cc092a71d45c778af7f4b13e67e257ec0fe8a5254417181f638c5ce66703f9d'
CODESIGNING_SUPPORT_SHA256 = '029e3ec958b6c07f7692b248438f1a8a28e9976fcfc453e1e170cca409ff0a55'
CODESIGNING_SUPPORT_PATCHED_SHA256 = '81f314b0306c4e5127acf8c57c195390ca864de96285712bf4f54a8322c82dbc'
UNSIGNED_FEATURE = 'exteraless_unsigned_compilation'
_RULES_IMAGES = {
    'apple/internal/ios_rules.bzl': (IOS_RULES_SHA256, IOS_RULES_PATCHED_SHA256),
    'apple/internal/codesigning_support.bzl': (
        CODESIGNING_SUPPORT_SHA256, CODESIGNING_SUPPORT_PATCHED_SHA256),
}


def _source_sha256(path):
    # Match the upstream LF blob, including its final newline. Do not strip
    # whitespace or reinterpret Starlark escapes while checking source identity.
    return hashlib.sha256(path.read_bytes().replace(b'\r\n', b'\n')).hexdigest()


def prepare_unsigned_rules(base_path):
    """Apply the checked-in patch idempotently, verifying both pinned images.

Use a content hash rather than .git: the canonical CI source copy deliberately
does not contain dangling submodule .git pointers to the checkout directory.
Line endings are normalized for the hash, so Windows can run the same check.
Also accept the exact historical six-guard patch as an upgrade input.
"""
    base = Path(base_path)
    rules = base / 'build-system/bazel-rules/rules_apple'
    patch = base / 'build-system/patches/unsigned-rules-apple.patch'
    pending = []
    for name, (pristine, patched) in _RULES_IMAGES.items():
        source = rules / name
        if not source.is_file():
            raise RuntimeError('rules_apple is missing {}; run git submodule update --init --recursive'.format(name))
        digest = _source_sha256(source)
        if digest not in (pristine, patched):
            raise RuntimeError('Unsigned packaging expects rules_apple {}; review the patch for this source revision ({} sha256={})'.format(
                RULES_APPLE_REVISION, name, digest))
        if digest == pristine:
            pending.append(name)
    if pending == ['apple/internal/ios_rules.bzl']:
        raise RuntimeError('The unsigned rules_apple patch is only partially applied')
    if not pending:
        print('Unsigned packaging patch already present')
        return
    # Restrict upgrades to known pristine files; never reapply the six guards
    # on an existing unsigned checkout, or touch any other vendored source.
    includes = ['--include=' + name for name in pending]
    for flags in (['--check'], []):
        subprocess.run(
            ['git', 'apply', '--ignore-space-change'] + includes + flags + [str(patch.resolve())],
            cwd=rules, check=True
        )
    for name, (_, patched) in _RULES_IMAGES.items():
        if _source_sha256(rules / name) != patched:
            raise RuntimeError('Unsigned packaging patch did not produce the expected source: ' + name)
    print('Unsigned packaging: pinned rules_apple patch applied')


def validate_unsigned_actions(graph_path):
    """Reject certificate-signing actions before the expensive compilation.

    The full aquery graph uses the SAME device target and flags as the build.
    Pinned rules_apple omits should_sign on unsigned actions (there is no
    should_not_sign token). Inspect imported frameworks and generated scripts
    as well, so a main-app-only toggle cannot hide extension signing.
"""
    graph_path = Path(graph_path)
    graph = json.loads(graph_path.read_text(encoding='utf-8'))
    actions = graph.get('actions', [])
    targets = {str(item['id']): item['label'] for item in graph.get('targets', [])}
    checked, failures = [], []
    imported = 0
    for fragment in graph.get('pathFragments', []):
        if fragment.get('label', '').endswith('.mobileprovision'):
            failures.append('Action graph still contains a provisioning profile: ' + fragment['label'])
    prohibited = {'FindProvisioningProfile', 'ExtractFromProvisioningProfile', 'SignBinary', 'PrebuiltWatchosPatchSign'}
    for action in actions:
        label = targets.get(str(action.get('targetId')), '<unknown target>')
        mnemonic = action.get('mnemonic', '')
        arguments = list(action.get('arguments', []))
        for params in action.get('paramFiles', []):
            arguments.extend(params.get('arguments', []))
        if mnemonic in prohibited:
            failures.append('{} schedules {}'.format(label, mnemonic))
        if mnemonic == 'ProcessAndSign':
            checked.append(label)
            if not arguments:
                failures.append('{} has no command line to inspect'.format(label))
            if 'should_sign' in arguments:
                failures.append('{} still selects signing'.format(label))
        if mnemonic == 'ImportedDynamicFrameworkProcessor':
            imported += 1
            if '--disable_signing' not in arguments:
                failures.append('{} imports a framework with signing enabled'.format(label))
        for substitution in action.get('substitutions', []):
            if substitution.get('key') == '%signing_command_lines%' and substitution.get('value', '').strip():
                failures.append('{} generated non-empty signing commands'.format(label))
        script = action.get('templateContent', '')
        for substitution in action.get('substitutions', []):
            script = script.replace(substitution.get('key', ''), substitution.get('value', ''))
        if action.get('isExecutable'):
            script += '\n' + action.get('fileContents', '')
        # Look at commands, not comments mentioning codesign in a template.
        active_lines = '\n'.join(line for line in script.splitlines() if not line.lstrip().startswith('#'))
        if re.search(r'(?:^|[\s\"\'])/usr/bin/codesign(?:[\s\"\']|$)', active_lines):
            failures.append('{} generated a codesign invocation'.format(label))
        if '--mobileprovision' in arguments or '--provisioning_profile' in arguments:
            failures.append('{} passes a profile to a tool'.format(label))
    expected = {'Telegram', 'ShareExtension', 'NotificationContentExtension',
                'NotificationServiceExtensionv1', 'IntentsExtension', 'WidgetExtension',
                'BroadcastUploadExtension'}
    present = {label.split('//Telegram:', 1)[1] for label in checked if '//Telegram:' in label}
    if not checked:
        failures.append('No ProcessAndSign actions found')
    missing = expected - present
    if missing:
        failures.append('Missing app/extension packaging actions: ' + ', '.join(sorted(missing)))
    report = {
        'signing': 'unsigned' if not failures else 'invalid',
        'total_actions': len(actions), 'packaging_actions': len(checked),
        'imported_framework_actions': imported, 'targets': sorted(set(checked)),
        'errors': sorted(set(failures)),
    }
    (graph_path.parent / 'unsigned-preflight.json').write_text(
        json.dumps(report, indent=2) + '\n', encoding='utf-8'
    )
    if failures:
        raise RuntimeError('Unsigned preflight failed:\n' + '\n'.join(report['errors']))
    print('Unsigned preflight: {} packaging actions require no identity'.format(len(checked)))
    return report
