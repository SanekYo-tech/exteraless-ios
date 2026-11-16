# Native test graph typecheck — 43812503558 / 93dcb653

## Evidence and actual failure classification

Read the supplied local artifacts under `build/artifacts/client-ui-43812503558/`.
The analysis log successfully analyzed38 targets; the native compile attempted
all37 XCTest labels with keep-going and reported19 successful top-level targets.
`native-tests/result.json` remains failed, with `native_execution_verified: false`.
The preceding MainApp/Harness build report is a separate successful build/package
receipt. UIKit20 execution/frame acceptance is still pending.

Evidence SHA-256:

| File under the artifact directory | SHA-256 |
| --- | --- |
| `native-tests/compile/console.log` | `1f2acdd3a353164aa4f540366bb9b754f6aac358baa7c7d7dd5f169a816d2a49` |
| `native-tests/analysis.log` | `fffe545c31ad4e2116553a996db9c8dfb6d1e370bc0cda5d15c001357e874de8` |
| `native-tests/result.json` | `62b65f6527f75d1d677ca7ed7259f6a556887ec61bb3935027f9c5ebc7ebf0af` |

### Bundle/link failures: actual ENOSPC

| Target | Exact compile-log evidence |
| --- | --- |
| `//submodules/ChatListUI:ExteralessChatSwipeTests` | Lines1663–1693: bundletool reaches `out_zip.writestr`, then `OSError: [Errno 28] No space left on device`. |
| `//Tests/Exteraless:RuntimeRecoveryContinuationTests` | Line2113: `ld: write() failed, errno=28 (No space left on device)` for its test-bundle binary. |
| `//submodules/TelegramUI:ExteralessPlayerNativeTests` | Line2131: the same `ld: write() failed, errno=28` for its test-bundle binary. |
| `//submodules/TelegramUI:ExteralessTLModelTests` | Line2181: the same `ld: write() failed, errno=28` for its test-bundle binary. |
| `//submodules/TelegramUI:ExteralessAppearanceRootTests` | Line2197: the same `ld: write() failed, errno=28` for its test-bundle binary. |

The earlier disk-cache upload also fails with ENOSPC at1641–1659, inside
`DiskCacheClient.saveFile`. There are no undefined-symbol, missing-library or
`BundleConflictError` diagnostics for these failures. The XCTest deployment
warnings (15.0 target versus17.0 XCTest dylibs) precede the write error and are not
the failing linker diagnostic.

The pinned bundletool's conflicting-destination path raises `BundleConflictError`
before writing an entry (`tools/bundletool/bundletool.py:236–241`). This traceback
instead reaches ZIP output at265 and fails on disk capacity. No speculative
link libraries, test-host migration or resource relocation is justified by that
stderr. Coordinator must restore sufficient space on the Bazel output/cache
volume before retrying the complete37-target compile; no cleanup was run here.

## Applied BUILD correction: Manager font extension dependency

The real compiler errors at1499 and1507 are:

```text
PluginUIViews.swift:8:39: error: value of type 'PresentationFontSize' has no member 'itemListBaseFontSize'
PluginUIResources.swift:19:71: error: value of type 'PresentationFontSize' has no member 'itemListBaseFontSize'
```

The public extension is owned by **ItemListUI**, in
`telegram-ios/submodules/ItemListUI/Sources/ItemListItem.swift:171–213`; the property
starts at176. Source SHA:
`c3b38ab1814e5a39ad10d8c0cc8debad9fa1fa4c22b9c13835f17cefbd912914`.
Display/PresentationDataUtils do not own this extension.

**Applied:** `Tests/ManagerCustomAlias/BUILD`, `ManagerCustomAliasTestsLib.deps`
now includes `//submodules/ItemListUI:ItemListUI`. The production TelegramUI target
already declares that dependency. The actual source filegroup still compiles both
shipping font consumers and all original Manager tests.

**Coordinator import hunk, not applied to shared Swift:**
[`native-test-font-imports-coordinator.patch`](native-test-font-imports-coordinator.patch).
It adds exactly `import ItemListUI` after Foundation in:

- `Sources/ExteralessClient/PluginUI/PluginUIViews.swift`;
- `Sources/ExteralessClient/PluginUI/PluginUIResources.swift`.

`git apply --check` passed. Both production files retain their preimage bytes.
The patch exposes the real public extension; it introduces no copied font math,
replacement API, UIKit layout or dummy implementation.

## Resource/test-host graph audit

- Affected hosted tests use `//Tests/Exteraless:NativeTestHost`; the existing two
  Composer targets keep `//Tests/ComposerHarness:ComposerHarness`.
- NativeTestHost is the genuine minimal UIKit application with its own
  `EXLNativeTestsAppDelegate`/scene, with Fonts, strings, assets and required notices
  supplied at the host's Bundle.main resource locations. The Monet notices enter
  through `TelegramUIResources`; both Roboto TTFs and OFL remain explicit.
- The pinned rules_apple uses the built test host as `bundle_loader` by default
  (`rule_attrs.bzl:335–340`, `apple_test_bundle_support.bzl:199–208`). It adds that
  loader to `targets_to_avoid` and forwards it to resource processing at379.
  Host resources are therefore part of the existing de-duplication graph.
- `source_resources()` verified all **six** pinned Font/Monet input files. The
  resource validator still requires exact process-bundle-root placement and rejects
  missing, modified, nested or duplicate font/resource placement. No asset, required
  font, resource validator or host was removed to make bundling appear successful.
- XCTest/XCTestSwiftSupport are supplied by the real Apple test rule, and the four
  linker-failed targets retain their existing MediaPlayer link option. Native host
  archive/resource validation still has to complete after a successful compile.

## Testability and Swift mode

No global Swift5 switch or testability override was added. In the pinned
rules_swift, `swift.enable_testing` is the actual feature name; `features.bzl:236–240`
enables it for dbg/fastbuild, and `compile_config.bzl:428–434` emits **`-enable-testing`**.
The provided compile log has no “not compiled for testing” error. A hypothetical
`bulk.enable_testing` setting is not an established compiler flag or a remedy for
these observed failures. Actor/concurrency test-body changes remain with their owners.

## Verification and handoff

**7 existing tests passed** in0.595s: native planner/budgets/platform contracts and
resource placement/hash rejection checks. BUILD syntax and dry-apply checks passed.
The before/after selected method map is identical: **37 labels /92 classes /
434 methods**, with the same two real host selections and unchanged process limits.

Receipts, complete before/after plans, shared-source hunk pins and exact delivery
paths live under `build/wave-2-dependencies/native-test-graph-93dcb653/`.
This packet needs the two coordinator imports and runner capacity recovery before
the next full native compile. No Apple build, native test execution, CI query,
commit/push, account/plugin/network work or cache deletion was performed here.
The reported independent Mac33 pass is not relabelled as this native37/UI20 pass.
