# Applied Runtime HNS stitch — source receipt

This records the exact original patch application. Later coordinator SDK05 and
HNS read/batch changes are current dependencies; their hashes are recorded in
`sdk-final-source-inventory.json`, not overwritten with this historical hash.

`plugin-ui-runtime-remediation.patch` is **applied** to
`telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift`.

| Input/output | Raw SHA-256 |
|---|---|
| UI author's Runtime input | `0f70d82e30d864df0698b5062277806a4fc6b03623301f54ea980d87361ba21a` |
| Supplied patch | `2e17d1076a7e2d70a5ed18c850dcd752ac6860127ae58ce49a7eaadf4a6c20bb` |
| Applied Runtime | `cac276516c768a12660780810fb4efa0657178194f86db88c4fa196c5e2f07eb` |

The input matched the author's hash. All hunks applied at the checked anchors;
the output equals the strict in-memory patch result. Reverse apply-check passes.

## Joined contracts

- HNS01: `PluginUIUnprovenSchemaCache.recordDynamic` forwards **nil evidence**;
  `location` forwards **nil validity** to the finalized Core Tools API. Arbitrary
  `create_settings()` cannot grant plugin backup access. Cache invalidation precedes
  maintenance; the location is captured after native drain/unload. Failure releases
  the acquired maintenance lease with `resume: false`.
- HNS04: the authority revokes account tokens before context replacement. Settings
  reads capture owner/account before `operationHost()`. Mutations capture the typed
  TaskLocal invocation before the await and forward its exact `expectedOwner`, SDK
  `account` and lock-only `isCurrent` predicate. The SDK optional account argument
  encloses both storage and callback; it rejects Bool/non-Int32/negative indexes.
- NativeServices keeps its convenience initializer, using the finalized mandatory
  five-argument controlled callback factories. UI/TL have their separate contracts.

Config composition and `applyGlobalPluginConfig` are byte-identical text regions:

| Region | SHA-256 (UTF-8 text) |
|---|---|
| Manager provider + composite composition | `91272a43da7767a28a90cbca112e7d7baa4aa8923c0b867784b583dd5d8a6cb1` |
| Global Config projection | `2beba01a147bf18ea1b272acc2fc362cd7c698e65867161aa01a78fbc0fac2d0` |

The supplied hunks preserve existing TB07 readonly directory access, owned callback
TL origin, hook composition and boot/recovery paths. Harness application belongs to
its owner.

## Evidence and freeze

- UI remediation source preflight: passed **before** application, exercising the
  exact candidate output in memory. That script expects an unapplied patch.
- Applied raw bytes equal that candidate's hash; `git apply --reverse --check
  docs/wave-2/plugin-ui-runtime-remediation.patch`: passed.
- Full `PostboxImportCheck.py .` from `telegram-ios`: passed, bounded at 30 seconds.
- Scoped whitespace/diff checks: passed. Native Swift/UIKit execution is pending.

Runtime source is handed back at the hash above. SDK/native-probe source freeze and
the three fresh 30-second children are described in `sdk-tl-remediation.md` and
`sdk-native-probe.md`. No CI/commit/push was performed.

The frozen Config receipt remains **260 implemented / 16 blocked / 32 unsupported**.
Its current regeneration check reports later parallel source drift (Tools/Chat and
this authorized Runtime stitch). Reconciliation is explicit in the SDK handoff;
the frozen 308-ID table was not silently regenerated during TL/HNS remediation.
