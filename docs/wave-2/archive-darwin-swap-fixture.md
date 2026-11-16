# Darwin archive-swap fixture: observed cause and native fix

2026-11-16. **Main-ready test fix; native macOS result: 7 tests, 0 failures.**

Only `swift/PluginHost/Tests/PluginHostTests/PluginArchiveDescriptorTests.swift`
and this new report were edited in the caller worktree. Production storage and
its descriptor/binding checks were read-only.

## Actual cause

The historical `5ce84b96` change called `resolvingSymlinksInPath()` before the
hook and compared its `.path` to the callback URL. The existing artifact
`build/artifacts/python-runtime-43791248294/swift-components/PluginHost/test.log:149–164`
shows the resulting three failures: no throw, `swapped == false`, no saved owner.
That artifact contained no callback path evidence, so it did not demonstrate a
production descriptor-guard failure.

The diagnostic-only native run retained that failing guard and recorded actual
Foundation URL, `.path`, filesystem representation and device/inode/type values
from the owned fixture. On this runner, **Foundation's resolved target still
used `/var/...`; the descriptor walker reported `/private/var/...`.** Both named
the same directory. Calling `resolvingSymlinksInPath` did not make these strings
equal.

Diagnostic run `43793493584`, `test.log:28–45` (common owned suffix abbreviated):

| Observation | Path prefix | Device | Inode | Result |
|---|---|---:|---:|---|
| Target before hook | `/var/folders/.../elyx/aaaa...` | 16777228 | 3025210 | directory |
| `resolvingSymlinksInPath` target | `/var/folders/.../elyx/aaaa...` | 16777228 | 3025210 | unchanged spelling |
| Actual `directoryOpened` callback | `/private/var/folders/.../elyx/aaaa...` | 16777228 | 3025210 | identity match, path mismatch |

All 13 directory callbacks were observed; none satisfied the string guard.
The final diagnostic was `observations=15 swapped=false captureError=<none>`.
The saved directory was absent because the fixture had never performed its
rename/symlink injection. This is the observed fixture-selection failure, not a
new production P1 counterexample.

## Fix and unchanged adversary/assertions

The fixture now captures its newly created target's device, inode and file type
using actual `FileManager` attributes (`systemNumber` / `systemFileNumber` as
`NSNumber.uint64Value`). The callback still requires `.directoryOpened` and the
one-shot guard, but selects the pre-adversary **identity**, not a path spelling.
No identity lookup selects a target after the adversarial link is installed.

The actual rename and symlink replacement are unchanged. The expected throw,
`swapped`, outside bytes and saved-original existence assertions remain. Added
assertions require the exact `BridgeFailure.permission("Archive descriptor
ownership: directory binding changed")`, the saved directory's original identity,
and its unchanged original file bytes. Diagnostics remain bounded to 64 records
and contain only this operation's owned paths/ancestor metadata.

The successful follow-up's `test.log:25–40` observed:

```text
target /var/...                  device=16777228 inode=3026464
callback /private/var/...        device=16777228 inode=3026464
identityMatch=true pathMatch=false
ARCHIVE_SWAP_RESULT observations=13 swapped=true
  captureError=Archive descriptor ownership: directory binding changed
target-after                    kind=NSFileTypeSymbolicLink inode=3026470
saved-after                     kind=NSFileTypeDirectory inode=3026464
```

The production re-verification therefore ran after the real mutation and
rejected the changed binding. The outside data and saved original bytes passed
their assertions. No production path comparison was changed to accommodate the
test.

## Bounded native execution

Both jobs used `macos-26`, Xcode **26.6 / 17F113**, Apple Swift **6.3.3**, on
macOS **26.7.2 arm64**. The private workflow checked 92 exact package input hashes,
compiled tests with two jobs and executed only `PluginArchiveDescriptorTests`.

| Stage | Run / private commit | Compile | Test process | XCTest result |
|---|---|---:|---:|---|
| Diagnostic, failing guard retained | [43793493584](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43793493584), `c752226b087090ec9178bce6c6a22390a7fd2d4b` | 66.567 s | 4.702 s | 7 tests, the same 3 assertions failed |
| Identity selection and stronger assertions | [43794021047](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43794021047), `cef03eec00d7a673910fd93386556155af61c661` | 87.427 s | 7.446 s | **7 tests, 0 failures**, 0.068 s suite wall time |

Commands, recorded verbatim with limits, duration, exit code and timeout state:

```text
swift build --build-tests --jobs 2 --package-path swift/PluginHost       # 180 s
swift test --skip-build --jobs 2 --package-path swift/PluginHost --filter PluginArchiveDescriptorTests  # 30 s
```

No command timed out or crashed. The workflow additionally checked that the
successful output contained seven passing tests, `swapped=true`, and the actual
binding-change error. Full stdout/stderr is in the artifacts, not a filtered
summary. No other Host/FD/transaction/ingress/Core/CPython tests were executed.

## Exact input and artifact seals

Main-ready test bytes (identical to the successful runner input):

```text
b9b101e12211e8992df975705ce49d020922da37f0d33e06bde75d1c75822a75  PluginArchiveDescriptorTests.swift
```

Historical `5ce84b96` test SHA-256 is retained as
`fdcc3f7a3c7cdf11d63315683b834ba6698e42c19b63c2a905ead035e832e1f5`.
The diagnostic test hash was
`de9b6fca08e4701c62f90c5a2c6b677d619cc241fb9dd6be5dacb46e95cc2609`.
Production `PluginArchiveStorage.swift` remained
`ecde8c195dfd7fbc5ec6aaa66705b4be4e74324e9d8de3306bae6b046d7625dc`.
Of the 92 package inputs, **only this test file differs between the two runs**.

Artifact `archive-darwin-swap-43794021047`:

```text
3a6af2cfcfbbcfb8d12df0ec78ff50d07a6a1d524e4439b61a4a9680c3cacebc  source-pins.json
0d73e10ff1713b7b85ed01592abbf624dbeaf11188b15caa8651f42454996cbc  commands.json
deafa9c154680570b211e477aafb21d381759186015b20de932e1b34b23d54cf  test.log
4f5dcf283fecd01b3a531875a340651ea73c0083b4f8cf63408c8ddd5a01bfe8  build.log
f3a1a22de763c42cf240c032df904e1e486a0e6270e01a0e984470c2cea97200  conclusion.json
```

Diagnostic artifact `archive-darwin-swap-43793493584`:

```text
b3ed8e729e1008e513db8b836aa01cea425a48c952fff7d53b6616766f592e07  source-pins.json
3143beca2a3268e26bb1af547947fd8062b8b0f085c90984097ec4669204a8cf  commands.json
0dc3f64de76af90cbfbee1fb6d87c4df832d2a9fc7849218cb067546c7d9eb57  test.log
```

Both artifacts also contain the exact test and storage input files plus tool
versions. Local downloads/control records are under the approved temporary root:

- `archive-darwin-swap-diag-357876ac59/artifact/`
- `archive-darwin-swap-fixed-c5684c6f13/artifact/`

## Isolation and main-ready handoff

The diagnostic branch was built from `3daf8d97...` with a separate temporary
`GIT_INDEX_FILE`, `read-tree`, canonical `hash-object`, `update-index`,
`write-tree` and `commit-tree`. The second private commit inherited that frozen
snapshot and changed only the test and branch-only workflow. Private branches:

- `verify/archive-darwin-swap-diag-ee1f001d97`
- `verify/archive-darwin-swap-fixed-c790620f1a`

The caller HEAD advanced independently to the coordinator's unrelated UIKit
commit `53cab85a...`; it was observed, not reset. Both preparations and the final
observation recorded the same main-index hash:
`f39f14de663a3e9854f646998262721c6bf1cbe85d1fae4c95e4273c65d64eb9`.
No main checkout/staging/reset/index mutation or main push was used. Origin
credentials were used only in child-process environments and were not printed.
Only the two owned verification runs were queried.

For main, take the verified worktree test file and this report. The reduced
workflow is private verification scaffolding, not a main workflow change. The
older whole-Mac failures and other owners' receipts remain historical evidence;
this result establishes the seven targeted native descriptor tests only.
