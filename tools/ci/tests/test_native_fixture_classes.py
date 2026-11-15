"""Only the newly required multi-class source declaration handling; no native run."""

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from native_test_plan import fixture_classes


class NativeFixtureClassChecks(unittest.TestCase):
    def test_identity_handoff_maps_both_real_classes_without_recounting_other_cohorts(self):
        text = (ROOT / 'telegram-ios/Tests/Exteraless/IdentityRemediationTests.swift').read_text(encoding='utf-8')
        classes = fixture_classes(text)
        actual = {item['class']: set(item['methods']) for item in classes}
        # Pin the handed-off membership, not an aggregate count that rejects
        # later author additions to the same source file.
        required = {
            'IdentityExpiryLeaseTests': {
                'testEarlyWakeupAfterBackwardJumpPublishesOnlyAtRealWallExpiry',
                'testForegroundAndSignificantTimeRefreshRescheduleEveryFutureDeadline',
                'testReplacedAccountTokenRejectsOldDeadlineAndOldDeinit',
                'testRejectedForeignSnapshotDoesNotInstallItsExpiry',
            },
            'IdentityNameFormattingTests': {
                'testNoAliasAndNoSnapshotUseTheSameFinalFilterAsStockTitles',
                'testAliasesNameOrdersResetAndFlagChangesDoNotRewriteStoredNames',
                'testOrdinaryDiacriticsZWJAndAttributedFirstLastFontsArePreserved',
            },
        }
        for name, methods in required.items():
            self.assertLessEqual(methods, actual[name])
        self.assertFalse(actual['IdentityExpiryLeaseTests'] & actual['IdentityNameFormattingTests'])

    def test_comments_strings_and_neighboring_helpers_are_not_test_members(self):
        classes = fixture_classes('''
// final class FalseTests: XCTestCase { func testFalse() {} }
final class FirstTests: XCTestCase {
    func testOne() { let value = "}\\(String("{"))" }
    final class Helper {
        func testNotAnXCTest() {}
    }
}
final class AnotherHelper {
    func testNotAMember() {}
}
@MainActor
final class SecondTests: XCTestCase {
    func testOne() { /* nested { /* } */ } */ }
    func testTwo() {}
}
''')
        self.assertEqual(classes, [
            {'class': 'FirstTests', 'methods': ['testOne']},
            {'class': 'SecondTests', 'methods': ['testOne', 'testTwo']},
        ])

    def test_frozen_sticker_source_keeps_both_native_review_classes(self):
        source = ROOT / 'telegram-ios/submodules/TelegramCore/Tests/ExteralessStickerReviewTests.swift'
        classes = fixture_classes(source.read_text(encoding='utf-8'))
        self.assertEqual({item['class']: len(item['methods']) for item in classes}, {
            'ExteralessStickerRecentsReviewTests': 3, 'ExteralessStickerPolicyReviewTests': 4,
        })

    def test_empty_or_unclosed_classes_fail_instead_of_a_zero_test_pass(self):
        for source in ('final class Empty: XCTestCase {}', 'final class Open: XCTestCase {\nfunc testOne() {}'):
            with self.assertRaises(ValueError):
                fixture_classes(source)


if __name__ == '__main__':
    unittest.main()
