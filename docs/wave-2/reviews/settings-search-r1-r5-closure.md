# MS-ROUTE-01 R1–R5 — independent source closure

**R1–R5 are source-closed at the reviewed pins. No remaining P1/P2 root cause was
identified within these five counterexamples.** The production callers consume
the new lifetime/schema authority; the fixes are not confined to helper tests.
Native app/UIKit execution and frame acceptance remain pending.

Review date: **2026-11-16**. Tool-reported UTC pin captures:
**2026-11-15 21:25:11–21:32:03**. Observed local HEAD advanced from
`27360543173ace07c77efed82b4d85d16d376acc` to
`4bd2f7e31568acc4723f5269a30977d78cf1c461` during the authorized fixture correction.
Working-tree hashes below identify the reviewed app sources.

Scope is the five witnesses in
[settings-search-source-closure.md](settings-search-source-closure.md#remaining-closure-counterexamples).
That report remains byte-identical, SHA-256
`a649cc519b15ea93ac959d3905f66c9072c5485aa789c018e011b5db0ad52c86`.
This new report is the only authored file. The Reset owner's two P2 findings and
their independent evidence retain their existing scope.

## Verdict ledger

| Witness | Current disposition | Load-bearing change |
|---|---|---|
| **R1 — launch/notification URL reaches intent hooks before denial** | **Source-closed** | `openUrlWhenReady` calls the existing client-settings consumer after privacy recovery and returns before intent interception. |
| **R2 — pending unlock operation rebinds after same-object ABA** | **Source-closed** | Preparation captures a concrete session and typed selection; one-shot start and session-owned cancellation prevent reacquisition after retirement. |
| **R3 — queued observers miss schema A→B→A** | **Source-closed** | The actual store publishes per-definition identities under its cache lock; every native admission reads those identities directly. |
| **R4 — default Root/private editor permits a missing session** | **Source-closed** | Default factories return optional results from the installed matching provider; private construction requires a live session and ticket. |
| **R5 — Nagram fallback discards an explicit class** | **Source-closed** | Fallback candidates retain the explicit class-page intersection; supported unqualified and correctly qualified moved rows remain available. |

## Source path key

| Key | Repository path |
|---|---|
| `CORE` | `swift/ExteralessCore/Sources/ExteralessCore/` |
| `CLIENT` | `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/` |
| `APP` | `telegram-ios/submodules/TelegramUI/Sources/` |
| `AC` | `telegram-ios/submodules/AccountContext/Sources/` |
| `HARNESS` | `telegram-ios/Tests/ExteralessHarness/Sources/` |

### R1 — the real application ingress now consumes the canary locally

`APP/AppDelegate.swift:3424–3455` now has this order:

1. Clean the opening URL using the existing rules.
2. Consume privacy recovery; clear `openUrlInProgress` and return when recognized.
3. **Consume client settings; clear `openUrlInProgress` and return when recognized.**
4. Construct the ordinary opener and offer it to `NativeServiceOpenHooks`.

Thus the original input
`tg://settings/exteraless/setting/clientAPI.customAppHash?value=OWNED_CANARY`
cannot reach that intent-hook branch. `clientCleanOpeningURL:3006–3012` preserves
recognized client bytes for validation. `consumeClientSettingsURL:3039–3053`
consumes recognized input even without a ready provider. Its existing
`ready && !locked`, `take(1)`, 30-second timeout and captured
`self.contextValue === context` checks remain present. Replacement cancels
`settingsRouteDisposable` at **1594**, and termination disposes it at **2557**.
The original account-ID selection in `openUrlWhenReady:3411–3422` is retained.

The ordinary `openUrl` ingress still performs the same early consumption at
**3069–3071**. `AC/ExteralessSettingsSearchEntry.swift:88–103` and
`CORE/ClientSettingsSearchIndex.swift:303–359` keep the canary a recognized,
invalid client link with a typed local error. No value payload is forwarded by
this newly joined branch. The actual AppDelegate launch/notification route is
source-reviewed here; the given-context fixture does not execute AppDelegate.

### R2 — a pending operation owns its original session

`APP/OpenUrl.swift:369–378` calls `ExteralessSettingsSearchEntry.prepare` **before
`dismissInput()` and before subscribing to unlock**. The returned operation, not
a raw URL/provider lookup, survives the wait.

The connected implementation is:

- `AC/ExteralessSettingsSearchEntry.swift:61–67` parses once into a typed request
  or error. A malformed query is not retained as the prepared selection.
- `CLIENT/ExteralessSettingsSearch.swift:180–204` resolves at admission and captures
  **`[self]`**, the concrete session, plus the immutable result/ticket or error.
  The continuation contains no call back into the global provider registry.
- `ExteralessSettingsSearchOpen.start:31–35` clears its stored closure before
  invocation. Repeated starts cannot admit another opening.
- Session `pendingURLs` owns the `MetaDisposable` before subscription. Retirement
  sets `active = false`, retires the index and disposes pending waits at
  **103–111**. Provider replacement invokes the previous provider's `retire()`
  at Entry **46–52**; an identical provider installation is an idempotent no-op.
- Before calling the supplied parent lookup, the unlock continuation checks the
  captured session and context at Session **193–198**. Even if the same
  `AccountContext` object becomes current again, the original session remains
  inactive. A prepared-but-not-started operation encounters the same check at
  **185–186**.
- The wait retains `filter`, `take(1)` and the 30-second timeout. Completion removes
  and disposes its subscription. SwiftSignalKit's actual `MetaDisposable.set`
  handles an already-disposed instance, including synchronous signal completion;
  `DisposableSet.dispose` releases its lock before disposing members
  (`telegram-ios/submodules/SSignalKit/SwiftSignalKit/Source/Disposable.swift:107–149,169–213`).

After the parent is obtained, `navigate:222–240` validates the captured ticket
again, including after `endEditing` and before committing a factory result to the
navigation stack. Action replacement/ABA still changes the registration UUID and
fails the old ticket. A **new explicit** open may prepare against the new provider;
the old pending operation cannot turn itself into that fresh open.

### R3 — publication identity survives an undrained MainActor observer queue

The new state is narrowly located in `ClientSettingsSnapshot.definitionVersions`,
`ClientSettings.Cache.definitionVersions`, and the index fingerprint's
`definitionVersion`.

`CORE/ClientSettings.swift:898–920` holds `cacheLock` while it compares the old and
next definitions/classifications, assigns each current definition a UUID, and
publishes the entire next cache. Its only cache replacement is **917**. Successful
operations, public batches and failure recovery all reach this publication point
(**387–463,521–527**). `readSnapshot:336–341` reads definitions, versions and
classifications under the same lock.

For the original native witness, the state progression is now:

```text
publish A -> version u0; obtain ticket t0
register B -> publish version u1
register A -> publish version u2
session.accepts(t0), without draining MainActor tasks -> reads u2 -> false
```

The store performs both publications synchronously before returning from the
registration calls. The native observer still schedules a MainActor task, but
that task is no longer responsible for remembering B. Session `refresh:123–132`
passes the **actual** `snapshot.definitionVersions` to the index. `accepts`,
`resolve`, `open(ticket:)` and navigation refresh on admission. The UUID participates
in the fingerprint at `ClientSettingsSearchIndex.swift:153–162`; its changed
fingerprint advances the entry version, so queued later refreshes cannot revive t0.

| Publication | Actual version rule |
|---|---|
| Same definition and same secret classification | Preserve the existing UUID. |
| Public value write, override insertion/removal, reload or error-only change | Preserve schema UUIDs; ordinary value/error notifications can still occur. |
| Changed title, section, default/options/shape, or effective secret classification | Mint a new UUID for that definition. |
| Definition absent from the published catalog | Omit its version and invalidate its old key; no historical definition/value tombstone is retained. |
| Accepted schema with a subsequent file-read failure | Failure recovery publishes the accepted definition and new identity, despite throwing the storage error. |

**Secret classification is monotonic.** `ClientSettingDefinition.canReplace:184–190`
rejects secret-to-public schema replacement. Store recovery unions known secret
classifications at **428–435**, public resolution retains them at **538**, and
normal resolution rejects a formerly secret key as plaintext at **683–686**.
Snapshot redaction remains at **109–111**. A failed migration can advance the
identity and disable navigation; it cannot be modeled as a permissible
secret→public→secret round trip that reveals a value. The index still refuses a
learned-secret/public-schema destination at **190–192**.

**Admission is not the only check.** The private destination factory checks the
captured ticket before selecting its mode and again before construction
(`CLIENT/ExteralessSettingsController.swift:75–108`). Its failable initializer
requires the ticket before `super.init` (**131–138**); Session checks it again
after the factory returns and before push (**234–236**). These checks address a
publication between initial admission and controller creation without depending
on observer delivery. Editor rendering/input/Save and the row-focus predicate
continue to validate the retained ticket, rather than resolving a new one.

**No persistence/CAS reinterpretation:** an independent byte comparison against
the pinned pre-remediation store confirmed that `perform` through the helpers
preceding `publish`, and the entire `ClientSettingsFile` implementation, are
unchanged. UUIDs are process-local metadata. The snapshot initializer's trailing
`definitionVersions = [:]` preserves reconstructed/CAS callers and prunes unknown
version keys. Public CAS at **498–510** still compares expected values and override
presence, with the existing secret gate; it does not consume caller-supplied UUIDs
as write authority. Existing admitted-write semantics are retained.

### R4 — the default factory and private renderer now require authority

The actual installed route remains Runtime → AccountContext factory →
`exteralessSettingsController(context:)`, but the result is now optional:

- Runtime's factory at `CLIENT/ExteralessClientRuntime.swift:245–248` returns the
  default factory's result directly. `AC/ExteralessSettingsEntry.swift:9,15,29–34`
  propagates the optional controller through its existing locked factory seam.
- Context-only and explicit-store factories at Controller **55–64** delegate to
  `ExteralessSettingsSearchEntry.makeRoot`. Session `makeRoot:173–176` requires
  the exact live context and, when supplied, the identical store.
- The explicit-session overload at Controller **67–71** obtains a current Root
  ticket. The private renderer has nonoptional `let` session/ticket fields and
  a failable, guarded initializer (**127–138**). There is no nil-session success
  branch and no implicit session construction in a default factory.
- A retained default factory may remain installed after retirement, but its
  provider returns nil. It cannot manufacture a new session. Runtime's explicit
  installation at **321–324** and retirement at **382–389** remain authoritative.

Root obtains per-row tickets at Controller **230–259**; it checks that the
definition snapshot still matches its publication version before attaching a
setting ticket. Actions invoke `session.open(ticket:)`. Settings, menus,
accessibility resets and controls retain their selected tickets (**274–329**).
Private `open:449–452` has no sessionless editor fallback. A stale page clears
its draft, editing and right-side actions at **187–194**. Input, Save, reset
confirmation and delayed UI completions recheck scope/tickets at
**388–393,459–496,499–549**. Row-focus layout and delayed cleanup check the same
authority (`ExteralessSettingsSearch.swift:369–385`) and fire no control action.

The actual direct callers propagate nil: `Appearance/ExteralessMainMenu.swift:372–376`,
`Player/ExteralessPlayerActions.swift:61–65`, and the existing optional unwrap in
`telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoSettingsItems.swift:279–285`.
The harness installs its own given-context/store session explicitly at
`HARNESS/ClientHarnessApplication.swift:239–253`. The secret-label segment uses an
explicit owned session with `defer { scope.retire() }` at
`ClientHarnessSecretAvailability.swift:144–149`; it no longer depends on an
unbound factory. The four accepted d7 status strings are preserved.

### R5 — explicit class ownership survives Nagram fallback

`CORE/ClientSettingsSourceRoutes.swift:406–436` saves the exact class's pages
separately as `classPages`. The ordinary page/class narrowing still applies.
Every fallback candidate must additionally intersect `classPages` with its
current/previous pages at **433–435**.

For the original `nasettings/general` + `OpenExteraGeneralActivity` +
`HideHelpSection` request, General permits only `general`, while the row belongs
to `hiding`/previous `appearance`. Both candidate paths are empty and **438–439**
returns `.notFound`, even with `appearance.hideHelpSection` registered.

The authored moved-row declarations, class names and page aliases are unchanged
from the prior source plus the already-authorized Reset alias. Controls remain:
unqualified Nagram General/HideHelpSection; Appearance/HideHelpSection; the
explicit Chats class's multi-page ownership; and
`exteraless_chats/videoMessagesCamera → tools.videoMessageCameraFacing`.
The resolver still requires one distinct destination and uses the declared Chats
constructor default, not an ambiguous first-result fallback.

## Test evidence and the authorized fixture correction

| Evidence | Precise scope |
|---|---|
| **43763528246 / 27360543**, supplied by coordinator | Core compiled and ran. The sole reported failure was `testPublishedTitleAndVisibilityABAInvalidateWithoutIntermediateIndexRefresh`: its initial `Data(contentsOf:)` encountered ENOENT because cold registration correctly creates no JSON file. This is not a green-run claim. |
| **4bd2f7e3** correction | Adds two comment lines and one actual `store.setPublic(.integer(30), for: a.key)` before index/file-baseline capture. Independent byte comparison confirms all other fixture bytes, including ABA/version/value/presence/file assertions, are unchanged. Production Core hashes are unchanged. |
| **43763898710** | Reported in progress; not queried. No result is inferred. |
| Core source cohort | **16 baseline + 6 closure methods = 22**. Current method identities match the frozen manifest. The corrected test is the sole changed cohort member; the original receipt/stager pins remain historical. |
| Author's **7/7 Python contracts**, 0.074 s | Supplied driver/source-contract receipt; not rerun as XCTest or UIKit evidence. |
| Earlier search16 and Reset17/704 runs | Prior snapshots only. They neither execute these native paths nor close the separately owned Reset P2s. |

The corrected setup writes a real public override through the real store, then
compares disk bytes across schema-only ABA. It repairs the fixture's file-existence
assumption without turning registration into a writer or weakening the negative
assertions. Its current raw SHA-256 is
`da0b8afe756875c603ae2a8e02438f095f3af5e6e3984e6625f0440cbc39bec6`.

The six Core fixtures cover undelivered title/visibility ABA, stable value/presence
publications, schema publication on load failure, compatible snapshot/version-key
construction, R5 with a registered destination and valid moved-row controls, and
the typed canary denial. They do not execute native actors/views.

The given-context `telegram-ios/Tests/Exteraless/SettingsSearchUIViewRouteChecks.swift`
now exercises the shipping default factory (**190**), a real Root table selection
and private numeric editor (**219–244**), same-turn actual-store ABA before observer
drain (**201–210,235–243**), retired default/store/explicit factories and retained
UIKit actions (**263–278**), cancellation and same-object provider replacement
(**248–291**), and a new explicit copied-link open (**293–301**). Its final checks
cover false navigation results for unavailable selections, gated typed denial,
retired Save and native Back cleanup (**303–333**).

`HARNESS/ClientHarnessSettingsSearch.swift:48–51` awaits this fixture and records
`facts.settingsSearchClosure` only after it completes. The actual core scenario
awaits it before secret-availability. The harness reuses its given account/context;
the replacement scopes do not construct accounts. The existing **13 probes**,
**30-second whole-process limit** and **eight recordings in 3+3+2 batches** remain.
The added closure segment specifies at most **5.45 seconds of explicit waits**;
whole-process timing is still unmeasured here.

**No UIKit execution or frame pass is claimed.** Acceptance retains the expected
frames in the remediation appendix: stale editor actions disappear, retired
pending opens produce no page/alert/keyboard, a fresh explicit open navigates once,
local errors reveal no canary, and Back restores home. Frame indices and **ffprobe
PTS** are still required. R1 launch/notification execution requires the real app,
as the fixture itself explicitly reports.

## Independent checks and read-time pins

All checks were local read-only data/source operations, each bounded to **30 s**.
They used JSON duplicate-key rejection, raw hashes, local Git objects, source-span
comparisons and Python/BUILD AST parsing. No CI query, network, account, simulator,
foreign-plugin operation or local Swift execution was performed.

At 21:25:11 UTC, **18/19** primary applied pins matched; BUILD matched its documented
later pin. At 21:32:03 UTC, **17/19** primary pins matched, plus that same BUILD pin
and the authorized fixture correction. An intervening strict comparison stopped
on the changed test; its exact one-call setup delta was then checked against
`27360543173ace07c77efed82b4d85d16d376acc`.

The corrected fixture is the only mismatch among the **13** frozen cohort source/
packaging records. Independent checks also confirmed the 22 method identities,
R1 ingress order and current ready/unlock gates, the single MainMenu fingerprint
input and existing Player glob, and unchanged driver/scenario-selection hashes.

The authorized Reset Runtime update/clear hooks and integration match their
preserved pins; `other/resetSettings → general.settingsReset` remains present.
These are compatibility checks for this search closure, not a Reset re-review.

| Pin | Raw SHA-256 |
|---|---|
| `docs/wave-2/settings-search-r1-r5-applied.json` | `17ebe753e35ec956845263db7ece4af58c222d3bd2ae07baa7d008581443ea89` |
| `docs/wave-2/settings-search-remediation.md`, including coordinator correction | `6602ba515b7b733c54c3725f66818437c09fa3c39c45acf359611914abc2b031` |
| `docs/wave-2/settings-search-r1-r5-cohort.json` | `a4143b197874a585f37e2f45679f4cb4e72712c9a6220b7113f88c10b2fe9068` |
| `CORE/ClientSettings.swift` | `8677713c19c4ff623caf9437f4ff2613d8665a5f48b89e53a45b348873320701` |
| `CORE/ClientSettingsSearchIndex.swift` | `22aa851f9fc313d9f764dc607629defbf95a0083a6483944ff2178548ebf2047` |
| `CORE/ClientSettingsSourceRoutes.swift` | `117282d9bd93fa1321fa6b0511b2fa65c5286d5bf2cb415df110648ceaa0a1f9` |
| `AC/ExteralessSettingsEntry.swift` | `0f8fe81f8782e53b4b222f692d30e6eef191c8ea37d893d8ed285218b1a7aa94` |
| `AC/ExteralessSettingsSearchEntry.swift` | `574c0d16253f2643d94ba53a47c56f41f7d81c8fe7f9347752c7c2e5cb015c5d` |
| `CLIENT/ExteralessSettingsSearch.swift` | `8e49e4d6b4c8a81df57129816700d4580755b8d979c0b0dd7289a62be87b0979` |
| `CLIENT/ExteralessSettingsController.swift` | `a0b332369915c6817e039bda1ca6a4ce8f6c0f6962debb10dc97e55fd8d35bf5` |
| `APP/OpenUrl.swift` | `384b70c842ad715d32b173d9286a9e9415244fe5ea3b95dcfd686dfaeff0ee5b` |
| `APP/AppDelegate.swift` | `2d77b0d4dee87086458057a2a99d50fa1da23ac247be5b93e1e7de2252edec62` |
| `telegram-ios/submodules/TelegramUI/BUILD`, 49,810 bytes | `8ea8d0e3ef2efe78f88c991f3dd7978e6fdb0c06e74facaace9faa8249dabd71` |
| `telegram-ios/Tests/Exteraless/SettingsSearchUIViewRouteChecks.swift` | `be2b05c6c0723cbeb3ba7c594d834279cf8085d9d284db3a34449725d57e8ff2` |
| `CLIENT/ExteralessClientRuntime.swift` | `5041de7b3d2e5d0098ec61773eef3617a63984dd167b946e443e1c5242fd48e8` |
| `CLIENT/SettingsResetIntegration.swift` | `bbbdae624a8a00ac07bc30e5402efee0347013ade5273b2a81618bd18cb67e4d` |

The remaining unchanged applied-file pins are the full-path entries in the
19-path receipt. BUILD's raw difference from its original primary pin is the
documented concurrent-owner edit; its search fingerprint input is present once.
The old review and schema-1 route map were not regenerated or promoted.

Unchanged store-span proof against baseline
`203b973a7f09bb657075ea92daf22065e2ee0baf060147bbc8c0661f1231c556`
(`93edf05e`), using exact raw bytes between named declarations:

| Span | Bytes | SHA-256 |
|---|---:|---|
| `private func perform` through immediately before `private func publish` | 29,056 | `a26a2d363c6d3d88c53f368096756b6c9f4e1f340c51ab173374f9fa98418351` |
| `private enum ClientSettingsFile` through EOF | 12,743 | `a00d25f6b31aaa644247177dfb75f83dd54e3addf33014dcb6442d09fc5b52ee` |

**Final disposition: all five R1–R5 source causes are closed.** Execution status
remains the bounded, attributed evidence above; this verdict supplies no native
UI/frame pass and no verdict on another owner's findings.
