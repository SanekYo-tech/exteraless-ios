# module.settings — authored native route map

**102/102 exact Original public method bodies accounted for, with no omissions or
duplicate identities.** [settings.json](settings.json) supplies the schema-1 member
map, 55 individually named native action registrations, 47 additional named
flow/row-group records, explicit missing providers and raw source pins.

All members retain **`verified: false`, `ported: false`**. This is independent
source-route authorship, not native execution or feature admission by count.

## Boundary and provenance

- Identity source: `docs/parity/client-features.json` →
  `modules.settings.public_method_bodies`.
- Identity tuple: **file + name + ordered parameter_types + line**. Inventory
  order is retained. Return types/binding/arity remain in the pinned inventory;
  they were not used to collapse distinct identities.
- Original paths below resolve under
  `third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/settings/`.
- All 12 Original Java files were read, including private/protected row builders,
  handlers and lifecycle context. Their raw bytes match all 12 inventory file pins.
  Supporting `BaseNekoSettingsActivity.java` search was read separately; its methods
  are outside the 102-body denominator.
- Initial read-time HEAD: `9bfce05f708fba472ca942bcfe355914847a347d`.
  **Working-tree file hashes, including the late coordinator UI edit, define this
  map's source snapshot.** Earlier inventory implementation hashes are not reused
  as proof of current UIKit source.
- JSON `hash_pins.files` contains **92 raw SHA-256/byte pins**: the inventory,
  Original sources/supporting search source and directly cited native sources.
  These are cited-file pins, not a complete app dependency/build fingerprint.

| Original file | Exact public bodies |
|---|---:|
| `AboutHeaderCell.java` | 3 |
| `OpenExteraAppNavigationActivity.java` | 3 |
| `OpenExteraAppearanceActivity.java` | 9 |
| `OpenExteraAyuMomentsActivity.java` | 9 |
| `OpenExteraChatsActivity.java` | 9 |
| `OpenExteraCloudActivity.java` | 8 |
| `OpenExteraGeneralActivity.java` | 7 |
| `OpenExteraGlyphActivity.java` | 6 |
| `OpenExteraOtherActivity.java` | 11 |
| `OpenExteraSettingsActivity.java` | 10 |
| `utils/SettingsRegistry.java` | 26 |
| `utils/SettingsRowMenu.java` | 1 |
| **Total** | **102** |

Important exact identities:

- `AboutHeaderCell.draw(Canvas):59` belongs to the anonymous logo ImageView.
- Navigation `onItemClick(int):95` handles **Back only**. Root
  `onItemClick(int):107` handles **Back/Cloud/Search**. Neither is the protected or
  private row-dispatch overload read alongside it.
- Chats `invalidate():2320` belongs to `StickerSizeCell`.
- `SettingsRegistry.onSettingNotFound():259` and
  `onSettingNotFound(BaseFragment):263` are separate entries. The latter is
  logging-only and ignores its argument.
- Chats' four constructor modes do not multiply its nine method bodies.

Disposition tally: **8 native-flow / 26 equivalent-platform-role / 43 partial /
25 unsupported**. Platform roles name the actual substitution, such as UIKit
insets, controller disposal, typed destination closures or native logo clipping.
Partial/unsupported members identify their missing provider. A boundary anchor
on an unsupported member is explicitly not an implementation.

`route[].line` identifies the relevant declaration or statement inside the named
symbol; `role` states its purpose. The JSON remains the full per-member authority.

## Actual Root composition and controls

The production entry chain is:

1. `telegram-ios/submodules/TelegramUI/Sources/AppDelegate.swift:1990–2073`
   subscribes to preparation and presents **Settings recovery → Retry** on failure.
2. `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift:55–118`
   composes the real domain definitions, prepares fonts, configures the chosen
   App Group settings file, registers/migrates, prepares private settings and
   Client API configuration on its serial worker.
3. The same runtime's `beginPreparation:205–241` installs entry points only after
   successful preparation. `installEntryPoints:244–247` installs the actual factory.
4. `AppDelegate.swift:1299–1319` gates initial shared/account-context construction
   on readiness. Runtime `update(context:):272–318` constructs/updates integrations.
5. `telegram-ios/submodules/AccountContext/Sources/ExteralessSettingsEntry.swift:15–34`
   supplies the factory to
   `telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoSettingsItems.swift:279–286`.
   The native advanced row pushes `exteralessSettingsController(context:)`.

In the following paragraphs, **SettingsController** means
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsController.swift`;
**UIHelpers** means the adjacent `ExteralessSettingsUIHelpers.swift`.

### Registration and visibility

- `ExteralessSettingsUI.registerActions:31–37` merges by unique String ID and
  preserves insertion order. Registration does not invoke the action.
- Root `renderRoot:147–163` excludes exactly: **`AI state` section**, keys matching
  **`ClientAPIFeatures.requiresNativeEditor`**, and
  **`ExteraConfigCompatibility.keys`**. It then appends current actions.
- Eligible secret definitions and raw metadata such as `ai.services` can still
  appear in generic Root. The owned provider/credential editor is a distinct
  semantic workflow, not a claim that every corresponding generic field is hidden.
- A tap re-queries the action registry (`:159`) and uses the invoking context and
  presenter. Additional availability/account checks are domain-owned; Root itself
  does not synthesize them or universally show a missing-provider alert.
- Original General/Appearance/Chats/Other category pages are reorganized into
  native sections/actions. Original root About/project/designer links are partial
  or absent with specific dispositions. Plugins has a separate PeerInfo entry
  (`PeerInfoSettingsItems.swift:301–308`) and Main Menu ID 102, outside the 55 client
  action registrations.

### Editors, export and reset

- `settingRow:175–225` chooses secure replacement, option selector, switch,
  numeric slider/editor or text/JSON editor from actual definitions.
- `renderSelector:228`, `renderEditor:248`, `savePressed:386` and `update:340`
  re-read definitions and validate type/options/range/step/shape; custom DoH also
  runs `NewNetworkFeatures.validate`. UIHelpers `ExteralessSettingsSlider:27–44`
  rejects unsuitable/inexact ranges rather than inventing a slider value.
- `confirmReset:356–377` is **one-key override/Keychain-item removal**. Long press,
  VoiceOver reset and the editor's reset row reach it. Generic Root set/reset does
  **not** supply an expected-snapshot CAS argument.
- `ClientSettings.applyPublic:294` and `runPublicBatchLocked:461–520` support
  actual multi-key value-and-presence CAS **when the caller supplies `expected`**.
  Pill layout, pinned-reaction edits and Client API ID/mode commits have explicit
  callers in the JSON. API existence alone is not assigned to every UI action.
- `exportPressed:417–427` shares JSON from the cached snapshot after removing
  secret keys (`ClientSettings.exportJSON:337–348`). It does not reuse Root's
  visibility filters, reread disk or produce a Tools/Cloud archive. Presentation
  requires the screen to remain visible and have no presented controller.
- Missing selector/editor definitions reach `missingSection:300–302`; an editor
  clears Save. Generic operation errors/progress are supplied by UIHelpers
  `operationSections:251`, `perform:265` and `showError:292`.

### Late coordinator secret-label correction — included

SettingsController `settingRow:187–193` was re-read after the four-line correction.
The pinned file SHA-256 is
`e8f2d6b67c4dc64a9f0dc5b7956121c40f6a4da5764e720fa00b1fdc38d26ed0`.

| Snapshot state for a registered secret | Actual Root label |
|---|---|
| Typed value missing (`values[key] == nil`), known stored presence | **Stored value unavailable** |
| Typed value missing, no known stored presence | **Secure storage unavailable** |
| Typed value available/redacted `.null`, stored presence | **Stored securely** |
| Typed value available/redacted `.null`, no stored override | **Not set** |

A learned secret whose current definition is public instead gets the disabled
migration-pending label. Repairable secret definitions still expose replacement
and reset when idle. Reset removes the item; saving an explicit empty value is a
different operation. `ClientSettingsSnapshot.init:102–111` and
`resolvePublic:534–539` preserve the nil-versus-redacted/presence distinction.

The supplied prior SCR-01 Core closure and three real Mac run20 regressions are
retained as coordinator context. This document does not reopen SCR-01 or claim
execution of the new label branch. No snapshot/API change was inferred.

## Named action registry — all 55 source declarations

Each ID below has its own JSON record with Original relationship, actual
registration/factory anchor, search/subpage/reset path and unavailable behavior.
Native extensions without a named row in the twelve-file boundary say so.

| Owner | Individually mapped IDs |
|---|---|
| Appearance (8) | `appearance.nativeThemes`, `appearance.autoNight`, `appearance.appIcons`, `appearance.mainMenu`, `appearance.customizeMenu`, `appearance.iconPacks`, `appearance.editIconPack`, `appearance.monetThemes` |
| Chats (5) | `chats.feed`, `chats.player`, `chats.bookmarks`, `chats.deleteDefaults`, `chats.trackingFilter` |
| Player (2) | `appearance.playerLibrary`, `appearance.playerDecoderInfo` |
| Pills (1) | `pills.status` |
| Privacy (5) | `privacy.ghost`, `privacy.chat`, `privacy.botAccount`, `privacy.proxies`, `privacy.notifications` |
| Privacy extras (2) | `privacy.localFilters`, `privacy.hiddenAccounts` |
| Dialogs (1) | `dialogs.forumLayout` |
| AI (8) | `ai.services`, `ai.roles`, `ai.editor`, `ai.result`, `ai.translationModels`, `ai.translationLanguages`, `ai.speech`, `ai.pluginReview` |
| Tools (7) | `tools.fileSaving`, `tools.favoriteStickers`, `tools.backup`, `tools.updates`, `tools.diagnostics`, `tools.files`, `tools.shortcuts` |
| Network (1) | `network.resolverStatus` |
| Maps (1) | `maps.providerScope` |
| Stickers (7) | `stickers.emojiPacks`, `stickers.pinnedChats`, `stickers.pinnedChannels`, `stickers.quickReaction`, `stickers.nativePacks`, `stickers.nativeEmojiPacks`, `stickers.localGifs` |
| Identity (1) | `identity.account` |
| Retention (4) | `retention.archive`, `retention.importAyu`, `retention.chatRecords`, `retention.exceptions` |
| Cloud / Client API (2) | `cloud.settings`, `clientAPI.edit` |

**55 is a source-declaration inventory, not a live registry/row count.** Examples:
`tools.shortcuts` requires real bindings; hidden-account management may unregister;
Cloud/Identity actions retire with their account. Main Menu has another registry
with provider filtering. Plugin-supplied menu/settings content is a separate source.

Original `SettingsRegistry.java:36–38,175–222` explicitly says the NagramX screens
do not self-register UItems. Plugins populate its two maps. Six category classes,
`addRow` call sites, method counts and native action declarations do not establish
the size of `preparedEntries`, aliases, search results or a rendered page.

## Owned screens and consequential route distinctions

- **Client API:** filtered `clientAPI.*` fields reach
  `Cloud/ExteralessClientAPIController.swift:29–124`. Production/test drafts are
  separate; ID/hash save uses a pending marker and public CAS
  (`swift/ExteralessCore/Sources/ExteralessCore/ClientAPISettings.swift:67–96`).
  Built-in mode retains the draft. Empty hash retains only a valid same-ID hash.
  Current accounts and started logins keep their pinned identity.
- **AI/provider credentials:** `AI/ExteralessAISettingsControllers.swift:28–187`
  owns provider/model/key binding; `:331–405` owns LLM keys/endpoints/prompts.
  An owned prompt editor intentionally reads prompt text. Generic Root shows
  redacted status and replacement controls. These are different UI roles.
- **Speech:** `Speech/ExteralessSpeechController.swift:23–111` owns selected-provider
  credentials and request fields. Apple Speech/installed voices replace Vosk model
  archives explicitly. Its OpenAI key branch uses typed remove; Cloudflare/Gemini
  branches call `store.set(.string(value))`, so their empty save must not be
  documented as proven Keychain-item removal. Generic Root reset is the actual
  per-key deletion route.
- **Cloud/backup:** Cloud restore requires the real maintenance binding and a
  reviewed plan; missing binding disables Restore with a reason
  (`Cloud/ExteralessCloudController.swift:85–101`). Root binds existing lazy Host
  capabilities at `ExteralessClientRuntime.swift:322–364`. Tools backup has its
  own bounded inspection/apply/recovery controller. Native Cloud history deletion
  preserves the Android-format copy; export/restore/repair are not interchangeable.
- **Local Premium/names:** `IdentityFeatures.accountDefinitions` are intentionally
  not global ClientSettings definitions. `identity.account` owns the permit,
  encrypted-account state, expected-value editing and local identity resets.
- **Server sensitive content:** Original Other's row maps to stock **Data and
  Storage**, not `privacy.ignoreContentRestrictions`. Actual native capability
  checks are at `DataAndStorageSettingsController.swift:644`; remote mutation is
  at `:888–915`. Stock path `data/show-18-content` is marked `isVisible: false`
  (`SettingsSearchableItems.swift:3627–3636`). Ordinary search availability must
  not be invented for that hidden entry.
- **Settings section consumers:** actual keys
  `appearance.hideHelpSection`, `appearance.hidePremiumSection`,
  `appearance.showStickersRowToplevel` are registered through
  `AppearanceAdditionalFeatures.settingsSectionDefinitions`. The PeerInfo builder
  invokes `ExteralessAppearanceSettingsItems.swift:6–23`: section-identity filters,
  stable inserted sticker-row ID and real `.stickers` action. The third ID is a
  required module-rollup input, not a fabricated row inside these twelve files.

Paths in this section beginning `AI/`, `Cloud/`, `Identity/`, `Speech/` or a runtime
filename are relative to the full ExteralessClient directory defined above. The
JSON provides repository-relative paths and raw pins for each cited anchor.

## Concrete missing scope

The JSON names each limitation where it affects a member or route:

- Client settings search/index, Original option aliases, row highlighting and
  Copy Link context-menu provider.
- Original About/project-link/category layout and inline avatar/chat/folder/FAB/
  sticker/double-tap/wide-post previews. Native logo clipping is relocated to App
  Icon and explicitly approximate.
- Original expandable group/master/dependent-row compositions. Root exposes
  registered individual controls; it does not reproduce every conditional row,
  coupled master mutation or preview animation.
- **Other → Reset all settings** and **Ayu → Disable all** composite providers.
  Per-key reset, ghost toggle, identity reset and archive clear have narrower,
  explicitly described scopes. Resetting defaults can restore true values and
  therefore is not equivalent to disabling every Ayu feature.
- Nothing Glyph hardware/SDK, Android push/gateway/resident/battery-whitelist
  controls, Android camera-engine chooser and Vosk archive management. Actual iOS
  adaptations and their missing exact UI/provider pieces are named separately.
- The stock account-deletion flow is real, but does not supply Android's 30-second
  button countdown or 500ms spinner delay.
- Original Other slots assigned `-1` remain **source-inactive**, not counted as
  live rows or newly broken native entries.

This map accounts for all 102 methods. Named row coverage is the explicitly
listed actions/control groups, not every spacer/header/runtime plugin row or
every downstream feature API. Native feature consumers, full-app compilation,
runtime account behavior and exact rendered frames require their own evidence.

## Finding MS-ROUTE-01 — P2, source-only

**Client settings search and row-link navigation lack a native index/resolver.**

- Original `OpenExteraSettingsActivity.java:112–113` invokes the actual
  `BaseNekoSettingsActivity.java:633–819` search UI. Navigation's
  `scrollToRow(String,Runnable):304–317` separately resolves and highlights named
  Original keys. Plugin `SettingsRegistry` is not mistaken for either implementation.
- Native SettingsController `Mode:65–69` has root/selector/editor. Its Root
  navigation item is Export (`:124–135`). The complete native index assembly in
  `telegram-ios/submodules/SettingsUI/Sources/Search/SettingsSearchableItems.swift:4379–4478`
  never projects client definitions or registered actions.
- **Counterexample by source trace:** `appearance.avatarCorners` is an actual
  editable Root setting, yet there is no client index/alias step leading a search
  result to it. `handleSettingsPathUrl:4598–4600` returns for a client-only path
  absent from that index. Main Menu Search instead calls chat/app search
  (`Appearance/ExteralessMainMenuRegistry.swift:100–108`).

The gap is route completeness, not a new storage regression or an executed UI
failure report. No closed SC/SCF/SCR counterexample is reinstated. Other named
partial/unsupported limits remain explicit dispositions rather than severity
claims inferred from counts.

## Static checks performed

Own inline Python/text checks, each bounded to 30 seconds:

- JSON parsing with duplicate-object-key rejection and required route fields.
- Exact identity multiset equality against the pinned inventory:
  **102 unique, 0 missing, 0 extra**, including both not-found overloads.
- **12/12 Original raw file pins** equal the inventory pins.
- **55/55 distinct action IDs** matched the actual registration declarations,
  including shorthand/conditional registration blocks; no runtime registry walk.
- **92/92 raw file hashes/byte lengths** matched the cited snapshot.
- **455 cited anchor line ranges and symbol tokens** resolved. This syntactic
  check supplements the authored control-flow reading; it is not behavioral proof.
- **0 verified/ported promotions.**

No Swift compilation or tests were executed. Coordinator-provided green
Core/Mac/SDK/C219 evidence keeps its component scope; it does not establish UIKit
or a full native app. The provided **36 targets / 410 methods / eight recordings**
remain source-provided, not executed in this task. Pending Mac/full-app work was
not queried. Visual/frame acceptance remains unclaimed.

## Output and key hashes

| Artifact/input | SHA-256 |
|---|---|
| `settings.json` | `ffc974596dbabdc71a4667e6673eca21dfd0a7eb0ab283832e6984daef1e406f` |
| `docs/parity/client-features.json` | `ee82f6d3f53c1ff2ccc9785305b63553ea504abdb5274c11fa9148144d5fc240` |
| Original module hash recorded in inventory | `304f847ff2fa5093e8aa46b507181423383a4b3752f4ab3add1d728c83ab8117` |
| Current `ExteralessClientRuntime.swift` | `5709414fc3a29f553eb160c3fc267956e3138de56fc207cbcf61e57981a4dcbf` |
| Updated `ExteralessSettingsController.swift` | `e8f2d6b67c4dc64a9f0dc5b7956121c40f6a4da5764e720fa00b1fdc38d26ed0` |
| Current `ClientSettings.swift` | `203b973a7f09bb657075ea92daf22065e2ee0baf060147bbc8c0661f1231c556` |

The only authored files are the new `docs/wave-2/module-routes/settings.json` and
`docs/wave-2/module-routes/settings.md`. Existing sources, scanner and receipts
remain inputs to this document. No commit or CI/network/account/plugin operation
was performed.
