# iOS appearance UI typecheck — 43761767575 / f05473ea

2026-11-16. **Source-only remediation; native iOS compilation and runtime validation are pending.**
The supplied full-build log reached the main TelegramUI target. Owned diagnostics occur in
`C:\Users\sasha\AppData\Local\Temp\opencode\ipa-f05473ea-failed.log:6663–6799`.

## Diagnostic mapping

Swift filenames below are relative to
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/`.
Diagnostic coordinates refer to the failed build; correction coordinates refer to the checked working tree.

| Failed-build location | Root cause | Source correction |
| --- | --- | --- |
| `ExteralessAppearanceIntegration.swift:6:1`; capture at `181:19` | SwiftSignalKit's mutex-backed `Atomic<UInt64>` lacks a Sendable declaration at the existing settings-queue handoff. | `:6`: `@preconcurrency import SwiftSignalKit`. |
| `ExteralessMainMenu.swift:311:118` | `NavigationController` is a `UINavigationController`, not Display's `ViewController`, which the search helper requires. | `:311–318`: inside the dismissal completion and `MainActor.assumeIsolated`, recheck account availability/root identity, then unwrap `root.topViewController as? ViewController` and pass that parent. |
| `ExteralessMainMenuRegistry.swift:135:5`, `138:100` | Missing `DeviceAccess` import also removes the completion's contextual `Bool` type. | `:3`: import the actual module. The native authorization call at `:136–140` supplies the closure type. |
| `ExteralessMainMenuRegistry.swift:146:67` | `Common_Copy` is absent from the generated PresentationStrings interface. | `:147`: use the generated `Conversation_ContextMenuCopy` accessor. |
| `ExteralessMonetThemeActions.swift:1:1`; capture at `84:17` | Legacy `AccountContext` is captured for the existing resource-store/account-manager handoff. | `:1`: `@preconcurrency import AccountContext`; queue/immutability evidence below. |
| `ExteralessMonetThemeActions.swift:5:1`; captures at `78:21`, `95:17` | Legacy `Subscriber` and `MetaDisposable` lack Sendable declarations. | `:5`: `@preconcurrency import SwiftSignalKit`; both use existing mutex-protected lifecycle state. |
| `ExteralessMonetThemeActions.swift:8:1`; capture at `98:106` | Captured `PresentationThemeReference` snapshot lacks a Sendable declaration. | `:8`: `@preconcurrency import TelegramUIPreferences`; the snapshot is compared inside the native transaction. |

## Native declarations and generated public header

- `telegram-ios/submodules/Display/Source/Navigation/NavigationController.swift:155,265–267`
  declares the navigation superclass and `topViewController: UIViewController?`.
  `Display/Source/ViewController.swift:86` declares the required native controller class.
  The callback resolves the top controller **after dismissal**, preserving the existing
  entry guard (`ExteralessMainMenu.swift:307`) and dismissal ownership guard (`:246–247`)
  and rechecking ownership at dispatch (`:313–315`). An absent/incompatible top ends the callback.
- `telegram-ios/submodules/DeviceAccess/Sources/DeviceAccess.swift:15–18,42–43,70,313–323`
  exports `DeviceAccess`, `.camera(.qrCode)`, presentation `(ViewController, Any?)`, and
  completion `(Bool) -> Void`. The camera request returns through the main queue at
  `:329–349`; existing authorization paths complete synchronously on the main-actor caller.
  **Dependency status:** `//submodules/DeviceAccess:DeviceAccess` is already a direct dependency
  at `telegram-ios/submodules/TelegramUI/BUILD:217`.
- Ran the real `telegram-ios/build-system/GenerateStrings/GenerateStrings.py` parser/generator
  against `telegram-ios/Telegram/Telegram-iOS/en.lproj/Localizable.strings`, the same inputs
  declared in `telegram-ios/Telegram/BUILD:145–161`. The public header is exported by
  `//Telegram:PresentationStrings` at `Telegram/BUILD:202–214`.
  Generated evidence: `C:\Users\sasha\AppData\Local\Temp\opencode\ios-appearance-ui-f05473ea-ktzhpu62\PresentationStrings.h:3450`:

  ```objc
  NSString * _Nonnull _Lamq(_PresentationStrings * _Nonnull _self) __attribute__((__swift_name__("getter:_PresentationStrings.Conversation_ContextMenuCopy(self:)")));
  ```

  Its source key is `"Conversation.ContextMenuCopy" = "Copy";` at `Localizable.strings:547`.
  The generated header contains neither `Common_Copy` nor `Message_Copy`.

## Existing concurrency boundaries reviewed

- **Calls preference mirror:** `ExteralessAppearanceIntegration.swift:15–24,172–191` confines
  integration state to the main actor and hands a mutex-backed generation plus settings snapshots to
  the serial settings queue. `SSignalKit/SwiftSignalKit/Source/Atomic.swift:22–46` locks reads
  and modifications. `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift:381–388`
  locks cached reads and writers. UI callbacks use the main-actor task/main-queue delivery
  at integration `:72–74,88–117`.
- **Monet resources and preferences:** `ExteralessMonetThemeActions.swift:42–71` keeps ownership
  on the main actor and schedules resource work on its existing serial queue. The accessed
  native context members are stable references (`TelegramUI/Sources/AccountContext.swift:119–125`,
  `SharedAccountContext.swift:168,262–265`); presentation reads use `Atomic.with`.
  Resource facades forward to native atomic writes (`Postbox/Sources/MediaBox.swift:318–327`)
  and completed-path checks (`:510–527`); cleanup touches cross a `QueueLocalObject`
  (`Postbox/Sources/TimeBasedCleanup.swift:619–633`). Native preferences execute through
  `TelegramCore/Sources/AccountManager/AccountManagerImpl.swift:716–755`'s queue-local implementation.
- **Cancellation and delivery:** the existing Monet token protects validity with `NSLock`
  (`ExteralessMonetThemeActions.swift:10–24`). SwiftSignalKit's subscriber and disposable
  protect termination/disposal with mutexes (`Subscriber.swift:152–163,203–249`,
  `Disposable.swift:83–149`, both under `SSignalKit/SwiftSignalKit/Source/`). The UI consumes
  results through `deliverOnMainQueue` (`ExteralessMonetSettingsController.swift:142–147`).
- **Theme snapshot:** `TelegramUIPreferences/Sources/PresentationThemeSettings.swift:60–104,139–142`
  defines the value reference and read-only payload fields. `expected` participates only in
  the transaction's slot comparison (`TelegramPresentationData/Sources/ExteralessMonetTheme.swift:248–255`).
  The byte-scope proof below covers the typed Telemone/Classic style selection, live settings
  projections, resource verification, cancellation checks, transaction updates and Result error paths.

Native module paths in this section are under `telegram-ios/submodules/` unless otherwise specified.
The four annotations address these existing handoffs; the patch introduces no Sendable conformance,
unsafe wrapper, global warning switch or off-main UI access.

## Raw SHA-256 checkpoint

Hashes describe raw working-tree bytes. The MainMenu **before** snapshot already includes
SearchR4's optional settings-factory binding in `case 110` (now `:381–382`). Reversing only
this task's hunks in memory reproduced every before hash exactly.

| Appearance source | Before | After |
| --- | --- | --- |
| `ExteralessAppearanceIntegration.swift` | `b2ce4c1a27807fd070e3910146d36b8c0b416a669f6813c81d62d91c274f59db` | `5fd9dd5afb15c268ba805294e32dfa8f67982e7b945128e46c6e5c7c8043558f` |
| `ExteralessMainMenu.swift` | `14b415c48b46254a5c46e864c82683b2cb5cbaf2f7fb0b5238b408f1571ddedb` | `472ba0c8977d899a710d559dda42f21c4d07db345db52a31eb02026d732d56a7` |
| `ExteralessMainMenuRegistry.swift` | `1ffbc696dbecb46c7af093a826911304cdd7a22d3f56df6e4eb5c1503c208c84` | `85186648e63505af7de8c5945dd1072f264cb06c01e38ec9af3141cf5e951a78` |
| `ExteralessMonetThemeActions.swift` | `b192d1f82cea62edcb440081b837d92fc2e2828aa932202ce3dfc64021828520` | `1cd1cd037d825b77d64c9c72bfff56c59e8dc7d94f234cc036c3b4cfebd6a6e5` |

| Evidence file | SHA-256 |
| --- | --- |
| Failed build log at the absolute path above | `44bbe728503d02f3103b75119344ad0ad4a710722195c63e88e752c6532ee749` |
| `telegram-ios/Telegram/Telegram-iOS/en.lproj/Localizable.strings` | `9d444bd06b7bca48b166fa17d63ea1e743aef2280a8c7ac8377ee0f7640208f2` |
| `telegram-ios/build-system/GenerateStrings/GenerateStrings.py` | `79260ec2374cfbfcf8784f87fe688868369adb5f325dc4a083d9aea278834a48` |
| Generated public header at the absolute path above | `cf434507f3541707a4ee4d7e7ebc18423aad767445567ae0f0796263c1dc63d9` |

## Verification and native handoff

- **PASS:** actual strings generation and accessor inspection (0.868 s).
- **PASS:** four exact pre-edit reconstruction checks (0.001 s), including the SearchR4 working-tree edit.
- **PASS:** scoped `git diff --check`.
- **PASS:** `python -B build-system/Make/PostboxImportCheck.py` from `telegram-ios/`.
- Every source-check command used a 30-second timeout.
- **Native pending:** coordinator-owned full iOS app compilation and native drawer-search,
  QR authorization/copy, and Monet selection/cancellation validation. This Windows source
  pass provides no Apple Swift compiler or runtime result for the patch.
