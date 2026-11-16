# Trust secondary permissions — independent S1/S2/S3 closure

Review date: 2026-11-16. **Disposition: CLOSED_SOURCE / NATIVE_PENDING.**

The three witnesses in [the original review](plugin-trust-level-source-closure.md)
are closed in the pinned production source. No remaining concrete P1/P2
counterexample was identified in this focused admission, continuation and cleanup
review. The old review and historical applied manifest retain their original bytes.
Swift compilation, Apple test execution, recorded UIKit behavior and physical
native/durability validation remain pending.

## Actual integration, not only a ready patch

All **eight ready hashes** in
[`plugin-trust-secondary-permissions.md`](../plugin-trust-secondary-permissions.md)
match the files read. Its appended **Coordinator APPLIED** section at **169–175**
is confirmed by the actual source:

* `telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift:172–181`
  supplies the real dispatcher permission predicate to TL.
* The same file at **213–227** supplies the native share resolver, real permission
  admission, controlled callback and **non-nil `classifyShareFile`**. Classification
  uses `PluginResourcePath` with `services.serviceStorage.filesDirectory` and
  `cacheDirectory` for the bound plugin. The actual provider is bound to its
  callback gate at **228** and installed in the composite at **275–277**.
* `telegram-ios/submodules/TelegramUI/BUILD:95` includes the secondary UI fixture
  in `ClientHarnessSDKFollowupSources`; **846–865** includes the new TL test source
  in the existing native test library/target. These are the coordinator patch's
  three hunks across Runtime and BUILD.
* PluginHost's production source glob and SwiftPM test target include the new
  classifier/tests (`swift/PluginHost/BUILD.bazel:17`, `Package.swift:21–24`).
  TelegramUI's production source glob includes the consumer and fixture sources
  (`telegram-ios/submodules/TelegramUI/BUILD:178–192`). The fixture remains behind
  `PLUGIN_TRUST_SECONDARY_UI_FIXTURE`; the gate owner's later debug define at
  **187** enables that source in debug configurations. The fingerprint entry and
  define provide no automatic fixture invocation or test-execution receipt.

The earlier handoff's staging/“still required” wording describes its pre-application
state. The production binding is present at these read pins.

## S1 — external-file media admission is complete

Primary source:
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLBridgeExtension.swift`.

* Actual single media, edit media and album dispatch classify respectively one,
  optional-one and **all** input resources before `admit` and `scheduleStart`
  (**176–200**). Text-only operations have no file resource. Admission derives
  `{ui, messages.send}` plus `files` when any captured resource requires it, then
  captures one complete predicate before reserving the ticket (**224–250**).
* The original remove-only-`files`/regrant witness now changes an epoch observed by
  that ticket. `permissionsChanged` finishes the denied ticket (**113–116**), and
  `nativeCancellation` retains both its full predicate and original owner
  (**273–276**). Regrant cannot make the old ticket executable again.
* Scheduled consumers receive immutable `PluginResourcePath` values; albums zip
  the admitted resources with their models, checking the counts (**322–419**).
  Their real preparation calls all use `isActive: { !isCancelled() }`. Native
  send/edit/album calls and controlled completions retain that same ticket
  authority. No `mediaURL` or fresh `files` grant is selected after an await.
* The actual reader in
  `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLMediaPreparation.swift:17–48`
  checks the full predicate before metadata inspection, validates the captured
  canonical URL, checks again immediately before `FileHandle` open, and checks on
  **each bounded read**. Post-read/photo/AVFoundation stages continue checking it
  (**48–145**). Thus the former “read while revoked, then regrant before send”
  sequence is blocked before reading when the queued work resumes revoked.
* Negative control: own-root resources do not add `files`; removing that unrelated
  grant leaves their predicate valid. Text-only operations retain the narrower
  set as well. All five discovered preparation call sites—three production and
  two in the new tests—supply the new resource type.

**S1: source-closed.**

## S2 — a rendered link owns its own permission epoch

Primary source:
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIBridgeExtension.swift:818–847`.

The actual `openLink` consumer captures `{ui, intents}` at tap/effect admission
(**830–835**). Its retained effect combines that predicate with the captured
owner/account scope. The deferred `original` checks the retained effect, identical
AccountContext and rendered revision/visibility before opening (**840–842**).
There is no late grant lookup that can revive the pre-revocation opener.

The renderer still calls this consumer (**605–607**). Production defaults still
use `NativeServiceOpenHooks` and `UIApplication.shared.open` (**837–847**), and
the real interception route still retains a one-shot opener and dispatches its
continuation to main
(`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginServices/NativeServiceOpenHooks.swift:33–45,123–129`).

The UI-only parent keeps its own narrower presentation predicate. Lowering then
explicitly regranting `intents` leaves that parent usable while the old opener
remains denied. A **new** authorized link and the false-interception path still
open normally. Successful completion, revoked execution and a discarded retained
continuation refund the same effect ticket; the budget removes each UUID only
once (`PluginUIRetainedEffect.swift:11–24`;
`swift/PluginHost/Sources/PluginHost/PluginNativeEffectBudget.swift:14–16,68–78`).
Optional internal opener/interceptor seams retain those production defaults.

**S2: source-closed.**

## S3 — share dependencies precede resolver, leases and queueing

Primary source:
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIBridgeExtension.swift`.

* Actual C-facing `uiPresent` calls `admitModelResources` before asset/main work,
  native callback-lease acceptance and presentation queueing (**182–198**).
  Classification of all file paths precedes permission capture; `files` is
  derived from `requiresFiles`, independently of current grants (**465–474**).
* With `files` absent for an external resource, the complete predicate fails at
  **474**, before the legacy resolver at **478**. There are **zero resolver calls,
  no new native callback leases and no queued presentation** on that path. The
  earlier `PluginUICallback.map` only parses supplied handle descriptors
  (`PluginUIModel.swift:136–162`); native handle ownership is entered later by
  `PluginUILeaseStore.acceptLocked` (**180–194**). A later grant cannot publish a
  previously rejected request.
* Both the retained effect and presentation lease receive the **same** captured
  predicate (**190–196**). Resolver agreement, file type and continuing permission
  are checked before returning the admitted resources (**475–486**). The resources
  travel through the scheduled closure (**498–502**) to `presentShare`.
* Actual share presentation consumes those captured canonical targets, checks
  resource count, revalidates each target and full authority, and checks again
  before presenting (**658–706**). It does not call the grant-dependent resolver
  or reconstruct file authorization from the original path strings on main.
* Removing `files` retires an external-resource lease synchronously and schedules
  native dismissal (**489–495**). A held presentation cannot reappear after
  regrant; a visible sheet loses its lease; queued non-cleanup deliveries keep
  the full irreversible predicate. `completeShare` also requires that predicate
  (**850–858**).
* Negative control: an own-root share requires only `{ui, intents}`, even if
  `files` happened to be granted during admission. Adding/removing that unrelated
  grant does not retire it. Text/URL-only shares require no file classifier.

**S3: source-closed.**

## Shared classifier and lifetime/cleanup controls

`swift/PluginHost/Sources/PluginHost/PluginResourcePath.swift:6–34` stores an immutable
canonical URL and ownership-derived requirement. Both resources and allowed roots
are canonicalized; ownership uses strict path-component descent, not a string
prefix. Empty/relative/NUL-containing/overlong paths are rejected. Classification
uses path metadata only, with no external content open/read. `validatedURL` rejects
a captured canonical target that later resolves elsewhere.

Current native root aliases are accounted for by
`swift/PluginHost/Sources/PluginHost/PluginServiceStorage.swift:62–73,178–207`: the
files/cache methods use validated native per-plugin components under a canonical
root and reject redirected internal directories. TL retains its additional
double-slash rejection (`PluginTLModels.swift:134–152`). This check covers the
resource-admission dependency, not a broader archive filesystem review.

The following real lifetime paths were also traced:

* **Permission epochs:** unchanged `PermissionsModel.futurePredicate` checks the
  captured required epochs (**PluginModel.swift:388–440**). Real Host consent
  loss emits `bridge.permissionsChanged`, without simulating unload
  (**PluginHost.swift:1314–1345**; `BridgeServices.swift:931–935`;
  `PluginBridgeExtension.swift:53–55`). The consumers above now supply the complete
  required sets to that existing mechanism.
* **TL cancellation/release:** `finish` claims completion once; the registry
  cancels resources while retaining its completion lease
  (`PluginTLBridgeExtension.swift:436–457`;
  `telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLRequestRegistry.swift:149–194`).
  Both normal/fallback callbacks retain `{ ticket.permitsExecution }`
  (**485,493**). A refused release leaves the completion queued; it is removed only
  after FIFO release admission (**531–536**). Revoked payloads are suppressed while
  cleanup drains.
* **UI release pressure:** the lease store reserves handles through retirement
  and rejects new owner admissions while cleanup is pending
  (`PluginUILifecycle.swift:157–194,491–504`). `retirePermissions` selects denied
  leases (**522–529**); non-cleanup deliveries retain their full predicate while
  `closed` bookkeeping remains permitted (**543–554**). `PluginUIReleaseQueue.swift:49–79`
  advances accepted callbacks once and retries a refused callback/release without
  publishing completed retirement early. The captured resource/effect memory
  remains budgeted until a held presentation drains or is discarded.
* **Account/owner binding:** TL retains the context epoch, immutable caller token
  and account record (**224–254,273–297**). UI checks the original owner, scope,
  context, lease/revision and visibility (**UI bridge:410–427,528–542,776–847**).
  Runtime's controlled callback combines permission and UI gates (**219–228**);
  `PluginUICallbackGate.swift:18–29` forwards to the actual provider. The dispatcher
  passes the predicate to Host (**PluginCallbackDispatcher.swift:194–212**), which
  rechecks it at worker entry (**PluginHost.swift:1541–1553,1995–2011**;
  `SubinterpreterManager.swift:429–440`). Releases remain bound to the captured
  owner, with no permission requirement substituted for cleanup authority
  (**PluginHost.swift:1565–1579**).

Here unqualified Host filenames are under `swift/PluginHost/Sources/PluginHost/`;
unqualified UI filenames are under
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/`;
`PluginTLModels.swift` and `PluginTLBridgeExtension.swift` are in its sibling `TL/`.

**MCA17 continuity only:** the ready UI-bridge hash includes the coordinated
three-argument `uiUpdate`, snapshot requirement and reservation (**199–235**), plus
the deferred `finishSettingsUpdate` completion/retirement path (**744–773**).
Those controls and the shared FIFO remain present. This receipt adds no separate
MCA disposition. Coordinated Host/Runtime/BUILD changes are pinned below rather
than compared wholesale against the historical trust manifest as unexpected drift.

## Prepared consumer evidence — not executed

| Source | Relevant prepared evidence |
| --- | --- |
| `swift/PluginHost/Tests/PluginHostTests/PluginResourcePathTests.swift:13–43` | Two cases: nonexistent own resource, sibling/root boundary and invalid path controls; canonical symlink ownership and post-admission retarget rejection. The symlink case is guarded out on Windows. |
| `telegram-ios/submodules/TelegramUI/Tests/PluginTLSecondaryPermissionTests.swift:136–145` | Actual document/edit/album dispatch with absent `files`; no ticket/work/callback/release; later grant creates no old work. |
| Same file, **147–179** | Holds actual start closures, removes only `files`, regrants, checks the captured ticket/cancellation, and invokes the real preparation reader against a now-absent file. Cancellation must win before file inspection. It then drains the actual starts, checks no account resolution/body, and tests refused release retaining the original ticket followed by one `[17]` release. |
| Same file, **181–202** | Own-root actual reader returns the fixture bytes without `files`; refused callback retains the completion, followed by exactly one release and a still-valid callback predicate. Native send/network output is controlled through `finish`, not measured server delivery. |
| `PluginTrustSecondaryUIFixture.swift:155–183` | Uses a genuinely visible alert and directly calls the production `openLink` consumer with a held opener; checks lower/regrant, UI-only parent survival, a fresh authorized/false-interception control and dropped-continuation budget refund. Physical link-tap delivery is not recorded here. |
| Same fixture, **185–234** | Actual `uiPresent`: absent-`files` rejection before resolver; held external share retirement; refused cleanup blocking new leases; visible sheet dismissal and retained callback revocation; real own-root sheet and cancel completion after unrelated `files` changes. |

The UI fixture's full path is
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/PluginTrustSecondaryUIFixture.swift`.
Its request helper uses actual Host bridge dispatch (**111–123**), and its
controlled scheduler drains production presentation closures (**130–135**).
Canned Host engines supply real captured `CallbackOwner` values. The fixtures
exercise consumers and retained predicates, not a second implementation of the
permission policy. Callback transport/OS opening are controlled; Apple execution,
physical callback/release counts and account/owner-transition execution remain
native validation work.

## Independent verification and scope

* **41 bounded read-only source/hash/ordering checks passed** in **0.064 s**,
  including all eight ready hashes, original S1/S2/S3 consumers, applied Runtime
  classifier/controlled callback, both BUILD additions, test-source counts and
  preservation of the old review/manifest. This is source evidence, not Swift
  execution. The handoff's separate 37 assertions remain its own receipt.
* Scoped `git diff --check` returned 0. Every shell command used a timeout of at
  most **30 seconds**. All implementation accesses were read-only.
* Two classifier tests, three TL tests and the compile-gated UIKit fixture were
  inspected, **not run**. No new module/Mac pass, app linkage or visual pass is
  claimed. Native Swift/XCTest, enabled UIKit fixture/recorded frames, physical
  native behavior and durability remain pending.
* No CI, account, network, simulator or plugin execution was performed. Scope is
  the three original secondary-permission witnesses and their negative controls,
  owner/account binding and FIFO cleanup. Archive and MCA reviews keep their own
  dispositions. Trust/resource flags confer no new root/thread/remote privilege.

## Read-time inputs

Worktree HEAD: `aca0eb38ca81f2556b82b3741991730a9a88ff38` (dirty coordinated tree).
The ready/composition sample was taken at tool-reported
**2026-11-15T21:36:06 UTC**, the independent source check at **21:41:58 UTC**, and
additional dependency pins at **21:43:22–21:43:47 UTC**. Three gate-owned BUILD
updates were observed and read at **21:49:08 UTC**; their table rows use the later
bytes. Hashes identify exact bytes; whole-file pins do not enlarge the reviewed
scope.

The initial BUILD pins were TelegramUI
`30f14405d7ba41f9840b8aa67e2c795eaf65a469a9329f631b60c27569f32f3e`,
Tests/Exteraless
`001c31291bfddfb72a750e663993f6261baeb6cbe64dab9ce3e11b4bd6cd424a`,
and Tests/ExteralessHarness
`72f2aec9a87247d6c4dc6562b42ebfabcc080e087e0d45ed151981af6edb8cbd`.
The later graph includes the debug fixture define, the
`SettingsResetNavigationChecks.swift` export and updated harness inputs. These
expected gate-owner changes retain the required trust fixture/test entries;
the eight ready files and actual Runtime classifier binding retain their pins.

### Eight ready files — all match handoff

| Input | SHA-256 |
| --- | --- |
| `swift/PluginHost/Sources/PluginHost/PluginResourcePath.swift` | `fd68d73978d46702f7a1a9e3e08f65e2d20189c0280c6a12b32b92436a6b0e45` |
| `swift/PluginHost/Tests/PluginHostTests/PluginResourcePathTests.swift` | `9762c3cff2bb68ff37daa6c629402db42337dd4afe05e1a3da6eeb24535df4ee` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLBridgeExtension.swift` | `f98ce7dce0500a5e322e68b2fecdbf01d5d1a5cecb98712b4b12f57613bc1583` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLMediaPreparation.swift` | `1610362e479d19d5f37737cc7f46bf105defd432cce84d58b078ff5f307b27cf` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIBridgeExtension.swift` | `cd5704a1efe1b3f532f128273a3707c4cb92baa7fce4e3c73d36827021cf9e9e` |
| `telegram-ios/submodules/TelegramUI/Tests/PluginTLSecondaryPermissionTests.swift` | `13f05fce3e6c053bec2ee26a40a61b09ccbce59f0c220ac7b566e9ca82752c93` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/PluginTrustSecondaryUIFixture.swift` | `0b11364ca436461cebbb1c0b26567f8a476042c4b7064efb18afb742bfa67076` |
| `docs/wave-2/plugin-trust-secondary-permissions-coordinator.patch` | `209a5491435ee927ef488a6fdac3c3f072b65ffcdd578527e0eed0eed32fb57c` |

### Handoff/history and actual coordinator composition

| Input | SHA-256 |
| --- | --- |
| `docs/wave-2/plugin-trust-secondary-permissions.md` | `06c63a7be6fd430767d48df676c36796463a37e42b00653516e38b5a8339ea1d` |
| `docs/wave-2/reviews/plugin-trust-level-source-closure.md` | `0567d638e77f5f4175bea49324dad7a1de9abe5dd156a6c74f6a9feb6dea8e60` |
| `docs/wave-2/plugin-trust-level-applied-manifest.json` | `9801472cdacb919cb6dd16a8d5cdf1fcbcfa673145aae0f28451f7c5bb46d76c` |
| `telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift` | `e6a98f569c043364809500f0870275358b84ab47b85a3ddca931fd4e9237169a` |
| `telegram-ios/submodules/TelegramUI/BUILD` | `ccb2e624b64bd05e52a0d92a5d098e16629af63ce63d2a074d43ad0c689200a4` |
| `telegram-ios/Tests/Exteraless/BUILD` | `57f8863db863891a390a57a1cea22bbce52bb05ec3b45a11ac60ea926acfacd9` |
| `telegram-ios/Tests/ExteralessHarness/BUILD` | `4430b2fad5bb19a53a1d45fc3e7ffa62a1cf6f8abbc2ceb902ddd9178b10493c` |

<details>
<summary>Dependency pins for the traced paths</summary>

| Input | SHA-256 |
| --- | --- |
| `swift/PluginHost/Sources/PluginHost/PluginModel.swift` | `10a00a89ddd35dc08eeb21014aab74f77284d6064ff90e297d9eba56985383e0` |
| `swift/PluginHost/Sources/PluginHost/PluginTrustLevel.swift` | `5880f3e6d9a3c00fb6793de3fa286b571350fbb81f4db7287ef8a6f498ea9ca8` |
| `swift/PluginHost/Sources/PluginHost/PluginHost.swift` | `bd2a4ae136cbb4754db9d14b8ea92d30735c4ef7ca9e9d540fda07f98cf34cca` |
| `swift/PluginHost/Sources/PluginHost/BridgeServices.swift` | `f856f35235a9e5bb022fc57a21ddc9986bf4e60876d3b1feb7fea48cf2284a4e` |
| `swift/PluginHost/Sources/PluginHost/PluginBridgeExtension.swift` | `09c7f5dd4234e96c4f8aeaad07de316743d2ff1672a74a53961bd514539cf47f` |
| `swift/PluginHost/Sources/PluginHost/PluginCallbackDispatcher.swift` | `907f1c8f5efe3b167040c73d10c619b8bbe48cd7dd8fc5477b2cc1b4f441f76a` |
| `swift/PluginHost/Sources/PluginHost/SubinterpreterManager.swift` | `2f01f17fd5e12d1d561339097a25270f4277766cda58f38c36b0f0005dd43c60` |
| `swift/PluginHost/Sources/PluginHost/PluginServiceModels.swift` | `d5cf1997b54359323a38db2dbe39002a59a59642514b8fc27db66dc7184c3815` |
| `swift/PluginHost/Sources/PluginHost/PluginServiceStorage.swift` | `827ce0d50604b56694fbfa83fa7112b7943cf9c33b102de20c57ac9e4ea603d2` |
| `swift/PluginHost/Sources/PluginHost/PluginNativeEffectBudget.swift` | `6dc6a7014d64cf28d33066d5dab475158210aa6bc094d656a61af38c860c97d5` |
| `swift/PluginHost/BUILD.bazel` | `8b68a42288905b1ac9ffd2bf67dec06829f0223fc1d197025053b610a61a3504` |
| `swift/PluginHost/Package.swift` | `fbc50ee84590add303641563b765c189fd1de71d47d8d4939bba42146734766c` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIModel.swift` | `a7772693585250a68b0c01e7c2d5e8e10e9acbd6f371d88f076fa5cf5b7dd3c6` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUILifecycle.swift` | `c6ab4980927ed6e1737fa10d049a6ea68c6952c558fd679e7ba30f10332ebeae` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIReleaseQueue.swift` | `bee70056fb61c58a40474631688be00ccccc96b4aca640e5c5b2e54533ead45e` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIRetainedEffect.swift` | `96ace8e25fa0c32d304ce2828c7cfa3354b1bbb017fa17c00c773310e2a03e88` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIShareFiles.swift` | `bcf60e4ef8ddd38d000b320a098b4b4f87c214155e9af742711b09fbeb5ae114` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUICallbackGate.swift` | `f1ddf2ada609a9005695f15fda2663b40e7ca183978157b933471f66443dd24b` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginServices/NativeServiceOpenHooks.swift` | `2f697cd25a01375ce6ccaa1753e1dec7758eeef8f2c7bfe2f17d11c6a536d7d5` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLModels.swift` | `ba406f0888a2bdf80a455c2d1b1cef79e308a4273b774804ba380ec7209bd061` |
| `telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLRequestRegistry.swift` | `a7ba8101615f8ac6753fe683c115321fb61ebb4c478e88a11fcd3eaa699c93f0` |

</details>

Final read-only verification at **2026-11-15T21:50:55 UTC** matched all **36 input
pins**, including the eight ready files and later BUILD versions. The old review
and manifest matched their initial pins; the latest BUILD diff check returned 0.

Only this new review document was written in this follow-up.
