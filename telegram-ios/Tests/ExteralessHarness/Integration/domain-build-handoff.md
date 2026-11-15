# Domain UI source edges — build owner applies

This implementer did **not** edit any existing BUILD/workflow or
`client_ui_harness_build.py`. New Swift files under `Sources/*.swift` and
`AppContext/*.swift` are already selected by the harness's current globs.

App/Retention's PFR01/PFR04 join has a separate frozen-caller contract in
[`bootstrap-compatibility.md`](bootstrap-compatibility.md), including the exact
constructors and the existing NoError wrapper's readiness-failure adapter point.

## Required direct dependencies

Add to `//Tests/ExteralessHarness:ClientHarnessAppContext.deps`:

```starlark
"//submodules/TelegramUI/Components/DCTAnimationCacheImpl:DCTAnimationCacheImpl",
"//submodules/TelegramUI/Components/DCTMultiAnimationRendererImpl:DCTMultiAnimationRendererImpl",
```

All other context imports (AccountContext, AnimationCache, MultiAnimationRenderer,
LottieSettings, TelegramCore, Postbox, TelegramUIPreferences, RangeSet, Display,
SwiftSignalKit) already have direct edges. Sources use public TelegramUI factory
APIs; **no TelegramUI → harness Swift module dependency** is required.

Confirm `DEBUG` is defined for the TelegramCore/TelegramUI debug simulator compile
actions: `ExteralessFeedOfflineFixture` and `makeExteralessFeedSmoke` are guarded
by it. Keep the full top-level iOS graph and existing unsigned patch.

## Build-time source fingerprint resource

Add filegroups named `ClientHarnessDomainFingerprintSources` with visibility
`["//Tests/ExteralessHarness:__pkg__"]` to the following existing packages:

1. `//submodules/TelegramUI`:
   `Sources/ExteralessClient/Feed/*.swift`,
   `Sources/ExteralessClient/Player/*.swift`,
   `Sources/ExteralessClient/Pills/*.swift`,
   `Sources/ExteralessClient/Chats/ExteralessPillStack.swift`,
   `Sources/ExteralessClient/Chats/ExteralessChatTableController.swift`,
   `Sources/ExteralessClient/ExteralessSettingsController.swift` and
   `Sources/ExteralessClient/ExteralessSettingsUIHelpers.swift`.
2. `//submodules/TelegramCore`:
   `Sources/Account/Account.swift`, `Sources/ExteralessClientAPI/*.swift`,
   `Sources/ExteralessRetention/*.swift`,
   `Sources/TelegramEngine/Messages/ExteralessFeed*.swift`.
3. `//submodules/AccountContext`: `Sources/AccountContext.swift`,
   `Sources/ExteralessContentOcclusions.swift`, `Sources/ExteralessPillEntry.swift`.
   **Do not add files to `ClientHarnessProtocolSource`**: its `$(location)` must
   continue to resolve to exactly the one protocol source.
4. Each of the following component packages, `srcs = glob(["Sources/**/*.swift"])`:
   `//submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode`,
   `//submodules/TelegramUI/Components/Chat/ChatMessageItemImpl`,
   `//submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode`,
   `//submodules/TelegramUI/Components/Chat/ChatMessageInteractiveMediaNode`.
   These have their own BUILD boundaries; a parent TelegramUI glob cannot collect them.
5. `//submodules/PhotoResources`: `Sources/PhotoResources.swift` (the real
   `chatMessagePhotoStatus` → MediaBox status path used by the local Feed image).

In the outer Core package `swift/ExteralessCore/BUILD.bazel`, add the same filegroup
with public visibility, covering `Sources/ExteralessCore/ClientAPI*.swift`,
`ClientSetting*.swift`, `ClientSecrets.swift`, `Retention*.swift`,
`ChatFeatures.swift`, `ChatFeedPolicy.swift`, `CorePillFeatures.swift`, `Feed*.swift`,
`Player*.swift` and `Pill*.swift`. The normal runtime preparer already copies that
BUILD and these sources into `@exteraless`; reference the full external label below.

Add to the harness BUILD:

```starlark
filegroup(
    name = "DomainFingerprintInputs",
    srcs = glob(["Sources/*.swift", "AppContext/*.swift", "Main/*.m", "Tools/*.py"]) + [
        "//Tests/ComposerHarness:DisposableAccountSources",
        "//submodules/TelegramUI:ClientHarnessDomainFingerprintSources",
        "//submodules/TelegramCore:ClientHarnessDomainFingerprintSources",
        "//submodules/AccountContext:ClientHarnessDomainFingerprintSources",
        "//submodules/PhotoResources:ClientHarnessDomainFingerprintSources",
        "//submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode:ClientHarnessDomainFingerprintSources",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemImpl:ClientHarnessDomainFingerprintSources",
        "//submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode:ClientHarnessDomainFingerprintSources",
        "//submodules/TelegramUI/Components/Chat/ChatMessageInteractiveMediaNode:ClientHarnessDomainFingerprintSources",
        "@exteraless//swift/ExteralessCore:ClientHarnessDomainFingerprintSources",
    ],
)
genrule(
    name = "DomainSourceManifest",
    srcs = [":DomainFingerprintInputs", "Tools/domain_source_manifest.py"],
    outs = ["client-ui-domain-sources.json"],
    cmd = "python3 $(location Tools/domain_source_manifest.py) --output $@ $(locations :DomainFingerprintInputs)",
)
```

Add `":DomainSourceManifest"` to `ClientUIHarness.resources`. The driver rejects a
domain run before creating a simulator if this resource or its required source
edges are missing. The running app reports the same resource; the driver compares
it to the current `.ipa` and emits `domain-source-fingerprints.json`. These are
SHA-256s of build-action inputs, not a hand-maintained claim of which revision ran.

## Workflow command selection

The baseline default stays `core-light`, `core-dark`, `sdk-ui`. For the **next
explicit domain batch**, append to the existing recording command (inside the
existing workspace lock wrapper):

```sh
--scenario feed-render --scenario player-render --scenario pill-render
```

No matrix, extra simulator, extra secrets, CI Python plugin or extended process
deadline. The driver rejects duplicates, mixed baseline/domain batches and more
than three cases. Each app process still has both the 30-second native alarm and
external deadline. Run after the latest FU fixes/SDK settings-account arity join
compile; no native or visual pass has been obtained by the implementer.
