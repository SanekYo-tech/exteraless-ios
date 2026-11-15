# Tools phase 2 — final source handoff

**Backup recovery/file/cache safety below is superseded by `tools-remediation.md`
(TB-01–07).** In particular, target equality in a restarted process is no longer
treated as proof of Tools write ownership; journal v3 has explicit reconciliation.

This is the current contract; phase-1 backup API/schema text in `tools.md` is historical.
Source-only evidence. The coordinator-reported **28 ClientSettings/CAS tests** on
`4b3f7064` / CI `43653040458` verify the core dependency, not this Tools patch.
No commit, push, CI, real network, send or account-data test was performed here.

## Closed source tails

### Backup presence / CAS / recovery

- `ToolsBackupSettingsSnapshot` retains effective public values, `storedKeys`,
  definitions and learned secret classifications. `ToolsBackupSettingsState` records
  only affected keys; it distinguishes an absent override from an explicit default.
- `ToolsBackupSettingsAccess.clientSettings()` calls the actual stable
  `applyPublic(values, resetting:expected:)`. There is **one batch**, never a loop
  over setters. Before and expected-applied images are computed **before** forward
  mutation. The rollback guards are those journaled images, never a later native read.
- Both forward CAS and rollback CAS include override presence. Rollback restores
  prior overrides and passes previously absent keys to `resetting`. A rejected
  forward write is distinguished from an uncertain/durability error and cannot
  undo a native edit which happens to equal the import target.
- A confirmed forward write followed by a failure rolls back only with the target
  image. If rejected, the second allowed CAS is an already-before confirmation.
  If neither matches, the native edit and original recovery record are retained:
  `ToolsError.rollbackFailed` → maintenance `needsRecovery` → no resume.
- Archive **v2** carries `clientStoredKeys`; source defaults reset to the current
  installation's defaults rather than becoming persisted overrides. Archive v1
  remains readable with its original explicit-value semantics (no invented presence).
- Journal **v2** stores before/target values+presence, client-write disposition,
  transaction phase and original/target plugin-file SHA-256 maps. Writes synchronize
  the journal and parent directory. Plugin copies stay private and survive failed
  recovery. Directory rollback checks its expected images rather than overwriting
  unexpected native file changes.
- Uncommitted v1 journals cannot reconstruct missing presence/after-image metadata;
  they fail closed and remain untouched for reconciliation. Committed v1 journals
  only clean scratch files. This is a deliberate information-preservation migration,
  not a fabricated successful rollback.
- Added real-Core file/CAS fixtures as well as deterministic model faults: absent
  overrides, explicit defaults, native writers, unrelated edits, durability error,
  v1 migration and crash-recovery images. Native folder replacement still needs Darwin.

### Host and cached schema

`ExteralessToolsHostMaintenance.begin(host:)` now wraps the **actual**
`PluginHost.beginSettingsMaintenance(timeout:)` / `PluginSettingsMaintenanceLease.finish(resume:)`.
It does not use terminal stop/start, initialize or finalize CPython. The startup
wrapper `recoverBeforeStart(host:settingsDirectory:settings:)` acquires the lease on
a fresh host, recovers on a worker, then releases it before ordinary `host.start()`.
Failure releases with resume=false. Exact runtime and context-aware root wiring is
in **`tools-ready-contract.md`**; those files belong to coordinator/UI integrator.

`ToolsPluginSchemaCache` consumes already-returned native settings JSON. No inspection
or export invokes Python/get_settings. It keeps only derived key/type/range metadata,
not returned values. Epoch/account mismatch or malformed schema denies export;
unknown widgets/inputs are not guessed public. Text inputs need explicit
`backup_exportable: true`; protected fields are excluded. The resulting location
validates imported values against that cached schema. Freeze the authorized mapping
with native install/reload/account admission; if ownership is uncertain, deny
plugin-data restore instead of executing code to discover a schema.

### Local favorites (actual native data + UI)

- `ToolsFavoriteStickers.swift` defines a versioned, checksummed, account-user-ID
  keyed metadata archive, up to 10,000 documents/account. Decoder creates only fixed
  validated DTOs; it does not call a generic TL/Postbox/FlatBuffer decoder on imports.
- `TelegramCore/Sources/ExteralessTools/ToolsLocalFavoriteStickers.swift` observes the
  real native `CloudSavedStickers` cache and an **independent per-account Postbox
  preference** `exteraless.tools.local-favorite-stickers.v1`. Import is one transaction
  merging the selected user's local list. No `addSavedSticker`, send or server quota
  RPC is issued. Corrupt existing local data is not overwritten as an empty list.
- Native file reconstruction retains cloud IDs/hash/reference, pack, dimensions,
  WebP/TGS/WebM kind and premium/no-premium state. Preview bytes/unsupported media
  kinds are not fabricated; unsupported source records are counted in the UI.
- `ExteralessFavoriteStickersController` is registered as `tools.favoriteStickers`:
  actual counts/list, export, inspect account match/checksum, merge, retain current
  cloud favorites locally, remove local copy, open native pack/copy ID, paginated rows.
- Shared keyboard/menu insertion is supplied to the **stickers owner** in
  `tools-favorites-hooks.md`. The local store/UI already have real consumers;
  pending shared-picker integration is not called verified or equivalent to server
  favorite-limit support. The native archive is not mislabeled as Android opaque TL.

### Normal Gallery subtitles

`ExteralessGallerySubtitleAdapter` is a real native picker/store/overlay adapter,
driven by MediaPlayerStatus timestamp/generationTimestamp/rate/playing primitives.
It creates no second player. `ToolsSubtitleStore` is per-account/document, checked,
actor-serialized; the clock handles seek/pause/buffer/rate. **GalleryUI bridge,
status, measured layout, menu and lifecycle hooks are now applied**, including real
native PiP transfer/return/failure. `tools-gallery-integration.md` records the installed
API and source checks. Native compilation and recorded-frame acceptance remain pending.

### Download request budgets / actual Files destination

- `ToolsDownloadPolicy` is consumed by **both** native paths:
  `TelegramCore/Sources/Network/MultipartFetch.swift` and `Network/FetchV2.swift`.
  `tools.downloadSpeedBoost` selects native / 512-KiB+8 / 1-MiB+12 floors for new
  large unencrypted downloads. Story/small/unknown/encrypted rules stay native;
  Rust's larger window is never reduced. CDN chunk/hash geometry, flood-wait,
  reference revalidation and the 1-MiB boundary code remain authoritative.
  Default 0 means native iOS behavior, explicitly not Android's 128-KiB/4 default.
- Original proof: `FileLoadOperation.updateParams:302–319` is a real Android effect.
  `MediaController.java:5835–5839,6218–6222,6521–6558` really uses customSavePath and
  saveToChatSubfolder for filesystem/MediaStore Downloads, Music, Pictures and Movies.
  That source contains bytes which made the ordinary content search treat it as
  binary; direct reading corrected the initial settings-only finding.
  `NekoConfig.customSavePath` also feeds `AyuConstants.APP_NAME` → retention attachments.
- iOS nevertheless has a concrete adaptation: `ToolsLocalFileSaver` streams a
  completed native resource into the user-selected Files folder, checks path bounds,
  uses stable account/chat-ID subfolders and numbered filenames without intentional
  overwrite. Copy/cancel/source-size-change errors propagate.
- `ExteralessFileSaving.swift` stores only the security-scoped destination bookmark
  in its dedicated Keychain service. The public `tools.customSavePath` and
  `tools.saveToChatSubfolder` config contain no bookmark/permission token.
- **Live ordinary Save to Files consumer:** `TelegramUI/Sources/SaveMediaToFiles.swift`
  invokes the helper only after the existing downloader produces a complete resource.
  Existing caller account/copy-protection gates remain required. No selected folder
  means the original Files picker. `tools.fileSaving` selects/forgets the destination.

## Exact remaining common work

1. **Coordinator/UI integrator:** install backup/shortcut bindings on the same
   `AccountContext` guarded by `ExteralessClientRuntime.currentContext`; preserve its
   already-applied `handleToolsShortcut(type:context:completion:)` forwarder.
2. **UI integrator:** before existing `host.start()`, invoke
   `ExteralessToolsHostMaintenance.recoverBeforeStart`; publish cached settings schema
   from an already-completed settings request and invalidate epochs appropriately.
   The UI integrator has already applied the real-operation trace producer; its
   current source calls `ToolsToggleTraceBuffer.shared.record` inside setEnabled.
   Keep that producer while applying the recovery/schema binding hunk.
3. **Gallery native acceptance:** the normal Gallery hooks are applied; compilation
   and recorded-frame checks are listed in `tools-gallery-integration.md`.
4. **Stickers owner:** apply local favorite keyboard/menu hooks from
   `tools-favorites-hooks.md`; preserve its recent/GIF work and errors.
5. **Retention owner:** Ayu SQLite conversion is exclusively its responsibility;
   `tools-retention-handoff.md` gives exact original tables/identity/aliases and the
   native retention boundary. Tools never opens an account/history database for import.
6. **Build owner:** include new `TelegramCore/Sources/ExteralessTools` source glob and
   existing Core dependency; UIKit additions use existing TelegramCore, PluginHost,
   PresentationDataUtils, OverlayStatusController, AVKit, ImageIO, MetricKit, Security
   and UniformTypeIdentifiers. No new entitlement or permission usage string is needed.

## Verification and remaining platform proof

Core batch's CI proof is dependency evidence only. Tools has new bounded XCTest
fixtures but no local Swift compiler/Apple SDK/XcodeBuildMCP. Final local checks are
source/fragment validation and official Postbox boundary checking, recorded below.
No field/module is promoted to verified for having source or an unrun test.

Still external: actual camera outputs/FPS/zoom/flash restoration, native overlay/
Files/bookmark/keychain behavior, normal Gallery/keyboard recorded frames, and full
app compile. Nothing Glyph hardware and external iOS signing remain separate genuine
platform constraints, not excuses for portable metadata-only implementations.

### Local checks at phase-2 handoff, before the Gallery insertion

- Bounded source sanity: **52 Swift files / 15 live Tools keys**, pass. This checks
  delimiters/string/comment structure and consumers, not Swift typechecking.
- Official `python -B build-system/Make/PostboxImportCheck.py`: **exit 0**.
- Targeted `git diff --check`: **exit 0**.
- **51 supplied Tools XCTest methods**, including actual Core file/CAS adapter
  cases. Not run locally because swift/swiftc and Apple SDK are absent.
- The final mergeable fragment delegates `utils.predictiveBackIntensity` to
  appearance and the 12 ExteraConfig storage-only API receipts to SDK config,
  avoiding contradictory independent overrides. Original classification remains
  in its separate metadata section. No Tools record is marked verified.
- Final fragment validation: **29 feature IDs, 9 modules, 105 source references,
  zero conflicting feature overrides and zero added verified claims**. The tracked
  main parity inventory was not modified by Tools.
