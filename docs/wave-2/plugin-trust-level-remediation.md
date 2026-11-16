# P2 plugin trust-level remediation — applied native integration

Date: 2026-11-15. Scope: `module-routes/plugins.md:92–100`.

**APPLIED:** all seven integration payloads have been merged into the current
shared source with `functions.patch`, following the coordinator's explicit
authorization. Source is ready for cohort freeze. Native Swift/XCTest and UIKit
execution remain unverified in this Windows session.

## APPLIED — cohort freeze receipt

The [actual-source manifest](plugin-trust-level-applied-manifest.json) covers all
21 original integration paths, the additional
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginDeveloperBridgeExtension.swift`,
and six owned policy/test paths. `sha256` hashes exact worktree bytes;
`lf_sha256` additionally supports line-ending-normalized cohort transfer.

Integration details beyond the historical patch payloads:

* Both Host install branches commit consent using the **post-staging `plugin`**,
  after archive re-inspection and old-owner retirement, before native file
  replacement and bootstrap. Caller `metadata` retains its existing ID/enabled
  role. No new install can bootstrap before its DEFAULT-0 or explicit selection
  record is durably written.
* `PluginDeveloperBridgeExtension` now requires `PluginPermissionAdmission`.
  Start/stop creates its settings predicate before `queue.enqueue`, stores it in
  owner-keyed `Admission`, and carries it through `PluginConfigAuthority` into
  execution. `permissionsChanged` retires denied pending admissions; active work
  retains the same irreversible predicate. Per-owner quotas, native opt-in and
  get-state readiness/credential handling retain their prior contracts. Runtime
  supplies the real dispatcher predicate and retains `pluginConfig, developer`
  provider order.
* The owned Host install test now exercises a data-only archive fixture whose
  staged permissions/version differ from its early preview. Post-staging metadata,
  initial zero consent and explicit replacement selection are asserted together.
  The manual UI fixture reports a missing template after removal rather than
  indexing an empty fixture array.

**Source verification completed:** 167 assertions passed in a bounded local
read-only source audit; 39 coordinated files retain their exact bytes and 32
existing method bodies match the captured pre-application source. This includes
Host archive load/copy/cache-related paths, send priority query/sort/admission,
settings page lease reads/actions, Runtime page forwarding and closeAll on
update/clear/terminate, the archive picker/copy, and C callback ledger methods.
The protected file comparison includes coordinated Python runtime/reflection/
developer/hook code, ExtensionPoints, page-lease contracts, targetRowId/focus and
manager Custom sources. All 34 discovered throwing consent calls use `try`.
`git diff --check` and source trailing-whitespace checks passed for this scope.

Prepared tests remain **9 policy/storage + 4 Host + 2 native UI contracts**.
The UI test source and PluginHost dependency are already on
`Tests/Exteraless/BUILD:NativeUIContractsTestsLib`. Native Swift/XCTest, app linkage
and recorded UIKit frames were not run. No CI, real engine, external plugin,
account or network operation was used. The focused native validation after cohort
freeze is `swift test --package-path swift/PluginHost --filter PluginTrust`.

The seven `.patch` files below are historical, already-applied payloads; the
current source and new manifest are the freeze inputs.

## Authority and behavior

Authority read directly: vendored
`third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/plugins/PluginTrustLevel.java`
(DEFAULT, migration, setLevel/pruning, allows) and `PluginPermissions.java:228–282`.

| Level | Effective authorization with unsafe mode off |
| --- | --- |
| ISOLATED / 0 / new-install default | UI only, independently of raw stored grants |
| GATED / 1 | UI plus explicitly granted non-dangerous permissions |
| TRUSTED / 2 | UI plus explicitly granted permissions, including hooks/native only when granted |

The existing **native** global unsafe mode overrides authorization, corresponding
to original `has`/`allows`. `PluginPermissionRecord.effective()` is the cap-only
projection; `PermissionsModel.snapshot(...).effective` includes that override.
The latter is not a claim that original Java `getEffective()` itself expands unsafe
mode. Level changes prune stored grants even while unsafe mode is active.

A level/grant is not platform support. Native screens explicitly label hooks as
Android/JVM/Xposed-unavailable and native-code consent as unable to enable
unsupported native-library loading. No engine/GIL lifecycle or platform loader is
changed by this work.

## Written owned files

Under `swift/PluginHost/`:

* `Sources/PluginHost/PluginTrustLevel.swift`: typed levels, raw consent record,
  coherent permission snapshot/revision, admission closure type and typed errors.
* `Sources/PluginHost/PluginPermissionStorage.swift`: strict, locked, versioned
  `grants.json` migration and atomic replacement.
* `Sources/PluginHost/PluginTrustSelection.swift`: actual native install draft;
  level selection never selects grants, and lowering a draft prunes its grants.
* `Sources/PluginHost/PluginModel.swift`: **only PermissionsModel and PluginStore
  lower sections, starting at PermissionsModel line 274**. The upper Plugin,
  PluginFileFormat, ID grammar and permission-enum sections belong to the archive
  owner. Existing upper-file changes in the worktree are not this task's changes.
  The lower model-file writer is also serialized and uses direct Foundation
  atomic replacement, so the throwing Host model publishers have a real result.
* `Tests/PluginHostTests/PluginTrustLevelTests.swift`: nine policy/storage cases.
* `Tests/PluginHostTests/PluginTrustHostTests.swift`: four Host/bridge/retirement
  cases over the applied Host and bridge integration.

## Storage and compatibility contract

Same location, same file: `grants.json`. New representation:

```json
{"version":1,"records":{"alpha":{"level":1,"grants":["network"]}}}
```

Legacy `{ "alpha": ["network", "hooks"] }` remains readable. Migration uses only
actual known raw grants: hooks/native → 2, other non-UI → 1, otherwise → 0.
Metadata requests and unsafe mode do not participate. Existing levels are not
re-inferred. A version-1 record with a missing level is also migrated; explicit
null, bad types, invalid level values and unknown version-1 fields/permissions
are errors. Legacy unknown permission strings are ignored as by the previous
native reader. Installed legacy IDs with no grant entry are pinned to 0 together
by `migrateInstalled`, without changing existing consent.

Migration must be written successfully before model publication. Only an absent
file in an existing consent directory means an empty store. Bad JSON, unknown
versions, missing directory, directories/symlinks in place of the file and I/O
errors do not fall back to empty consent and do not overwrite the bad input.

`setLevel` writes level **and** pruned grants in a single atomic replacement. It
also prunes bits already forbidden by the old ceiling, so upgrading a mismatched
old record cannot reveal hidden grants. Reopen/upgrade does not recreate consent.
Clearing a record removes both fields together.

Source-compatible native call names now propagate errors:

* `PermissionsModel.load`, `setGranted`, `clear` are `throws`.
* `PluginStore.loadGrants`, `saveGrants` are `throws` and use the versioned records.
* `saveGrants` remains a full raw-grant replacement, preserving and respecting
  existing levels; only a new entry derives a tier from its supplied grants.
* **Legacy native explicit-consent contract:** `setGranted(id, grants, to:)` and
  Host's existing `setGrantedPermissions(id:permissions:)` mean the caller
  explicitly consents to the supplied list and its minimum tier. They retain a
  higher existing tier. They do not derive consent from metadata and are not
  Python setters. This preserves existing native fixture/integration callers,
  including callers after a new DEFAULT-0 install.
* Level-aware UI uses `setConsent` / the Host `atLevel:expected:shouldExecute:`
  overload. Forbidden selections throw; a level alone grants nothing.

Store transactions finish all decoding/encoding and the captured authority check
before atomic replacement. There is no post-commit cancellation/authority check
that could report an already committed consent change as uncommitted. On a failed
write, the model retains its previous published state. The snapshot lock is not
held during disk work or external predicates. Unsafe mode, level, raw grants and
native-editor revision are read together. Permission-specific revocation epochs
make a captured `futurePredicate` permanently false after the required permission
is removed, even if it is regranted before worker entry. Native editor revisions
also reject A → B → A stale selections.

## Historical shared-file payloads — applied in this order

These files use the **OpenCode `*** Begin Patch` format**, with exact context
hunks. The initial handoff staged them in a temporary copy. They have now been
applied to shared source, with the post-staging Host and Developer additions
recorded above, preserving the coordinator's already-applied changes.

1. [`plugin-trust-level-host.patch`](plugin-trust-level-host.patch)
   * Constructor: throwing load and batched missing-record migration.
   * Public/private install: optional native `selection`, one-time `admission`
     and continuing `shouldExecute` predicates; existing call labels still work.
   * New install pins DEFAULT before bootstrap; replacement without a selection
     preserves consent. Explicit native selections are committed before file
     replacement; a replacement's new selection is committed only after retiring
     its old interpreter. Rechecks follow archive metadata/unload awaits.
   * Uninstall clears consent before destructive source/archive/model cleanup;
     failure cannot be swallowed. Source removal and model-write failures throw.
   * `persistInstalledPlugin` / `persistUninstalledPlugin` publish metadata only
     after the throwing model write, rather than the old log-only writer.
   * Snapshot read, legacy setter, strict setter and `setPluginTrustLevel` all
     use the existing lifecycle/per-ID mutation gate. Successful changes invoke
     `permissionsChanged`, recompute subscribers and notify native UI.
   * Required `try` adaptations in the two existing test files are included.

2. [`plugin-trust-level-bridge.patch`](plugin-trust-level-bridge.patch)
   * Bridge extension/composite `permissionsChanged` forwarding, preserving live
     C pending-reference accounting instead of simulating an owner unload.
   * Captured permission predicates for deferred core native effects and the
     existing dispatcher; NativeServices lease/operation/interception retirement.
   * NativeServices and TL capture predicates before queue hops; TL cancellation
     uses its existing ticket completion/FIFO release path.
   * Native Runtime **read-only** `getTrustLevel()` (zero arguments, C-bound own
     plugin ID) in bootstrap admission, dispatch and member discovery. No SDK or
     Original file changes, no cross-plugin query, no level/grant setter export.

3. [`plugin-trust-level-native-ui.patch`](plugin-trust-level-native-ui.patch)
   * New `PluginTrustControls.swift`, optional `PluginManagerActions.trust` and
     actual production action wiring. Existing constructors retain their labels.
   * Three checkmarked level rows, capped grant toggles, unsafe-mode explanation,
     explicit platform limitations and persisted-state readback after errors.
   * Native document import now previews metadata and opens an install-selection
     screen before installation/execution. New drafts start at 0 with no grants;
     replacements start with current consent. Requests are displayed separately.
     Pending preview waits for the manager's actual post-picker appearance.
   * `PluginImportCopy` becomes an immutable lifetime-owned class so the selected
     staged file survives the preview and pending install, then is cleaned up.
     Archive-owner picker formats, extension validation and ID rules are not
     replaced by this hunk.

4. [`plugin-trust-level-runtime.patch`](plugin-trust-level-runtime.patch)
   * Reuses `PluginConfigAuthority` and the existing settings account/page gates.
     Native button factories capture page/account/owner **before** creating a
     Task; nil owner for a disabled plugin is also captured, not reacquired.
     Factories are bound to the manager's original AccountContext.
   * Detached writer rechecks that capability and expected snapshot at commit.
     Install additionally captures the prior owner/plugin/consent for admission
     under Host's mutation gate. Actual results reach the native operation UI.
   * Wires the real dispatcher permission-admission provider into TL/UI.

5. [`plugin-trust-level-ui-retirement.patch`](plugin-trust-level-ui-retirement.patch)
   * UI presentation/navigation leases retain their permission predicate at
     admission. Existing lease retirement dismisses revoked native effects.
   * Queued UI deliveries carry that predicate into the controlled dispatcher
     callback; regrant or terminal-history eviction cannot revive their bodies.
     Closing bookkeeping retains the existing captured-owner FIFO release path.
   * The original four-argument UI callback constructor remains a legacy native
     fixture transport; production supplies the controlled callback explicitly.

6. [`plugin-trust-level-config.patch`](plugin-trust-level-config.patch)
   * Existing Config command admission captures the settings permission predicate
     before queueing. Retirement and the already-existing `PluginConfigAuthority`
     reject pending/in-flight stale grants. Per-owner queue limits keep their
     original owner identity. The closed Config field list gains no trust/unsafe
     mutation operation.

7. [`plugin-trust-level-ui-tests.patch`](plugin-trust-level-ui-tests.patch)
   * Two native UI contract cases, exact Tests/BUILD entries, and prepared
     `PLUGIN_TRUST_UI_FIXTURE` manager/install entry points for a loginless harness.

### Coordination / transaction boundary

At initial inspection this checkout contained `PluginConfigAuthority`, captured
owners, page/admission guards and FIFO retirement machinery, but no named
`permissionsChanged` or permission `futurePredicate` path. The patches add the
missing forwarding and reuse those existing mechanisms. If the coordinator has
already introduced equivalent names in another pending patch, merge at these
same call sites rather than defining a second retirement or authority system.

Consent replacement is one atomic file transaction; it is not a transaction over
all archive files plus `plugins.json`. The supplied install/uninstall hunks make
consent a durable stage, then call the archive owner's file pipeline and throwing
model publisher. A later archive/model failure returns an error and leaves any
already committed consent visible; it must not restore old higher grants. The
archive owner should retain its source rollback/staging behavior around these
points. No source-file transactional success is inferred from a consent receipt.

No `Plugin` field, metadata wire key, archive ID grammar, source/archive suffix,
pin-preference name or SDK symbol inventory is added/renamed. API coordination is
limited to the throwing persistence methods, optional install/action arguments,
new typed read/set-level methods and permission-admission/retirement hooks above.

## Tests and BUILD needs

**Prepared, not executed here:**

* 9 `PluginTrustLevelTests`: new default/orphan reset/replacement/clear; raw legacy
  tier migration and reopen (including unsafe and no-grant IDs); independent cap
  over mismatched stored bits; downgrade/upgrade pruning and reopen; legacy native
  API plus strict level-aware writes/bulk compatibility; strict corrupt-storage
  failures; migration/write failures with unchanged bytes/state; commit-authority
  timing/publication; permanent retained predicates, A-B-A revision and coherent
  concurrent unsafe snapshots.
  Write failure includes a real atomic-write destination obstruction after decode,
  in addition to the deterministic pre-commit failure seam.
* 4 `PluginTrustHostTests`: actual pre-load default/install selection and read-only
  bridge/no setter; real captured-owner dispatcher dropping queued persistent and
  terminal bodies after lower/regrant with signal cancellation/exact FIFO release;
  failed permission/uninstall propagation; failed metadata persistence refusing
  installed success/publication.
* 2 `PluginTrustUIContractsTests`: real install draft selections/caps/pruning;
  shipping UI lease retirement, queued predicate persistence beyond history,
  UI-only preservation and permitted closed bookkeeping.

SwiftPM discovers owned source/test files automatically. PluginHost's Bazel
`Sources/PluginHost/**/*.swift` glob already covers the three new source files.
With the Host + bridge integration now applied, the focused native command is:

```sh
swift test --package-path swift/PluginHost --filter PluginTrust
```

Host waits are explicitly bounded to 2–4 seconds, stop to 2 seconds; synchronous
logic cases have finite local-file loops and no network/engine work. Each case is
designed for the requested ≤30-second bound. No full suite/CI was launched.

The applied UI test patch adds `PluginTrustUIContractsTests.swift` to
`telegram-ios/Tests/Exteraless/BUILD:NativeUIContractsTestsLib` and adds
`//third-party/exteraless:PluginHost` there. Existing Foundation UI-contract
filegroup sources already include `PluginUILifecycle.swift`. Production
TelegramUI's source glob includes the new controls. The optional visual fixture
requires `-D PLUGIN_TRUST_UI_FIXTURE` and a supplied loginless harness context;
it does not install itself or start Runtime/accounts/network.

## Initial handoff verification / remaining native validation

* Exact-context source staging succeeded for all seven integration patch files
  (98 hunks/additions across 21 shared/new source paths);
  generated previews are only under
  `C:\Users\sasha\AppData\Local\Temp\opencode\trust-integration-preview`.
  This validates hunk application, **not Swift compilation**.
* `git diff --check` on the owned source change returned no whitespace errors.
  The five new owned Swift source/test files also passed a trailing-whitespace check.
* Swift/SwiftC are unavailable on PATH here, WSL is not installed, and this
  Windows session has no Apple simulator tools. Swift tests, Tests/BUILD linkage
  and actual UIKit presentation/recorded frames remain unverified.
* Coordinator-provided Core/SDK green `20e16` and the running full-app CI are
  background receipts only. No status was queried and no CI was launched.

Before visual verification, expected frames are: DEFAULT-0 is the single checked
level and all grant switches are off/capped; GATED changes only the checked level
until a non-dangerous grant is actually selected; TRUSTED enables dangerous
consent choices while keeping the platform-limit text visible; lowering clears
the affected switches and upgrading leaves them clear; a failed save shows its
error while retaining the previous stored selection. Inspect light/dark and large
text for wrapped, unclipped cap/limitation text and stable selection. Record the
prepared manager/install fixture and label frames/times using
`telegram-ios/AGENTS.md` before claiming any visual pass. No frames or actual
UITests baseline are claimed by this handoff.
