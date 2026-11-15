# PluginUI / Runtime remediation — HNS and F01/F02 follow-up

Independent reviews: `reviews/host-native-services.md`,
`reviews/host-native-services-followup.md` and `reviews/tools-backup-followup.md`
(read-only).
This work owns `PluginSettingsController.swift`, `ExteralessClient/PluginUI/**`
and new narrowly named helpers. Runtime is coordinator-owned and was not edited
by this follow-up. The HNS and F02 Runtime/harness stitches are present in actual
source, together with coordinator's TL F01 five-argument callback binding.
Current source receipt:
[`plugin-ui-followup-postimage.json`](plugin-ui-followup-postimage.json).
The patch files below are application history, not remaining work.

| Finding | Implemented source | Integration / proof status |
|---|---|---|
| HNS-01 | `PluginUIUnprovenSchemaCache` consumes the new Core evidence contract; current arbitrary SDK results grant no backup fields. Runtime revokes observations on mutations and clears them before maintenance, capturing the location after drain. | Coordinator stitch present; native UI-consumer tests pending. |
| HNS-02 | UI cleanup routes before active-owner acquisition; `PluginUILeaseStore.revoke` validates the stored owner under the resource lock, including bounded tombstone/retirement identity. | Applied in owned UI sources; real-CPython SDK-unload join pending. |
| HNS-04 | Native action authority, account/page revision gates, pre-Task owner/index capture and cancellation-aware typed TaskLocal propagation through existing ManagerActions. UI expiry rejects queued mutations and does not trigger a replacement Python settings read. | UI and coordinator mutation stitch present. Queued reads are addressed separately by F02 below. |
| HNS-05 | Synchronous Host-budget reservation before the UI main hop; credit survives executing, cancelled-retained and deferred URL work. | Applied in owned UI sources; native/ARC execution verification pending. |
| HNS-F01 | The actual UI retained-effect constructor now captures the common `PluginNativeCallLease`. Present/navigation/update/refresh/resource-admission routes retain and check it at native admission. | Owned source applied; real UI-consumer-in-Host-batch fixture authored, execution pending. |
| HNS-F02 | Separate initial/page/read-request permit, captured before Task/await, carried through the settings closure and Host native-only read envelope. | UI, Runtime and harness postimages applied and source-checked. Mac execution pending SDK lead final source. |
| TBF-06 | Fixed ISO archive timestamp and explicit assertion of restore's schema-authority error. | Fixture source corrected; no validators/proof rules changed. Native execution pending. |

## HNS-01 contract to Tools owner

An interpreter/account epoch does **not** authorize backup fields from arbitrary
`create_settings()`. The current SDK supplies no immutable schema/dependency
proof. The UI producer must treat those results as **unproven dynamic display
data** and must not feed them to the old epoch-only `record` grant. In that case
export skips plugin fields and restore rejects those fields, while client-settings
backup stays data-only. No export operation may execute Python to refresh proof.

The requested Core evidence contract must enforce all of these at its actual
descriptor read / restore-stage / pre-install boundaries, not only at `location()`:

1. Exact plugin source identity/content fingerprint, account lifetime, captured
   interpreter owner, exact settings bytes **including absent versus present**,
   and a mutation/dependency revision. Same bytes after ABA are not a revision.
2. A native immutable-schema/dependency guarantee, or a named unproven-dynamic
   disposition. A Bool supplied by the dynamic Python result is not that guarantee.
3. A revocable, Foundation-only evidence capability carried by the detached
   location. `validate` receives the actual file snapshot being used; a captured
   epoch string or an always-true callback is insufficient.
4. Mutations, source/owner/account changes and schema replacement revoke old
   evidence. Revalidation after Host drain/unload must compare the post-drain
   snapshot and source. Pre-drain permissions cannot be frozen through unload
   writes. Once source/owner evidence expires, reacquiring a newest owner by id
   must not revive the old receipt.
5. Restore validation must bind both the read-before snapshot and the proposed
   target under a compatible immutable contract, then recheck immediately before
   atomic install. Failed proof is a skip/rejection, not a fallback to `schemas`
   or `exportableFields` alone. Recovery/journal reconciliation remains Core-owned.

The concrete Core contract is now `tools-schema-evidence-contract.md` and its
implementation supplies `ToolsPluginSchemaEvidence`, `ToolsPluginSchemaValidity`
and the source/settings descriptor checks. `PluginUIUnprovenSchemaCache` consumes
it explicitly with `evidence: nil` / `validity: nil`. It has no immutable-grant
method and invents neither a revision nor a source/settings hash. This is the
current producer's deliberate skip/reject disposition for arbitrary Python,
including equal-byte/time-dependent schemas. It still uses Core's strict decoder.

The coordinator-applied Runtime clears the old cache before mutations and maintenance,
captures its data-only location after drain, and removes the misleading epoch-only
evidence naming. Positive immutable grants stay exclusively with a separate
native-enforced producer; the UI cache cannot manufacture one from a Python Bool.

Authored fixtures: S1 → mode/settings change → S2 in the same interpreter;
unload changing settings after location capture; source replacement between
location and descriptor read/apply. Include a valid immutable-evidence control
and a dynamic-with-identical-bytes rejection. Export/inspection invoke no Python.

The current producer passes **nil evidence**, as the Core contract explicitly
requires for this SDK. It does not claim source/settings revision tracking which
the native storage API has not supplied, and it cannot mint `.nativeImmutable`.
That future path requires the complete source/snapshot/revision/maintenance pin;
the fields cannot be populated with an epoch, mtime, zero revision or a guessed
immutable flag. Core independently denies hand-built allowlists without evidence
at the actual read/apply boundaries. The new fixture uses a separate, truly
fixture-owned native declarative schema as its positive Core control.

## HNS-02: own-resource revocation

`PluginUIBridgeExtension.dispatch` recognizes `uiDismiss` / `menuRemove` immediately
after immutable request-token validation and before `owner()` / UI permission or
account admission. `cleanup` calls the production `PluginUILeaseStore.revoke`.
Inside that lock it compares the request plugin/token with the **stored** owner;
an old token cannot remove a replacement registration using its id or item alias.
The operation only changes the existing lease to dismissing or retires its menu.

Known terminal ids validate their stored owner too. Unknown/evicted terminal ids
are idempotent no-ops and schedule no new work. Malformed requests or identity
mismatches remain errors. Repeated valid dismissal schedules one native dismissal;
the existing FIFO retirement transport owns the single captured-owner release.
Ordinary valid programmatic dismissal retains its existing callback semantics.
During unload, cleanup admission succeeds with no active owner; subsequent native
retirement suppresses user callbacks, and Host destruction owns the final C sweep.

This uses UI's own UUID/owner registry. It does not call NativeServices removal APIs
or release a handle through a newer interpreter. The corresponding NativeServices
fix is independently owned in `native-services-remediation.md`.

## HNS-04 binding to Host owner

Use `host-settings-execution-contract.md` exactly: the native action captures its
`PluginHost.CallbackOwner`, **Int32 SDK account index**, and lock-only account /
rendered-settings revision token before `operationHost()` or any other await.
The Settings controller must revoke the token on invalidation, replacement and
page expiry. Cancellation must reach the token and Host worker predicate.
`expectedOwner`, `account`, `shouldExecute` are passed unchanged to the additive
Host update/click overloads. No worker predicate reads UIKit or waits for MainActor.

Applied UI helpers:

- `PluginUISettingsActionAuthority.swift`: the root installs the real Host owner
  capture and SDK index lookup before startup. Account replacement revokes the
  old lock-only token **before** `services.update`; clear/terminate do likewise.
- `PluginUISettingsActionGate.swift`: opaque account lifetimes and rendered-page
  revisions are never reissued. Publish/invalidate/hide/close change the gate.
- `PluginUISettingsActionInvocation.swift`: a page stores its captured owner and
  account token. Each click/change captures a permit before `perform` creates its
  Task. A subpage forks visibility/revision while retaining the exact owner and
  account lifetime. Worker `isCurrent` reads only locked Foundation data.
- `PluginSettingsController.swift`: all four mutation paths use the invocation.
  Refresh/schema replacement, external invalidation, disappearance and deinit
  revoke old permits. Cancellation/superseded actions exit without a new Python
  settings read. Ordinary current callback errors still reread real stored values.

`PluginUISettingsActionExecution.current` is a typed native TaskLocal, allowing the
existing `PluginManagerActions` constructor/closures to remain source-compatible.
The applied Runtime mutation stitch reads `require(pluginId:)` **before** `operationHost()` and passes:

```swift
expectedOwner: invocation.owner, account: invocation.account,
shouldExecute: { invocation.isCurrent }
```

A MainActor-only `scopeIsCurrent` closure cannot manufacture this capability.
Without the installed authority, a mutation fails by name. The authority binding
is now present in Runtime and the harness. Host's optional nil defaults remain for its separate immediate
probe API; bound native UI actions do not use them.

### Harness join

[`plugin-ui-harness-remediation.patch`](plugin-ui-harness-remediation.patch) records
the prior coordinator-applied `ClientHarnessRuntime.swift` changes. It installs the
same authority with the harness's actual record / explicitly provided SDK slot 41,
forwards its task-local action token to Host, and revokes at stop. The explicit
`actionScope:` factory argument is optional and keeps prior source signatures
usable. That stitch also supplied `return admitted` in the harness's UI release
closure. F02's read-only addition from `plugin-ui-runtime-read-followup.patch` is
also applied: the harness captures `PluginUISettingsReadExecution.current` before
await and forwards exact owner/account/predicate, then checks the result's scope.
No harness source or BUILD was edited here.

## HNS-05: retained effect budget

`PluginUIRetainedEffect` uses the real `PluginNativeEffectBudget.Ticket`:
256 outstanding effects per plugin, 1024 total, 32 MiB aggregate UTF-8 payload by
default. The provider reserves before `DispatchQueue.main.async`; rejection creates
no main work. URL accounting includes both retained input text and parsed URL.

- Clipboard credit ends after the synchronous native assignment or after its
  rejected queued block is actually drained.
- URL credit follows the strong captured effect through the existing deferred
  opening barrier and `UIApplication.open` completion. A handled/cancelled barrier
  drops the continuation without running it; the last ticket reference returns
  credit. A still-retained cancelled closure continues to consume credit.
- Owner/account invalidation changes execution validity, not budget ownership.
  This dedicated UI budget is never cancelled/reset on unload or account changes.
  Tickets complete idempotently and cannot refund a newer ticket's credit.
- Clickable links use the same budget and retain only their small identity/URL,
  not a captured full widget model. URL owner/account/intents/revision checks and
  the native open barrier remain on the actual continuation path.

The Runtime patch retains the NativeServices convenience initializer. Its newly
mandatory controlled callback/result factories from HNS-03 therefore remain
installed; no manual four-argument NativeServices callback is introduced. UI's
separate callback signature still forwards its own mailbox gate and bounded FIFO.

## HNS-F01: batch authority reaches the actual UI consumers

`PluginUIRetainedEffect.init` creates the real `PluginNativeCallLease` on the
originating C owner worker and checks it before reserving budget. The common
constructor captures `PluginNativeExecutionContext.captureGuard()` from Host's
installed worker context. `permitsExecution` combines that lease with the retained
budget ticket; the supplied predicate still checks actual owner/account/permissions.
No new end-of-batch cancellation is invented and no guard is first captured on main.

`PluginUIBridgeExtension.dispatch` captures a common execution lease after active
owner validation and **after** the separate cleanup branch. The lock-only closure
contains owner/UI permission plus batch revocation; captured account scope is
checked by the store and retained effect. This avoids recursively acquiring the
UI store lock while validating its admission.

| Real route | Native admission / lifetime |
|---|---|
| Clipboard / URL | Reservation and lease capture on C before the main hop; check again at actual clipboard assignment / URL continuation. Deferred barrier and UIApplication completion retain the same effect/ticket. |
| Present / navigation / share | Capture before resource readback and lease acceptance. Main checks again before constructing/pushing/presenting native controllers. A revoked pending presentation closes/release-cleans quietly, without a new user error/dismiss callback. Accepted UIKit handoff is not undone by later batch completion. |
| Update | C validates and reserves a queued patch, but does **not** mutate the committed model/revision. Main checks the original lease and scope, commits the model and renders in one synchronous turn. Dropping a revoked patch leaves the prior model intact, including for later partial updates. Patch and validation-model bytes are budgeted. |
| Menu register / replace | The registry mutation itself commits synchronously under the store lock, with the captured execution lease and account checked at that point. Resource readback before that commit carries the retained guard. The later coalesced main notification only projects the current registry; it does not replay a deferred mutation or grant a new resource. Later user menu gestures are independent actions. |
| Settings refresh | C captures/reserves; main checks before posting the notification which causes the actual refresh. |
| State / fragment readback | The already-captured execution lease is checked again in the main readback body. |
| Dismiss / menu removal / retirement | Existing immutable stored-owner revoke-only cleanup. No effect lease or new active-owner capability is acquired. |

`PluginUILeaseStore` now accepts an optional `expectedScope` for accept/update/menu
commit. Production supplies the C-captured scope, checked inside the store lock;
an account change during resource readback cannot redirect admission.

The new fixture creates **`PluginUIRetainedEffect` itself inside A's real Host
batch worker**, then blocks B. It covers batch timeout, native-send cancellation,
timeout after a manual-main deferred URL start, and successful batch completion
(including cancelling the already-completed waiter). A's owner/account/UI grant
are asserted still valid, so a skipped sink must be caused by the batch guard.
Credits remain held until manual-main/deferred drain; a fresh partial model update
also proves the dropped queued patch did not contaminate committed state.

## HNS-F02: queued reads, initial appearance and postchecks

The additive Host contract is `host-settings-execution-contract.md:61+`:

```swift
host.settingsJSON(id: id, account: read.account, expectedOwner: read.owner,
    shouldExecute: { read.isCurrent })
```

`PluginUISettingsReadInvocation.swift` carries the page's immutable owner and SDK
index plus lock-only account/read-request validity. `PluginSettingsController`
captures it before creating a refresh Task. Post-mutation rereads capture their own
read permit before that read's first await. A separate typed native TaskLocal
passes it through the existing `PluginManagerActions.settings` closure.

The page gate allows initial reads during `viewWillAppear`, before a schema or
visible controls exist; it still denies actions in that state. Subsequent reads,
explicit invalidation, disappearance, account change and cancellation revoke old
read requests. Ordinary successful result handling only changes action revisions:
it does not revoke its successful read/batch as a side effect of `apply`/`publish`.
Post-result, post-decode and completion checks remain additional display guards.

The coordinator applied the changes to `Runtime.settings(id:)` and the harness's
settings-read closure. Runtime reads the native read token **before `operationHost()`**, forwards
its exact owner/index/predicate to Host, and retains the existing postchecks and
unproven-schema cache policy. The Host envelope is native-only request identity;
no extra SDK argument or wire-token serialization is introduced for this read API.

New read fixtures hold the event queue with a different plugin, accept P1's read,
then reload P2 / change account / hide page / invalidate the request / cancel.
They assert **no `create_settings` engine entry** from the stale read, then run a
fresh positive read. A separate first-appearance/publish fixture guards the normal
successful read lifetime.

## TBF-06: archive fixture reaches the intended boundary

`dynamicSchemasNeverAuthorize` now uses fixed
`createdAt: "2026-11-15T00:00:00Z"`. It constructs and inspects the real archive
first, asserting that the plugin payload survived. The actual restore must then
throw exactly `ToolsError.invalidArchive("Plugin backup requires current native
schema evidence.")`; an earlier date/shape/I/O error cannot pass a generic rejection
assertion. The positive native-declaration, source/unload/ABA and worker scenarios
remain unconditional later steps of the suite. No archive validator or immutable
proof rule was weakened.

## Applied postimage / Mac gate handoff

Both files from
[`plugin-ui-runtime-read-followup.patch`](plugin-ui-runtime-read-followup.patch)
are applied. The checks read production source directly and no longer reconstruct
or apply patch preimages. Coordinator's newer Runtime/TL/SDK05 regions are accepted:
TL forwards its mandatory fifth predicate as `shouldExecute: $4`; typed
`PluginConfigAuthority`, writer-boundary checks and atomic `.pinnedSet` remain in
the current composition.

[`plugin-ui-followup-postimage.json`](plugin-ui-followup-postimage.json) records
UTF-8/LF-normalized pins for the UI/helpers/fixture sources and exactly three shared
composition regions:

| Region | Postimage SHA-256 |
|---|---|
| Runtime `settings(id:)` | `8367fe40146a2a74dcb29cf5daeabadacfd4e5150e38a4e54aae769f58c9e0ce` |
| Harness `settings` closure | `76471a5408cf6e23d48d19bc362ee7d90fa9bc9dd0b0eac9d223419352307c62` |
| Runtime TL constructor/binding | `f3686c2a862b741b74cbc0bf158568bec9a9042a9c8f1a37b103cd281e97e9f3` |

`plugin_ui_postimage.py` verifies explicit start/end markers and their hashes.
It rejects whole-file Runtime/harness pins. Unrelated coordinator edits outside
these regions do not invalidate the receipt; changes within a pinned region or
helper require source review and an explicit pin refresh.

The Mac fixture runner records `applied_postimage` before compilation and checks
it again before/after executing all 23 scenarios, alongside its existing exact
Core/Host/input/executable fingerprints. It does not compare the entire Runtime
with an old file hash. SDK final-source confirmation is still required before
the coordinator launches that native gate.

```text
python telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/run_remediation_source_checks.py
```

### Prior stitch history

The original HNS patch changed the root's settings authority/cache/read/action/maintenance seams.
SDKConfig composition, `applyGlobalPluginConfig`, UI/TL/NativeServices/Pill bindings,
`onOwnedCallback` TL origin and toggle tracing were preserved. Those earlier
Runtime/harness patches and the F02 read patch are already applied by the coordinator.
Current verification uses the actual postimage and scoped pins above.

Core and Host source/API changes belong to their respective owners. The joined
native gate also needs the SDK owner's account-aware
`setting_changed_json(..., account)` / `setting_click_json(..., account)` and
`_scope(platform, account)` implementation. No Core/Host/NativeService/Python edits
were made by this task.

## Bounded fixtures / receipts

`Tests/PluginUIRemediationFixture.swift` contains **23** small scenarios:

1. Retiring UI dismissal with no active owner provider, duplicate/tombstone cleanup
   and exactly-once captured handles.
2. Old menu cleanup against a replacement id/alias cannot revoke its callbacks.
3. Real Host effect count/byte limits, overflow before manual-main enqueue and
   executing/old-ticket credit.
4. Repeated cancelled-owner submissions cannot bypass retained payload credit.
5. Deferred/handled URL continuation and actual-completion credit lifetimes.
6. Dynamic S1 → value/mode mutation → S2 in one epoch: export skips, restore rejects,
   stores remain intact; post-drain location cannot revive an unload-era schema.
7. Positive immutable native Core control, source replacement before read, changed
   settings bytes and ABA/revoked authority all exercise actual Core archive I/O.
8–12. Block the actual Host owner worker; queue settings change/click; replace
   account, hide page, replace rendered revision or cancel; no settings script reaches
   the engine. The predicate's worker identity is checked.
13. Reload between capture and Host admission rejects the old owner; a current
    callback emits the captured SDK index 41, not account record 9000.
14–17. The actual UI effect consumer created by Host batch A survives successful
    completion, but denies its sink after timeout/cancel while B is blocked,
    including a deferred URL continuation. Retained budget/model state is checked.
18–22. Global queue blocked by another plugin, then read-owner reload, account
    replacement, page expiry, read invalidation or cancellation; fresh read control.
23. Initial read before controls, normal successful publish and non-resurrection
    of an old read when returning to the page.

The fixture uses the **real Host mailbox and effect budget**, with an explicitly
named deterministic `CPythonEngine` fixture. It does not execute CPython, SDK unload,
UIKit, a real account or a socket. Inputs are small; worker escapes are three seconds,
admission waits one second, test batch deadlines 0.5 seconds. The coordinator's
updated runner stages only shipping sources and local Host/Core packages, with
separate bounded compilation (up to 480 seconds) and execution (at most 30 seconds),
source/component fingerprints and process-group termination on timeout. Its cache
and reporting changes were retained. No remote package is requested. Local checks
use `--compile-seconds 20 --run-seconds 5` under a 30-second outer cap; Swift is
unavailable here. The existing 36-scenario Foundation fixture remains separate.

```text
python telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/run_remediation_source_checks.py
python telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/run_source_checks.py
python telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/run_remediation_fixture.py
python telegram-ios/build-system/Make/PostboxImportCheck.py telegram-ios
```

Local follow-up receipts (each command externally capped at 30 seconds):

- Applied F01/F02/TBF06 postimage, scoped pins and TL fifth-argument forwarding:
  **PASS** — 3 shared composition regions and 13 UI/helper/fixture source pins.
- Existing native source checks: **PASS**, 72 dependency targets. The publisher
  assertion now checks the coordinator's typed committed result / unchanged-result map.
  The shared inventory container has advanced since its historical receipt; all
  16 R-runtime kinds/defaults/source references still match exactly. That check is
  scoped to those original records and does not rewrite the coordinator's inventory.
- Full PostboxImportCheck: **PASS** from `telegram-ios`; no allowlist edits.
- Runtime/harness read patch: **APPLIED** by coordinator; retained as history.
- Owned tracked diff hygiene: **PASS** (Git only reports LF/CRLF informational text).
- Follow-up source hygiene, Python runner syntax, staged read helper and the exact
  23-scenario completion contract: **PASS** in the implementation slice. The new
  postimage-check / scoped-pin verification receipt is recorded above.
- Scoped-pin controls: **PASS** — an in-memory manager-only edit and CRLF checkout
  preserve the relevant hashes; changing the read execution guard invalidates its
  pin. No production Runtime/harness bytes were written by these checks.
- UI-consumer/Host 23-scenario fixture: **PENDING**, Swift unavailable on this Windows host.

Coordinator-provided component evidence: `43708260304` / `7d04a35a`,
545 Core / 169 Host / 30 Hooks passed, including the common lease constructor.
No CI was fetched or launched here. That receipt does not execute the new
`PluginUIRetainedEffect` consumer fixture or its F02 read/initial-page cases.

Before a native acceptance claim, run the short real-CPython join: leave an open UI
lease alongside NativeServices scheduler/subscription leases, let SDK
`CallbackLeases.end()` issue cleanup during actual unload, require a successful Host
maintenance lease and one native retirement per resource, and deny new effects from
that retiring owner. Repeat stale cleanup against a replacement epoch. Verify the
queued settings/account-scope cases with the SDK's new account arity too.

Native Swift/UIKit/real-CPython execution and independent re-review remain pending.
This report does not alter the old review verdict. No CI, commit/push, account,
network effect or external plugin was run.
