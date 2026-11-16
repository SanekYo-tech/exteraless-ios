# SCR-01 — independent coordinator follow-up

**Core SCR-01 is source-closed.** This is an independent inspection of the earlier
Settings owner's fix, not a restatement of the owner report. The inspected Core
implementation and tests are the published bytes executed by Mac run
**43743252038 / e16f3808**. No additional Core changes were made for this review.

## Original counterexample

`settings-recovery-followup.md:119–164` found that a successfully quarantined raw
secret B lost its stored flag; a later unrelated public batch manufactured an
empty-string default. B was then displayed as absent despite its retained bytes.

The actual paths now preserve the three independent facts:

| Boundary | Inspected implementation |
|---|---|
| New raw quarantine | `ClientSettings.swift:727–735` stages raw bytes and sets B's stored flag while leaving its typed value absent. |
| Matching duplicate retry | `:696–709` applies the confirmed observation before deleting only the matching plaintext duplicate. |
| Acknowledged partial write / failed later read | `:755–764`, `:851–869` retain confirmed presence across unknown observations; unavailable or invalid data never acquire a default. |
| Failed transaction recovery | `:403–448`, `:786–809` read each secret independently and reapply writer-owned observations before publication. |
| Unrelated public batch | `:534–539` copies cached typed availability and stored presence exactly, without reading or writing the secret backend. |
| Explicit reset/default-equal set | Confirmed absence alone supplies the default; a successful nonnil write retains presence. |

`ClientSettingsSnapshot:88–111` redacts available secrets to `.null` but leaves
unavailable typed values absent. Raw quarantine bytes are not exposed by snapshots.
Observation bookkeeping is cleared before callbacks run (`:452–454`).

## Executed regressions

The actual Mac Core log contains `started` and `passed` for all three tests:

- `testSCR01PartialAliasWriteRetainsConfirmedPresenceWhenReadsBecomeUnavailable`
  — 0.005 s, lines560–561;
- `testSCR01QuarantinePresenceSurvivesPublicBatchesAndUnreadableBackend`
  — 0.010 s, lines562–563;
- `testSCR01RecoveryPreservesCommittedPresenceBeforeAndAfterRename`
  — 0.023 s, lines564–565.

Their assertions cover raw `false` and `null`, presence after copy/retry/reopen,
no secret I/O from public batches, pre/post-rename outcomes, retained successful
partial writes, explicit defaults and resets. The complete Core suite passed
680 tests with zero failures. These use the injected backend, not physical-device
Keychain fault injection.

## UI follow-up

The coordinator additionally corrected four lines in
`ExteralessSettingsController.settingRow`: an unavailable typed value with no
confirmed presence was still labelled **Not set**. The row now distinguishes
unavailable/known-stored-unavailable from a redacted available default. This uses
the existing snapshot state and performs no extra storage reads. Native rendering
and frames for the new wording remain unexecuted; the Core verdict above does not
claim their acceptance.

## Raw SHA-256

```text
203b973a7f09bb657075ea92daf22065e2ee0baf060147bbc8c0661f1231c556  swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift
7c02673d9a6b1fa3e00fc7b93672ce61a814030206299d7b28982485afab7696  swift/ExteralessCore/Tests/ExteralessCoreTests/ClientSettingsTests.swift
e8f2d6b67c4dc64a9f0dc5b7956121c40f6a4da5764e720fa00b1fdc38d26ed0  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsController.swift
64c0573f11ea5461f39dce46f061ed95aecf2b305a7662daa9341c140b4b030e  build/artifacts/python-runtime-43743252038/swift-components/ExteralessCore/test.log
```
