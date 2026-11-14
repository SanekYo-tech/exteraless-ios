"""Explicit unsigned packaging for the pinned rules_apple, without keychains.

The six iOS packaging guards use the same approach as VoidGram's unsigned
build patch. The normal signed path is selected unless Make.py receives
--unsigned. Work on a disposable checkout/copy: the patch is applied to the
submodule worktree, not committed as a different upstream gitlink.
"""

import hashlib
import json
from pathlib import Path
import re
import subprocess


RULES_APPLE_REVISION = '485016eb5b0948cc17307064e7977a6d68e94046'
IOS_RULES_SHA256 = 'b6776b1c10a2c965f01259dd95ebe1b045afc5e22b3446b8ae81d44f11c3a7da'
UNSIGNED_FEATURE = 'exteraless_unsigned_compilation'
_ORIGINAL = 'if platform_prerequisites.platform.is_device:'
_GUARDED = 'if platform_prerequisites.platform.is_device and "{}" not in features:'.format(UNSIGNED_FEATURE)


def prepare_unsigned_rules(base_path):
    """Apply the checked-in patch idempotently, verifying its pinned input.

Use a content hash rather than .git: the canonical CI source copy deliberately
does not contain dangling submodule .git pointers to the checkout directory.
Line endings are normalized for the hash, so Windows can run the same check.
"""
    base = Path(base_path)
    rules = base / 'build-system/bazel-rules/rules_apple'
    source = rules / 'apple/internal/ios_rules.bzl'
    patch = base / 'build-system/patches/unsigned-rules-apple.patch'
    if not source.is_file():
        raise RuntimeError('rules_apple is missing; run git submodule update --init --recursive')
    text = source.read_text(encoding='utf-8')
    pristine = text.replace(_GUARDED, _ORIGINAL)
    if hashlib.sha256(pristine.encode('utf-8')).hexdigest() != IOS_RULES_SHA256:
        raise RuntimeError('Unsigned packaging expects rules_apple {}; review the patch for this source revision'.format(RULES_APPLE_REVISION))
    if text != pristine:
        if text.count(_GUARDED) != 6:
            raise RuntimeError('The unsigned rules_apple patch is only partially applied')
        print('Unsigned packaging patch already present')
        return
    for flags in (['--check'], []):
        subprocess.run(
            ['git', 'apply', '--ignore-space-change'] + flags + [str(patch.resolve())],
            cwd=rules, check=True
        )
    patched = source.read_text(encoding='utf-8')
    if patched.count(_GUARDED) != 6 or patched.replace(_GUARDED, _ORIGINAL) != pristine:
        raise RuntimeError('Unsigned packaging patch did not produce the expected source')
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
