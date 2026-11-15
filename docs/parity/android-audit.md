# Android inventory: source semantics and DATA join

The generated [index](index.md) and [client JSON](client-features.json) are the
searchable inventory. [SDK JSON](sdk-surface.json) is an independent surface;
client settings, compatibility methods and Python names have separate counts.
Original-source findings and published iOS receipts are separate evidence layers.
This document records the data reconciliation; it does not establish device parity.

## Final wave-2 source join

The [reconciliation](wave-2-reconciliation.md) now selects **567/567 Original IDs**,
including **56/56** formerly missing receipts. The original **30 modules**, **925 SDK
symbols**, **308 ExteraConfig overload IDs**, and all declaration defaults/types
remain explicit. **Verified/ported: 0 before, 0 after.**

- Tools: 43 feature rows; Appearance: 78 + appicons; Chat: 137; independent AI
  visibility: 3; Privacy includes both ancillary proxy-state receipts.
- Pills' distinct published schema is normalized by **original symbol AND Android
  key** into 20 setting/state IDs. The 15 type contracts are retained separately.
- `nagram.showTextTranslate` selects Chat / `chats.showTextTranslate`; the AI claim
  survives as secondary evidence, without a second feature ID. Current policy
  readers, removed duplicate AI declaration and main/Share migrations have targeted
  symbol/line/hash evidence in the reconciliation.
- The six former module-rollup gaps are scoped `partial` compositions of existing
  feature/domain APIs. General, Settings and Plugins retain exact requested
  coordinator-authorship fields; no module pass is inferred from the counts.
- SDK308 uses the **published 272 implemented / 4 blocked / 32 unsupported** snapshot
  pinned in `wave-2-reconciliation.json.sources.sdk-config`. These are author mapping
  claims, distinct from behavioral compatibility for all 925 SDK symbols. The old
  260/16/32 receipt is historical. SDK-owner outputs are not generated here.

The reported Linux run **43708260304 / 7d04a35a** covers **545 Core / 169 Host /
30 Hooks**. The request's `6f718b11` cohort and later concurrent source commits do
not acquire a compiled status from those numbers. Native build/frames remain
unreceived; current HNS-F/PFR/CMC/FU/SDK and other review tails remain separate.
A one-shot final comparison found later Feed and SDK Config receipts. The selected
hashes and exact newer hashes are recorded in the reconciliation; newer revisions
are not silently mixed into this snapshot or used to close findings.

## Corrections to the original inventory

- Scan **Java and Kotlin extensions in both source roots**. `NaConfig.kt` and the
  functional `app/exteraless/*Config.kt` files are Kotlin; `LlmConfig.kt` and
  `NotificationsHelper.kt` also live under the directory named `java`.
- `ExteraConfig.java` has **139 distinct public static scalar-returning symbols**,
  not 139 independent client features. Its comment at lines 37–51 explicitly
  describes the field-shaped plugin shim and own-file storage without app effects.
  Getter/setter aliases are mapped to the owning real config. The API inventory
  also includes enum/collection/helper signatures and distinguishes overloads.
- The functional baseline includes `AppearanceConfig` (62 registrations),
  `ChatsConfig` (42), `GeneralConfig` (7), `OpenExteraConfig` (4), `UtilsConfig` (1),
  `IconPacksConfig` (5), `GlyphConfig` (5), `PillStackConfig` (20), `NaConfig` (248),
  `NekoConfig` (97), preference-backed AI/feed/NekoX/dialog configs, and auxiliary
  preference stores. These are declarations, including state, not completion counts.
- All **30 app/exteraless modules** are represented. `links` is Kotlin-only;
  `notifications` contains Kotlin in the Java root. Backup, privacy, player,
  speech, feed, AI and plugin helpers also have their public method-body index.
- Real `DialogsActivity.java` contains `/* || /* ... */`. Applying Kotlin nested
  comment semantics to Java hid the latter half of this file, including live
  `hideStoriesFromHeader` and `hideDialogsSearchField` consumers. A fixture now
  prevents this specific inventory regression.

## Source semantics the Core implementations need

| Source setting / subsystem | Important boundary |
|---|---|
| `appearance.centerTitle` | Private obsolete storage. `centerTitle()` reads `NaConfig.centerActionBarTitle`; do not expose a duplicate feature. |
| `nagram.backAnimationStyle` | Declared 0, but `UtilsConfig.applyMotionDefaults` writes Spring=1 for an absent preference. |
| `nagram.cameraInVideoMessages` | Declared 1; `fixConfig` migrates absent keys from `RearVideoMessages`, whose false default selects front=0. |
| `nagram.strokeOnViews` | Fresh value is adjusted according to device performance when no explicit choice exists. |
| Five `nagram.defaultDeleteMenu*` IDs (including `defaultDeleteMenReportSpam`) | These are **not unused/UI-only**. The four linked flags share the parent bitmask; `NekoChatSettingsActivity.getDeleteMenuChecks` is statically imported by `AlertsCreator`, then fed to `DeleteMessagesBottomSheet.toggleDefaultChecks`. Native `AdminUserActionsSheet` consumes `ChatDeleteMenuDefaults.current()`. Checked helper anchors now participate in the scanner's non-Config owner/static-import index. |
| `general.showNagramSettings` | `migrateLegacyKeys` clears true; a read site alone does not imply the switch remains enabled. |
| `chats.flashWarmth`, `chats.flashIntensity` | Stored as integer percentages (50/100), exposed by float getters divided by 100. |
| `utils.predictiveBackIntensity` | Stored 100, getter divides by 100 and clamps 0…2. |
| `pillstack.activePillsRaw`, `hiddenPillsRaw` | Stored strings feed live integer collections. Getter-to-collection edges have checked source anchors. |
| `nagram.preferredTranslateTargetLang` | The live translator reads a materialized list, populated from this string. |
| `voskmanager.language` | Stored default null; resolves locale/model availability, then falls back to `en-us`. |
| `nagram.sortByUnread` vs `neko.sortByUnread` | Different preference keys. Nagram's `SortByUnread` has real `MessagesController` consumers; legacy Neko `sort_by_unread` does not. Keep the collision visible; use the live Nagram field for `chats.sortByUnread`. |
| `nagram.performanceClass` | Automatic native energy policy has real consumers; forced Android 1/2/3 semantics remain unimplemented. This is an explicit portable adapter gap, not a blanket unavailable-iOS claim. |
| `etgbackup.ChatSwipeAction` | Original −1 and 0…5 select primary reveal action/folder behavior. Native per-peer reveal actions exist, but eligible-primary-action and folder/row gesture projection for imported values remains a Chat/Root adapter gap. |
| `neko.cachePath` | Legacy Android filesystem-migration input, not a live export destination. Native MediaBox ownership and Files export do not make the imported Android absolute path usable. |

`LegacyDefaults.java` is also important for upgrades: it pins selected old boolean
defaults and double-tap values only for prior installations/generations. A source
declaration is not a migration policy. These mutation paths stay source-pinned in
the inventory and must be reviewed for any corresponding iOS migration.

The `ui-only`, `storage-or-migration` and `unresolved` lists intentionally survive.
For example, `AiConfig.getInsertAsQuote/getShowResponseOnly` exist in storage/API
without a discovered application consumer. Several old Neko/Na controls are now
migrated to replacement fields. A reviewer should resolve these against the pinned
source rather than manufacture a native effect to inflate a count.

## Native equivalents and constraints

- Stock Telegram-iOS has per-chat themes, chat headers and bottom navigation.
  These are reuse candidates with exact native files, not proof of equivalent
  global Exteraless switches. Every live setting has a proposed native subsystem
  target; actual `ClientSettings` key reads and tests come from implementer evidence.
- Android feed aggregation is not the same as stock iOS News.
  `TelegramCore/Sources/TelegramEngine/Feed/TelegramEngineFeed.swift` explicitly
  gates the News API with `TELEGRAM_NEWS_FEED_API`; its presence cannot close the
  Android feed port.
- CameraX, Nothing Glyph, launcher/notification customization, Android background
  services, filesystem/database layouts and provider keys require their recorded
  native/platform adaptation. Stored flags are not those effects.
- Appearance's native switch/slider/back-motion/icon-preview and settings-section
  receipts preserve their actual scope. Missing Android font/palette assets and
  forced tablet policy remain concrete limits on `neko.typeface`,
  `appearance.monetStyle`, and `neko.tabletMode`; they are not generic UI exclusions.
- Root/TLN04/05/CA04/AP/four Tools modes/IDS Avatar/AF History shared insertions are
  reported applied in the coordinator's top progress block. This supersedes older
  unapplied-hunk notes in the source receipts, without promoting feature statuses.

## SDK and dependencies

- AST inspection covers the complete `python/sdk` file set and compares public
  declarations with the vendored Android SDK. It imports neither SDK modules nor
  plugins. Public declarations/reexports and native operations remain distinct.
- Builtin `BridgeServices` accepts a bounded operation/member surface. The scanner
  checks dispatch bodies, not just `member_kind` metadata. Android constructors,
  arbitrary writes, arbitrary `getInstance` and unknown members are not implied.
- `client_utils.send_text/send_message` originally build Android
  `SendMessageParams`. Native `Runtime.sendMessage(peer,text,account)` alone does
  not adapt those SDK helpers. Current exact published adapter claims are now
  projected into individual SDK records; unlisted symbols stay explicitly
  unreconciled. Earlier builtin-only exclusions remain historical classifier data,
  not fresh negative findings against later SDK providers.
- Android Gradle contains **7 direct pip requirements**. The first runtime wave's
  iOS lock had 8 distributions and only `packaging`/`requests` intersected the
  direct list. During this parallel implementation wave the dependency owner
  expanded that lock to **12**, adding BeautifulSoup4, SoupSieve, PyYAML and debugpy.
  The generator reads the current lock rather than hard-coding either count.
  PyYAML/debugpy are **source projections**, not native-accelerated packages.
  In particular, debugpy's lock records unavailable process-spawning `listen`,
  unverified `connect`, and absent `stop_listening`; these constraints are retained
  in SDK JSON. lxml and Pillow are not supplied by this Python lock. A lock entry
  is not evidence of current-IPA importability or full package behavior.
- The original plan excludes Java/DEX plugin loading. JVM/Xposed replacement is
  not a blanket native capability; explicit extension points are separate APIs.

## Evidence handoff

Owners should provide the **original feature ID**, actual Core key, exact native
read/effect sites, adaptations, and verification records in independent JSON.
Use the [merge contract](schema.md). A basic definition is not sufficient evidence
for `ported=true`; visual behavior still needs recorded frames. The inventory
preserves valid implementation evidence when regenerated.

Each joined record retains its unmodified author claim and input receipt hash.
Fresh references carry read-time file hashes plus symbol/key matches. Unresolved
old line numbers are retained only as `reported_line`, never incremented or silently
treated as current callsites. Generic helpers and field-token candidates are not
functional/runtime verification. See [schema.md](schema.md) for replay and pure
data-check commands.
