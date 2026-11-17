"""Pinned packaging replay and owned-file copy tests; no Bazel/SDK/app build.

The Darwin test executes the command extracted from the patched rule, probes
public clonefile(2), and measures statvfs deltas against the original cp -p.
st_blocks is recorded only as context: it does not establish APFS sharing.
Set EXTERALESS_ARCHIVE_COPY_REPORT to retain the physical-allocation receipt.
"""

import ast
import contextlib
import ctypes
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import plistlib
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'telegram-ios/build-system/Make'))
import UnsignedBuild as unsigned

RULES_RELATIVE = Path('build-system/bazel-rules/rules_apple')
PATCH_RELATIVE = Path('build-system/patches/unsigned-rules-apple.patch')
IMAGES = {
    'ios_rules.bzl': (unsigned.IOS_RULES_SHA256, unsigned.IOS_RULES_PATCHED_SHA256),
    'codesigning_support.bzl': (
        unsigned.CODESIGNING_SUPPORT_SHA256, unsigned.CODESIGNING_SUPPORT_PATCHED_SHA256),
}
BASH = shutil.which('bash')
if BASH is None and os.name == 'nt':
    candidate = Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'Git/bin/bash.exe'
    if candidate.is_file():
        BASH = str(candidate)


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def source_hash(path):
    return hashlib.sha256(path.read_bytes().replace(b'\r\n', b'\n')).hexdigest()


def rules_fixture(root):
    """Replay only exact pinned preimages, in a disposable non-git source copy."""
    patch_file = root / PATCH_RELATIVE
    patch_file.parent.mkdir(parents=True)
    shutil.copyfile(ROOT / 'telegram-ios' / PATCH_RELATIVE, patch_file)
    internal = root / RULES_RELATIVE / 'apple/internal'
    internal.mkdir(parents=True)
    for name, (pristine, patched) in IMAGES.items():
        source = ROOT / 'telegram-ios' / RULES_RELATIVE / 'apple/internal' / name
        text = source.read_text(encoding='utf-8')
        digest = hashlib.sha256(text.encode('utf-8')).hexdigest()
        if digest == patched:
            # A local Make.py run may already have patched this gitlink. Read
            # its pinned blob, without resetting or modifying the checkout.
            text = subprocess.check_output(
                ['git', 'show', unsigned.RULES_APPLE_REVISION + ':apple/internal/' + name],
                cwd=source.parents[2], timeout=10,
            ).decode('utf-8')
        if hashlib.sha256(text.encode('utf-8')).hexdigest() != pristine:
            raise AssertionError('Fixture is not the pinned rules_apple source: ' + name)
        (internal / name).write_text(text, encoding='utf-8', newline='\n')
    return internal


def prepare(root):
    with contextlib.redirect_stdout(io.StringIO()):
        unsigned.prepare_unsigned_rules(root)


class Actions:
    def __init__(self):
        self.calls = []

    def run_shell(self, **kwargs):
        self.calls.append(('run_shell', kwargs))

    def expand_template(self, **kwargs):
        self.calls.append(('expand_template', kwargs))

    def run(self, **kwargs):
        self.calls.append(('run', kwargs))

    def apple_run(self, **kwargs):
        # The action recorder itself is not part of the action's identity.
        kwargs.pop('actions')
        self.calls.append(('apple_run', kwargs))


def archive_action(text, source='input.zip', output='output.zip', *,
                   features=(unsigned.UNSIGNED_FEATURE,), signing=False,
                   processor=False, compress=None, mode='dbg'):
    """Execute the actual rule function's Python-compatible Starlark subset.

    Only its external providers/action sinks are fixtures. In particular,
    has_work, feature selection, quoting and the shell command are real code.
    This source-contract test is not represented as a Bazel analysis/build.
    """
    parsed = ast.parse(text)
    function = next(node for node in parsed.body if isinstance(node, ast.FunctionDef)
                    and node.name == '_post_process_and_sign_archive_action')
    actions = Actions()
    scope = {
        '_codesigning_command': lambda **kwargs: 'fixture-signing' if signing else '',
        'defines': SimpleNamespace(bool_value=lambda config_vars, define_name, default:
                                   config_vars.get(define_name, default)),
        'intermediates': SimpleNamespace(file=lambda **kwargs: SimpleNamespace(path='process.sh')),
        'shell': SimpleNamespace(quote=shlex.quote),
        'shared_environment': SimpleNamespace(default_env={}),
        'apple_support': SimpleNamespace(run=actions.apple_run),
    }
    exec(compile(ast.Module(body=[function], type_ignores=[]), '<pinned-rule-function>', 'exec'), scope)
    config_vars = {'COMPILATION_MODE': mode}
    if compress is not None:
        config_vars['apple.compress_ipa'] = compress
    scope[function.name](
        actions=actions, archive_codesigning_path='Payload/Owned.app', codesign_inputs=[],
        codesigningtool=SimpleNamespace(executable='fixture-tool'), codesignopts=[],
        features=list(features), frameworks_path='Frameworks', input_archive=SimpleNamespace(path=source),
        ipa_post_processor=SimpleNamespace(path='fixture-processor') if processor else None,
        label_name='Owned', output_archive=SimpleNamespace(path=output), output_archive_root_path='root',
        output_discriminator=None,
        platform_prerequisites=SimpleNamespace(config_vars=config_vars, platform=SimpleNamespace(is_device=False),
                                               apple_fragment=None, xcode_version_config=None),
        process_and_sign_template='template', provisioning_profile=None, rule_descriptor=None, signed_frameworks=[],
    )
    return actions.calls


def run_command(command, root, env=None):
    # env={} matches the ProcessAndSign action's env - on the actual Darwin
    # runner. Git Bash needs Windows' system environment to start local tests.
    if env is None:
        env = os.environ.copy() if os.name == 'nt' else {}
    return subprocess.run([BASH, '-c', command], cwd=root, env=env,
                          text=True, capture_output=True, timeout=15)


def write_archive(path, mib_per_member=1):
    chunk_size = 1024 * 1024
    pattern = b'exteraless-owned-stored-archive-fixture\n'
    compressible = (pattern * (chunk_size // len(pattern) + 1))[:chunk_size]
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as archive:
        for name, executable, repeated in (
                ('Payload/Owned.app/Owned', True, False),
                ('Payload/Owned.app/Resources/fixture.dat', False, True)):
            info = zipfile.ZipInfo(name, date_time=(2000, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | (0o750 if executable else 0o640)) << 16
            with archive.open(info, 'w') as member:
                for index in range(mib_per_member):
                    chunk = compressible if repeated else hashlib.shake_256(
                        b'exteraless-owned-incompressible-' + str(index).encode('ascii')).digest(chunk_size)
                    member.write(chunk)
    # Windows _commit/FlushFileBuffers requires a writable file descriptor.
    with path.open('r+b') as stream:
        os.fsync(stream.fileno())
    path.chmod(0o640)
    os.utime(path, ns=(946684800123456789, 946684800123456789))


def attributes(path):
    value = path.stat()
    result = {'size': value.st_size, 'mode': stat.S_IMODE(value.st_mode),
              'uid': value.st_uid, 'gid': value.st_gid, 'mtimeNs': value.st_mtime_ns}
    if sys.platform == 'darwin':
        result['flags'] = value.st_flags
        result['xattrs'] = {name: os.getxattr(path, name).hex() for name in os.listxattr(path)}
        result['acl'] = subprocess.check_output(
            ['/bin/ls', '-le', str(path)], text=True, timeout=5).splitlines()[1:]
    return result


class UnsignedArchiveCopyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='unsigned-archive-', dir=os.environ.get('RUNNER_TEMP'))
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.internal = rules_fixture(self.root)
        self.original = (self.internal / 'codesigning_support.bzl').read_text(encoding='utf-8')

    def patched(self):
        prepare(self.root)
        return (self.internal / 'codesigning_support.bzl').read_text(encoding='utf-8')

    def assert_postimages(self):
        for name, (_, expected) in IMAGES.items():
            self.assertEqual(source_hash(self.internal / name), expected, name)

    def test_pinned_replay_and_idempotence(self):
        prepare(self.root)
        self.assert_postimages()
        before = {p.name: p.read_bytes() for p in self.internal.iterdir()}
        with patch.object(unsigned.subprocess, 'run', side_effect=AssertionError('already patched')):
            prepare(self.root)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.internal.iterdir()})

    def test_exact_historical_six_guard_upgrade(self):
        ios = self.internal / 'ios_rules.bzl'
        original = ios.read_text(encoding='utf-8')
        # These are exactly the six provisioning guards in the old patch, not
        # every is_device condition (the upstream file has eight of those).
        context = ('if platform_prerequisites.platform.is_device:\n'
                   '        processor_partials.append(\n'
                   '            partials.provisioning_profile_partial(')
        self.assertEqual(original.count(context), 6)
        expected = original.replace(context, context.replace(
            'is_device:', 'is_device and "exteraless_unsigned_compilation" not in features:'))
        subprocess.run(['git', 'apply', '--include=apple/internal/ios_rules.bzl',
                        str(self.root / PATCH_RELATIVE)], cwd=self.root / RULES_RELATIVE, check=True, timeout=10)
        self.assertEqual(ios.read_text(encoding='utf-8'), expected)
        self.assertEqual(source_hash(ios), unsigned.IOS_RULES_PATCHED_SHA256)
        before = ios.read_bytes(), ios.stat().st_ino, ios.stat().st_mtime_ns
        prepare(self.root)
        self.assert_postimages()
        self.assertEqual(before, (ios.read_bytes(), ios.stat().st_ino, ios.stat().st_mtime_ns))

    def test_both_sources_are_checked_before_mutation(self):
        for name in IMAGES:
            with self.subTest(name=name):
                path = self.internal / name
                pristine = path.read_bytes()
                path.write_bytes(pristine + b'\n# different upstream\n')
                before = {p.name: p.read_bytes() for p in self.internal.iterdir()}
                with patch.object(unsigned.subprocess, 'run', side_effect=AssertionError('must not apply')):
                    with self.assertRaisesRegex(RuntimeError, 'review the patch'):
                        prepare(self.root)
                self.assertEqual(before, {p.name: p.read_bytes() for p in self.internal.iterdir()})
                path.write_bytes(pristine)

    def test_partial_guards_and_inverse_partial_patch_are_rejected(self):
        ios = self.internal / 'ios_rules.bzl'
        original = ios.read_text(encoding='utf-8')
        ios.write_text(original.replace('if platform_prerequisites.platform.is_device:',
                       'if platform_prerequisites.platform.is_device and "exteraless_unsigned_compilation" not in features:', 1),
                       encoding='utf-8', newline='\n')
        with self.assertRaisesRegex(RuntimeError, 'review the patch'):
            prepare(self.root)
        ios.write_text(original, encoding='utf-8', newline='\n')
        subprocess.run(['git', 'apply', '--include=apple/internal/codesigning_support.bzl',
                        str(self.root / PATCH_RELATIVE)], cwd=self.root / RULES_RELATIVE, check=True, timeout=10)
        with self.assertRaisesRegex(RuntimeError, 'only partially applied'):
            prepare(self.root)
        self.assertEqual(ios.read_text(encoding='utf-8'), original)

    def test_missing_second_source_cannot_apply_first_source(self):
        (self.internal / 'codesigning_support.bzl').unlink()
        with patch.object(unsigned.subprocess, 'run', side_effect=AssertionError('must not apply')):
            with self.assertRaisesRegex(RuntimeError, 'rules_apple is missing'):
                prepare(self.root)
        self.assertEqual(source_hash(self.internal / 'ios_rules.bzl'), unsigned.IOS_RULES_SHA256)

    def test_unexpected_patch_postimage_is_rejected(self):
        path = self.root / PATCH_RELATIVE
        path.write_text(path.read_text(encoding='utf-8').replace('clone requested;', 'clone claimed;'),
                        encoding='utf-8', newline='\n')
        with self.assertRaisesRegex(RuntimeError, 'did not produce the expected source'):
            prepare(self.root)

    def test_crlf_source_identity_and_replay(self):
        for path in self.internal.iterdir():
            path.write_bytes(path.read_bytes().replace(b'\n', b'\r\n'))
        prepare(self.root)
        self.assert_postimages()
        prepare(self.root)

    def test_only_existing_feature_and_no_work_select_clone_command(self):
        patched = self.patched()
        for settings in ({'features': ()}, {'signing': True}, {'processor': True},
                         {'compress': True}, {'mode': 'opt'},
                         {'features': ('disable_legacy_signing',)},
                         {'features': (), 'mode': 'opt', 'compress': False}):
            with self.subTest(settings=settings):
                self.assertEqual(archive_action(self.original, **settings), archive_action(patched, **settings))
        original = archive_action(self.original)
        changed = archive_action(patched)
        self.assertEqual(len(changed), 1)
        self.assertEqual(changed[0][0], 'run_shell')
        before = dict(original[0][1])
        after = dict(changed[0][1])
        self.assertNotEqual(before.pop('command'), after.pop('command'))
        self.assertEqual(before, after)  # inputs, outputs, mnemonic, progress

    @unittest.skipUnless(BASH, 'requires a POSIX shell (Git Bash is sufficient for byte checks)')
    def test_real_shell_preserves_archive_bytes_attributes_and_separate_inode(self):
        source = self.root / "input 'quoted' $archive.zip"
        output = self.root / "output 'quoted' $archive.zip"
        write_archive(source)
        expected = attributes(source)
        source_inode = source.stat().st_ino
        command = archive_action(self.patched(), source.name, output.name)[0][1]['command']
        result = run_command(command, self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(attributes(output), expected)
        self.assertEqual(sha256_file(source), sha256_file(output))
        self.assertNotEqual(output.stat().st_ino, source_inode)
        self.assertEqual(source.stat().st_nlink, 1)
        self.assertEqual(output.stat().st_nlink, 1)
        with zipfile.ZipFile(output) as archive:
            self.assertIsNone(archive.testzip())
            self.assertTrue(all(i.compress_type == zipfile.ZIP_STORED for i in archive.infolist()))
        self.assertIn('clone requested' if sys.platform == 'darwin' else 'clone not requested', result.stderr)
        digest = sha256_file(source)
        with output.open('r+b') as stream:
            stream.seek(128)
            stream.write(b'owned-output-mutation')
        output.chmod(0o400)
        self.assertEqual(sha256_file(source), digest)
        self.assertEqual(attributes(source), expected)
        output.chmod(0o600)  # Windows TemporaryDirectory cleanup needs write permission.

    @unittest.skipUnless(BASH, 'requires a POSIX shell')
    def test_darwin_copy_error_and_platform_probe_error_are_not_retried(self):
        binary = self.root / 'bin'
        binary.mkdir()
        cp = binary / 'cp'
        cp.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> copy-attempts\nprintf "fixture ENOSPC\\n" >&2\nexit 28\n',
                      encoding='utf-8', newline='\n')
        cp.chmod(0o755)
        uname = binary / 'uname'
        env = os.environ.copy()
        # Set this inside the shell: Git Bash rewrites an inherited Windows
        # PATH during startup, which otherwise bypasses the owned error stubs.
        command = 'export PATH="$PWD/bin:/usr/bin:/bin"\n' + archive_action(self.patched())[0][1]['command']
        for system in ('Darwin', 'Linux'):
            uname.write_text('#!/bin/sh\nprintf "' + system + '\\n"\n', encoding='utf-8', newline='\n')
            uname.chmod(0o755)
            result = run_command(command, self.root, env)
            self.assertEqual(result.returncode, 28, result.stderr)
            attempts = self.root / 'copy-attempts'
            self.assertEqual(attempts.read_text().splitlines(),
                             [('-c -p' if system == 'Darwin' else '-p') + ' input.zip output.zip'])
            attempts.unlink()
        uname.write_text('#!/bin/sh\nexit 9\n', encoding='utf-8', newline='\n')
        self.assertEqual(run_command(command, self.root, env).returncode, 9)
        self.assertFalse((self.root / 'copy-attempts').exists())

    @unittest.skipUnless(sys.platform == 'darwin', 'physical APFS clone proof requires actual Darwin')
    def test_darwin_clone_allocation_and_copy_on_write(self):
        report = {'schema': 1, 'status': 'running', 'host': platform.platform(),
                  'rulesAppleRevision': unsigned.RULES_APPLE_REVISION,
                  'allocationMethod': 'sync + statvfs f_bavail; st_blocks is not a sharing test'}
        try:
            self.darwin_proof(report)
            report['status'] = 'passed'
        except BaseException as error:
            report.update(status='failed', error=str(error))
            raise
        finally:
            if os.environ.get('EXTERALESS_ARCHIVE_COPY_REPORT'):
                path = Path(os.environ['EXTERALESS_ARCHIVE_COPY_REPORT'])
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n', encoding='utf-8')

    def darwin_proof(self, report):
        patched = self.patched()
        self.assert_postimages()
        report['sourceImages'] = {name: {'pristine': pre, 'patched': post} for name, (pre, post) in IMAGES.items()}
        report['sourcePins'] = {name: sha256_file(ROOT / name) for name in (
            'telegram-ios/build-system/Make/UnsignedBuild.py',
            'telegram-ios/build-system/patches/unsigned-rules-apple.patch',
            'tools/ci/tests/test_unsigned_archive_copy.py',
            'tools/ci/tests/test_unsigned_build.py',
        )}
        report['sourceCommit'] = subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True, timeout=5).strip()
        report['checkedOutRulesCommit'] = subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'], cwd=ROOT / 'telegram-ios' / RULES_RELATIVE,
            text=True, timeout=5).strip()
        self.assertEqual(report['checkedOutRulesCommit'], unsigned.RULES_APPLE_REVISION)
        report['cpPath'] = run_command('command -v cp', self.root).stdout.strip()
        self.assertEqual(Path(report['cpPath']).resolve(), Path('/bin/cp').resolve())
        report['cpSha256'] = sha256_file(Path('/bin/cp'))
        report['swVers'] = subprocess.check_output(['/usr/bin/sw_vers'], text=True, timeout=5)
        device = subprocess.check_output(['/bin/df', '-P', str(self.root)], text=True, timeout=5).splitlines()[-1].split()[0]
        disk = plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil', 'info', '-plist', device], timeout=10))
        report['filesystem'] = {key: disk.get(key) for key in ('FilesystemType', 'DeviceIdentifier', 'MountPoint')}
        self.assertEqual(disk.get('FilesystemType'), 'apfs', report['filesystem'])
        source = self.root / 'owned-stored.zip'
        baseline = self.root / 'original-cp.zip'
        output = self.root / 'patched-cp.zip'
        probe = self.root / 'public-clonefile.zip'
        write_archive(source, mib_per_member=30)  # 60 MiB + ZIP headers, inside the 64 MiB cap.
        os.setxattr(source, 'org.exteraless.bundle-copy-fixture', b'owned fixture')
        os.chflags(source, stat.UF_NODUMP)
        subprocess.run(['/bin/chmod', '+a', 'everyone allow read,readattr,readextattr,readsecurity', str(source)],
                       check=True, timeout=5)
        expected = attributes(source)
        original_hash = sha256_file(source)
        report['archiveBytes'] = source.stat().st_size
        report['originalSha256'] = original_hash
        report['attributes'] = expected
        with zipfile.ZipFile(source) as archive:
            report['members'] = [{'name': info.filename, 'bytes': info.file_size,
                                  'compression': info.compress_type, 'attributes': info.external_attr}
                                 for info in archive.infolist()]
            self.assertIsNone(archive.testzip())

        def free_sample():
            subprocess.run(['/bin/sync'], check=True, timeout=10)
            time.sleep(0.25)
            value = os.statvfs(self.root)
            return {'availableBytes': value.f_bavail * value.f_frsize,
                    'freeBytes': value.f_bfree * value.f_frsize, 'blockBytes': value.f_frsize}

        def measure(name, operation):
            before = free_sample()
            operation()
            after = free_sample()
            report[name] = {'before': before, 'after': after,
                            'allocatedDeltaBytes': before['availableBytes'] - after['availableBytes']}
            return report[name]['allocatedDeltaBytes']

        library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        clonefile = library.clonefile
        clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
        clonefile.restype = ctypes.c_int

        def public_clone():
            ctypes.set_errno(0)
            result = clonefile(os.fsencode(source), os.fsencode(probe), 0)
            error = ctypes.get_errno() if result else 0
            report['clonefileCapability'] = {'returnCode': result, 'errno': error,
                                           'error': os.strerror(error) if error else None}
            self.assertEqual(result, 0, 'clonefile unsupported/failing; cp success alone cannot prove cloning: ' + str(report['clonefileCapability']))

        public_clone_delta = measure('publicClone', public_clone)
        self.assertEqual(sha256_file(probe), original_hash)
        self.assertEqual(attributes(probe), expected)

        def execute_copy(text, destination):
            command = archive_action(text, source.name, destination.name)[0][1]['command']
            atime = source.stat().st_atime_ns
            result = run_command(command, self.root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(destination.stat().st_atime_ns, atime)
            report[destination.name] = {'command': command, 'stderr': result.stderr}

        baseline_delta = measure('baselineCopy', lambda: execute_copy(self.original, baseline))
        clone_delta = measure('patchedCopy', lambda: execute_copy(patched, output))
        for path in (baseline, output):
            self.assertEqual(attributes(path), expected)
            self.assertEqual(sha256_file(path), original_hash)
        stats = {path.name: path.stat() for path in (source, baseline, output, probe)}
        report['files'] = {name: {'inode': value.st_ino, 'device': value.st_dev, 'links': value.st_nlink,
                                 'logicalBytes': value.st_size, 'stBlocksBytesNotPhysicalSharing': value.st_blocks * 512}
                           for name, value in stats.items()}
        self.assertEqual(len({value.st_ino for value in stats.values()}), 4)
        self.assertEqual(len({value.st_dev for value in stats.values()}), 1)
        self.assertTrue(all(value.st_nlink == 1 for value in stats.values()))
        size = source.stat().st_size
        # A meaningful physical control is mandatory. Background allocation
        # larger than 1/4 of this 60 MiB fixture fails, rather than claiming COW.
        self.assertGreater(baseline_delta, size * 0.75, report['baselineCopy'])
        self.assertLess(baseline_delta, size * 1.25, report['baselineCopy'])
        self.assertLess(abs(clone_delta), size * 0.25, report['patchedCopy'])
        self.assertLess(abs(public_clone_delta), size * 0.25, report['publicClone'])
        self.assertGreater(baseline_delta - clone_delta, size * 0.50)
        report['avoidedAllocationBytes'] = baseline_delta - clone_delta

        def mutate(path, offset, tag):
            with path.open('r+b') as stream:
                stream.seek(offset)
                stream.write(hashlib.shake_256(tag).digest(1024 * 1024))
                stream.flush()
                os.fsync(stream.fileno())

        measure('outputMutation', lambda: mutate(output, 2 * 1024 * 1024, b'output-only'))
        output_hash = sha256_file(output)
        self.assertNotEqual(output_hash, original_hash)
        self.assertEqual(sha256_file(source), original_hash)
        output.chmod(0o600)
        self.assertEqual(attributes(source), expected)
        measure('sourceMutation', lambda: mutate(source, 4 * 1024 * 1024, b'source-only'))
        self.assertNotEqual(sha256_file(source), original_hash)
        self.assertEqual(sha256_file(output), output_hash)
        self.assertEqual(sha256_file(baseline), original_hash)
        self.assertEqual(sha256_file(probe), original_hash)
        report['copyOnWrite'] = {'outputMutationLeavesSourceIdentical': True,
                                 'sourceMutationLeavesOutputIdentical': True,
                                 'outputChmodLeavesSourceModeAndAclIdentical': True}


if __name__ == '__main__':
    if os.environ.get('EXTERALESS_REQUIRE_DARWIN_CLONE') == '1' and sys.platform != 'darwin':
        raise SystemExit('Darwin clone proof required: this host is ' + sys.platform)
    unittest.main()
