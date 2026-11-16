# Source-bound diagnostic recording after native failure

Follow-up to NEO-03 in `native-execution-orchestration-review.md`.

The manual UIKit workflow now accepts `diagnostic_recordings` (default false).
After a successful full app/Harness build and an explicitly failed native gate,
this option uses the existing nine recording slots and the same twenty scenarios.
It runs the same `client_ui_harness.py`, retained IPA, fresh simulators, 30-second
app processes, `simctl recordVideo`, ffprobe PTS and frame-sheet extraction.

`record_client_ui_batch.py --diagnostic-native-failure` requires:

- the exact compiled plan, harness, staging and IPA identity before collection;
- a native result with `status=failed` and `native_execution_verified=false`;
- the prior native guest to be deleted, if it was created, and no active guests;
- the same build identity and native-result bytes after collection, including
  after a nonzero recorder exit, plus a fresh check that no guest remains active.

Its sidecar is `diagnostic-identity.json`, with `nativeAcceptance=false`, the
recorder exit code and an explicit `cohortUnchanged` result. It cannot produce
`batch-identity.json` or native acceptance evidence. Successful diagnostic capture
still requires the recorder's normal semantic/frame checks. Partial recordings
and their failed exit codes remain available for investigation.

Diagnostic outputs live under `diagnostic-recordings/` in the always-uploaded
artifact. Subsequent independent batches can run after a sibling failure. Native
failure continues to fail the job. Both final joins require genuine native PASS
and read only ordinary `evidence/` batches. Final acceptance still requires all
434 methods, twenty scenes and a separate review of the actual recorded frames.

The expected frames remain the already-published contracts in `ui-harness.md`,
`native-gate-sdk-followup.md` and `map-attribution-native-handoff.md`.

Local verification: 27 recording/batch/supplement/Map tooling tests passed.
The new counterexamples cover incorrect IPA identity, post-failure source/native
drift, unfinished native results, active/undeleted guests, a guest left active
by the recorder, preservation of failed exit codes and strict normal acceptance.
No native tests or recordings were executed by these local checks.

## Failure-path integration

`diagnostic-recording-failure-closure.md` records the three subsequent DRF
corrections. All nine commands now pass their existing outer envelope to the
wrapper:600/600/600/180/180/180/120/150/150 seconds. The wrapper reserves30 seconds
for independent postchecks and five seconds of outer margin. Its early signal
receipt labels uncompleted checks as unfinished; it never substitutes them for
successful identity or simulator-cleanup observations. Captured source hashes
survive path loss, and the CLI preserves the recorder's nonzero exit status.
