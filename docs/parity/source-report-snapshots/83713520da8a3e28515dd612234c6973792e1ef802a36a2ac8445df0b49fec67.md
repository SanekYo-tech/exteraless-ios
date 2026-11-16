# Native Elyx — final independent source closure

**NFD-01 and NFD-03 are source-closed. Production startup/readiness/TLS is actually
joined, but one P2 remains: competing developer-mode off/on writes can preserve
the old activation/session.** No remaining P1 was found in this scope. Native
compilation, the 47 core / 7 ingress tests and the fifth real C/Swift child are
execution evidence still to be supplied; they are not counted as passes here.

Review date: **2026-11-16**. Observed HEAD:
`54b2f7e8586b42ca5537333133d2427c2cccfae2` plus the frozen working-tree cohort.
Initial read: `2026-11-15T23:56:17Z`; pin recheck:
**`2026-11-16T00:03:23Z`**. Only this new report is authored.

| Reviewed item | Verdict | Decisive source change |
|---|---|---|
| NFD-01, cleanup after staging namespace loss | **P1 source-closed** | Continuous namespace and directory-binding checks now surround lookup/quarantine/unlink, including failed initialization and the old `beforeCleanup` witness. Loss retains data and closes new stage admission. |
| NFD-03, lost publication knowledge | **P2 source-closed** | One native publication state reaches Host, transaction, Root/Ingress and protocol. Known commit/unknown outcomes survive subsequent persistence, load and delivery failures. |
| Production activation/readiness/TLS | **Joined; one remaining P2** | Real installation, challenge and worker TLS are present. The developer-mode transition race below can avoid revoking a previously valid activation. |

NFD-02 retains its [independent closure](elyx-nfd02-closure.md) at the sealed
`_archives.py` hash `72380885…`. Its supplied Linux **50/0** result is separate
execution evidence, not a rerun by this review.

## Frozen input verification

The [final manifest](../native-elyx-developer-final-inputs.json) and
[owner's final handoff, line 616 onward](../native-elyx-developer-remediation.md)
were checked against actual files:

- **41/41 changed-file postimages, 11/11 read-only inputs, 4/4 historical handoffs
  matched. Zero unexpected source drift.**
- Its complete **58-record** corpus recomputes to
  `3895957680f1d1378276ea97eb12c2d500b5c25b247a2993c74188e01d84d4cb`.
- The other two records are explicitly **tooling preimages**. Their current
  bytes correctly differ after coordinator application. All **12/12 complete
  tooling postimages** matched uniquely at the initial check. A later parallel
  parent-driver update retained the fifth-child route and strengthened the input
  guard; its successor hash and verification are recorded below.
- All three prior review files were preserved; their hashes appear below.

`H` below means `swift/PluginHost/Sources/PluginHost/`; `U` means
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/`;
`APP` means `telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift`.

## NFD-01: the exact destructive-cleanup witness

The earlier witness moved `.elyx-developer-staging/op-…` to `stolen-stage` in
`beforeCleanup`, then dropped the last prepared reference. The old helper used
the still-open directory FD to delete the candidate despite namespace loss.

Current `H/PluginElyxDeveloperFiles.swift` closes that route:

1. `ElyxStage.deinit:556–574` runs the fixture hook, then **checks the continuously
   held namespace before any rename/unlink**. A stolen or ABA operation directory
   reaches `requireRecovery`, retaining the candidate.
2. `elyxRemoveOwned:436–472` calls the supplied namespace guard and
   `directory.verify()` before lookup and again after `cleanupLookup`. Even
   ENOENT is revalidated before returning. The guard runs again before the
   quarantine's unlink or attempted restoration.
3. Candidate removal uses the full stage watch throughout. Operation-directory
   removal establishes a **parent-only watch while full custody is valid**
   (`563–572`). After its own expected quarantine rename, deletion checks that
   parent watch rather than rejecting its own rename event. The moved inode must
   still match, and directory removal remains nonrecursive.
4. Failed initialization uses the same guarded cleanup (`529–544`). `self` is
   initialized only after all throwing candidate checks (`523–528`), so a failed
   initializer and destructor do not become competing cleanup owners.
5. Namespace/cleanup failure records recovery (`676–678`); subsequent stage
   admission rejects it (`668–674`). A new provider also refuses a nonempty
   staging root (`615–617`).

**Positive cleanup remains reachable:** an intact candidate can be quarantined
and removed, followed by its empty operation directory. Own leaf writes do not
count as namespace-self renames, and the parent-only watch permits the expected
operation-directory rename. Guarded publication rollback is still a separate
two-slot operation.

The real-provider test definitions now contain the exact old witness at
`swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperFilesTests.swift:588–607`:
candidate bytes must survive and the next prepare must report recovery. Additional
tests at `609–696` cover loss after lookup, failed-init loss, ABA at both hook
boundaries, and intact failed-init cleanup followed by successful retry. These
use actual filesystem/provider operations; they have **not been executed here**.

## NFD-03: typed outcome through the full response path

### File engine and retained commit state

`H/PluginElyxDeveloperFiles.swift:36–52` preserves the typed underlying error and
these meanings:

| `publication_outcome` | `source_changed` |
|---|---|
| `refused` | `false` |
| `rolledBack` | `false` |
| `committed` | `true` |
| `recoveryRequired` | JSON `null` |

The exchange still verifies both actual slots and their bytes. Once confirmed,
a directory-sync failure does not become a no-write refusal: `836–865` confirms
the installed candidate and emits committed, or retains staging and emits
recoveryRequired if confirmation is impossible. An unprovable rollback also
retains staging and emits unknown (`867–892`). The production default uses real
directory fsync; the optional hook is explicitly a native fault-injection seam.

`H/PluginElyxDeveloperRequest.swift:167–203` carries monotonic publication knowledge:
recoveryRequired is sticky, committed cannot be downgraded by a later refusal,
and typed nested errors preserve their outcome. It is native invocation state,
not a request-field capability.

### Actual Host → transaction → Root/Ingress → listener

- `H/PluginHost.swift:1140–1159` records commit **immediately after** successful
  `prepared.publish`, before published-source checks, model persistence, verified
  load and final scope checks. File-engine exceptions enter the same typed state.
- `loadPlugin:1702–1793` reports its original typed error through `onFailure` at
  lines 1716/1765. `publishElyxDeveloper:1153–1156` retains/rethrows that failure;
  it does not reconstruct its kind from `Plugin.loadError` text.
- `H/PluginElyxDeveloperTransaction.swift:193–213` records successful publication
  before final session/owner/model/source checks and contextualizes thrown errors.
  An unsuccessful new load returns the structured failure with commit knowledge.
- `APP:1078–1138` creates publication state before the first changes guard,
  adopts the captured plan's same state, passes it into Host, and retains it in
  the outer Root catch. Therefore readiness/admission failures are refused, while
  failures after publication retain the later outcome.
- `U/PluginElyxDeveloperIngress.swift:37–67` retains the state's reply before late
  actor/session guards and preserves it through both ordinary conversion and the
  scalar fallback. `H/PluginElyxDeveloperRequest.swift:145–160` emits `ok=false`,
  selected `plugin_id`, `reloaded=false`, `error_kind`, `error`, `errors`, outcome
  and Bool/null source-change fields.
- `U/PluginDeveloperProtocol.swift:52–62` preserves the handler's Boolean false
  and replaces only `#` with the original request correlation ID. The actual
  listener at `U/PluginDeveloperServer.swift:138–149` no longer performs a late
  cancellation throw that replaces the handler's committed receipt with a bare
  error. Existing epoch/connection checks still control delivery.

For these response fields, `H/PluginServiceModels.swift:88–99` encodes null and
Bool distinctly; `U/PluginUIModel.swift:28–32,54–67` retains NSNull/CFBoolean and
encodes them back to JSON. The reviewed guarantee concerns the typed outcome
envelope, not arbitrary userdata or all Cocoa/serialization alias behavior.

### Prepared tests exercise the pipeline

`PluginElyxDeveloperTests.swift:241–343` tests all four outcomes through the actual
transaction, late session/owner/model/source failures, an actual Host model-write
failure after publication, and an actual Host verified-load failure preserving
its original type. The file publication in the latter Host tests is an explicit
recorder; they are not substitutes for real FD publication.

`PluginElyxDeveloperProtocolTests.swift:66–143` drives actual ingress/protocol
conversion, including late delivery guards and pre-admission no-execution. It
asserts the original fields, outcome, Bool/null and correlation ID together.
`PluginElyxDeveloperFilesTests.swift:718–743` faults the directory-sync boundary
after real exchange and checks committed/true plus actual installed bytes.
`NativeDeveloperServerProbe.swift:85–122` cancels its own handler after producing
a committed failure and checks the receipt on the actual listener wire.

These are prepared native test definitions, not formatter-only assertions and
not new execution passes from this review.

## Production startup, readiness and TLS

### Actual installation is called

There is no remaining unused-factory gap. Both `APP.updateDeveloperServer:1014–1042`
and authenticated `handleDeveloperRequest:1078–1138` call
**`PluginHost.activateElyxDeveloper(scope:isCurrent:)`**. The handler captures its
plan before the readiness await, then obtains `service.fileAuthority()` and
passes that actual provider to Host execution.

`H/PluginHost.swift:928–937` enters lifecycle admission and acquires/prepares the
Host-owned service. `H/PluginElyxDeveloperService.swift:171–192` coalesces the same
Host/scope, invalidates a superseded service, and calls `attach`. `attach:37–44`
installs `registry.dispatch` using the atomic dispatcher/epoch API at
`H/BridgeServices.swift:201–228`.

The service constructor/attachment are native-only, even though the service type
and Host activation API are public Swift. They have no Python bridge export.
`U/PluginDeveloperBridgeExtension.swift:8–11` still exports only the three bounded
listener controls. No generic issuer, context installer, source-registry or FD
registration operation is exported to Python.

### Readiness requires a real native observation

1. Service setup is coalesced and runs in `Task.detached`
   (`PluginElyxDeveloperService.swift:89–140`), including file-anchor construction.
   Failure clears cached setup/proof/files for retry; success is published only
   while Host, activation and dispatcher epoch remain current.
2. `PluginHost.probeElyxSourceReadiness:944–991` issues a new native challenge and
   creates a **fresh metadata interpreter with `allowThreads=false`**. Its
   metadata bootstrap (`H/PythonRuntime.swift:100–104`) imports the trusted runtime,
   excludes the plugin root and does not configure/load a plugin entry.
3. `python/exteraless_runtime/_elyx_readiness.py:12–46` verifies bounded lowercase
   challenge syntax, built-in module origin/name, the exact module-bound builtin
   `xt_elyx_source`, archive ABI and the three callable hooks. It calls ordinary
   `check` with an unknown ticket and requires the exact native Superseded error;
   unexpected success or any other error fails.
4. C `python/bridge/_exteraless_bridge.c:3529–3592` supplies immutable module-state
   identity (or the unbound inspector label), uses the retained dispatcher under
   the caller GIL, and frees the response buffer. The applied early route at
   `BridgeServices.swift:238–255` reaches this registry, not a legacy service.
5. `H/PluginElyxDeveloperDescriptor.swift:185–204,369–373` observes the nonce only
   under its exact issued inspector TLS context, matching C inspector identity
   and null owner. It still returns the normal unknown-ticket error and issues
   no read authority. `PluginElyxDeveloperReadiness.swift:19–31` independently
   requires **exactly one native observation**, matching challenge/ABI/hooks and
   Boolean rejected=true. A fabricated positive Python JSON receipt is insufficient.
6. `PluginElyxDeveloperService.swift:115–164` binds the receipt to this registry
   and dispatcher epoch, then constructs the real file authority with concrete
   Host inspector, current-owner, target and consent predicates. Readiness is
   neither a hardcoded true closure nor merely a list of available names.

### Worker scope, captured target and retirement

Readiness TLS is installed in the actual interpreter `shouldExecute` closure and
cleared by `onExecutionFinished` (`PluginHost.swift:970–978`). Candidate inspection
does the same at `1018–1055`. Ordinary manifest and verified-load invocation use
the actual captured owner or issued new-load consumer at `2078–2147`.
`H/SubinterpreterManager.swift:429–442` executes those closures on the native
mailbox worker, with completion in `defer`. The MainActor publishes service state;
it does not install interpreter TLS there.

`APP:1092–1110` captures target IDs, native owner, persisted model, consent revision
and account before awaiting activation. The subsequent path rechecks those
captured values and account mapping; it does not take a new target snapshot to
revive a retired request. `PluginHost.swift:995–1013` compares the captured owner
and consent; transaction/Host publication retain their existing per-ID reservation
and expected old-owner retirement rules. A normal update is not rejected merely
because that transaction deliberately unloaded its old worker.

| Retirement event | Actual revocation path |
|---|---|
| Account/context change | `APP:62–77` calls `stopDeveloperServices` before `services.update` publishes replacement account state; clear-context does so at `93–110`. |
| Termination | `APP:613–647` invalidates the activation/service at line 617, before its first await, then drains Host and uninstalls the native binding. |
| Engine/safe-mode or settings maintenance | `APP:808–809,948–950` synchronously stops developer services; Host maintenance separately invalidates its slot at `PluginHost.swift:786–790`. |
| Host stop/replacement | Host stop invalidates before waiting and again at the stopping transition (`702–737`); Runtime retires the old service before assigning a new Host (`APP:166–167`). |
| New activation / dispatcher ABA | Service slot validates the old scope before replacement. Every dispatcher assignment advances its epoch; obsolete removal requires its own exact epoch (`BridgeServices.swift:205–228`). |

`APP:1044–1062` invalidates the captured activation object, file/service references
and Host slot. `PluginElyxDeveloperService.invalidate:55–65` clears readiness,
cancels setup and removes only its own dispatcher epoch. Registry invalidation
marks retained entries unusable without closing FDs still held by actual work
(`PluginElyxDeveloperDescriptor.swift:166–179`).

Read/check require current authority; release retains the recorded caller's
cleanup path, including retirement (`Descriptor.swift:329,372–400,502–516`).
Native scope finish removes read tickets even if Python release did not run.
Resolved readers keep their duplicate FD/backing through in-flight execution;
Host's `PluginInvocationRetention` retains issued load sources until the actual
worker finishes. Clearing a waiter or service does not recycle that FD early.
The new real-FD test at `PluginElyxDeveloperFilesTests.swift:745–765` explicitly
checks refusal after retirement, live FD while retained, then EBADF after final
reader release. Its execution remains pending.

## Remaining P2 — DEV-LIFECYCLE-01: developer-mode ABA can skip retirement

**Locations:** `APP:1065–1075` (`updateManagerPreference`),
`APP:1014–1042,1053–1057` (sampling the latest mode and reusing the scope), and
`U/PluginManagerPreferences.swift:68–95` (persisted Boolean without a transition
revision). This is a concrete interleaving in the reviewed startup/teardown path,
not a filesystem or generic serialization finding.

`updateManagerPreference` first awaits a detached `store.apply(change)`. Only
after that await does it call `updateDeveloperServer()`. The latter acts on the
**current snapshot**, rather than the transition that completed. Neither method
invalidates the activation/session before the off write or records that an off
transition occurred. The store's lock serializes writes, but not their subsequent
MainActor continuations.

There are actual independently queued callers:

- Native listener stop → `U/PluginDeveloperBridgeExtension.swift:40–53` →
  `APP:262–274` → `.developer(false)`.
- Global config `setPluginConfig("developerMode", true)` →
  `U/PluginConfigBridgeExtension.swift:50–66,109–123` →
  `APP:751–775` → `.developer(true)`.

Those providers have separate `ExteraConfigCommandQueue` instances. Each queue
awaits its own command, not the other provider's command. The public manager
control at `APP:738` is another caller of the same async writer. Developer-mode
changes also bypass the engine/safe-mode busy wait at `APP:754–765`.

**Minimal permitted schedule, source counterexample; not executed on Windows:**

1. An activation, session and pending Elyx request exist with developer mode on.
2. Caller A enters `.developer(false)`, submits its detached write, then suspends
   on MainActor. Caller B enters `.developer(true)` and also suspends on its write.
3. The preference lock commits **false, then true**, before either MainActor
   continuation runs. All native owner/settings grants remain unchanged.
4. Both continuations call `updateDeveloperServer()`. Both see true, so neither
   takes `stopDeveloperServices()` at line 1017.
5. `elyxActivationScope()` returns the still-current old scope. The service slot
   reuses its matching Host/scope/dispatcher epoch; the listener also retains its
   existing active session. A pending request rechecking after the two writes sees
   true again and can continue with its old activation.

This schedule requires no fabricated JSON authority or invalid input. MainActor
reentrancy at the two existing awaits and the two native queues permit it. The
new explicit scope invalidation correctly handles an off state **when observed**;
it does not latch this intervening off transition. The existing activation tests
and fifth child explicitly invalidate their scopes; they do not drive competing
Root preference writers through this sequence.

**Required closure:** revoke the old activation/session as part of the accepted
off transition, or use a monotonic transition revision which old work cannot
regain by reading a later true. Preserve failure handling for the durable write.
A bounded regression should hold both actor continuations until the two real
preference writes finish, then assert the old scope/session is retired, its
pending request is rejected, and a new activation uses a new registry epoch.

## Fifth child and full parent driver: source-connected, not a native PASS

The coordinator's 12-hunk tooling join was verified. The executable dispatches
`--elyx-developer` at `python/runtime/smoke/swift_plugin_probe.swift:398–402`, before
existing helper startup. The parent compiles the fifth Swift source and stages
its pinned helper/emitter/inputs.

`tools/runtime/fixtures/swift_sdk_elyx_developer_probe.swift` uses real
`CPythonXCFrameworkEngine`, `NativeBridgeBinding`, public Host activation, registry
and FD provider. Its engine observer forwards production scripts; the three
negative readiness attempts remove/change actual attributes only in their own
fresh inspector. The assertions cover:

- real missing-gate/hook/ABI refusal followed by readiness/retry (`190–205`);
- disabled inspection/install without entry, then actual initial owner (`207–236`);
- both NFD-02 FD refusals with old owner/source/model/consent unchanged, **one
  load and zero unloads**, no new loader or retained stage/ticket (`250–279`);
- changed entry class/helper/asset/metadata/same-filename wheel, actual new-owner
  verified load, clean compare and no grant from declared network metadata
  (`281–311`);
- stale owner/session/source, dispatcher ABA, retired activation and decoded
  old-capability refusal (`313–357`);
- two real owners plus ten data-only inspectors, one initialize/finalize, all
  three Python hooks/five registry operations, and zero remaining custody,
  handles/leases/plugins/external effects (`361–404`).

The report validator at `tools/runtime/fixtures/elyx_developer_probe_driver.py:70–141`
requires exact true fields, script counts, actual source paths, changed snapshots,
refusal fields and cleanup state. The parent at
`tools/runtime/check_swift_plugin_embedding.py:626–645` remains `ok=false` until
the fifth process returns, its detailed report/marker passes, and the complete
five-child source hashes still agree. A completion marker alone is insufficient.
The later parent-driver image calls
`validate_cohort_inputs(source_hashes)` for the final guard. That helper rejects
an empty inventory and missing/changed inputs; staged copies/manifests are also
added to the hashed inventory, which is checked before child execution as well.

The six emitted artifacts plus observer are bounded to 32 KiB aggregate by the
staging driver; the child report is independently bounded, and execution uses the
existing 30-second process-group runner. This review checked the source connection
and requirements; it did not launch the child or any CI process.

## Verification and remaining execution evidence

- **Fresh here:** 41 sealed changed postimages, the other current input pins,
  sealed 58-record corpus, all 12 tooling postimages, four Python AST checks, and
  **four isolated Python readiness-negative children passed** on CPython 3.14.8
  in 0.179 s. Each had a 20-second bound; the tool had 30 seconds. Each reported
  zero entry calls and `native_readiness_claimed=false`.
- Native definitions were independently counted: **29 Files + 6 Activation +
  12 Transaction/Host = 47**, plus **7 Ingress**. Activation tests use real Host
  workers/TLS/registry with a stated Python execution recorder; the fifth child
  supplies the distinct real-C/CPython proof when run.
- The unchanged C source remains `2d4ea9f3…`. Supplied **7/7 on both Python
  versions** establishes its prior C-gate/recorder behavior, not execution of
  this native registry or production activation. Supplied Linux NFD-02 50/0 is
  likewise not promoted into 47/7 or fifth-child passes.
- Windows has no Swift execution result here. The coordinator's native executions
  remain outside this review. No account, external plugin/archive, HTTP, CI or
  progress-poll operation was used.

This source verdict closes the two specified cleanup/outcome counterexamples and
confirms the production join, with DEV-LIFECYCLE-01 remaining in mode-transition
retirement. It does not certify UIKit/app behavior, arbitrary userdata
serialization, all SDK symbols or a full native acceptance result.

## Read-time anchors and preserved reports

The complete frozen source scope is the linked final manifest: raw SHA-256
`15082e16ba5fd4d4edcd285ff685d3b7a1b9910a4b71405f47d91e8ae4b290a2`, with the
58-record corpus above. Rechecking its 56 current-file records found no drift.
Current tooling images and additional caller/conversion inputs are pinned
below, alongside the three untouched prior reports. Raw bytes are hashed without
newline normalization. The three additional mode-writer context files were
captured at `2026-11-16T00:08:08Z`; the frozen Runtime/Service bodies already
contained the reported interleaving. At `00:11:41Z`, a parallel parent-tooling
update changed `check_swift_plugin_embedding.py` from the initially verified
`493243fd98365a5511810eceebc499f1681f67b8f2eb9ab45df62011ad73e682`
to the successor below. Its fifth-child call/report checks and factored final
source guard were reread. The 56 frozen current-file records still matched.

```text
15082e16ba5fd4d4edcd285ff685d3b7a1b9910a4b71405f47d91e8ae4b290a2 docs/wave-2/native-elyx-developer-final-inputs.json
97449670d3711d9c3a6ef9c8905abb59047c7c89f784867a0c0a58d03bb18790 python/runtime/smoke/swift_plugin_probe.swift
82466e1fe26e94ef1a69ab5c273edbcf25b621d2dfd78099692c1c52e493c20d tools/runtime/check_swift_plugin_embedding.py
1e9235e65f1fb860da218317a033d12e2b37f545b2b2dbdad33de29fce6544f1 swift/PluginHost/Sources/PluginHost/PythonRuntime.swift
2f01f17fd5e12d1d561339097a25270f4277766cda58f38c36b0f0005dd43c60 swift/PluginHost/Sources/PluginHost/SubinterpreterManager.swift
27f65038bf5c316494bcdbecbf4f1c0f83a567d01e3d471120c1a6d3b00d7246 swift/PluginHost/Sources/PluginHost/NativeBridgeBinding.swift
d5cf1997b54359323a38db2dbe39002a59a59642514b8fc27db66dc7184c3815 swift/PluginHost/Sources/PluginHost/PluginServiceModels.swift
a7772693585250a68b0c01e7c2d5e8e10e9acbd6f371d88f076fa5cf5b7dd3c6 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIModel.swift
e78665ba5d8c6a3ea47dae228ed69cd03b0586e9fdff8425265eb5faed9e4f44 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginManagerPreferences.swift
48f6e7690a46474cae73a1bb13418b667cad645e2d0716ad534dd54c73ccabb9 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginConfigBridgeExtension.swift
35eee798ab988f79f6a2d77e512b8fedda06c1d2f3f41f4cc65e345b8e4ffefe swift/ExteralessCore/Sources/ExteralessCore/ExteraConfigCompatibility.swift
d4f4c8b4443b0fb943fd170cbff6343fc05d47225d350ae6addc249582301256 docs/wave-2/reviews/sdk-symbol-remediation-source-closure.md
b025b0368fa0ae787e14701073c4b0116cf1378a938bc27bd47d3ceede0cae08 docs/wave-2/reviews/native-elyx-fd-authority-review.md
1b29daf08e5539e7b460bb092b12b34ce9f73149f70a1aea25c3306f49af5ccf docs/wave-2/reviews/elyx-nfd02-closure.md
```

Focused span hashes use inclusive lines, UTF-8/LF, original indentation and one
terminal LF. `H` and `APP` expand as defined above.

| Span | Lines | SHA-256 |
|---|---:|---|
| `H/PluginElyxDeveloperFiles.swift#cleanup` | 436–472 | `e34678b37842cfa6794c7fee3d1a9fe682d24632877202c645eac31981f7ef6b` |
| `H/PluginElyxDeveloperFiles.swift#ElyxStage.deinit` | 556–574 | `459adfed5b443b067a2fa64a05be7c057d31e6cc8ff829fe9d88555168c53e9c` |
| `H/PluginHost.swift#activateElyxDeveloper` | 928–937 | `6dfe3a4552fbaf138500a68f436e261be5d316ac1cc9bf5f64d3035b8b0f6e7d` |
| `H/PluginHost.swift#probeElyxSourceReadiness` | 944–991 | `49edb0abff6d5ff8648e3b249da6cf6bad884b83971aea240b4a314b47701263` |
| `H/PluginHost.swift#publishElyxDeveloper` | 1107–1160 | `2bdd8888aaf6c882593dc57db030ceac947b8e5abdd3c9498abd29033b72675f` |
| `H/PluginHost.swift#invokePlugin` | 2078–2147 | `e26607e6684afaa776cf75d9a07f17d3df8cfd712d4fa0a9567ea06b4401b23c` |
| `APP#updateDeveloperServer` | 1014–1042 | `5bb0a1e3b751c5f642e83528252645c7afbbea080916ed04406ebda836d685d0` |
| `APP#handleDeveloperRequest.elyx` | 1078–1139 | `e4fe6551a34dab3fe1ce63a1d054a30a68fee8aa81075f6dcf9d783d126637c6` |
