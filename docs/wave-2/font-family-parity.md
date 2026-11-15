# Native font-family choice — `neko.typeface`

**Status (2026-11-15): owned implementation and resources are present; coordinator
registration/build/SDK joins and native verification are pending.** No Swift,
Xcode, simulator, XCTest or frame execution is claimed on this Windows host.

## Original contract and iOS adaptation

Original source root: `third_party/exteraless-android/TMessagesProj/src/main/java/`.

| Evidence | Contract |
|---|---|
| `tw/nekomimi/nekogram/NekoConfig.java:94` | `typeface = addConfig("TypefaceUseDefault", configTypeBool, true)` |
| `org/telegram/messenger/AndroidUtilities.java:2452–2463` | `true` calls `TypefaceHelper.createTypeface`; `false` calls `createTypefaceFromAsset` |
| `tw/nekomimi/nekogram/helpers/TypefaceHelper.java:73–117` | System sans/weight/italic selection versus actual bundled asset construction |
| `com/exteragram/messenger/ExteraConfig.java:527–535` | `getUseSystemFonts` / `setUseSystemFonts` directly alias the same boolean |
| `TypefaceHelper.java:136–249` | Pixel-only Google Sans discovery/metric heuristic, specific to Android system fonts |

Native key: **`appearance.useSystemFonts`**, public boolean, default **true**.

- **True:** actual Apple system fonts obtained through UIKit.
- **False:** actual bundled **Roboto 3.015**, using its separate upright/italic
  variable faces. This is the Roboto-family equivalent of Android's bundled base
  assets. The supplied Android tree lacks those asset files, so byte-identical
  Android assets, exact Android line metrics and Pixel Google Sans are not claimed.
- `NekoConfig.typeface` is the canonical `androidSymbols` binding. The Config SDK
  remains a boolean accessor to the real native setting; it produces no Java
  `Typeface` substitute.
- Native text-size / Dynamic Type `useSystemFont` and
  `appearance.forceFontWeightFallback` remain independent preferences.

San Francisco and the camera's existing Aremac resources are never renamed or
described as Google Sans. The Pixel heuristic has no iOS counterpart to emulate.

## Implemented source

1. `swift/ExteralessCore/Sources/ExteralessCore/CoreAppearanceFontFamilyPolicy.swift`
   declares the typed setting, original default and explicit-design policy.
   It uses Foundation only and can be tested through the Core Swift package.
2. `telegram-ios/submodules/Display/Source/ExteralessFontFamily.swift` validates
   exact bundled bytes, registers both graphics fonts in-process and produces
   real `UIFont` / `CTFont` instances from retained templates.
3. `telegram-ios/submodules/Display/Source/Font.swift` connects the real shared
   producer: `with`, `regular`, `light`, `medium`, `semibold`, `bold`, `heavy`,
   `italic`, `mediumItalic`, `semiboldItalic`. The cache key includes family,
   size, resolved weight, design, width and traits. A previous system entry
   cannot hide the user's Roboto selection, and switching back reuses its entry.

Native weights map to Roboto's real `wght` axis:

| UIKit role | thin | light | regular | medium | semibold | bold | heavy |
|---|---:|---:|---:|---:|---:|---:|---:|
| Roboto coordinate | 200 | 300 | 400 | 500 | 600 | 700 | 800 |

Italic uses the actual italic file at the same coordinate. Weight/italic
metadata is carried as native CoreText traits for formatting consumers, in
addition to the real variable outlines. The existing bold-weight fallback is
resolved before family selection. The semibold-italic convenience producer now
uses its semibold request rather than its former hard-coded bold trait.

The UIKit descriptor path merges weight/width into the existing traits instead
of discarding the italic trait or overwriting weight with width. Sizes are
forwarded exactly: a caller's already scaled size stays scaled once, and
`UIFontMetrics` can scale the returned font normally.

Explicit serif, monospace, rounded and camera designs retain their native role.
Roboto supports standard and condensed widths (`wdth=100/75`). Explicit SF
compressed/expanded requests and SF's alternate-dollar (`cv09`) glyph role
retain their native font; the bundled Roboto has no `cv09` feature. Tabular
numbers use Roboto's real OpenType `tnum` feature.

The consumer boundary is `Display.Font`, including its chat/UI attributed-text
callers. Direct `UIFont` / `SwiftUI.Font` callers and explicit document/art fonts
have their own font roles. Native screen coverage still needs the frame pass
below; a factory test is not proof that every view rebuilds its attributed text.

## Process lifetime, reload and shaping

`ExteralessFontFamily.prepare()` resolves a Swift static `Result` once. Initialization
is thread-safe, validates byte count and SHA-256 before font decoding, checks
PostScript identity and variable axes, then uses
`CTFontManagerRegisterGraphicsFont`. A name collision is an error rather than
acceptance of an unrelated installed font. Both `CGFont` providers and `CTFont`
templates are retained for the process lifetime. There is no unregister on
settings reset, account change or reload, and no registration work per frame.

The coordinator hook calls `prepare()` **before configure/register/reload can
publish settings**. It runs even for the true default and reports a font-loading
failure through the existing preparation result. Early standard Font producers
also finish that same registration before returning a font. Their nonthrowing
API can use a real system fallback if packaging failed; successful bootstrap is
the condition for exposing the functioning family choice. Initialization failure
is retained, so repeated callers do not retry registration or read assets.

Existing `appearance.*` observation in
`TelegramPresentationData/Sources/ExteralessAppearanceUpdates.swift` already
invalidates presentation data on set/reset/reload. Font entries for both families
remain valid while old attributed strings, CTLines and asynchronous layouts are
alive. The selector reads the current setting on each production request.

Fallback uses the actual Apple default cascade from a matching system
weight/italic font (`CTFontCopyDefaultCascadeListForLanguages`). CoreText/TextKit
continue to perform shaping, bidi, CJK and emoji fallback. The selector does not
walk characters, rewrite text, split UTF-16 ranges or replace link/attachment
attributes. Custom emoji's existing rendering layer remains the owner of its
explicit emoji fonts.

## Bundled bytes and license

Owned resource directory:
`telegram-ios/submodules/Display/Resources/Fonts/ExteralessRoboto/`.

Distribution pin: `google/fonts@1c627bfa375fc51cf86fabeca4f6e08a95f0aa5c`,
`ofl/roboto`. Its source metadata identifies
`googlefonts/roboto-3-classic@91d5d3e5b81efa04a77925cc609fdcdd7ee663d1`
(Roboto 3.015). Every download used an immutable raw commit URL, and its Git blob
identity was verified before copying. Only **1,019,528 bytes of font data** were
downloaded. Both files are unmodified; only the local filenames are namespaced.

| File | Bytes | SHA-256 |
|---|---:|---|
| `ExteralessRoboto-Regular.ttf` | 488584 | `d7598e12c5dbef095ff8272cfc55da0250bd07fbdecbac8a530b9b277872a134` |
| `ExteralessRoboto-Italic.ttf` | 530944 | `9725a847af6b460ffca162ae66d20dad48b01876137947180b42d7dcd7887182` |
| `ExteralessRoboto-OFL.txt` | 4394 | `061402327a96aadb0bfb694a960ed289ecd38d383e396243831ab81feb109c41` |

`pins.json` records exact URLs, both commits, Git blob SHA-1, SHA-256, name-table
identities, license and axis ranges. OFL-1.1 and its copyright notice are shipped
verbatim. Local `.gitattributes` preserves binary and license bytes across Windows
checkouts.

The existing WebRTC example was inspected, not assumed compatible:
`telegram-ios/third-party/webrtc/webrtc/examples/objc/AppRTCMobile/ios/resources/Roboto-Regular.ttf`
is **126072 bytes**, version **2.000980; 2014**, SHA-256
`bde8a188e37aa936b167aecc5e5a3da40262f6e51fd54c584f2cf2b6b99d96ca`.
Its embedded notice says “Font data copyright Google 2014”, Apache License 2.0,
`http://www.apache.org/licenses/LICENSE-2.0`. It supplies one static regular face.
A matched variable pair avoids mixing that old face with new weight/italic
metrics and preserves the full native weight matrix with two small files.

## Exact coordinator/build handoff

These patches are supplied **without applying shared-file edits**:

| Patch | Owner join |
|---|---|
| [`font-family-source.patch`](font-family-source.patch) | Append the new definitions to `AppearanceFeatures.definitions`; run `prepare()` in the actual root `ExteralessClientSettingsWorker` before initial publication and reload; prepare/register in Share and Notification Content extension roots. |
| [`font-family-build.patch`](font-family-build.patch) | Add explicit font/license filegroup and native test target; stage resources directly into each consuming main bundle; add extension Display imports' dependency edges. |
| [`font-family-config.patch`](font-family-config.patch) | SDK scanner registration and accessor regression update; remove the obsolete typeface-blocked disposition; Cloud owner's boolean `neko.typeface` → native-key import rule and removal of its Android-only exclusion. |

From workspace root, the handoff was checked with:

```sh
git apply --check docs/wave-2/font-family-source.patch docs/wave-2/font-family-build.patch docs/wave-2/font-family-config.patch
```

The build filegroup is `//submodules/Display:ExteralessFontResources`. Its three
files must land at the **root of the process's own main bundle**:

- `//Telegram:Telegram`
- `//Telegram:ShareExtension`
- `//Telegram:NotificationContentExtension`
- `//Tests/Exteraless:NativeTestHost`
- `//Tests/ExteralessHarness:ClientUIHarness` (resources for later visual fixtures)

Framework-only staging or finding a containing application's font from an appex
is insufficient. The filegroup uses flat `resources`, not `structured_resources`.
Registration is explicit; do not additionally register these files via
`UIAppFonts`. Notification Service's OS-rendered notification text and WidgetKit's
SwiftUI font calls are not Display family consumers.

The existing `Display/Source/**/*.swift` and Core source globs include the new
implementation. Core's test glob includes its two tests. The new native target is
`//submodules/Display:ExteralessFontFamilyTests`, using the existing
`//Tests/Exteraless:Runner` / `NativeTestHost`. Its test source is excluded from
the older hostless Display test glob, so that target cannot latch a missing-font
initialization before the resource-bearing tests run.

After the source/build join, the SDK owner regenerates the existing manifest and
receipt with `python -m tools.compat.sdk_config_manifest --write` and runs its
binding tests. A read-only in-memory preview of that join confirmed:

```text
NekoConfig.typeface → appearance.useSystemFonts (bool, public)
ExteraConfig.getUseSystemFonts() → read / identity
ExteraConfig.setUseSystemFonts(boolean) → write / identity
```

No generated SDK file or existing AP receipt was overwritten. Coordinator should
update the `neko.typeface` row in `appearance-parity.json` to reference this
consumer/key, retaining the explicit Apple-system/Roboto adaptation and pending
native proof. Integrate the Cloud hunks with that owner's other appearance rules;
native exported settings already carry the new boolean once registered.

## Tests and checks

Authored **two Core tests** (`CoreAppearanceFontFamilyPolicyTests`): original and
pre-registration true default; real store public write/reopen/reload/reset/type
rejection; independent weight setting; native roles and canonical SDK symbol.

Authored **five native tests** (`ExteralessFontFamilyTests`):

1. Every public sans-serif producer selects actual UIKit or registered Roboto;
   real glyph outlines differ; cache restoration returns the prior face.
2. Real variation coordinates/outlines for every weight and italic combination,
   tabular digit advances, condensed bold italic, and independent weight fallback.
3. Explicit designs and Dynamic Type sizes, including largest accessibility size.
4. An actual settings reload observer immediately produces registered Roboto;
   retained CTLine bitmaps stay identical across resets/reloads and repeated prepare.
5. Actual TextNode layout with Latin/combining marks/Cyrillic/Greek/Arabic/Devanagari/
   CJK/ZWJ emoji/flag/link text at 17 and 32pt, with both family choices and traits;
   bounded UTF-16 run ranges, real non-.notdef fallback glyphs, preserved links,
   and CJK/emoji/link selection rectangles within layout bounds.

Run Core on a supported Swift host from workspace root:

```sh
swift test --package-path swift/ExteralessCore --filter CoreAppearanceFontFamilyPolicyTests
```

Use the supported full application build in `telegram-ios/CLAUDE.md`, then the
specific native test target (from `telegram-ios`, with its normal configured
codesigning environment):

```sh
python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir ~/telegram-bazel-cache \
  test --configurationPath build-system/appstore-configuration.json \
  --gitCodesigningRepository git@gitlab.com:peter-iakovlev/fastlanematch.git \
  --gitCodesigningType development --gitCodesigningUseCurrent \
  --target //submodules/Display:ExteralessFontFamilyTests
```

Current source pins Xcode **27.1**; the shared native runner names iPhone 17 /
iOS **27.0**. Use the repository's approved loginless native test environment.

**Checks actually executed here:** all three handoff patches passed
`git apply --check`; each bundled resource matched byte count, SHA-256 and upstream Git
blob SHA-1; both SFNTs had in-bounds tables, `fvar`/`gvar`/`GSUB`, expected Roboto
name/license/version records and exact weight/width axes; the old 2014 face hash
matched; the in-memory SDK join resolved both accessor routes. Swift/Core/UIKit
tests have been prepared but **not run**. No CI was dispatched.

On the Mac, additionally inspect the freshly built IPA's actual `.app` and both
appex bundles and the built NativeTestHost for all three root filenames and the
above hashes. Use the IPA, not a possibly stale `archive-root` directory. Runtime
`prepare()` validates the font data but the shipping license still needs that
bundle check.

## Frame expectations — written before recording

Use synthetic/loginless content and the `AGENTS.md` / `CLAUDE.md` recording
workflow: `simctl io recordVideo`, frame timestamps from `ffprobe`, labelled frame
sheets via `tools/animation_sheet.py`. No native capture exists in this handoff.

Record the actual common-Font chat-list header/rows, message body and settings
controls while toggling **true → false → true**, then after a settings reload and
fresh process start. Include light/dark, mixed LTR/RTL, small/large text and the
largest accessibility category; exercise the Share/Notification Content renderers
in their disposable fixtures after loading the shared boolean.

Expected frames:

- True matches UIKit's actual system family; false visibly changes Latin forms
  and advances to Roboto. Native point-size intent remains constant. A rewrap from
  different family metrics is expected; repeated rewrapping after settling is not.
- Each updated label/run uses one coherent face. Text remains visible while an
  old CTLine/layout finishes. No blank/tofu frame, mixed-family word, stale cached
  system-only result, clipped descender/accent or overlap with adjacent controls.
- Medium/semibold/bold remain distinct, and italic retains its slant and weight.
  Enabling the existing weight fallback changes medium/semibold to bold in the
  selected family, including italic; size and family stay stable.
- Mono/code and serif/document samples retain their role and alignment. CJK,
  Arabic/Indic shaping, combining marks and complete emoji graphemes remain
  visible through Apple fallback, including adjacent links and selection handles.
- Link hit/selection bounds follow the displayed glyphs after relayout; emoji and
  CJK do not enlarge bounds outside their rows or clip at top/bottom. Long titles
  still truncate in the native action-safe lane at accessibility sizes.
- Reset/reload and fresh-process false selection have the same final family and
  wrapping as the live toggle. Return-to-system restores the original appearance.

For acceptance, identify the actual labelled frames/timestamps proving these
expectations and inspect every flagged jump/gap. Unit results and source/hash
checks alone do not certify the visual result.

## PFM-01 follow-up — actual consumer lifetime (2026-11-15)

The independent, read-only review is
[`reviews/portable-fonts-monet.md`](reviews/portable-fonts-monet.md). Its source
counterexample is valid: a file-global `let UIFont` survives a family flip even
when a new node/layout calls the consumer. A correct factory cache cannot refresh
a UIFont that the consumer never requests again.

**Integration state supersedes the original pending-join paragraphs above:** the
coordinator has applied root prepare, Appearance definitions and extension hooks;
the Build owner has applied all five resource-bundle edges. The successor SDK
cohort is **276 implemented / 0 blocked / 32 unsupported**. The old source/config/
resource handoff patches above are historical, not patches to reapply or a reason
to reopen SDK dispositions. The first Mac attempt stopped before UI/Core font
execution; it supplies no Font finding or native Font test result. The original
five Font tests remain queued, not executed.

### Direct fixes in the three authorized consumers

| Source (under `telegram-ios/submodules/`) | Actual resolution point |
|---|---|
| `ListSectionHeaderNode/Sources/ListSectionHeaderNode.swift` | Removes both file-global fonts. Title/action rebuilding uses one current Font request. A node-local UIFont identity check refreshes both attributed strings in `updateLayout`, including unchanged title/action/theme; `updateTheme` also checks the font. The shared Font cache already keys that identity by family. |
| `ChatListUI/Sources/Node/ChatListArchiveInfoItem.swift` | Removes both globals; each invocation of the real `InfoPageNode.asyncLayout` closure resolves regular 20/15pt before measuring. This also covers a layout closure retained across the flip. The real section header uses the refreshed header path above. |
| `TelegramUI/Components/Chat/ChatMessageContactBubbleContentNode/Sources/ChatMessageContactBubbleContentNode.swift` | Removes the title/body globals. The production `asyncLayoutContent` delegates its text measurement and apply to `asyncLayoutContactText`, which resolves semibold/regular 14pt inside each request and updates the node's actual title/body TextNodes and frames. |

Contact text enters this path **after** the existing
`exteralessIdentityContactPresentation` result. `displayName`, fallback organization
resolution, `contactNamePresentation.initials`, associated photo peer and
`overrideLetters`/`setCustomLetters` routing remain the shipping IDSF path. The
fixture can call the actual account-independent text stage and the identity
snapshot overload without constructing an Account or fabricating AccountContext.

No font registration, retained font-template or existing CTLine lifetime policy
changes are needed. Old layouts continue to own immutable fonts/lines; later
measurements query current fonts. This is a source-level repair, not a pixel claim.

### Bounded analogous-global scan and coordinator hunks

`font-family-cache-scan.py` performs a local, bounded query of production
`Source`/`Sources` Swift files under `telegram-ios/submodules`. It matches one-line
file-global/static `Display.Font` requests, masks comments/strings, preserves each
original request and excludes explicit native designs/widths/glyphs, code/fixed,
emoji and icon-art roles. Ordinary titles **with** or **without** an icon are text
roles; QR Studio's control labels are also ordinary text, not QR artwork.

The completed scan examined **194 candidate files / 6,552,082 source bytes** and
recorded **330 declarations**: **294 ordinary-sans requests in 167 files** have
exact computed-getter hunks; **36** retain named explicit-role dispositions.
Bounds are 512 candidate files, 64 MiB total, 4 MiB/file, 600 declarations and
15 seconds for the git query; the complete local command used a 30-second limit.

- [`font-family-global-cache-hunks.patch`](font-family-global-cache-hunks.patch)
  is the **pending coordinator companion**, not direct edits to other owners'
  consumers. Each hunk converts the global/static capture to a read-only UIFont
  getter backed by the current family-keyed Font cache.
- [`font-family-global-cache-scan.json`](font-family-global-cache-scan.json)
  enumerates exact paths, symbols, requests, source SHA-256 and dispositions.
  It includes nearby archive filter title/badge, contact attached-button text,
  date/reaction labels and ordinary chat/map/invoice/webpage titles.
- Both companion artifacts are generated from source; the script never applies
  a source patch. Its ordinary control-label inclusions were checked against
  their real consumers, including iconless swipe titles and QR control labels.

These companion hunks address the process-global capture specifically. They do
not certify every instance-local attributed-string, image or measurement cache;
for example, QR control update guards also key on content/color and need a font
identity dependency for unchanged-content live relayout. Such consumer-specific
cache work requires its owner and native coverage. Full application-wide live
typography closure is not claimed from this bounded scan. Explicit direct-UIFont
baselines, multiline initializer closures, Mono/art/math and the parallel Nav/DCT
work are outside these direct edits.

### New real-consumer fixtures and BUILD needs

New source: `telegram-ios/Tests/Exteraless/FontFamilyConsumerTests.swift`.
Three **prepared, unexecuted** tests perform true → false → reset, including new
nodes in the same process:

1. `ListSectionHeaderNode.updateLayout` with unchanged title/action/theme, then
   `updateTheme` and a newly constructed header; observes both real TextNodes.
2. `ChatListArchiveInfoItemNode.asyncLayout` reused across the sequence and a new
   archive node; observes all six actual page title/body layouts and the real
   section header with 20/15/13pt roles.
3. The actual contact node's production text measurement/apply closure, retained
   across flips, plus a new contact node. The shipping identity snapshot overload
   supplies a combining-mark-filtered name and initials; the native payload's
   UTF-16 stays unchanged. The two real contact TextNodes and their existing frame
   offsets are inspected after apply.

Every case retains prior consumer `TextNodeLayout`/UIFont/CTLine objects and checks
their immutable attributed text and line metrics after subsequent layouts. No
Account, AccountContext, network, plugin or resource download is created. Loops,
strings and tree walks are bounded, there are no waits, and each case asserts a
30-second logic budget. The existing native test driver enforces
`logic_seconds=30`; the new manifest entry uses that same driver.

[`font-family-consumer-build.patch`](font-family-consumer-build.patch) is the new
Build-owner request: add `//Tests/Exteraless:FontFamilyConsumerTests` and its direct
module dependencies, include it in IntegrationTests and add its required source
to `native-tests.json`. It uses the **existing resource-bearing NativeTestHost**;
there are no new font assets or resource edges. Both testable imports target the
real ChatListUI/contact modules, not copied implementations.

After that join, use the repository's normal native test command with
`--target //Tests/Exteraless:FontFamilyConsumerTests`. Source/patch checks can be
run locally with:

```sh
git diff --check -- telegram-ios/submodules/ListSectionHeaderNode/Sources/ListSectionHeaderNode.swift telegram-ios/submodules/ChatListUI/Sources/Node/ChatListArchiveInfoItem.swift telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageContactBubbleContentNode/Sources/ChatMessageContactBubbleContentNode.swift
git apply --check docs/wave-2/font-family-consumer-build.patch docs/wave-2/font-family-global-cache-hunks.patch
python docs/wave-2/font-family-cache-scan.py
```

Executed locally with 30-second command limits: the direct-file whitespace
check and both new patch applicability checks passed. A source-only check also
confirmed removal of the six reported globals, the production contact-stage
delegate/apply calls, preserved IDSF name/initials plumbing, three actual-consumer
test declarations and all 330 scan-record source hashes. These checks execute
neither Swift nor UIKit.

Native execution and frame acceptance remain pending. In the eventual frame pass,
repeat the review's Archive/header/contact counterexample in one process, keeping
existing nodes alive and also creating new ones. After each completed new layout,
the labels must show the selected family; old retained layouts must remain usable.
Record/read labelled frames before claiming visual closure.

## Approved 294-getter application — 2026-11-15

The coordinator-authorized companion is now **applied: exactly 294 read-only
Font-getter substitutions in 167 Swift files**, with no source drift requiring
adaptation. This supersedes its pending status above. The original requests,
weights, sizes, traits and role exclusions are retained verbatim.

`font-family-global-cache-scan.json` now has an `application` section containing
`actual_count`, the approved patch SHA-256, the empty drift list and
`applied_hashes` for all 167 files. Its earlier `records` remain the pre-application
scan and request inventory. Each applied file was compared byte-for-byte against
its saved preimage with only those approved declaration substitutions; all other
bytes, including callback/class bodies and the 36 excluded declarations, match.
The narrow patch tool stripped a trailing blank-line byte in nine files; those
original bytes were restored before the exact postimage check and hash capture.

Source checks passed: exact 294/167 counts and request inventory, exact postimages,
`git diff --check`, and reverse applicability of the approved companion patch.
The accepted three main consumer fixes and their three prepared fixtures are a
separate preceding slice. Build-owner integration of
`//Tests/Exteraless:FontFamilyConsumerTests` remains coordinated through its existing
handoff; this bulk application changes no Root, SDK or BUILD source.

Scope remains process-global/static font captures. The instance-local cache and
native/recorded-frame limits documented above still apply; no all-live-instance
closure or UI pixel result is claimed. This approved slice ends here.
