# Elyx native FD-provider POSIX gate — capture aborted

**2026-11-16: ABORTED before snapshot creation or CI dispatch. Two provider source files did not match the explicitly supplied raw SHA-256 handoff pins.** No new native-provider acceptance is claimed.

## Requested cohort

- Intended immutable parent: `0ad00c3ef8e856d3a95cd33d43a059c4bc0c648f`.
- Handoff authority: `docs/wave-2/native-elyx-developer-remediation.md:581–588`.
- Authorized new inputs: exactly the two provider/registry Swift source files and `PluginElyxDeveloperFilesTests.swift`.
- Intended execution: only the 21 `PluginElyxDeveloperFilesTests`, Linux Swift 6.4.2, full target build bounded to 180 seconds and test execution bounded to 30 seconds.

The requested rule was to abort capture on any disagreement with these handoff hashes, without refreshing other main work, guessing a newer source version, waiting or polling. The initial read-only hash observation failed that rule:

| Path | Expected raw SHA-256 | Observed raw SHA-256 | Result |
|---|---|---|---|
| `swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperFiles.swift` | `e8382f29bb7967c3de7e635158b0d312b62b4ecde9ea9b336dbf482d04895ede` | `3b5fbd409139999e31244c8ad45fd2633ee2353f0f43c5bbc356e83d7261b2dd` | **MISMATCH** |
| `swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperDescriptor.swift` | `4146d16f51d345280cea3a85a1b364e30f599d4fdbf40cddb4c833fb971b48ba` | `24aa4fc3e79b2f9d907f9f97188e31f7f25e64b56c801a028c194aced44ad146` | **MISMATCH** |
| `swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperFilesTests.swift` | `fc1d977df4c278ea89fd745872e8ace0de98c8854255e87b0e51add8d3c3bab6` | `fc1d977df4c278ea89fd745872e8ace0de98c8854255e87b0e51add8d3c3bab6` | MATCH |

These are initial observed hashes, not newly accepted pins. The reason for the source-byte differences was not inferred. Updated, explicitly sealed owner/coordinator pins are required before a new capture attempt.

## Outcome and custody

- New verification branch/commit: **none**.
- Manual CI run/artifacts: **none**.
- Provider tests executed: **0**; pass/failure/skip counts: **not applicable** because no test command ran.
- No source files were copied into a snapshot; no canonical blob was substituted for a mismatching raw handoff.
- No main source/index/ref was edited, reset or checked out. The only authored caller-worktree file is this new abort receipt. Earlier verification receipts remain untouched.
- Initial caller observation: HEAD `31287b9204aef5384b85d75f97f233dccf230409`; main index SHA-256 `379e420b82d3c9265444917da651a58a79eec10ea54e73ce66ec79d2dfe82dff`. Caller progress remains independent of this capture attempt.
- The prior 53-case Host PASS and 42-case Python PASS retain their existing immutable evidence. Neither suite was rerun.
- The unrelated main-app CI run was not queried or cancelled.

This aborted attempt establishes no native FD-provider/registry filesystem or CAP-v1 execution result. Actual C/CPython/Root-startup integration and Darwin-specific rename/kqueue behavior likewise remain outside its evidence.
