# DEV-LIFECYCLE-01 — independent source closure

**DEV-LIFECYCLE-01 is source-closed. No remaining P1/P2 was found within this
developer-mode transition scope.** An accepted off command now irreversibly
retires the old session/scope/registry before creating its detached preference
writer. Later true writes cannot hide that retirement.

Review: **2026-11-16**. Observed HEAD
`6de4ac36fefb54890a3dd043044e5a021a3d0e76` plus the sealed worktree delta.
Read-time pins were checked at **00:56:02Z** and **01:02:51Z**.
Inputs: [mode-ABA seal](../native-elyx-mode-aba-inputs.json),
[remediation, line 816 onward](../native-elyx-developer-remediation.md), and
[the exact earlier P2](native-elyx-final-source-closure.md#remaining-p2--dev-lifecycle-01-developer-mode-aba-can-skip-retirement).
Only this new report is authored; the prior NFD-01/NFD-03 source closures remain
preserved. No native test pass is inferred from source extraction.

`APP` below is
`telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift`;
`UI` is `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/`;
`HOST` is `swift/PluginHost/Sources/PluginHost/`.

## Exact counterexample and repaired order

Previously, two independent callers could commit false then true while both
MainActor continuations were suspended. Both continuations subsequently sampled
true, so neither called `stopDeveloperServices`; the old activation/session could
survive. The preference lock serialized writes, not their actor continuations.

`APP.updateManagerPreference:1065–1088` now orders the operation as follows:

1. Require the existing manager store at line **1066**.
2. For developer changes, check cancellation, `!terminating`, `hasAccount`, a
   non-null current Root context, and the supplied native authority at
   **1067–1070**.
3. For off, call **`stopDeveloperServices()` at 1076**, synchronously on MainActor.
4. Only then create/await `Task.detached` at **1079–1081**. The original
   write-time `authority.isCurrent()` predicate is still passed to the store.
5. Reconcile services from the successfully published preference state at **1086**.

There is no suspension between the Root admission checks and retirement.
`stopDeveloperServices:1060–1062` cancels the session and calls
`retireElyxDeveloperService:1044–1050`, which invalidates the activation object,
clears file/service references, invalidates the service and retires the Host slot.
`HOST/PluginElyxDeveloperService.swift:55–65,186–192` makes this irreversible for
the old service/registry and removes only its own dispatcher epoch.

Thus the original **false → true before either continuation** schedule remains
possible, but step 3 has already retired the old authority. Subsequent
`updateDeveloperServer:1014–1042` calls may both observe true; they obtain a new
scope through `elyxActivationScope:1053–1057`. The unchanged service-slot matching
at `PluginElyxDeveloperService.swift:175–184` coalesces that new activation rather
than recovering the old one.

## The real callers retain their admission checks

- Native listener stop uses `UI/PluginDeveloperBridgeExtension.swift:56–85` to
  validate the current native owner/settings grant and capture its permission
  predicate before queue admission. The queue rechecks that captured lifetime
  at `40–52`; the actual Root initializer at `APP:254–278` forwards off to the
  repaired writer.
- Global `setPluginConfig("developerMode", Bool)` uses the distinct real queue
  at `UI/PluginConfigBridgeExtension.swift:50–66,109–123`, including its captured
  permission predicate. `APP:242–253,751–775` reaches the same Root writer.
- The public native manager control at `APP:734–746` also uses that writer.
  Its optional nil authority represents this native UI path; bridge callers
  supply the captured native authority through their real initializer closures.

The early Root check is therefore not a late grant fabricated from JSON or a
new permissive queue. Denied native admission cannot reach retirement. A revoked
permission predicate remains false after a regrant; Root rejects it before
changing developer authority or preference state.

## Truthful off-error and normal-control semantics

| Situation | Reviewed consequence |
|---|---|
| Missing store, cancelled caller, terminating/no-account/no-context Root, or expired supplied authority at entry | Failure precedes retirement and preference writing. |
| Off accepted, then write fails or write-time authority expires | Old authority stays dead. The original error propagates; no false persisted state is manufactured. |
| Failed off while last published preference is true | Store/cache retain their successful true state. The failing invocation never reaches the restart at line 1086. |
| Explicit later on/start with valid context and published true | Creates fresh scope/registry/epoch/session; old capabilities remain invalid. |
| Already off | Idempotent retirement and false write; no activation/session is created. |
| Ordinary on or listener-start retry while already current | Existing on-path and service coalescing remain; current authority is not retired. |

`UI/PluginManagerPreferences.swift:73–105` still checks write authority immediately
before the real atomic `Data.write`; cached `state = next` occurs only afterward.
Root has no error handler that automatically restarts or revives the old scope.
Async provider admission remains distinct from persistence completion: native
queue failures use their existing failure callback, while the direct manager
writer propagates the original typed error.

The optional native `didPersist` observer at store lines **48–55,74–78,102–104**
does not supply a persistence result. Its callback is nonthrowing and runs only
after successful write/state publication. LIFO defer ordering releases the store
lock **before** invoking it, permitting the second real writer to commit while
the first callback is held. Shipping Root store construction supplies no observer.

The existing invalidation/actual-execution-completion design remains in place:
retirement revokes future use, while an in-flight resolved reader retains its FD
backing until actual completion. This delta does not add an early FD close.

## Four prepared native regressions

The fixture uses exact production Root methods/initializers and Core queue bodies,
plus the actual native providers, store, Host, registry and session class. Its
UI/context/transport and Python execution are explicitly recorded boundaries.
The transport has no listener/ready token; readiness Python is supplied by
`MaintenanceTestEngine`, with actual Host worker/TLS/registry handling.

All test anchors below are in
`tools/compat/tests/fixtures/native_elyx_mode/ModeABATests.swift`.

| Definition | What the prepared test actually observes |
|---|---|
| `testTwoRealNativeQueuesCommitOffOnBeforeEitherActorContinuation`, **189–257** | Real stop/config providers enqueue separately. The post-write observer holds off, then observes on's actual disk/cache true before either Root writer reaches `changed()`. It requires the old scope, session, registry, pending invocation and unconsumed native-issued capability to be retired. Actual Ingress/Host subsequently refuses the pending request; restart must have a new scope/registry/epoch/session, and both registries reject the old proof. |
| `testFailedOffWritePropagatesErrorAndRestartUsesFreshAuthority`, **260–289** | A directory obstructs the actual atomic preference write. The original Foundation error propagates, cached state and the preserved previous file remain true, and old authority/capability are dead. After restoring its own file, native listener-start obtains fresh authority. |
| `testRejectedPermissionAuthorityAndContextCannotRetireCurrentDeveloperService`, **292–320** | Real Host grant revocation rejects provider admission. Regrant does not revive the captured permission predicate. Direct Root entry also rejects that stale authority and missing context, preserving prior authority and preference bytes. Missing-store/cancellation/termination gates were additionally checked in source, not claimed as separate executed cases. |
| `testAlreadyOffAndCoalescedOnControlsPreserveCurrentAuthority`, **323–352** | Already-off creates no service/session. Subsequent on starts one; actual config-on and native start reuse its scope/registry/session, with one probe and unchanged consent/engine/safe-mode fields. |

The regression does not replace the preference writer or return canned mode
results. `ModeWriteHold:22–54` observes real successful writes after unlock and
controls only their return timing. The two-commit observation at `217–234` reads
the actual file and cache, checks the independent Root-completion counter, and
checks native lifetime objects. `RootFixture.swift:72–88` supplies insertion sites
and boundary wrappers; it does not contain an alternate mode writer.

## Independent checks and limits

**Performed here, with a 30-second outer bound:**

- **72/72 unique read-time file pins** and the sealed corpus matched.
- Ran the driver's **`--prepare` only** in an owned temporary directory, with
  a 20-second child bound. Its generated receipt matched all **64 fixture input
  pins**; all **8 copied UI files** were byte-identical.
- Independently delimited complete Root methods/property, both initializer
  expressions and the three queue declarations; all **13 exact spans** matched
  the seal and appeared once in the generated fixture. Four test definitions
  were confirmed. No Swift process was started.
- A memory-only inverse of the new Root admission block reproduced the previous
  Root hash `3ec2999e…`. Removing only the store's observer additions reproduced
  `e78665ba…`. No source file was reverted or edited.

The seal's current `PluginElyxDeveloperFilesTests.swift` hash `762f265f…` includes
the authorized cancellable helper, its two call sites and two finish defers;
it is outside the Mode fixture's 64 inputs. The qualified descriptor constants
match their sealed postimage as well. These adjacent test/compiler changes are
not treated as new FD findings or as evidence from the separate 47-test run.

The four native Mode tests remain **unexecuted here**. Source preparation is not
compilation or a native PASS; the reported Windows platform skip is likewise not
a pass. This review produces no C/CPython, native listener, actual-account, full-app
or in-flight-FD execution receipt. No CI/status, network, real account or foreign
plugin operation was used. The prior source closures are retained, not rerun.

## Read-time fingerprints

Manifest raw SHA-256:
`f26bf2af05449bffc832f33f9da7ee615fe86693aaf68db837fe61f75bcbec45`.
Its **72-file current-input corpus** recomputes to
`01adac8e4e37194f67e34e8f3306c6453750e89aec245cb8b1ba559c2d173eb8`:
SHA-256 of sorted unique UTF-8 `path + NUL + raw_sha256_hex + LF` records.
Historical preimages and span hashes are excluded from that corpus.

```text
f26bf2af05449bffc832f33f9da7ee615fe86693aaf68db837fe61f75bcbec45 docs/wave-2/native-elyx-mode-aba-inputs.json
cd8829a64228253082717598b45e551e9b91c92e74684bef3734bd89678efbd7 telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift
3adb13b77a4fa351b9bfea3f0e21b9c7cf0f83b707795d095575d90797d3f962 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginManagerPreferences.swift
016b79f1b6135587567e8a20bdbddfc5e6785fcf52219b330119ce8339faa2b3 tools/compat/tests/test_native_elyx_mode_aba.py
39e5586750867ced1ced2d9347791515f7bd4cb4efbe708b0a96abb715702241 tools/compat/tests/fixtures/native_elyx_mode/RootFixture.swift
6ff47c162c7cd274f5361c3bed382b3f71daae004f201e08e19a4a1cf629506b tools/compat/tests/fixtures/native_elyx_mode/ModeABATests.swift
83713520da8a3e28515dd612234c6973792e1ef802a36a2ac8445df0b49fec67 docs/wave-2/reviews/native-elyx-final-source-closure.md
b025b0368fa0ae787e14701073c4b0116cf1378a938bc27bd47d3ceede0cae08 docs/wave-2/reviews/native-elyx-fd-authority-review.md
1b29daf08e5539e7b460bb092b12b34ce9f73149f70a1aea25c3306f49af5ccf docs/wave-2/reviews/elyx-nfd02-closure.md
```

Focused spans use inclusive lines, original indentation, UTF-8/LF and one final LF:

| Span | Lines | SHA-256 |
|---|---:|---|
| `APP#updateManagerPreference` | 1065–1088 | `b59f3a84cb2b3a5607ec944b89c7ee63574e3bec1e7fa600b3dcd8ca619f14d4` |
| `UI/PluginManagerPreferences.swift#apply` | 73–105 | `91abea8a1facabfaa86348d19a599a0a565db411f1225ba53e6097ba6cf0dac1` |
