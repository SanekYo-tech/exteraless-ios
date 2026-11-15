# SDK02/03/04 + HNS-F03/F04 — final source handoff

## Latest source alignment — TBF05 / Java cohort

Config generation/check was repeated after the coordinator's approved cold-start
continuation. Only SOURCES changed (Runtime and shared inventory/receipt hashes); all
508 bindings, 308 API records, root registration groups and **272/4/32** counts
were identical. The final receipt/registration checks passed **4/4 on 3.12 and
3.14**. The four unavailable methods retain their exact native-provider reasons.
The subsequent Appearance receipt hash refresh also preserved all API records;
its tabletMode/typeface rows still explicitly have setting_key=null. Final --check passed.

Java SDK06–09 runtime files are required by the native driver and must byte-match
the current repository when a separate --python-root is supplied. The driver
retains nine source copies under `java-sdk-cohort/`: five runtime adapters/codecs,
the Java regression test, schema, native codec fixture and owner handoff. These
copies and hashes enter `build-inputs.json`; native children use the complete
--python-root. Run the independent Java tests from their repository path as
documented in `sdk-java-remediation.md`.

The Java owner's **12 passed/1 skip on 3.12**, **11 passed/2 skips on 3.14**, and
**34 existing regressions per interpreter** are preserved as reported evidence,
not relabeled as new alignment runs. `_tl.py` including its four-line byte-array
branch still matches that cohort's raw hash. Local staging verification confirmed
all nine copies byte-identical. No native test, CI or Cloud-review polling was done.

## Config / SDK02

`sdk-config-parity.json` is regenerated against the applied root, frozen child
definitions, current native manager authority and domain receipts:
**272 implemented / 4 blocked / 32 unsupported = 308 exact IDs**. Partition stays
220 mapped aliases / 44 global storage / 44 utilities. No native execution or
ported=true status is inferred from registration.

- The actual consumed root set must contain ExteraConfigCompatibility.definitions.
  The App owner applied registration and generic-UI hiding. All 44 storage calls
  execute in two fresh SDK workers against a root-sensitive recorder; missing-root
  negative control fails before the fixture can supply defaults.
- The native TL child additionally uses the actual ClientSettingsBridgeExtension
  and Core ClientSettings. Its staged registration expression is generated from
  that same consumed root set. One real SDK plugin executes all 44 overloads;
  the store is reopened from disk and the second plugin reads all 22 results while
  their per-plugin settings remain separate. Missing root groups fail the driver;
  the native fixture never adds compatibility definitions independently.
- Only connected child initializers are scanned. Unregistered declarations in the
  same file are excluded; removing a registered child reference fails generation.
- Actual AppearanceAdditionalFeatures, ToolsNativeModePolicy and AI visibility
  declarations and their registration sites are pinned.
- Four exact HideAllChats / UseSystemIconShape overload IDs are asserted, in
  addition to the 308-ID identity check and public SDK read/write tests.
- Rear-camera Bool ↔ native Front/Rear is explicit. Ask reads fail by name without
  rewriting the native selection. Native default metadata remains authoritative.
- Migration-only disableCrashlyticsCollection and enhancedFileLoader cannot become
  direct aliases. Getter/setter fail explicitly; GeneralConfig owns the live flags.
  In particular legacy false cannot enable native diagnostics.
- Native writer joins from `sdk-manager-authority-remediation.md` are consumed as
  current source. Python handles the new Java HashSet's Set interface without editing
  the Java owner's arrays/finder/ADT files.

The four remaining blocked overloads are get/setTabletMode and get/setUseSystemFonts.
The final Appearance receipts still have setting_key=null and explicitly state that
forced layout / font-family selection is absent. These are precise native-provider
gaps, not missing classification receipts. See `sdk-config-binding.md`.

## SDK03 — explicit cancellation winners

NativeOperation.cancel and Scheduler.cancel now close only after a positive,
strict Bool native result. False, malformed and throwing replies keep completion
and native FIFO release ownership. Scheduler returns actual cancellation success,
not presence in its local map. Completion and on-close removal check lease identity;
an old close cannot delete a replacement entry. CallbackLeases.end retains its
separate terminal unload cleanup semantics.

Fresh SDK scenarios cover controller/task false, malformed, throwing and positive
cancel, delayed completion exactly once, release after completion, original account,
duplicate cancellation, replacement-entry preservation and no transient handle leak.

## SDK04 — additive discovery and actual notification payloads

The SDK recognizes all 12 IDs in the native NativeServiceNotification registry.
Well-formed unknown availability rows are filtered, allowing old subscriptions to
continue. A wrong name for a known ID is rejected. Missing native publishers and
unknown subscriptions remain explicit failures. File events require files permission.

Payloads follow `native-services.md` Phase 2:

- Empty: dialogs/contacts/self/network/downloading-list changes.
- Messages: dialog, ArrayList of partial NativeMessageObject facades, scheduled Bool,
  ordinary mode. Real getId/getDialogId/isOut/isForwarded fields are projected; absent
  TL flags/hashes/media members raise rather than acquiring defaults.
- File completion: opaque native resource key and the existing portable File object;
  failure retains its native integer reason.
- Playback: message ID/fraction, message ID, or new/previous partial message DTOs.

The fixtures use the full native table, an additive unknown ID, all argument shapes,
wrong-name/forged-account/bad-shape cases and unavailable publishers. The real native
HNS child also compares SDK discovery with NativeServiceNotification.allCases.
Notification delegates retain the original explicit account argument and no implicit
hook account; ignored returns remain void.

## HNS native probe corrections

- **F03:** grants is `[PluginPermission]` at all three array-API callsites, retaining
  ui/messages.read/network/files.
- **F04:** destroyed/old-replacement tokens sent through the actual Host bridge must
  produce `{ok:false,error:{kind:SecurityError,...}}` before provider execution.
  Provider cleanup/release counts and replacement resources must remain unchanged.
- Duplicate removal is tested **during actual retiring SDK unload** by replaying the
  same immutable identity through the production NativeServiceCleanupRoute and the
  UI DTO recorder's stored-lease revoke. Each returns a no-op, with no second release.
  Eight such checks cover both epochs. Actual CallbackLeases.end and all 31 native
  `(owner,handle)` retirements remain required.
- The direct settings-read probe uses the finalized HNS-F02 `expectedOwner` and
  worker predicate, with a captured account-generation scope and revocable read
  permit. SDK create_settings invocation/arity is unchanged. No Host validator or
  NativeService callback-control type was weakened.

The existing driver still runs **three fresh children, 30 seconds each**, compiles
actual Host/C/SDK and native TL codec source, and requires every report/marker. Its
fingerprint remains `build-inputs.json`; C219 test numbering is untouched. Native
DTO recorders make no UIKit rendering, production enqueue/state or delivery claim.
The local ExteralessCore package is built once for the real root-Config provider;
it has no remote package dependency. Compilation has a separate 240-second cap.

## Verification / source freeze

- Full changed-contract SDK cohort: **49 passed on CPython 3.12.10 (32.97 s)**;
  **49 passed on 3.14.8 (36.23 s)**. Runtime scenarios use fresh 20-second workers.
- Final receipt refresh: only the App owner's root source hash changed after those
  runs; bindings and all 308 statuses were identical. `--write`, `--check`, exact-ID
  assertions and three negative registration controls passed (4 tests, 0.88 s).
- The subsequently joined exact native Config helper and related Config/TL fixtures
  passed **7/7 on each interpreter** (5.45 s / 5.61 s). This adds one distinct
  two-worker scenario; it is not reported as another full-suite run.
- Scoped Python parsing, Swift delimiter/type-contract source checks and whitespace
  checks passed. These are not Swift typechecking. The local Windows host has no
  swift/swiftc; the native component/probe gate remains with the coordinator.
- Evidence: `tests/sdk-python-checks.json`; raw current inputs:
  `sdk-final-source-inventory.json`. Earlier Runtime stitch hashes are historical;
  current coordinator guards are fingerprinted honestly.

SDK-owned files are ready for the coordinator's source cohort. Source paths include
`_config.py`, `_config_manifest.py`, `_controllers.py`, `_notifications.py`,
`_scheduling.py`, the SDK generator/tests and HNS probe/driver. SDK01 app roots,
SDK05 manager writer, Host F02 and Java SDK06–09 remain their owners' source. No CI,
commit, push, external plugin or native Mac pass was performed here.
