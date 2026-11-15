# Native primary chat swipe — etgbackup.ChatSwipeAction

2026-11-15. **Portable source implementation and integration cohort**, with one typed
native selector and real eligible reveal/pager consumers. Swift/native execution and
recorded frames are pending. No CI, commits, live accounts or network were used.

## Original semantics

`SharedConfig.java:791,1774–1790` stores `mainconfig.ChatSwipeAction`, default **-1**.
`SwipeGestureSettingsView.java:30–35,100–117` defines and selects the six explicit
actions; without filters its picker omits Folders. Native storage keeps all seven
source values so an explicit Folders choice survives temporary filter removal.

| Stored value | Meaning |
|---:|---|
| -1 | Automatic: Folders with filters, Archive otherwise |
| 0 | Pin / unpin |
| 1 | Read / unread |
| 2 | Archive / unarchive |
| 3 | Mute / unmute |
| 4 | Delete |
| 5 | Folders; resolves to Archive without filters |

The source operational handlers are `DialogsActivity.java:2247–2294,2519–2542`.
`EtgBackup.java:574–579` exports explicit 0…5; the unset -1 value is normally omitted.
The Cloud raw SharedPreferences converter also accepts explicit -1 as the native Auto
value, without changing the archive's other fields.

## Definition / Core policy

- `swift/ExteralessCore/Sources/ExteralessCore/CoreChatSwipePolicy.swift` declares
  `ChatSwipePolicy` and the exact raw values, eligible primary choice and gesture owner.
- `ChatSwipeFeatures.swift` registers **`chats.chatSwipeAction`**, integer -1 by default,
  with the seven validated options. It is a separate definition array for coordinator
  registration; the frozen CMC definitions/helpers were not refactored.
- Missing/disallowed peer actions select the existing native full-swipe fallback.
  The policy can only return a member of the supplied native eligible set. Unknown
  native keys (Hide PSA, Close topic, etc.) keep their original behavior.

## Native callsites and effects

Direct changes are confined to `ChatListUI/Sources/Node/ChatListItem.swift` reveal
policy sections. `ChatListItemNode.setRevealOptions` consumes the arrays **after**
native peer/forum/custom eligibility, inline-navigation, Dialog/Privacy and editing
gates. It promotes the selected existing option to the trailing full-swipe position.
The complete option is retained: current pin/read/mute variant, title, icon, colors
and destructive metadata. Moving between sides retains the union of all buttons.

`canBeginReveal` refreshes the policy from cached **native** options at the next
gesture, so changing the selector does not require restarting or reconstructing the
chat list. Filter availability is taken from the actual ancestor folder container.
The existing `revealOptionSelected` native handlers remain the sole effect paths:
pin, mute, grouping, read state and deletion use their current interaction callbacks.
There is no direct Postbox mutation or independent delete implementation.

### Gesture arbitration

- `ChatSwipePolicy.gestureOwner` is shared by row reveal and the actual folder pager.
- Folders/Auto with filter pages: center gestures belong to the existing pager;
  native edge gestures still reveal action buttons. No extra Folders action/button
  or custom horizontal pager is created.
- Explicit row actions: eligible row center gestures go to row reveal. Native
  header/empty-area paging and navigation/Story edge rules retain their own checks.
- An already-open reveal keeps its closing/control gesture. Horizontal scrollable
  descendants and explicit native horizontal-content guards take priority over both
  row and pager, including content outside a row.
- The edge calculation matches the existing native `widthMultiplier(1/6,22,80)`.
  The existing recognizer failure relationships and vertical-intent rules remain.

## Exact owner hunks

Apply this cohort together; the new override requires the base hook hunk.

1. **`chat-swipe-shared.patch`**:
   - Main `ExteralessClientSettingsWorker.definitions`: append `ChatSwipeFeatures.definitions`.
   - `ItemListEditableItem.swift`: make the existing `canBeginReveal` overridable;
     its native body/guards remain the default for every other list row.
   - `ChatListControllerNode.swift` / `ChatListContainerNode`: consult the shared
     arbitration in `allowedDirections` after the existing native root/navigation
     checks. No direct edit was made to Feed's busy ChatListController.
2. **`chat-swipe-cloud.patch`**, for the booked Cloud owner/coordinator:
   - Catalog only `mainconfig.ChatSwipeAction` → `etgbackup.ChatSwipeAction`.
   - Add the exact typed -1…5 identity conversion to `chats.chatSwipeAction`.
   - Admit only this one mainconfig key into the existing conversion path.
   - The existing registered/non-secret validation, Cloud admitted preview projection,
     CAS/public apply and credential boundaries remain the owners of persistence.
     No Tools/Backup implementation or broad mainconfig importer was added.
3. **`chat-swipe-build.patch`**, Build owner:
   - Production ChatListUI already directly declares ExteralessCore; the base hook
     adds no new ItemListUI dependency.
   - Add `//submodules/ChatListUI:ExteralessChatSwipeTests`, using the existing hosted
     runner/strings/assets, its IntegrationTests edge and native-tests.json mapping.
   - Exclude the new hosted fixture from the older unhosted ChatListUITests glob.
4. **`chat-swipe-receipt.patch`** removes only the previous Tools-owned placeholder
   record before merging **`chat-swipe-parity.json`**. Strict merge must see one record
   for this Original ID; the main inventory remains coordinator-owned.

## Bounded tests

**11 new XCTest methods, not executed here**:

- `ChatSwipePolicyTests`: all values/defaults, all 32 subsets of native action
  eligibility, folder/edge/open-reveal/content arbitration, native edge widths,
  real register/write/reopen and invalid type/value rejection.
- `ChatSwipeLegacyImportTests`: the actual Cloud admitted preview and public apply;
  only the exact mainconfig field enters it, wrong types/ranges and missing native
  registration are rejected, unrelated mainconfig fields remain excluded. These tests
  require `chat-swipe-cloud.patch`; do not take the tests without that owner hunk.
- `ChatSwipeNativeTests`: actual native reveal builders for pinned/muted/read states,
  Saved Messages/service/archive/forum and deletion restrictions; all buttons retained;
  final empty eligibility stays empty; real horizontal UIView/UIScrollView arbitration.
  These fixtures instantiate no Account and invoke no mutation handler.

After integration, bounded commands:

```text
swift test --package-path swift/ExteralessCore --jobs 1 --filter ChatSwipe
Make.py test ... --target //submodules/ChatListUI:ExteralessChatSwipeTests
```

Use the existing native runner, serial XCTest (`-parallel-testing-enabled NO`) and
the 30-second logic budget. Native compiler/frames are required separately from Core.

## Frames expected before visual acceptance

1. For each eligible explicit action, a slow left swipe exposes the native buttons;
   the chosen trailing option expands at the native threshold. Releasing executes
   that native handler once. Pin/read/mute variants match current state; Delete keeps
   native confirmation. A cancelled swipe executes nothing.
2. With filters, Auto/Folders center swipes move the list and folder header together,
   without a row sliding first or firing Archive. Edge swipes still reveal controls.
   Removing filters makes the next Auto/Folders row swipe use Archive/Unarchive.
3. In horizontal rich/table/carousel content, only that child scrolls: row and folder
   pager stay still, with no reveal highlight or action. Ordinary vertical scrolling
   and the native Story/navigation edge paths remain responsive.
4. Change the selector, return to an already visible list and swipe: the first new
   gesture uses the new choice. Open reveal controls remain tappable/closable.
5. Saved Messages, service peers, forums, archived rows and editing/privacy-disabled
   rows never expose a forbidden operation. Record narrow/wide layouts, RTL and
   light/dark; inspect clipping and coupled motion in labelled frames.

No visual status or source-receipt count is a substitute for those recordings.

## Source handoff checks / freeze

The Swipe cohort was resumed after the priority CMC-05 P2 media-schedule fix was
frozen in `chat-review-remediation.md`. The following Swipe checks are source-only:

- `git diff --check` for the direct `ChatListItem.swift` edits passed.
- UTF-8/NUL checks passed for the six source/test files. Eleven XCTest methods
  are authored; Swift/swiftc/xcrun are unavailable in this Windows session.
- All four owner packets dry-applied **in memory**, preserving surrounding sources:

  | Packet | Files | Hunks |
  |---|---:|---:|
  | `chat-swipe-shared.patch` | 3 | 4 |
  | `chat-swipe-cloud.patch` | 3 | 3 |
  | `chat-swipe-build.patch` | 3 | 4 |
  | `chat-swipe-receipt.patch` | 1 | 1 |

- Projected registration, overridable base admission, actual pager callback and
  typed Cloud admitted projection were checked together. The Tools-fragment
  replacement retains its exact Original-ID set/count, with exactly one new
  `etgbackup.ChatSwipeAction` record and valid JSON.
- Production `swift/ExteralessCore/BUILD.bazel` already globs both new Core files;
  ChatListUI already links that module. The native test packet supplies its hosted
  target and IntegrationTests/native-tests.json edges.

`chat-swipe-frozen.sha256` pins the current six-file source/test snapshot for owner
integration. **The shared/Cloud/BUILD/receipt packets still require owner application.**
In particular, ChatListItem's new override requires the base `canBeginReveal` hunk
before a native build; take the definition, registration, row and pager together.
These fingerprints and dry-apply checks do not establish compilation or frame quality.
