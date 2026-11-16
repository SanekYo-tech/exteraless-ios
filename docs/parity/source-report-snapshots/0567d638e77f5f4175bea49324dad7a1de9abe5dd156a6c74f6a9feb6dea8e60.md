# PLUGINS-P2-04 — independent trust-level source follow-up

Date: 2026-11-15. **Disposition: NOT SOURCE-CLOSED — three P2 counterexamples.**

The original missing ISOLATED/GATED/TRUSTED cap is implemented. The full requested
source closure remains open because three actual TL/UI continuations do not retain
all required permission epochs. No P1 counterexample was found in this focused
trust review. The counterexamples below are source walkthroughs, not executed
native reproductions.

## P2 counterexamples

### S1 — TL external-file media does not retain the `files` epoch

**Location:**
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLBridgeExtension.swift:224–242`,
especially `permissionAdmission(pluginId, [permission])` at line 235. Media callers
at **182–200** supply only `.messagesSend`, although `mediaURL` at **535–545**
requires `.files` for a path outside the plugin's files/cache roots.

Source counterexample, with unsafe mode off and one own, unchanged interpreter:

1. At GATED, explicitly grant `messages.send` and `files`. Admit a document
   `sendMedia` request for a regular native fixture file outside its own roots;
   retain its scheduled main/preparation work.
2. Remove only `files` through the strict Host grant overload, keeping GATED and
   `messages.send`. Host emits `permissionsChanged`, but the TL ticket still
   permits execution: its retained predicate observes only `messages.send`.
   The retirement loop at **113–116** therefore leaves it running.
3. Regrant `files` before releasing the queued work. `nativeCancellation` at
   **267–270** remains false, and the fresh `mediaURL` check at **330–337** accepts
   the new grant. The old request can prepare/send and deliver its old callback.

Even without regrant, single-file send/edit preparation can read the external file
before the later `mediaURL` recheck. The actual reader is
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLMediaPreparation.swift:16–39`;
its `isActive` comes from the incomplete ticket predicate at TL **323–324** and
**397–399**. Albums use the same incomplete admission, with fresh checks at
**363,374**.

**Closure requirement:** determine the complete permission set at admission,
including `files` for external media; carry the same irreversible predicate through
preparation, native cancellation and callback delivery. Retire through the existing
ticket completion/FIFO release path. Text and own-root media must retain their
appropriate narrower requirements.

### S2 — a rendered UI link's deferred opener can recover after `intents` regrant

**Location:**
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIBridgeExtension.swift:751–771`,
especially the retained-effect construction and continuation at **762–769**.

`openLink` checks `intents` at the tap, then constructs `PluginUIRetainedEffect`
directly with only `isCurrent(owner:scope:)`. That helper checks owner, account scope
and UI at **394–395**. This path does not use the permission-admission helper at
**417–425**. Its deferred `original` checks a fresh `hasPermission(.intents)`.

Source counterexample:

1. An own-plugin `uiPresent` alert with a clickable link is visible, with `intents`
   explicitly granted. Its presentation lease requires only UI (**172–186,
   428–434**).
2. Tap the link and let the existing URL interception barrier retain the opener.
   Native consent is lowered to ISOLATED, then `intents` is explicitly regranted,
   before the opener's queued main continuation runs. Keep the same owner,
   account, rendered revision and visible alert.
3. The UI-only alert correctly survives the lowering; its old link effect also
   survives, incorrectly. The fresh `intents` check passes and
   `UIApplication.shared.open` at **769** runs for the pre-revocation tap.

This is a real continuation route:
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginServices/NativeServiceOpenHooks.swift:33–45,123–129`
retains `original` and dispatches it back to main after a continue-opening decision.
The same own plugin's registration suffices; no foreign plugin is required.
The renderer is connected to `openLink` at UI bridge **553–555**.

**Closure requirement:** capture the `intents` permission predicate when the link
effect is admitted and retain it through the intercepted opener. Preserve the
UI-only presentation and the existing completion/budget cleanup.

### S3 — share admission derives required `files` from current grants

**Location:**
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIBridgeExtension.swift:428–434`,
especially `if !model.files.isEmpty && self.hasPermission(pluginId, .files)` at
**432**. The resulting set is captured by both the presentation lease and retained
effect at **178–186**.

Source counterexample:

1. At GATED with `intents` but without `files`, submit an own-plugin share model
   containing a regular native fixture file outside its own files/cache roots.
   The required set becomes `{ui, intents}`. `requireModelPermissions` at
   **409–414** checks the resolver's presence, not this file's authorization.
   Asset validation at **453–458** only validates UI resources; it does not resolve
   share files. An accepted presentation can therefore wait for main with no
   retained `files` requirement.
2. Explicitly grant `files` before `presentShare` runs. The actual resolver at
   **623–630** consults the new grant through production wiring in
   `telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift:210–215`.
   `PluginUIShareFiles.swift:7–22` consequently accepts the external file, and
   the old request can present at UI bridge **646–648**.
3. Remove `files` again while that sheet is open. Its captured `{ui, intents}`
   predicate still passes, so `PluginUILeaseStore.retirePermissions` does not
   retire this external-file share. Its non-cleanup deliveries also carry the
   incomplete predicate.

The canonical ownership check itself is present at
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIShareFiles.swift:11–18`.
The gap is when its permission dependency is established. A later grant must not
authorize an older admission that needed an absent permission.

**Closure requirement:** determine share-file authorization/dependencies before
queue admission, independently of which grants happen to be present. Retain that
complete predicate for the effect, presentation and deliveries; preserve sharing
from native-owned plugin roots without an unnecessary `files` requirement.

## Confirmed source contracts

Paths below use `H = swift/PluginHost/Sources/PluginHost/` and
`A = telegram-ios/submodules/TelegramUI/Sources/`. These are source observations;
the exceptions S1–S3 limit any blanket retained-effect claim.

| Contract | Source evidence and conclusion |
| --- | --- |
| Original policy | Vendored `PluginTrustLevel.java:35–40,59–109,113–125` and `PluginPermissions.java:82–84,228–281` establish DEFAULT 0; UI-only 0; explicit non-dangerous grants at 1; explicit dangerous grants allowed at 2. Original `has`/`allows` have the unsafe override; Java `getEffective` itself remains cap-only. |
| Native cap and unsafe | `H/PluginTrustLevel.swift:9–70,75–96` and `H/PluginModel.swift:415–451` implement that distinction. A high level grants nothing; hooks/native still need raw grants. Native `snapshot.effective`/`has` include the global unsafe override. |
| Migration and new default | `H/PluginPermissionStorage.swift:63–74,96–107` infers missing levels solely from known raw grants: hooks/native → 2, other non-UI → 1, none → 0. Metadata and unsafe mode are absent from inference. `H/PluginModel.swift:311–323,351–362` durably migrates missing installed records and resets new/orphan installs to DEFAULT 0; replacement without selection preserves consent. |
| Atomic pruning and errors | `H/PluginTrustLevel.swift:63–70`, `H/PluginModel.swift:365–398`, and `H/PluginPermissionStorage.swift:22–42` prune against old and new ceilings and replace level plus grants together. Upgrade cannot expose hidden old bits. Publication follows successful disk return; no post-commit consent-authority check converts success to failure. |
| Strict consent storage | `H/PluginPermissionStorage.swift:45–74,96–129` permits empty storage only for an absent file under an existing directory. Corrupt JSON, unsupported versions, invalid/null levels, unknown versioned fields/permissions, nonregular files and I/O errors propagate. They do not cause empty overwrite. Legacy unknown permission strings retain the previous sanitizing behavior. |
| Legacy native API exception | `H/PluginModel.swift:325–348,535–551` and `H/PluginHost.swift:1149–1170` explicitly distinguish native `setGranted`/old Host setter minimum-tier consent from strict level-aware UI writes. Bulk raw save preserves existing levels. This exception is documented at `docs/wave-2/plugin-trust-level-remediation.md:130–143`; it is not exported to Python. |
| Coherent snapshots and ABA | `H/PluginModel.swift:282–299,379–440` reads level/grants/unsafe/revision together, keeps disk/external predicates outside the snapshot lock, and records permission-specific revocation epochs. A captured required permission stays revoked after regrant. Native snapshot revisions reject A → B → A edits. The defects above omit dependencies at consumers; they do not invalidate this model mechanism. |
| Actual install stage | Both Host branches use post-staging `plugin`, after metadata reinspection and old-owner unload, in `H/PluginHost.swift:993–1023`. Caller metadata retains the ID/enabled role. Consent precedes target replacement, model publication and bootstrap (**1008–1013,1023–1042**). `persistInstalledPlugin`/`persistUninstalledPlugin` write before publishing (**1923–1938**), using the throwing atomic model writer at `H/PluginModel.swift:515–521,556–558`. |
| Failure/readback boundary | Uninstall clears consent before destructive cleanup and propagates failures (`H/PluginHost.swift:1049–1069`). Consent is a separate committed stage, not an archive/files/model-wide transaction; later failure throws without restoring old higher grants. Runtime install/setter errors propagate (`A/Exteraless/ExteralessPluginRuntime.swift:540–591`); manager grant errors reread actual snapshots (`A/Exteraless/PluginManagerController.swift:465–474`), and operation UI renders the real error (`A/Exteraless/PluginUIHelpers.swift:243–267`). |
| Actual native controls | Production manager supplies `trust` at `A/Exteraless/PluginManagerController.swift:49–69`; level/grant rows use strict actions (**346–357**). Document import opens the selection screen (**477–485,581–596**). `H/PluginTrustSelection.swift:6–30` starts at 0/empty, changes levels without selecting grants, and prunes on lowering. `A/Exteraless/PluginTrustControls.swift:36–78,91–98,140–152` implements the controls and explicit install action. |
| Native editor authority | `A/Exteraless/ExteralessPluginRuntime.swift:515–588` captures before Tasks, retains expected consent, and checks at commit. Install pins old plugin/owner/consent at admission. `A/ExteralessClient/PluginUI/PluginUISettingsActionAuthority.swift:42–52` captures even a nil disabled-plugin owner. The page/account gates use nonreissued tokens (`PluginUISettingsActionGate.swift:19–27,42–98`). |
| Read-only own getter | `H/BridgeServices.swift:258–262,394–395,485–510,801` exposes zero-argument `getTrustLevel`, using the bound caller ID; setter/field mutation is absent. C replaces supplied identities (`python/bridge/_exteraless_bridge.c:1956–1994`), rejects rebinding (**3169–3249**), and Host binds before plugin load (`H/PythonRuntime.swift:118–135`; `H/PluginHost.swift:1487–1492`). No cross-plugin argument or Python trust/grant setter was found. |

### Real admission, retirement and cleanup wiring

* **Notification:** `H/PluginHost.swift:1173–1205` runs consent changes under the
  lifecycle/per-ID mutation gate, emits `bridge.permissionsChanged` on effective
  loss, recomputes subscribers and notifies native UI. `H/BridgeServices.swift:931–935`
  forwards without clearing live C accounting; the composite forwards to providers
  at `H/PluginBridgeExtension.swift:53–55`.
* **Core deferred effects:** `H/BridgeServices.swift:1002–1013` captures the actual
  `futurePredicate` before scheduling. `A/Exteraless/TelegramPluginServices.swift:240–277,281–330,368–389`
  retains/rechecks it for clipboard, deferred URL opening and text-send native
  commit/cancellation.
* **NativeServices:** production convenience construction supplies the real
  dispatcher predicate (`A/ExteralessClient/PluginServices/PluginNativeServicesBridgeExtension.swift:86–97`).
  `makeLease` captures required permissions before the main hop (**225–239,265–276**).
  Permission retirement cancels operations/interceptions/leases (**136–143**;
  `H/NativeServiceOperations.swift:113–147`;
  `H/NativeServiceOpenBarrier.swift:272–279`).
* **UI:** ordinary presentations/navigation capture predicates before queueing
  (`A/ExteralessClient/PluginUI/PluginUIBridgeExtension.swift:178–187,267–291`).
  Store retirement and retained `Delivery.permissionIsCurrent` survive terminal
  history eviction (`PluginUILifecycle.swift:292–315,370–395,452–480`). Production
  uses the controlled callback, not the legacy fixture callback
  (`A/Exteraless/ExteralessPluginRuntime.swift:215–220`). S2/S3 are the remaining
  actual-consumer exceptions.
* **TL:** primary permission predicates are captured before `scheduleStart`,
  retained by tickets and forwarded into actual worker callbacks
  (`A/ExteralessClient/TL/PluginTLBridgeExtension.swift:224–270,432–443,459–490`).
  `permissionsChanged` uses existing completion/cancellation and FIFO release
  (**113–116,527–532**); S1 is the missing secondary permission.
* **Config/developer:** settings predicates are captured before enqueue and carried
  into `PluginConfigAuthority`; pending retirement uses those same predicates
  (`A/ExteralessClient/PluginUI/PluginConfigBridgeExtension.swift:27–66,117–133`;
  `PluginDeveloperBridgeExtension.swift:17–53,80–99`). Owner-keyed equality keeps
  per-owner quotas. Runtime supplies real predicates at **242,267**, keeps
  `pluginConfig, developer` provider order at **269**, and passes authority to
  detached preference writes at **1011–1015**. The native writer checks before
  replacement (`PluginManagerPreferences.swift:68–94`). Config's field list
  (**82–83**) has no trust/unsafe setter. Developer start still requires native
  opt-in; get-state projects readiness without returning the credential
  (`PluginDeveloperBridgeExtension.swift:66–78`).
* **Actual callback entry:** `H/PluginCallbackDispatcher.swift:79–81,194–212` carries
  the supplied closure into Host, which rechecks after FIFO waiting
  (`H/PluginHost.swift:1400–1412,1835–1851`;
  `H/SubinterpreterManager.swift:429–440`). Release remains an independent FIFO
  control operation, with no required-permission predicate (**155–163,211–212**).
* **Stored cleanup entitlement:** NativeServices cleanup precedes active-grant
  admission and matches the immutable identity already stored on the resource
  (`H/NativeServiceCleanup.swift:18–43`;
  `H/NativeServiceCallback.swift:190–194`). UI cleanup similarly uses the stored
  owner (`PluginUIBridgeExtension.swift:134–140,341–355`;
  `PluginUILifecycle.swift:230–270`). `closed` bookkeeping remains allowed while
  non-cleanup deliveries retain their predicates (**473–480**).
* **Exact release accounting:** unique lease retirement is guarded by
  `retiredOnce`; terminal delivery retains its entitlement independently of pool
  membership (`H/NativeServiceCallback.swift:120–137,197–277`). Native/UI release
  queues retain refused releases until FIFO admission or actual owner retirement
  (`H/NativeServiceReleaseQueue.swift:25–72`;
  `A/ExteralessClient/PluginUI/PluginUIReleaseQueue.swift:49–79`). C runnable
  accounting remains per-origin/per-handle and decrements once per completion
  (`H/BridgeServices.swift:689–727`); Python completes and releases consecutively
  in its own GIL `finally` (`python/exteraless_runtime/__init__.py:412–423`).
  Permission notification does not simulate unload or erase that ledger.

## Scope and validation status

**NativeUI: yes, actual production manager/install/grant controls are connected in
source.** This does not establish root authority, arbitrary Python main-thread
execution or remote-service privilege. Level selection alone supplies none of
those. Hooks/native-code rows explicitly state platform limitations
(`PluginTrustControls.swift:63–69`); existing owner queues and native developer
opt-in remain separate authorities.

This review follows the consent seams in the shared Host/model files. Archive
owner P1 extraction/cache-field work, upper `Plugin` changes and general archive
filesystem behavior belong to the separate archive review. Whole-file hashes here
pin inputs, not a review of every unrelated body in those files.

Independent bounded local static checks:

* Seven historical payloads contain **95 context hunks + 3 new-file additions = 98**
  across 21 unique paths. The applied manifest adds one Developer path and six
  owned policy/test paths: **28 total**. Payloads remain historical inputs.
* **27/28** manifest files match exact raw bytes (also LF hashes at the first
  sample). At the first audit the sole difference was the authorized BUILD export;
  subsequent composition-only BUILD additions are pinned separately below.
* A read-only scan of **340 Swift files** in PluginHost and the relevant app/test
  roots found **98 call-containing lines** for the consent/persistence APIs checked,
  all with `try`. Host/Runtime/UI propagation was then traced as described above.
  This is textual source evidence, not a compiler result or the handoff's separate
  historical 34-call assertion set.
* Scoped `git diff --check` returned 0. The manifest/count/diff audit took **0.107 s**;
  the caller scan took **0.251 s**; supplemental hashing took **0.004 s**.
  Every shell command in this review had a timeout of at most 30 seconds.
* The provided **9 policy/storage + 4 Host + 2 UI contract cases** are present and
  were read, not executed. Host tests include staged archive metadata versus its
  preview (**PluginTrustHostTests.swift:111–126**) and failed model publication
  (**199–214**). The UI cases exercise the draft and lease store; these 15 cases
  do not drive the three actual continuation paths above.

The handoff's 167 assertions/39 preserved files/32 preserved method bodies remain
its historical receipt, not tests rerun by this reviewer. Swift/XCTest execution,
app compilation/linkage, actual UIKit frames, physical native behavior and
crash/power-loss durability remain **pending**. No CI, simulator, account, network
or foreign-plugin operation was performed. Source closure requires resolving
S1–S3 and checking their actual admission/continuation paths, including release
drain, before any broader native verification claim.

## Read-time input pins and manifest continuity

Worktree base HEAD: `93edf05ec061ff976380465c838f2bfe0fe82caa` (shared dirty worktree;
HEAD alone does not identify these changes). Manifest-covered source samples:
**2026-11-15 20:27:04 UTC** and **20:35:48 UTC**. Handoff documents and Original
authorities were pinned with the first sample; supplemental source hashes were
sampled at **20:37:09 UTC**. Two subsequent BUILD changes were read at
**20:44:40 UTC** and checked at **20:45:58 UTC**; their table rows use those later
bytes. All hashes below are SHA-256 of exact bytes.

| Input | SHA-256 |
| --- | --- |
| `docs/wave-2/plugin-trust-level-applied-manifest.json` | `9801472cdacb919cb6dd16a8d5cdf1fcbcfa673145aae0f28451f7c5bb46d76c` |
| `docs/wave-2/plugin-trust-level-remediation.md` | `ae869ce422b5b8146fbf466c9b21c29a241dc6d764cfbdd521ffe66949ffb733` |
| `docs/plugin-trust-level-remediation.md` | `dc9ad856d1f0e9bf618ce191d681afafbb90bdf4e5fc53b448349e2fb5220cae` |
| `docs/wave-2/module-routes/plugins.md` | `df7986c5bcb4e81bc6113e5a8c165a616d8d5c421655ade6c95c54c1f89a5e84` |
| `third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/plugins/PluginTrustLevel.java` | `5474a7c0fb2235a9ce7f6370fa9c208fb9cb4631e7a3d13b17de6cc75a5adf82` |
| `third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/plugins/PluginPermissions.java` | `344749888cfe8b409bbeb6d828bf2e9c56dadbf4f7559b310882042d09150901` |
| `telegram-ios/Tests/Exteraless/BUILD` | `001c31291bfddfb72a750e663993f6261baeb6cbe64dab9ce3e11b4bd6cd424a` |

For the 27 matching paths, the immutable manifest above supplies the exact source
hashes. In particular the findings use its unchanged TL bridge
`cf692f8205717edc0f810089d1a14f490d23bbeb5903337fef511cd029892499`
and UI bridge
`65814d7032e377c3c29c0639864c23e46ba4693783d46506dbb783e35e036aae`.

At 20:35 the Tests BUILD was **10,566 bytes**, SHA-256
`8d6349b229fdf223b16e5c6be026729ca4ff923ec9ff8ad5dca058687b168bc5`,
versus the manifest's **10,445**. Removing only the **121-byte** `exports_files`
block at `telegram-ios/Tests/Exteraless/BUILD:8–12` for
`SettingsSearchUIViewRouteChecks.swift` reconstructed the historical hash
`0665dd2749723e181dd37bdf67fc545fcb5bbba4843c52994b1efb933d9ac61b`
exactly. This is the coordinator's subsequent Settings Search export, not trust
drift. The manifest is preserved as history.

During final verification two further parallel composition additions appeared:

* Tests BUILD gained the **62-byte** suite row
  `//Tests/ManagerCustomAlias:ManagerCustomAliasTests` at **260**, becoming **10,628
  bytes**. Removing that row exactly reconstructs the 20:35 hash above, then
  removing the Settings Search export reconstructs the applied-manifest hash.
* `telegram-ios/submodules/TelegramUI/BUILD:76–96` gained the **1,198-byte**
  `ClientHarnessSDKFollowupSources` filegroup, becoming **49,186 bytes**. Removing
  just that block reconstructs its 20:37 source pin
  `4931ffba01c25541800582d062c4f7640966539b4f3131e4bdb87ce7702acf2b`.

These additive graph changes do not supply execution evidence or alter the three
findings. Trust test source/dependency entries remain at Tests BUILD **55,65**;
production globs include the new Swift sources (`swift/PluginHost/BUILD.bazel:17`;
current `telegram-ios/submodules/TelegramUI/BUILD:169–180`, formerly **148–159**).

<details>
<summary>Supplemental source pins used for continuation, cleanup and build tracing</summary>

| Input | SHA-256 |
| --- | --- |
| `python/bridge/_exteraless_bridge.c` | `f9a94d4ed8cbaa7fae9e23f7b232313fa838a89c5407b60a603cebcea277f92a` |
| `python/exteraless_runtime/__init__.py` | `cf1feebdc7534faf4237a76ed32b8f81fa1f8bf19bff3ef42a72c8164223c12d` |
| `swift/PluginHost/Sources/PluginHost/NativeServiceCleanup.swift` | `1b820dc298fe2442a456d6d6b483510dfe51ad6a27649b9d1a234952b0d10f39` |
| `swift/PluginHost/Sources/PluginHost/NativeServiceReleaseQueue.swift` | `91b6e32299632e4960c581ddab40f02d15b13c4ac42e7fb26d899af43253f525` |
| `swift/PluginHost/Sources/PluginHost/PluginServiceModels.swift` | `d5cf1997b54359323a38db2dbe39002a59a59642514b8fc27db66dc7184c3815` |
| `swift/PluginHost/Sources/PluginHost/PythonRuntime.swift` | `1e9235e65f1fb860da218317a033d12e2b37f545b2b2dbdad33de29fce6544f1` |
| `swift/PluginHost/Sources/PluginHost/SubinterpreterManager.swift` | `2f01f17fd5e12d1d561339097a25270f4277766cda58f38c36b0f0005dd43c60` |
| `swift/PluginHost/Sources/PluginHost/SecurityGates.swift` | `2467c87171c86cb7e9f1960afbd57f087000b2fcf5e33e6a98854d60fd7a7bba` |
| `swift/ExteralessCore/Sources/ExteralessCore/ExteraConfigCompatibility.swift` | `35eee798ab988f79f6a2d77e512b8fedda06c1d2f3f41f4cc65e345b8e4ffefe` |
| `swift/PluginHost/BUILD.bazel` | `8b68a42288905b1ac9ffd2bf67dec06829f0223fc1d197025053b610a61a3504` |
| `swift/PluginHost/Package.swift` | `fbc50ee84590add303641563b765c189fd1de71d47d8d4939bba42146734766c` |
| `telegram-ios/submodules/TelegramUI/BUILD` | `dac21918e3660159d9863f22a74618c91169013a8e39f337e0b81fa2686d92bf` |
| `telegram-ios/submodules/TelegramUI/Sources/Exteraless/TelegramPluginServices.swift` | `291507fe97af636bfd2aff7cfc60f1410712c3ec04468a6926523f9f0959ee87` |
| `telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginUIHelpers.swift` | `2efbc39538adffee7b457d0e359da2937d5c76d5184313c90330ab7b721d0e0c` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginServices/NativeServiceOpenHooks.swift` | `2f697cd25a01375ce6ccaa1753e1dec7758eeef8f2c7bfe2f17d11c6a536d7d5` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIReleaseQueue.swift` | `bee70056fb61c58a40474631688be00ccccc96b4aca640e5c5b2e54533ead45e` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIRetainedEffect.swift` | `96ace8e25fa0c32d304ce2828c7cfa3354b1bbb017fa17c00c773310e2a03e88` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIResources.swift` | `b2c2fee2a8c61c80a038378d873215380537261bd013f751535b8461cb8512b7` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIShareFiles.swift` | `bcf60e4ef8ddd38d000b320a098b4b4f87c214155e9af742711b09fbeb5ae114` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIModel.swift` | `d61ea20efaf8ac9b6c733796fc9eb6ef49e82ca9276bb7d0cc2e9c07d804a7a0` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUISettingsActionGate.swift` | `dc0f894d909340d48ffa227ae7e68721ddc01f53cab1a598f6c9fc89496024fb` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginManagerPreferences.swift` | `e78665ba5d8c6a3ea47dae228ed69cd03b0586e9fdff8425265eb5faed9e4f44` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLMediaPreparation.swift` | `987db9218fd79bbaa7cca7cfc67d94a96bd2ed00d53635e03ff614488e126da7` |
| `telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLRequestRegistry.swift` | `a7ba8101615f8ac6753fe683c115321fb61ebb4c478e88a11fcd3eaa699c93f0` |

</details>

Final read-only verification at **2026-11-15 20:46:45 UTC** matched all **31 explicit
pins** and all **28 manifest paths** with the documented later BUILD version:
**58 unique input paths**. The later BUILD diff check also returned 0.

Only this new review document was written by this review; implementation and
historical manifests/payloads were read-only.
