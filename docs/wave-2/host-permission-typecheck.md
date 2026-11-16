# Host permission-predicate typecheck

The47-case run43781210777/a707e85b compiled, then exceeded its30s runtime bound.
Source tracing identified two fixture cycles: cancelling a Task awaiting plain
`OneShotResult` cannot complete it, while the test waits for that cancellation
before releasing its held native completion. Both fixture waiters now use the
same cancellation-aware result pattern as native invocation; detached work still
holds the FD until its explicit finish signal. A defer releases that signal on
early test failure. Production code, FD lifetime assertions and deadlines stay
intact. Native re-execution is required to verify this diagnosis.

FD follow-up43780298237/a5720a43 passed the descriptor constant fix and found a
test-only throwing short-circuit condition. The `try` now covers the whole `||`
expression in the bounded cleanup wait. Its two-second deadline, cancellation
and exact no-outstanding-descriptor/no-stage assertions are retained.

The later FD cohort43779077310/ecaa9d85 exposed a separate CoreFoundation/Glibc
`S_IFREG` ambiguity in `PluginElyxDeveloperDescriptor.checkLocked`. The file-type
mask and regular-file constant now explicitly use Darwin or Glibc under the
existing POSIX platform guard. Descriptor checks and predicates are unchanged.

Follow-up43769449668/ec1131cf passed the dispatcher expression and found the
same optional-call/closure fallback shape in `BridgeServices.nativeEffectLease`.
That site now assigns the typed predicate in explicit present/absent branches,
preserving the existing fixture-mode fallback and captured revocation epochs.

Linux verification43768124344 / ff913492 compiled the new Host cohort with
Swift6.4.2 and failed to diagnose the optional-chain/closure fallback expression
in `PluginCallbackDispatcher.permissionPredicate`.

The helper now unwraps the existing weak Host before returning the typed
`PermissionsModel.futurePredicate`. A missing Host still returns false. The
returned predicate retains its existing weak permission-model reference and
captured revocation epochs; no authority or lifetime policy is changed.

The next targeted Host run must confirm this correction. That run is independent
of the same snapshot's completed Python POSIX result:42 passed,0 skipped.
