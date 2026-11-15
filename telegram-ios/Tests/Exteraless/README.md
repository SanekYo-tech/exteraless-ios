# Focused Exteraless test targets

Run through the repository's full `build-system/Make/Make.py test` wrapper with
the usual configuration/codesigning arguments (see `CLAUDE.md`), selecting:

- `//Tests/Exteraless:NativeUIContractsTests`
- `//Tests/Exteraless:NativeTLContractsTests`
- `//Tests/Exteraless:IdentityPresentationTests`
- `//Tests/Exteraless:DialogNativePreferenceTests`
- `//Tests/Exteraless:StickerEmojiRenderingTests`
- `//Tests/Exteraless:PluginPillContractsTests`
- `//submodules/TelegramCore:ExteralessPrivacyTests`
- `//submodules/TelegramCore:ExteralessNativeCoreTests`
- `//submodules/TelegramUI:ExteralessFeedTests`
- `//submodules/TelegramUI:ExteralessAINativeTests`
- `//submodules/TelegramUI:ExteralessPlayerNativeTests`
- `//submodules/TelegramUI:ExteralessAppearanceRootTests`
- `//submodules/AvatarNode:ExteralessAppearanceAvatarTests`
- `//submodules/TelegramPresentationData:ExteralessAppearancePresentationTests`
- `//submodules/TelegramStringFormatting:ExteralessAppearancePresenceTests`
- `//submodules/TelegramUI/Components/NavigationExpansionTransition:ExteralessGlassTests`
- `//submodules/Postbox:ExteralessRetentionMediaTests`
- `//submodules/MTProtoRustEngine:ExteralessPassivePingTests`
- `//submodules/TextFormat:ExteralessComposerTests`
- or the focused suite `//Tests/Exteraless:IntegrationTests`.

The common runner is iPhone 17 / iOS 27.0, checked against actual Xcode 27.1 and
available simulator inventory by the native execution helper. The
wrapper supplies the iOS simulator transition; a bare host library build is not
the app build. Do not select the unrelated `//Tests/AllTests` suite.

UI/TL contract tests compile the **shipping source files** through explicit
filegroups. The UI group follows all nine Foundation files in the owner's current
fixture driver, including the style model. These two targets need only Foundation/
CoreFoundation and XCTest.

All selected targets execute with the minimal `NativeTestHost`, which provides
the real Bundle.main strings/assets required by presentation APIs. Its empty
UIKit scene is independent of the acceptance harness's scene/scenarios.

Identity and Dialogs use native value objects. Emoji tests use UIKit/CoreText and
the owner's generated font fixture, exported and staged from ExteralessCore's test
directory as a compile input, plus the owner's native favorite-sticker projection
fixtures. Pill contract tests compile the shipping identity
archive/wire files with Core and Host; they start no plugin interpreter.

Privacy and NativeCore tests remain in TelegramCore's package for TelegramApi/
Postbox visibility. NativeCore includes the authored cloud gzip, auth metadata,
outgoing-chat transforms, fake resolver and disposable encrypted-retention tests.
The owner's nine in-memory Postbox AI fixtures are included in NativeCore too.
Feed tests import testable TelegramUI and inject finite page/window signals into
the shipping registry/timeline. The separate native AI target compiles the owner's
eight UIKit/mapper/scoped-transport/speech fixtures against testable TelegramUI.
Each newly added iOS test rule has a `short` Bazel
execution timeout; builds have the normal Make.py budget.

The shipping app still links one ExteralessCore copy in TelegramCoreFramework;
these test-only modules do not alter that framework graph. Full UIKit presentation
code is compiled by the Telegram IPA and requires separate recorded-frame review.

The existing bounded native Foundation fixtures are also run by the manual
Python Framework CI job using their original drivers:

```sh
python -B telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/run_fixture.py
python -B tools/compat/tests/tl_bridge/run_native_fixtures.py
```

The same workflow runs complete, unfiltered Core/Host/Hooks SwiftPM suites through
`tools/runtime/check_swift_components.py`: 240 seconds to build all tests, then a
separate 30-second `--skip-build` execution. Reports retain the source fingerprints,
compiler logs and owned process-group deadlines. The real SDK native fixture uses
`check_swift_plugin_embedding.py` with the current sealed Python root.

No iOS XCTest or new Mac fixture execution is claimed until the coordinator runs
the joined source snapshot.

`native-tests.json` is the mandatory source-to-label map. The manual UIKit workflow
uses `tools/runtime/run_native_integration_tests.py` after full-sim compilation,
through the existing owned workspace exec. Compilation and XCTest logic have
separate budgets; execution refuses build actions and checks every actual native
test method. Full mapping and 30-second logic/startup semantics are documented in
`docs/wave-2/native-tests.md` in the outer repository.
