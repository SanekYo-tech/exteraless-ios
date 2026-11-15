# App integration — privacy, Settings and launcher shortcuts

Status: source integration applied in the delegated common files. Native build,
UIKit frames and APNs delivery have **not** been verified in this Windows session.
The MainRoot forwarder/bindings below remain a coordinator integration requirement.

## Exact files changed by this implementer

- `telegram-ios/submodules/TelegramUI/Sources/AppDelegate.swift`
- `telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoSettingsItems.swift`
- `docs/wave-2/app-integration.md`

`telegram-ios/submodules/TelegramCore/Sources/Network/Network.swift` was inspected:
the requested proxy invalidation is already connected at the account-owned seam
described below. Its incoming coordinator diff (two privacy request guards,
will-submit and completion hooks) is retained; no additional Network edit was needed.

## Applied source integrations

### Notifications

- AppDelegate imports `ExteralessCore`; token receipt and registration failure feed
  `PrivacyNotificationDiagnostics`. Logs contain receipt/failure events and numeric
  registration error codes, never the token or notification payload. Removed the
  logging-only `redactedPayload` copy; Firebase receipt/nonce handling reads the
  original `userInfo` and retains its existing completion paths.
- `didReceiveRemoteNotification` uses
  `exteralessBackgroundNotificationCompletion`: once-only, 25-second fallback.
  Existing bounded wakeup/getDifference processing and 29-second wakeup extension
  remain the processing mechanism; the watchdog only finishes the OS callback.
- `willPresent` takes one account result, delegates to the lock-aware foreground
  options helper, and completes with `[]` for a missing/current account or suppressed
  locked preview. The helper's two-second watchdog covers stalled initialization.
- Registration delegates to `exteralessRegisterForNotifications`; authorized,
  provisional and ephemeral permissions register without re-prompting. Denied,
  unknown, not-determined-without-authorization and denied prompt paths finish false.
  The outer application binding now also finishes false when no authorized context
  is available.
- All **nine original category expressions** match HEAD exactly (order-independent
  comparison): `unknown`, `r`, `m`, `gr`, `gm`, `c`, `t`, `st`, `str`. Both search-message
  Intents, reply actions, hidden placeholders and CarPlay options are preserved.
- Both PushKit entry points and both inner forwarding logs omit payloads. The shared
  implementation wraps its completion in `PrivacyCompletion<Void>`; all original
  early returns and the synchronous final completion converge there. This path does
  not wait for account initialization before completing, so no delayed PushKit
  watchdog was introduced. CallKit reporting and notification forwarding stay live.
- Availability check: `Telegram/BUILD:169` sets the application floor to **iOS 15**;
  `.banner`/`.list` and `.ephemeral` require iOS 14, and category preview options
  require iOS 11. These insertions do not rely on an assumed iOS 13 floor.

### Native Settings

- Optional Ghost mode shortcut is advanced item **9**, directly after native
  exteraless item **8** and before Plugins item **7**. Advanced IDs checked:
  `0, 1, 2, 3, 6, 4, 8, 9, 7`, all distinct.
- The action calls the existing `exteralessToggleGhostMode(account:)` and presents a
  native save-error alert. Both result and error request a native layout refresh so
  the label rereads the actual policy even if the presence stream deduplicates it.
  `PresentationDataUtils` is explicitly imported; the
  inspected factory is `textAlertController(context: AccountContext, ...)` and the
  PeerInfo target already declares this dependency.
- Phone-confirmation title/Keep action use `••••` while own-phone hiding is enabled;
  the editing disclosure label becomes empty. Change Number still uses its native
  `.phoneNumber` route. The exteraless settings factory remains
  `ExteralessSettingsEntry.makeController(context: AccountContext)`; profile editing
  and normal settings navigation retain their routes.

### Launcher lifecycle

- `didFinishLaunchingWithOptions` consumes `.shortcutItem` and returns false for a
  manually handled item, preventing duplicate UIApplication delivery. A shortcut is
  the single startup navigation choice when both shortcut and URL data are present.
- Scene attach compares the consumed shortcut's type/userInfo and skips its duplicate.
  A launch URL repeated in scene URL contexts or a browsing activity is also skipped;
  the startup records are cleared at attach. Subsequent normal URL/shortcut entries
  remain separate user actions.
- Added the normal UIApplication `performActionFor` callback. Both it and the existing
  SceneDelegate callback call `handleShortcutItem`; unknown types complete false.
- A **private AppDelegate-local** `ExteralessToolsPendingShortcutCoordinator` owns one
  request, its completion and disposable. At inspection, no such Tools helper or
  launch-envelope API existed in the tree; `tools.md` and the actual Tools integration
  exposed `handleShortcut(type:completion:)`. The local adapter uses that actual seam
  through the MainRoot forwarder below rather than assuming an unpublished initializer.
- Readiness and the real app-lock signal are combined as `Signal<Bool, NoError>`.
  Only the existing stock account-switch action skips the lock. Other stock actions
  and Tools actions execute after readiness/unlock; stock actions now complete true.
- The request binds to the initialized `AuthorizedApplicationContext` object. An
  initially unauthorized context, account replacement/logout, a competing pending
  request or a 30-second initialization/unlock timeout finishes false. Starting an
  add-account authorization cancels/rejects pending Tools actions. Completion and
  disposal happen before reentrant work can submit another request.
- Main-thread context publication happens after the existing ClientRuntime and
  PluginRuntime update calls. Before forwarding Tools, AppDelegate checks
  `contextValue === context` and passes the actual `AccountContext` to MainRoot.
  An already admitted native operation owns its completion; its cancellation on
  account replacement is the MainRoot/Tools lifecycle requirement below.

### Proxy: already connected source

The live subscription is **not** in `Network.swift` in this revision:

```swift
// TelegramCore/Sources/Network/ExteralessProxyPolicy.swift:45–50
combineLatest(
    accountManager.sharedData(keys: [SharedDataKeys.proxySettings]),
    ExteralessProxyEnvironment.shared.changes(),
    exteralessPrivacySettingsChanges()
)
// map shared settings -> effectiveActiveServer, then distinctUntilChanged
```

- `changes()` is `Signal<PrivacyProxyPathState, NoError>` from an initially populated
  `ValuePromise`; NWPathMonitor updates the default mobile/Wi-Fi route state.
- `exteralessPrivacySettingsChanges()` is `Signal<Void, NoError>`; it observes
  `ClientSettings`, emits an initial value and cancels its observation on disposal.
- Both `Account.swift:236` (unauthorized) and `:1579` (authorized) retain a subscription
  and call `network.updateProxySettings`. This already refreshes the real effective
  connection on proxy preference, route and privacy-condition changes. No `.never()`
  input or mixed error generic is introduced.
- Network's existing privacy hooks were counted: exactly two request guards, two
  will-submit calls and two completion calls. No TL/RPC pipeline changes were made.

## Required MainRoot forwarder — exact coordinator hunk

File: `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift`.
The inspected root has `private var tools: ExteralessToolsIntegration?` and is
`@MainActor`. AppDelegate now calls the following **context-aware** signature;
the two-argument forwarder in the older `tools.md` is insufficient for the identity
check. Use the root's equivalent context field if the coordinator has introduced one.

```diff
@@ final class ExteralessClientRuntime {
     private var tools: ExteralessToolsIntegration?
+    private weak var toolsShortcutContext: AccountContext?
@@ func update(context: AccountContext) {
+        if self.toolsShortcutContext !== context {
+            self.clearContext()
+        }
+        self.toolsShortcutContext = context
         configure(rootPath: context.sharedContext.basePath)
@@ func clearContext() {
+        self.toolsShortcutContext = nil
         appearance?.clearContext()
@@
+    func handleToolsShortcut(type: String, context: AccountContext, completion: @escaping (Bool) -> Void) {
+        guard self.toolsShortcutContext === context, let tools = self.tools else {
+            completion(false)
+            return
+        }
+        if !tools.handleShortcut(type: type, completion: completion) {
+            completion(false)
+        }
+    }
```

Required binding semantics:

1. Configure the actual `ExteralessToolsShortcutBindings` before accepting Tools
   actions. The inspected root still constructed `ExteralessToolsIntegration()` with
   default nil bindings; its `handleShortcut` correctly reports failure while unbound.
   Preserve the coordinator's backup/maintenance bindings when calling
   `tools.configure(backupBindings:shortcutBindings:)`.
2. Ghost toggle must apply `PrivacyPolicy.current.ghostModeChanges(enabled:)` with
   the native atomic public settings API and report the resulting confirmed state,
   respecting locked fields. Safe mode must use real runtime admission/maintenance
   behavior and its confirmed state. No synthetic safe-mode setting is supplied here.
3. Clear Tools on **identity replacement as well as logout** before binding the next
   account. Its `clearContext()` cancels the native task, retires the generation and
   completes the held callback false. MainRoot callback delivery must stay on main,
   as the actual `ExteralessToolsIntegration.handleShortcut` implementation does.

## Checks performed

- `git diff --check` on the three inspected Swift files: passed.
- Bounded, read-only source checks: balanced delimiters after the existing Swift
  comment/string stripper; no Markdown headings in Swift; added-binding single-use
  heuristic; category/Intents equality; no token/payload log interpolation; callback,
  context and launcher callsites; Settings IDs/factories/phone guards; existing proxy
  subscriptions and privacy-hook counts. All passed. The binding heuristic is **not**
  a Swift compiler unused-variable check.
- `python -B build-system/Make/PostboxImportCheck.py` from `telegram-ios`: failed with
  two findings outside these files, both in
  `submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAINativeAdapter.swift`:
  line 6 imports Postbox; line 103 accesses `.postbox`. No finding named an owned file.
  The AI owner/coordinator must resolve those; allowlists were not changed.
- Toolchain probe found Python but no `swift`/`swiftc`; no Apple SDK/XcodeBuildMCP
  is available. Source inspection does not establish native typechecking, runtime
  behavior, visual correctness or APNs delivery. No commit, push, CI, account action
  or real-network test was performed.

## Native cases and expected frames (not yet executed)

| Case | Expected result / frames |
| --- | --- |
| Ghost shortcut setting off/on | Advanced row 9 absent/present after exteraless, with stable native cell geometry in light/dark, large type and RTL. |
| Ghost toggle and locked fields | On/Off reflects the resulting policy; locked fields keep their values. Save error presents one native alert. Record the list update with no duplicate row, clipping or stale label. |
| Own phone hidden/unhidden | Confirmation title and Keep action show `••••` when hidden, edit label is blank; Change Number and profile-edit navigation still work. Verify default hide=true and opt-out. |
| Cold launch, scene launch, UIApplication and scene runtime shortcuts | One action and one completion per user choice; the same launch item is not replayed, while a later intentional identical shortcut works. |
| Launch URL repeated by scene/browsing activity | One navigation, with ordinary later URL opens still working. A selected startup shortcut does not also open the startup URL. |
| Locked or slowly initialized app | No action before both gates open. Unlock/readiness before 30 seconds dispatches once; timeout disposes the wait and a later unlock does not replay it. |
| Pending shortcut then logout/account replacement/add-account | False completion, no action on the new account; repeat with identical record ID but a replacement context object. Test native in-flight cancellation after the MainRoot hunk/bindings. |
| Root context mismatch / nil Tools bindings / native toggle error | False completion, no fabricated success announcement or state. |
| Denied, not-determined, authorized, provisional and ephemeral permission | Completion on every branch, original category actions/Intents; only an authorized entry point asks for permission. |
| Foreground notification on current/other account, URL notification and app lock | Exactly one completion with the policy's expected options; no stale unredacted locked banner. Record actual device output. |
| Background initialization stall and PushKit early failure | Background once-only fallback; PushKit once-only synchronous completion through the retained paths. Real CallKit/APNs delivery is a separate device test. |
| Proxy 0/2/4/6 condition changes and mobile/Wi-Fi route transitions | Effective connection updates without restart; manually disabled proxy stays disabled, selected server/credentials remain durable. |

Before calling visual behavior verified, record the simulator/device paths and
evaluate timestamped frames per `telegram-ios/AGENTS.md`; no frame pass is claimed here.
