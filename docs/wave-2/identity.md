# Identity / local Premium — 22 original IDs

**Application slice: 36 permitted shared files / 127 identity anchors are now
applied through `functions.patch`.** The 6 reserved files / 27 anchors are in
[`identity-shared-remaining.patch`](identity-shared-remaining.patch). Source
integration is partial; Swift execution and visual acceptance are not claimed. Receipt:
[`identity-parity.json`](identity-parity.json), exactly the 11 + 11 IDs from
`docs/parity/remaining-ownership.json` / `.md`.

## Application result and coordinator handoff

[`identity-application.json`](identity-application.json) records the exact applied
and remaining paths, native adapter adjustments and frozen input hashes.
**This session did not write the 7 Foundation Core Identity sources or their 3
XCTest files.** Final freeze checking found one concurrent external change:
`IdentityDatePolicy.swift` removes the erroneous Gregorian AD-era assumption
from Persian conversion (`7d3050c2…` → `30754a8a…`). Both hashes and the precise
change are retained in the manifest; **the Core CI input is therefore changed**.
The other 9 frozen files still match. The user-reported coordinator push
`2a03061` / progress into NetworkResolver compilation is not native-view build
evidence and predates this recorded working-tree era correction.

The applied source includes real title/alias consumers, profile ID/DC/copy rows,
native about expansion, common-groups default selection, reply/link/contact
styles, native effects/reaction presentation, all forward-date media inputs,
Persian date/clock/header formatting, and their available invalidation seams.
`IdentityArchive.encode`, the share controller, Android/native import and native
mutation/permit functions have actual editor callsites. Application-root account
lease/action setup remains reserved, as shown below.

Two native adapter corrections were made during application:

- `ExteralessPeerIdentityPresentation.localAlias/localNameOrder` preserves native
  first/last-name font composition in `ContactsPeerItem`. A default name is not
  flattened into an all-bold alias row.
- `exteralessIdentityContactName` receives the original contact-message payload
  first/last names; it only applies an actual local alias/order override. A cached
  server peer cannot replace an unchanged contact card's supplied name.

These Identity-application changes are in TelegramCore/native consumer code,
**not the Core policy/test package**. The existing EnginePeer name/premium properties and actual
auth/send capability paths retain their native APIs.

### Reserved remainder

The materialized patch contains only `ExteralessClientRuntime.swift`,
`ChatListController.swift`, `ChatController.swift`, `ChatListItem.swift`,
`AvatarNode.swift` and `PeerAvatar.swift`. Each unified hunk has a unique preimage;
AvatarNode context includes its account-bearing overload to disambiguate it.
The root definition anchor composes with the current Network/Maps/Dialogs domains.

Exact root API for the app integrator:

```swift
private var identity: ExteralessIdentityIntegration?
// After ClientSettings storage selection, with the existing definition families:
// + IdentityFeatures.definitions
if identity == nil { identity = ExteralessIdentityIntegration() }
identity?.update(context: context)
// In clearAccountDomains(), reached by clearContext/account switching:
identity?.clearContext()
```

`identity.showOnlineStatus` still needs its reserved ChatListItem caller;
`identity.premiumItemCustomWallpaper` still needs its reserved ChatController
projection. List alias/status and avatar-initial consumers plus list/chat
invalidation remain in that same patch. Their presence in a prepared diff is not
recorded as an applied callsite or verified feature.

### Appearance handback / AP10

After the user's latest ownership update, `PresenceStrings.swift` and
`PeerInfoAvatarTransformContainerNode.swift` are read-only for this Identity
slice. Appearance remediation retains their already-applied identity changes.
ChatListItem video/mask geometry, AvatarNode and AvatarStoryIndicator also remain
with Appearance/Dialogs; Identity has made no new writes in those scopes.

AP10 composition: `TextFormat.stringForMessageTimestamp` continues to choose
seconds through `AppearanceTimePolicy.seconds`; Persian digit conversion wraps
the formatted clock result. `PresenceStrings` keeps Appearance's relative-last-seen
branch before the exact-date Persian fallback. Calendar conversion does not
substitute or reinterpret source timestamps. Subsequent AP10 fixes must compose
with those calls; they are not an alternative formatter implementation to discard.

[`identity-hunks.py`](identity-hunks.py) remains a **read-only, bounded, exact-anchor
diff/check producer**. It now detects already-applied insertions, emits only the
pending differences, and supports the permitted/reserved split. Conflicting
preimages still fail rather than overwrite another owner. The producer never
writes the repository.

```text
python docs/wave-2/identity-hunks.py --scope allowed --check
python docs/wave-2/identity-hunks.py --scope remaining
git apply --check --whitespace=error docs/wave-2/identity-shared-remaining.patch
python -m unittest discover -s docs/wave-2/tests -p test_identity_contract.py
```

The remaining root insertion makes `ExteralessClientRuntime`
register **`IdentityFeatures.definitions`**, retain
**`ExteralessIdentityIntegration()`**, call **`update(context:)`** and
**`clearContext()`**. Register all 15 global definitions together with their
insertions; the 2 account-only definitions are used by the encrypted account
editor and must not be registered in shared `ClientSettings`.

The shared changes are restricted to presentation/formatting and explicit
composition. They compose with Appearance's title/status/wallpaper/marker geometry
and Chat's reply colors/pattern preferences. No common `EnginePeer` premium or
name property is replaced. Existing `LocalizedPeerData/PeerTitle.swift` gains
explicit **account-bearing** display methods; known native consumers call those.

## Owned implementation

- `swift/ExteralessCore/Sources/ExteralessCore/Identity*.swift`: definitions,
  account/peer keys, names, presence bands, display policy, Foundation Persian
  conversion/formatting, bounded archive, field-CAS mutations, edit permits and
  thread-safe immutable publication cache.
- `telegram-ios/submodules/TelegramCore/Sources/ExteralessIdentity/`: thin native
  Postbox read/write functions, native-peer projectors, metadata source selection,
  account leases and expiration publication. No UIKit or Display dependency.
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Identity/`: lifecycle,
  account settings, native peer selection, alias/status/color editors, import,
  export and reset. No Postbox access/import in these UI files.

### Persistence and lifecycle

One durable **account-encrypted Postbox preference**:
`exteraless.identity.state.v1`. Durable aliases should not live in an evictable
item-cache collection. The existing central
`Namespaces.CachedItemCollection.exteralessLocalState == 63` is neither redeclared
nor cleared. Reset removes **only the owned preference row**, including recovery
from a malformed record.

Records contain only explicit local choices, owner user ID and environment — no
copy of global contacts or original server names. Limits: **2,048 aliases**, **128
graphemes / 512 UTF-8 bytes per alias**, **1 MiB encoded record**, **64 simultaneously
published account snapshots**, **3 selected native emoji descriptors per write**.
Peer IDs are checked against native 56-bit range before constructing `PeerId`.
Document IDs remain lossless signed Int64; color IDs use native Int32 range.

Cache keys include record ID, user ID and test/production environment. A lease
token rejects callbacks from a retired context; sequence checks reject reordered
publications and equal snapshots are deduplicated. Layout queues read immutable
snapshots under a lock. Alias fallback reads the current native peer every time,
so reset cannot restore an obsolete saved server name. All active account
contexts have independent leases.

Editors use field-level CAS and an account-pinned permit checked inside the
queued transaction. Account switching invalidates those permits. Local expiry
uses a one-shot native timer plus foreground/significant-time-change invalidation.
`identityRevision` travels through native presentation values, which rebuild
list/chat/contact/profile consumers even if the theme/strings objects are equal.

## Original-to-native map

Android roots: `third_party/exteraless-android/TMessagesProj/src/main/java` **and**
`src/main/kotlin`. `AGENTS.md` and `CLAUDE.md` were read. Full individual source
anchors, defaults, owned callsites and exact hunk IDs are in the JSON receipt.

| Original ID | Default | Native behavior / exact shared seam |
|---|---|---|
| `localnamehelper.chatNameOverride` | null | Native selector + alias editor; list/header/profile/forward/contacts and avatar initials; per-account chat-kind key |
| `localnamehelper.userNameOverride` | null | Same native editor and scoped projector; message/reply/forward authors, contact cards, initials; regular-user aliases apply in secret chats |
| `neko.nameOrder` | 1 | Account editor: 0 last-first, 1 first-last; explicit-account name formatters and initials; reset 1 |
| `nagram.dateOfForwardedMsg` | false | Forward header gets `forwardInfo.date` in bubble, animated/static sticker and both round-video paths; story headers excluded |
| `nagram.idDcType` | 1 | Native profile copyable ID/DC rows: hidden, Telegram API, Bot API. Actual account/statistics/avatar DC source labelled |
| `neko.showIdAndDc` | true | Source migration to `idDcType`; one replacement selector. Pure import helper supplies original absent-target/false-legacy precedence |
| `nagram.preferCommonGroupsTab` | true | Existing groups-in-common pane replaces gifts default only; explicit pane choice wins |
| `nagram.showFullAbout` | true | Native multiline description gets `expandedByDefault`; off restores native collapse/manual expansion, complete text/entities retained |
| `nagram.showOnlineStatus` | false | Existing native marker interior gets original green/yellow/orange/red recent-activity bands; account/bot/privacy checks and native timer semantics |
| `neko.usePersianCalendar` | false | Native chat/list/forward/last-seen/entity/absolute date pipeline plus live chat header; real time zones and civil-day/year boundaries |
| `neko.displayPersianCalendarByLatin` | false | Both original Latin month names and Latin digits; otherwise Persian names/digits, only while calendar is enabled |
| `nagram.premiumItemEmojiStatus` | true | Native message-author emoji **and fallback Premium star**, matching `ChatMessageCell.getAuthorStatus` |
| `nagram.premiumItemCustomColorInReplies` | true | Native reply/link/contact color/stripe projection; off uses standard native theme |
| `nagram.premiumItemEmojiInReplies` | true | Native reply/link/contact patterns and collectible decoration, combined with Chat's `replyEmoji` |
| `nagram.premiumItemCustomWallpaper` | true | Cached per-chat wallpaper projection after Appearance custom-theme policy |
| `nagram.premiumItemVideoAvatar` | true | Native list/nav/profile video eligibility + live video layer; emoji/vector markup remains its distinct native path |
| `nagram.premiumItemStarInReactions` | true | Copied date/footer/menu/pager reaction presentation arrays and add-star affordance |
| `nagram.premiumItemStickerEffects` | true | Native Premium sticker/additional emoji/message effects; tap synchronization and queued-interaction cancellation |
| `nagram.premiumItemBoosts` | true | Native boost badge/count **measure and apply**, not synthetic boosts |
| `nagram.useLocalEmojiStatusData` | empty | Native callback picker + lossless documentId/until, explicit Kotlin JSON import, encrypted account export/reset/expiry |
| `nagram.useLocalQuoteColorData` | empty | All four Kotlin fields, native palette/pattern picker, original-value initialization, import/export/CAS/reset |
| `neko.localPremium` | false | Account-local badge/status/reply/profile presentation and unlocked local-only picker; actual native subscription capability remains separate |

### Source decisions that matter

- `LocalNameHelper.java` / `MessagesController.java:6939–6952,7089–7100`
  overwrite shared Android user/chat objects. The native variant instead projects
  only presentation fields, with no rename RPC, `updatePeers` or saved contact dump.
- `ContactsController.java:3062–3119`: first-last is exactly value **1**, last-first
  **0**. Native Unicode handling preserves ZWJ emoji, Persian ZWNJ and grapheme
  initials while enforcing explicit string/record bounds.
- `NaConfig.kt:1612–1616`: `ShowIdAndDc` is a migrated legacy boolean. There is no
  second global UI control and no claim of automatic Android preference discovery.
- `UserConfig.java:588–601` already distinguishes actual Premium from
  `isPremiumOrLocal`. `UserObject.java:176–205,219–257` prefers active server fields,
  then local fallback. Native projectors follow that precedence; specifically,
  they inspect **`TelegramUser.nameColor`**, not `PeerUtils.nameColor`'s generated
  `id % 7`, which would make local fallback unreachable.
- `LocalPremiumStatusHelper.kt` and `LocalPeerColorHelper.kt` migrate an old
  global JSON string into per-user keys. Native import is an **explicit one-account
  action**, not fan-out into all accounts. Blank records and 0/-1 sentinels are
  normalized; selected documents use the account's ordinary media cache.
- Local editors use `EmojiStatusSelectionController.customStatusSelection` /
  `.backgroundSelection` callbacks. Only that local picker receives
  `forceHasPremium: true`. Server-name, status and color RPC wrappers are not used
  by these editors. A server status/color can therefore remain visible while a
  local fallback is stored.
- Boosts, Stars, subscriptions, server quotas and outgoing custom-emoji entitlement
  remain real native capabilities. Android's separate `LinkedCustomEmoji.java`
  wire adaptation and broad folder/quota gate alterations are **not reported as
  delivered by this presentation slice**. This is a precise `neko.localPremium`
  remainder, not a claim that its cosmetics cannot be implemented.
- `PersianDate.java`'s 33-year approximation and post-2029 adjustment are replaced
  with native Foundation Persian conversion. Date construction round-trips its
  components to reject normalization and DST gaps. Incomplete month/day-only
  values are not guessed into a year. Gregorian-grouped media months keep their
  actual endpoints, presented as a Persian range. ID/payload/birthday storage and
  scheduled instants are not reinterpreted.

## Verification and acceptance

- **Application final source gate: 12 contracts passed in 0.544 s.** Permitted
  pending diff is **0 bytes**; all **127 permitted anchors** are applied.
  `identity-shared-remaining.patch` passes **`git apply --check --whitespace=error`**
  and each old hunk body is uniquely anchored in its reserved file. **43 native /
  consumer files** scanned: no replacement-character or conflict markers;
  `git diff --check` passes for the applied consumer paths.
- The Core hash gate explicitly accounts for the concurrent external Persian-era
  correction; it does not silently repin it as unchanged. The 9 other Core/test
  inputs match their entry hashes. Native/XCTest/frame execution is still pending.
- Previous preparation-only result: **8 offline contracts passed in 0.529 s**; generated diff
  passes **`git apply --check --whitespace=error`**. **42 shared files / 152 exact
  anchors / 202 replacements and additions**. **18 owned Swift files** checked
  for whitespace/conflict markers, no issues. **21 XCTest methods authored**
  (18 Core + 3 native), execution status below.
- The composition anchor was refreshed against the coordinator's concurrent
  Feed/Player/Pills/PrivacyExtras/Dialogs/Network/Maps integration. Identity's
  remaining root lifecycle hook uses the current `clearAccountDomains()` path.
- Offline source contracts validate the exact 22 IDs/defaults against the original
  inventory, real Java/Kotlin effect anchors, all prepared insertion anchors,
  local-only persistence, callback picker/network separation, date payload
  boundaries, media variants and marker/video semantics.
- The reserved remainder is checked with `git apply --check` (no working
  tree writes). Commands use a **30-second outer bound**, nested git check 20 s.
- Application source checks require an empty permitted diff, uniquely anchored
  reserved hunks, exact Core hashes including the explicitly recorded external era fix, declared helper callees,
  actual editor export/write paths, preserved contact payload/fonts, and truthful
  per-ID applied versus remaining receipts. They are not an iOS typecheck.
- Core XCTest: aliases/fallbacks/Unicode/quota, record precision/account isolation,
  field-CAS/dedup/reset, publication order/lifetime/concurrent readers, actual
  Premium versus local render availability, metadata bands/ID migration, Persian
  leap/Nowruz/2029/2030/inverse conversion/DST/timezone/format/range fixtures.
- Native XCTest: pure `TelegramUser` / `EnginePeer` projections assert server
  names/flags/status/color are intact, local self-only behavior, active-server
  precedence and independent message/reply presentation gates. **No actual
  Account, Postbox or network is constructed.**
- **Swift/XCTest execution and iOS build not run:** this Windows host has no Swift
  toolchain, no installed WSL, no XcodeBuildMCP/device. Calendar goldens were
  independently checked with local .NET; that is not Swift execution evidence.
- **No frame/visual pass.** Before recording, expected frames: alias edit/reset
  changes title/initials together in list, chat, profile, contacts and forwarded /
  replied messages; full descriptions expand with intact links and collapse back;
  four presence bands keep the row outline and do not overlap the timer badge;
  reply patterns/colors and profile cover restore cleanly; hiding status/boost/
  paid reaction rows removes reserved width; disabling video reveals static photo
  while vector markup remains visible; calendar/language/timezone toggles update
  dates without changing the message or navigation target. Record light/dark,
  two accounts, stale/expired status, long Unicode alias, narrow profile and each
  forward media variant with indexed/timestamped frames per `AGENTS.md`.

## Build-owner notes

Owned source files are picked up by existing recursive ExteralessCore,
TelegramCore and TelegramUI globs. Existing TelegramUI dependencies include
`ExteralessCore`, `LocalizedPeerData`, `EntityKeyboard` and
`EmojiStatusSelectionComponent`. `ChatMessageForwardInfoNode` already declares
`TelegramStringFormatting`; its new import is explicit. The new presentation and
date helper files in the shared diff use those modules' existing dependencies.
Include `Tests/Exteraless/IdentityPresentationTests.swift` in the native fixture
target alongside `TelegramCore` and `ExteralessCore`. BUILD/MODULE/workflows remain
with the build owner. No CI/commit/push or actual account test effects were run.
