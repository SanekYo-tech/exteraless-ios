import copy
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from apply_telegram_client_patches import prove_clean_base
from ClientSourcePatches import BASE_COMMIT, HELPER, MANIFEST, prepare_client_source_copy, prepare_client_sources, sha256, validate_patch_provenance, verify_client_sources


def create_fixture(root):
    root = Path(root)
    before, after = b'before\n', b'after\r\n'
    files, chunks = {}, []
    for name in ('resolver', 'session_runtime', 'worker'):
        relative = 'crates/mtproto-engine/src/' + name + '.rs'
        target = root / 'third-party/mtproto-engine' / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(before)
        files[relative] = {'preimage_sha256': sha256(before), 'preimage_size': len(before),
                           'postimage_sha256': sha256(after), 'postimage_size': len(after),
                           'postimage_crlf_ranges': [[1, 1]]}
        chunks.append('diff --git a/{0} b/{0}\nindex {1}..{2} 100644\n--- a/{0}\n+++ b/{0}\n@@ -1 +1 @@\n-before\n+after\n'.format(relative, '0' * 40, '1' * 40))
    patch_data = ''.join(chunks).encode()
    contract = {'schema': 1, 'repository': 'third-party/mtproto-engine', 'base_commit': BASE_COMMIT,
                'format': 'git-unified-lf-with-exact-postimage-crlf-ranges',
                'patch': 'mtproto-engine-native-dns.patch', 'patch_sha256': sha256(patch_data), 'files': files}
    manifest = root / MANIFEST
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps(contract), encoding='utf-8')
    (manifest.parent / contract['patch']).write_bytes(patch_data)
    helper = root / HELPER
    helper.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / 'telegram-ios' / HELPER, helper)
    return contract


class ClientSourcePatchTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix='client-source-patch-test-')
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.contract = create_fixture(self.root)
        self.files = [self.root / self.contract['repository'] / name for name in self.contract['files']]

    def test_clean_apply_is_exact_and_postimage_validation_never_writes(self):
        with self.assertRaisesRegex(ValueError, 'not been prepared'):
            verify_client_sources(self.root)
        first = prepare_client_sources(self.root)
        self.assertTrue(all(path.read_bytes() == b'after\r\n' for path in self.files))
        timestamps = [path.stat().st_mtime_ns for path in self.files]
        self.assertEqual(first, prepare_client_sources(self.root))
        self.assertEqual(first, verify_client_sources(self.root))
        self.assertEqual(timestamps, [path.stat().st_mtime_ns for path in self.files])
        self.assertEqual(validate_patch_provenance(first), first)

    def test_third_state_is_rejected_before_other_files_are_changed(self):
        for replacement in (b'edited\n', b'before\r\n'):
            self.files[-1].write_bytes(replacement)
            before = [path.read_bytes() for path in self.files]
            with self.assertRaisesRegex(ValueError, 'third state'):
                prepare_client_sources(self.root)
            self.assertEqual(before, [path.read_bytes() for path in self.files])

    def test_partial_apply_is_not_silently_finished(self):
        self.files[0].write_bytes(b'after\r\n')
        with self.assertRaisesRegex(ValueError, 'mixed source images'):
            prepare_client_sources(self.root)
        self.assertEqual(self.files[1].read_bytes(), b'before\n')

    def test_altered_patch_and_wrong_postimage_pin_cannot_write_any_source(self):
        patch_path = self.root / MANIFEST
        data_path = patch_path.parent / self.contract['patch']
        original = data_path.read_bytes()
        data_path.write_bytes(original + b'altered\n')
        with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
            prepare_client_sources(self.root)
        data_path.write_bytes(original)
        spec = next(iter(self.contract['files'].values()))
        spec['postimage_sha256'] = '0' * 64
        patch_path.write_text(json.dumps(self.contract), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'unexpected raw postimage'):
            prepare_client_sources(self.root)
        self.assertTrue(all(path.read_bytes() == b'before\n' for path in self.files))

    def test_changed_gitlink_base_is_rejected_even_with_exact_source_bytes(self):
        (self.files[0].parents[3] / '.git').write_text('gitdir: unused')
        with patch('ClientSourcePatches.subprocess.check_output', return_value=b'0' * 40 + b'\n'):
            with self.assertRaisesRegex(ValueError, 'base commit'):
                prepare_client_sources(self.root)

    def test_stale_artifact_and_changed_patch_input_fingerprints_are_rejected(self):
        first = prepare_client_sources(self.root)
        stale = copy.deepcopy(first)
        stale['input_sha256'][MANIFEST] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'fingerprint mismatch'):
            validate_patch_provenance(stale)
        with self.assertRaisesRegex(ValueError, 'Missing or stale'):
            validate_patch_provenance(None)
        manifest = self.root / MANIFEST
        manifest.write_bytes(manifest.read_bytes() + b'\n')
        self.assertNotEqual(first['source_fingerprint'], verify_client_sources(self.root)['source_fingerprint'])

    def test_postimage_with_a_different_line_ending_map_is_rejected(self):
        prepare_client_sources(self.root)
        next(iter(self.contract['files'].values()))['postimage_crlf_ranges'] = []
        (self.root / MANIFEST).write_text(json.dumps(self.contract), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'line-ending map differs'):
            verify_client_sources(self.root)

    def test_relocated_copy_checks_patch_identity_before_writing_destination(self):
        destination = self.root / 'copy'
        create_fixture(destination)
        metadata = destination / MANIFEST
        metadata.write_bytes(metadata.read_bytes() + b'\n')
        with self.assertRaisesRegex(ValueError, 'Relocated client patch inputs differ'):
            prepare_client_source_copy(self.root, destination)
        path = destination / self.contract['repository'] / next(iter(self.contract['files']))
        self.assertEqual(path.read_bytes(), b'before\n')

    def test_harness_patch_gate_runs_inside_owned_stage_before_copy(self):
        from client_ui_harness_workspace import stage
        source = self.root / 'source'
        create_fixture(source)
        for name in ('versions.json', 'MODULE.bazel', 'Tests/ExteralessHarness/BUILD'):
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('{}', encoding='utf-8')
        calls = []
        def prepare(path):
            calls.append('prepare')
            prepare_client_sources(path)
        def copy(*args, **kwargs):
            verify_client_sources(source)
            calls.append('copy')
        stage(self.root / 'owned', 'fixture/repository', 'test-1', source, run=copy, before_copy=prepare)
        self.assertEqual(calls, ['prepare', 'copy'])

    def test_harness_rejects_unowned_workspace_before_source_preparation(self):
        from client_ui_harness_workspace import stage
        source = self.root / 'source'
        create_fixture(source)
        for name in ('versions.json', 'MODULE.bazel', 'Tests/ExteralessHarness/BUILD'):
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('{}', encoding='utf-8')
        destination = self.root / 'unowned'
        destination.mkdir()
        with patch('ClientSourcePatches.prepare_client_sources') as prepare:
            with self.assertRaisesRegex(ValueError, 'without a harness ownership sentinel'):
                stage(destination, 'fixture/repository', 'test-1', source, before_copy=prepare)
        prepare.assert_not_called()

    def test_published_patch_replays_three_real_git_show_blobs(self):
        # CPython-only sparse jobs have no Telegram Rust checkout. Full app CI
        # independently requires this same proof via --prove-clean-base.
        if not (ROOT / 'telegram-ios/third-party/mtproto-engine/.git').exists():
            self.skipTest('CPython-only checkout; full app preparation requires clean-base proof')
        report = prove_clean_base(ROOT / 'telegram-ios')
        self.assertEqual(report['files'], 3)
        self.assertEqual(report['tamper_rejected'], 3)
        self.assertTrue(report['idempotent_without_writes'])


if __name__ == '__main__':
    unittest.main()
