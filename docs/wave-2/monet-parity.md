# Monet — native theme adaptation handoff

**Authored native consumer/helpers and tests are ready; the shared integration patch is not applied by this child. No Swift/iOS build, XCTest or recorded-frame pass is claimed.**

Original ID: `appearance.monetStyle`, reconciliation `docs/parity/wave-2-reconciliation.md:51`.

## Scope and source proof

- Original selector: `AppearanceConfig.kt:81–97`, **Telemone = 0**, **Classic = 1**; unknown values select Telemone. `Theme.java:5733–5760` reloads only selected Monet themes, keeping the day/night state.
- Original color machinery: `MonetHelper.java`: M3 light/dark/fixed roles, five tonal palettes, exact `toneToShade`, reconstruction of intermediate tones from **shade 600**, HCT harmonization, custom palette matching and neutral-accent link recoloring.
- Supplied Original still has no `res/assets`. None of its six Telemone/Classic Light/Dark/AMOLED asset files has been recovered.
- Targeted public upstream discovery found **two** assets at immutable exteraGram commit **`6f78031aafd7f27e0dfaa31a207715569a6df1a2`**. That commit is dated **2023-06-02**, despite the repository's later archive date. These are Classic **reference tokens**, not proof that Original's missing `*_gram` assets match them.
- `monet_light.attheme`, 23,411 bytes, SHA-256 `3eeca58882fc503e36917e53554c99badf2afb549fc134cecc323c1eeca459f5`.
- `monet_dark.attheme`, 23,424 bytes, SHA-256 `f8a866697ade7f55a1637abb06aa35f6960d6c308f0972a33260abd871e315d6`.
- Upstream license: GPL-2.0-or-later, from that commit's actual LICENSE, SHA-256 `3f0901488e52e36314c701ba4cc0c0086db7377633334c04a7c17cd173077bb0`. Its original bytes and attribution are included with the native notices.
- HCT/CAM16/Blend: **seven unmodified Swift files** from `material-foundation/material-color-utilities` commit **`194144d75ed7d34f06264a625e086db81a7ab9aa`**, Apache-2.0. Flattened paths only; no package download at build/run time.

All Original, upstream, math and independent-oracle pins: [`monet-source-pins.json`](monet-source-pins.json). Each external file download was bounded to 32 KiB and checked against the discovered Git blob before its SHA-256 was recorded.

## Native implementation

### Core

`swift/ExteralessCore/Sources/ExteralessCore/CoreAppearanceMonetPolicy.swift`:

- `AppearanceMonetPolicy.definition`: the only new setting, `appearance.monetStyle`, integer 0/1, default 0. There is no enabled/mode preference that could opt existing users in during bootstrap.
- `AppearanceMonetStyle`, `AppearanceMonetMode`, `AppearanceMonetRoleTone`: portable selection and Original role/tone tables, including the unusual `on_*_fixed_dim = 80` aliases.
- `AppearanceMonetTokens`: actual surface-token mapping consumed by the theme factory.
- `AppearanceMonetDescriptor`: strict, versioned metadata in a native local theme's encoded `name`. Ordinary themes named “Monet Light” are not recognized as Monet.

### TelegramPresentationData

`Sources/ExteralessMonetPalette.swift`:

- Five immutable palettes, 13 system tones each. iOS seed recipe: HCT primary chroma `max(48, C)`, secondary 16, tertiary 24 at hue + 60°, neutral 4, neutral-variant 8. Seeds below chroma 8 keep neutral chroma. **This seed recipe is an iOS adaptation**, not Android wallpaper extraction.
- Exact system-tone/shade lookup; missing M3 tones such as 98/6/17/22 derive from quantized palette tone 40 as Original does.
- Named M3/fixed/tonal tokens, `monet_` alias, constants, material/harmonized/custom colors, bounded `s/l/a/t/c` modifiers and percentage darkening. Unknown resource tokens return nil. Android `monetRed*` resources and avatar-specific tokens are outside this consumer's token vocabulary.
- Neutral accent links use Original's hue 250/chroma 70 at the resolved tone, preserving alpha. Regular text stays neutral.
- `readable(_:on:)` is an explicit native correction: retain hue/chroma and move tone only when a text pair falls below 4.5:1. In particular, some upstream Classic outgoing-link pairs need correction. Corrected colors are not represented as exact Android asset colors.

`Sources/ExteralessMonetTheme.swift`:

- `makeExteralessMonetPresentationTheme(descriptor:index:preview:source:wallpaper:)` creates the **real** `PresentationTheme`: list and chat-list backgrounds/text, navigation/tab bars, incoming/outgoing bubbles and text/links, reaction/poll controls, composer, emoji/media keyboard panels, action sheets, context menus, service messages, notifications, passcode and chart colors.
- Light uses native light keyboard/status contrast; Dark/AMOLED use native dark keyboard/white status contrast. The Apple keyboard exposes a light/dark appearance, not an app-defined wallpaper palette; the app's media keyboard surfaces use the generated colors.
- `exteralessMonetDescriptor(_:)` admits a canonical descriptor only in the native **local theme index namespace**. Builtin/cloud themes remain ordinary native themes.
- `exteralessCustomizeMonetPresentationTheme(...)` sits before the stock no-overrides fast path. An explicit native accent becomes the new seed. Explicit native outgoing colors and wallpaper outputs retain precedence through the stock customizers. Their unrelated reaction-color side effects are not copied back.
- `exteralessMonetAppearanceTheme(_:style:)` handles in-memory style replay. `ExteralessMonetThemeReplay` keeps one bounded source-object/style/result memo per presentation adapter. A same-index new native object still invalidates it.
- Before a process has a registered style cache, decoding retains the descriptor's saved style. After preparation, the registered selector/default is authoritative. This avoids an unprepared decoder inventing a Telemone reset.
- Native `index`, preview, `forceSync`, `starGift`, wallpaper and explicit outgoing overrides survive replay. Each produced presentation theme has a **fresh resource cache**. No global UIImage cache is modified.
- `ExteralessMonetThemeSlot` / `exteralessMonetReplacingTheme(...)` merge only the chosen native day/night reference after checking its expected reference. They preserve native schedules/force, typography, accessibility/motion settings and all unrelated theme-specific dictionaries.

### UI / account lifetime / persistence

New files under `TelegramUI/Sources/ExteralessClient/Appearance/`:

- `ExteralessMonetSettingsController.swift`: reachable Monet Themes screen, style rows, explicit day/night destination, editable sRGB accent seed, Light/Dark/AMOLED actions and existing native theme/auto-night routes. Default seed is the active Monet seed or the current native accent.
- `ExteralessMonetThemeActions.swift`: a **real encoded native local theme** is saved to native resource stores before publishing its reference. Resource IDs use the stock random local-file identity. Mode/seed survive native preferences and theme-codec reload; there is no shadow account-theme store.
- Uses existing `context.engine.resources.storeResourceData` / `completedResourcePath(id:)` and `context.sharedContext.accountManager.resources` equivalents. No `import Postbox`, `.postbox`, allowlist expansion or new storage wrapper.
- Encoding and verified resource writes run on a serial worker queue (maximum encoded theme 256 KiB). Main-thread style replay has no file decode/read/write.
- Native `accountManager.transaction` reads live settings, rechecks immutable account/operation tokens and CASes the selected reference. The active-slot selection also performs the same `SharedDataKeys.themeSettings = ThemeSettings(currentTheme: nil)` update as stock `applyTheme(nil)`, **in that transaction**. Selecting an inactive slot does not retire the active cloud theme.
- Account `attach` creates a token; `detach` invalidates it. A dismissed controller disposes its operation. An already admitted atomic transaction may finish; retired tokens cannot admit later work. There is no detached task publishing a stale account/theme.

Resource trace: the canonical reload resource is the **AccountManager** media store, separate from the account media cache. `Account.swift:2201–2211` configures cleanup on the latter; `TimeBasedCleanup.swift:345–374` starts scanning only after `setMaxStoreTimes`. No production call configuring AccountManager cleanup was found. `PresentationThemeSettings.relatedResources` currently has no runtime reader, so the preliminary idea of appending its night resource was not an effective retention fix and was removed from this packet. Both day/night references are persisted and reloaded by the existing native codec/store architecture.

## Exact shared integration patch

[`monet-integration.patch`](monet-integration.patch), relative to **`C:\exteraless-ios`**, passed `git apply --check --whitespace=error`. It is intentionally handed back to the coordinator because these are shared files:

| Shared file | Exact insertion |
|---|---|
| `swift/ExteralessCore/Sources/ExteralessCore/AppearanceFeatures.swift` | Insert `AppearanceMonetPolicy.definition` into the existing array; does not rewrite agents' appended definition chains. |
| `TelegramUI/.../Appearance/ExteralessAppearanceIntegration.swift` | Register `exteralessMonetSettingsActions()`, attach after setting current context, detach at `clearContext`. |
| `TelegramPresentationData/Sources/MakePresentationTheme.swift` | Invoke the Monet native customizer **before** the early return in `customizePresentationTheme`. |
| `TelegramPresentationData/Sources/PresentationThemeCoder.swift` | Replay selected Monet style after a native local theme is decoded. |
| `TelegramPresentationData/Sources/ExteralessAppearanceUpdates.swift` | Replay through the local memo before existing immutable divider/presentation copying. Add injectable `monetStyle` closure for actual native signal tests. |
| `TelegramPresentationData/BUILD` | Bind the new native test file to the existing appearance test target, add its direct imports, expose the three checked-in notice resources. |
| `TelegramUI/BUILD` | Add the notice filegroup to existing `TelegramUIResources`, also used by the prepared native host. |
| `Tests/Exteraless/native-tests.json` | Add mandatory source → existing appearance target binding. |
| `Telegram/Share/ShareRootController.swift`, `Telegram/NotificationContent/NotificationViewController.swift` | Add only `AppearanceMonetPolicy.definitions` to the existing shared-settings preparation batch, before either extension's presentation factory. |

No new production dependency, resource downloader, native test host or CI workflow is needed. Existing recursive Swift globs include all new production sources and the Core test. The main app already registers `AppearanceFeatures.definitions` in `ExteralessClientSettingsWorker` before `AppDelegate.swift:1297–1303` admits its first presentation factory. Share and NotificationContent have narrower schemas; their two explicit registration hunks are required for current saved Classic/Telemone selection. They add no new configure/read operation outside those existing batches. Existing `exteralessAppearanceUpdates` observes the new key during set/reset/reload, without restarting its file-backed native source.

## Classic source-token crosswalk

These are direct token receipts from the two pinned upstream assets. The native factory applies them to corresponding iOS roles; it is not an Android key-for-key theme renderer.

| Native role | Upstream key | Light | Dark |
|---|---|---|---|
| Background | `windowBackgroundGray` / `chat_wallpaper` | `mWhite` | `n1_900` |
| List surface | `windowBackgroundWhite` | `mWhite` | `n1_900` |
| Navigation | `actionBarDefault` | `mWhite` | `n1_900` |
| Raised menu surface | `actionBarDefaultSubmenuBackground` | `a1_10` | `n2_800` |
| Primary text | `windowBackgroundWhiteBlackText` | `mBlack` | `n1_50` |
| Secondary text | `windowBackgroundWhiteGrayText` | `n1_600` | `n1_300` |
| Accent | `windowBackgroundWhiteBlueText` | `a1_600` | `a1_200` |
| Accent foreground | `chats_actionIcon` | `a1_100` | `a1_800` |
| Incoming bubble | `chat_inBubble` | `n1_50` | `n1_800` |
| Incoming text | `chat_messageTextIn` | `mBlack` | `n1_50` |
| Incoming link | `chat_messageLinkIn` | `a3_600` | `a3_100` |
| Outgoing bubble | `chat_outBubble` | `a1_600` | `a1_200` |
| Outgoing text | `chat_messageTextOut` | `n1_50` | `n1_900` |
| Outgoing link | `chat_messageLinkOut` | `a3_200` | `a3_600` |
| Service fill/text | `chat_serviceBackground` / `chat_serviceText` | `n2_100` / `n2_800` | `n2_800` / `n2_100` |
| Search/input surface | `dialogSearchBackground` | `n1_50` | `n2_800` |
| Generic link | `windowBackgroundWhiteLinkText` | `a3_600` | `a3_200` |

The separator treatment, Telemone's iOS surface-to-M3-role assignments, AMOLED black planes and text contrast corrections are explicitly native choices. AMOLED retains tonal raised surfaces and bubbles; it is not an all-black palette with unreadable controls.

## Expected frames, defined before recording

Fixture accent **`#007AFF`**, no custom outgoing overrides, newly selecting each variant:

| Style | Mode | Root/chat default background | Incoming bubble | Outgoing bubble | Keyboard/status |
|---|---|---|---|---|---|
| Telemone | Light | `#FAF9FF` | `#E1E2EC` | `#D8E2FF` | light / black |
| Telemone | Dark | `#11131A` | `#32353C` | `#004493` | dark / white |
| Telemone | AMOLED | `#000000` | `#32353C` | `#004493` | dark / white |
| Classic | Light | `#FFFFFF` | `#F2F0F4` | `#005BC1` | light / black |
| Classic | Dark | `#1B1B1F` | `#303033` | `#ADC6FF` | dark / white |
| Classic | AMOLED | `#000000` | `#303033` | `#ADC6FF` | dark / white |

Expected recording paths using the normal loginless native harness / disposable simulator:

1. Each of the six variants: real settings list, chat list, chat containing incoming/outgoing text + links, composer, media keyboard, action sheet. Text must remain legible; AMOLED main/navigation planes must be black with no stock-blue/white plane flash.
2. Telemone ↔ Classic on selected Monet: list/navigation/bubbles/text update together on native presentation delivery. **The native saved chat wallpaper stays selected** during style-only replay; its background need not change to the fresh-selection table above. No geometry, scroll position, input content or sheet lifecycle should reset.
3. Same style change on an ordinary builtin/cloud/local theme: its actual colors remain the same. Returning to a Monet choice uses the saved selector.
4. Automatic day/night switch and forced-night toggle: each native slot keeps its selected theme; schedule/force are not silently rewritten. Relaunch restores both from the canonical shared theme store, including the previously inactive local night resource.
5. Custom native wallpaper and outgoing bubble gradient: both remain visible across style replay; a native accent edit recolors other Monet roles using that accent as seed.
6. Neutral seed `#777777`: body remains neutral, links acquire the chromatic fallback; readable text/link contrast, no arbitrary saturated accent replacement.

Record `simctl io recordVideo`, decode using `tools/animation_sheet.py`, evaluate labeled **ffprobe** timestamps/frames per AGENTS. Frame evidence remains pending: this Windows session has no Swift, Xcode or XcodeBuildMCP tool. Numeric vectors are not rendered frames.

## Tests and completed checks

- Core: `AppearanceMonetPolicyTests` — 4 small tests: raw selector/mode mapping, Original role/shade vectors, strict native metadata admission/roundtrip, real ClientSettings save/reload/reset. No real account.
- Native: `AppearanceMonetPresentationTests` — 6 tests, same actual `PresentationTheme` factories/codecs and presentation signal used by production; six variants, HCT/reference/link vectors, real customization precedence, native preferences codec/slot CAS and disposal/replay. Only bounded 1-second signal drains; prepared-class budget **≤30 seconds** via the existing runner.
- Target after coordinator applies the patch: `//submodules/TelegramPresentationData:ExteralessAppearancePresentationTests`; fixture class `AppearanceMonetPresentationTests`. Core file is picked up by the existing SwiftPM test glob.
- Independent oracle: [`monet-reference.mjs`](monet-reference.mjs), executed with Node 24.21.0 against the checksum-verified **TypeScript** math from the same immutable MCU commit. It recorded vectors for `6750A4`, `007AFF`, `777777`; selected values are literal expectations in native tests. This did not execute the Swift implementation.
- **Passed here:** seven vendored Swift-file SHA checks, both verbatim license SHA checks, three Original source SHA checks; independent reference generation; complete `PostboxImportCheck.py`; shared patch dry-run.
- **Pending:** Swift/native compilation and XCTest, actual shared-media-store save/relaunch on the prepared native host, real UIKit frame evaluation. No CI, live account, simulator installation or commit was performed.

## Remaining parity limits

This closes the authored *portable native consumer* design, subject to shared integration and native execution. It does **not** establish full Original asset/visual parity: Original Telemone/Classic/AMOLED tokens are still absent, public upstream supplies only older Classic references, iOS generates a palette from a chosen accent, and OEM Android framework-role/wallpaper colors are not reproduced. The native local resource is a save-time encoded snapshot with its descriptor; the current Monet selector is interpreted at load/replay. Native per-chat/cloud/forced-theme selection keeps the existing precedence because those themes are not admitted by the local descriptor gate.
