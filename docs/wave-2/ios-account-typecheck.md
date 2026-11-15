# iOS Account type fixes — 43740868881 / fac6cf26

2026-11-15. **Source-only remediation; actual iOS compilation is pending.**
The failed full build reached TelegramCore. The scoped diagnostics are in
`C:\Users\sasha\AppData\Local\Temp\opencode\ipa-fac6cf26-failed.log:5744–5776`.

## Changed source

Only [`Account.swift`](../../telegram-ios/submodules/TelegramCore/Sources/Account/Account.swift),
two small hunks:

| Build diagnostic | Correction |
| --- | --- |
| `Account.swift:536`, `ValuePromise` requires recovery entries to be `Equatable` | `ExteralessAccountRecoveryEntry: Equatable`; equality is `lhs.recovery === rhs.recovery && lhs.status == rhs.status`. Array and Optional conditional conformances follow from this. |
| `Account.swift:880`, optional localization tuple rejected as a nonoptional tuple; `:941`, optional chaining rejected | Pin the receiving `mapToSignal` parameter to the complete `(PostboxCoding?, LocalizationSettings?, ProxySettings?, NetworkSettings?, AppConfiguration)` tuple and destructure it locally. The producer was already explicitly optional. |

The entry compares the **retained handle's referential identity** and the captured
typed status. Equal account IDs/error descriptions cannot equate different recovery
lifetimes. Recovery attempts, readiness tokens and generation checks continue to
belong to that exact retained handle. `ValuePromise<[ExteralessAccountRecoveryEntry]>([])`
keeps its existing publication behavior; equality does not introduce a replacement
promise, constant-false comparator, or a separate formal model.

## Native optional/default semantics checked

Read the whole pre-edit `Account.swift` (2,582 lines) and traced all five network
initialization callsites using localization:

| Entry/branch | Localization input |
| --- | --- |
| `accountWithId`, main application | Optional stored `LocalizationSettings`; absent/undecodable shared data yields nil. |
| `accountWithId`, supplementary | The existing `!supplementary` condition leaves localization nil. |
| Existing unauthorized, authorized/recovery, and new/no-state account branches | Pass `localizationSettings?.primaryComponent.languageCode`, preserving nil through each branch. Backup-authorized state uses the same tuple. |
| `UnauthorizedAccount.changedMasterDatacenterId` | Loads optional stored settings and passes optional language when constructing the replacement network. |
| `standaloneStateManager` | Its settings tuple deliberately carries nil localization; the optional language reaches network initialization after typed readiness admission. |

[`Network.swift:539–556`](../../telegram-ios/submodules/TelegramCore/Sources/Network/Network.swift)
accepts `languageCode: String?` and owns the native `languageCode ?? "en"` fallback.
The correction pins the optional transport type rather than manufacturing default
`LocalizationSettings` or force-unwrapping stored data.

ClientAPI argument binding, PFR readiness/attempt admission, writer transfer/CAS,
keychain/network/auth registration and the remaining Account branches are covered
by the byte-level scope check below. Existing
[`PFRAppIntegrationTests.swift`](../../telegram-ios/submodules/TelegramCore/Tests/PFRAppIntegrationTests.swift)
was read, including `PFRAppIntegrationTests` and `PFRNativeAccountStartupTests`.
Its real types and assertions require no adjustment for these two hunks.

## Raw SHA-256 checkpoint

Paths are relative to repository root; hashes describe raw working-tree bytes.

| File / snapshot | SHA-256 |
| --- | --- |
| `telegram-ios/submodules/TelegramCore/Sources/Account/Account.swift`, before | `f6fb64a487b4969e777731e5f211c444f0239eac8fcf004a6d6676b8ae346470` |
| Same source, after | `8c753fa5c6908775cd2d234fca4eafe8bc86b3c35b28f0c3f9ce56dd81b83215` |
| `telegram-ios/submodules/TelegramCore/Sources/SyncCore/SyncCore_LocalizationSettings.swift`, read-only | `314b280908e59806ca90aa63a3b6ee6edc19cfd47ce03ab29c8e5474f4935732` |
| `telegram-ios/submodules/TelegramCore/Sources/Network/Network.swift`, read-only | `d77c9983d248b7fa97d95645bff61e9db5d4ff8f2f8f3c9a8cbe7065c1741d8a` |
| `telegram-ios/submodules/SSignalKit/SwiftSignalKit/Source/Promise.swift`, read-only | `e691338e89b656e5d272f70e6c97f5d07990d57badfd7e1d7e1dae86f9a3693a` |
| `telegram-ios/submodules/TelegramCore/Tests/PFRAppIntegrationTests.swift`, read-only | `c498a1872a8303e4cc706f5b436ed07228af9fee5a953fc3a88c0d8fe6e1f12f` |
| Failed build log at the absolute path above | `74877bb5ed60df6267d6d5c51dcbc21d7b356a7f6860b6256d5a2d9381651062` |

## Verification boundary

- **PASS:** reversing only these two type-fix hunks in memory reproduces the exact
  pre-edit Account SHA-256. All five optional-language callsites and the original
  `ValuePromise` declaration are present.
- **PASS:** scoped `git diff --check` (only Git's LF/CRLF conversion notice).
- **PASS:** `python -B build-system/Make/PostboxImportCheck.py` from `telegram-ios/`.
- **Pending:** Apple Swift typecheck/full iOS build and existing native startup
  fixtures. The original failed run is diagnostic evidence, not a build of this fix.

No CI, commit, real account, network startup or new enum/model-only test was run.

## Subsequent compiler result: 43743182219 / e16f3808

The three original diagnostics passed. The compiler next required the generic
`Prepared` type of the authorized retention startup chain. Its `prepare` closure
and nested `mapToSignal` now explicitly return `Signal<Network, NoError>`.
Readiness/transfer checks and the optional Account construction remain the same;
the correction supplies type context rather than a cast or fallback result.
