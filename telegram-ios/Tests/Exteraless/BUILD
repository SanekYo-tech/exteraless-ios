load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@rules_cc//cc:objc_library.bzl", "objc_library")

package(default_visibility = ["//visibility:public"])

exports_files(
    ["SettingsSearchUIViewRouteChecks.swift", "SettingsResetNavigationChecks.swift"],
    visibility = ["//Tests/ExteralessHarness:__pkg__"],
)

ios_test_runner(
    name = "Runner",
    device_type = "iPhone 17",
    os_version = "27.0",
    test_environment = {"NSUnbufferedIO": "YES"},
)

objc_library(
    name = "NativeTestHostMain",
    testonly = True,
    srcs = ["NativeTestHost.m"],
    sdk_frameworks = ["Foundation", "UIKit"],
)

# Bundle.main is used by the shipping strings/theme/image APIs under test.
ios_application(
    name = "NativeTestHost",
    testonly = True,
    bundle_id = "org.exteraless.NativeTests",
    families = ["iphone"],
    minimum_os_version = "15.0",
    infoplists = ["NativeTestHost.plist"],
    resources = [
        "//submodules/Display:ExteralessFontResources",
        "//Telegram:AppStringResources",
        "//Telegram:GeneratedPresentationStrings/Resources/PresentationStrings.data",
        "//submodules/TelegramUI:TelegramUIAssets",
        "//submodules/TelegramUI:TelegramUIResources",
        "//submodules/TelegramUI:ExteralessLinkResources",
        "//submodules/LegacyComponents:LegacyComponentsAssets",
        "//submodules/LegacyComponents:LegacyComponentsResources",
    ],
    deps = [":NativeTestHostMain"],
)

swift_library(
    name = "NativeUIContractsTestsLib",
    testonly = True,
    module_name = "ExteralessNativeUIContractsTests",
    srcs = [
        "NativeUIContractsTests.swift",
        "PluginManagerAuthorityTests.swift",
        "PluginTrustUIContractsTests.swift",
        "BrowserGestureContractsTests.swift",
        "//submodules/TelegramUI:ExteralessNativeUIContractSources",
        "//submodules/BrowserUI:ExteralessBrowserGestureContractSource",
    ],
    copts = ["-swift-version", "6"],
    deps = [
        "//submodules/Display:Display",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//third-party/exteraless:ExteralessCore",
        "//third-party/exteraless:PluginHost",
    ],
)

ios_unit_test(
    name = "NativeUIContractsTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = ":Runner",
    test_host = ":NativeTestHost",
    linkopts = ["-framework", "MediaPlayer"],
    deps = [":NativeUIContractsTestsLib"],
)

swift_library(
    name = "NativeTLContractsTestsLib",
    testonly = True,
    module_name = "ExteralessNativeTLContractsTests",
    srcs = [
        "NativeTLContractsTests.swift",
        "//submodules/TelegramCore:ExteralessTLContractSources",
    ],
    copts = ["-swift-version", "6"],
)

ios_unit_test(
    name = "NativeTLContractsTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = ":Runner",
    test_host = ":NativeTestHost",
    linkopts = ["-framework", "MediaPlayer"],
    deps = [":NativeTLContractsTestsLib"],
)

swift_library(
    name = "IdentityPresentationTestsLib",
    testonly = True,
    module_name = "ExteralessIdentityPresentationTests",
    srcs = ["IdentityPresentationTests.swift", "IdentityRemediationTests.swift"],
    copts = ["-swift-version", "6"],
    deps = [
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/LocalizedPeerData:LocalizedPeerData",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//third-party/exteraless:ExteralessCore",
    ],
)

ios_unit_test(
    name = "IdentityPresentationTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = ":Runner",
    test_host = ":NativeTestHost",
    linkopts = ["-framework", "MediaPlayer"],
    deps = [":IdentityPresentationTestsLib"],
)

swift_library(
    name = "DialogNativePreferenceTestsLib",
    testonly = True,
    module_name = "ExteralessDialogNativePreferenceTests",
    srcs = ["DialogNativePreferenceTests.swift"],
    copts = ["-swift-version", "6"],
    deps = [
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
    ],
)

ios_unit_test(
    name = "DialogNativePreferenceTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = ":Runner",
    test_host = ":NativeTestHost",
    linkopts = ["-framework", "MediaPlayer"],
    deps = [":DialogNativePreferenceTestsLib"],
)

swift_library(
    name = "StickerEmojiRenderingTestsLib",
    testonly = True,
    module_name = "ExteralessStickerEmojiRenderingTests",
    srcs = [
        "StickerEmojiRenderingTests.swift",
        "StickerFavoritesIntegrationTests.swift",
        "ToolsFavoriteStorageNativeTests.swift",
        "@exteraless//swift/ExteralessCore:Tests/ExteralessCoreTests/EmojiFontFixture.swift",
    ],
    copts = ["-swift-version", "6"],
    deps = [
        "//submodules/Emoji:Emoji",
        "//submodules/TelegramCore:TelegramCore",
        "//third-party/exteraless:ExteralessCore",
    ],
)

ios_unit_test(
    name = "StickerEmojiRenderingTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = ":Runner",
    test_host = ":NativeTestHost",
    linkopts = ["-framework", "MediaPlayer"],
    deps = [":StickerEmojiRenderingTestsLib"],
)

swift_library(
    name = "PluginPillContractsTestsLib",
    testonly = True,
    module_name = "ExteralessPluginPillContractsTests",
    srcs = [
        "PluginPillContractsTests.swift",
        "PillSettingsEntryContractsTests.swift",
        "PillPassivePingContractsTests.swift",
        "//submodules/TelegramUI:ExteralessPluginPillContractSources",
    ],
    copts = ["-swift-version", "6"],
    deps = [
        "//third-party/exteraless:ExteralessCore",
        "//third-party/exteraless:PluginHost",
        "//submodules/TelegramCore:TelegramCore",
    ],
)

ios_unit_test(
    name = "PluginPillContractsTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = ":Runner",
    test_host = ":NativeTestHost",
    linkopts = ["-framework", "MediaPlayer"],
    deps = [":PluginPillContractsTestsLib"],
)

swift_library(
    name = "RuntimeRecoveryContinuationTestsLib",
    testonly = True,
    module_name = "ExteralessRuntimeRecoveryContinuationTests",
    srcs = ["RuntimeRecoveryContinuationTests.swift"],
    copts = ["-swift-version", "6"],
    deps = [
        "//submodules/TelegramUI:TelegramUI",
        "//third-party/exteraless:ExteralessCore",
        "//third-party/exteraless:PluginHost",
    ],
)

ios_unit_test(
    name = "RuntimeRecoveryContinuationTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = ":Runner",
    test_host = ":NativeTestHost",
    linkopts = ["-framework", "MediaPlayer"],
    deps = [":RuntimeRecoveryContinuationTestsLib"],
)

swift_library(
    name = "FontFamilyConsumerTestsLib",
    testonly = True,
    module_name = "FontFamilyConsumerTests",
    srcs = ["FontFamilyConsumerTests.swift"],
    copts = ["-swift-version", "6"],
    deps = [
        "//third-party/exteraless:ExteralessCore",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/ChatListUI:ChatListUI",
        "//submodules/ListSectionHeaderNode:ListSectionHeaderNode",
        "//submodules/LottieSettings:LottieSettings",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUI/Components/Chat/ChatMessageContactBubbleContentNode:ChatMessageContactBubbleContentNode",
    ],
)

ios_unit_test(
    name = "FontFamilyConsumerTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = ":Runner",
    test_host = ":NativeTestHost",
    linkopts = ["-framework", "MediaPlayer"],
    deps = [":FontFamilyConsumerTestsLib"],
)

test_suite(
    name = "IntegrationTests",
    tests = [
        ":NativeUIContractsTests",
        "//Tests/ManagerCustomAlias:ManagerCustomAliasTests",
        ":NativeTLContractsTests",
        ":RuntimeRecoveryContinuationTests",
        ":IdentityPresentationTests",
        ":DialogNativePreferenceTests",
        ":StickerEmojiRenderingTests",
        ":PluginPillContractsTests",
        "//submodules/TelegramCore:ExteralessPrivacyTests",
        "//submodules/TelegramCore:ExteralessNativeCoreTests",
        "//submodules/TelegramUI:ExteralessFeedTests",
        "//submodules/TelegramUI:ExteralessAINativeTests",
        "//submodules/TelegramUI:ExteralessChatMediaTests",
        "//submodules/ChatListUI:ExteralessChatSwipeTests",
        "//submodules/InstantPageUI:ExteralessAIVisibilityTests",
        "//submodules/TelegramUI:ExteralessTLModelTests",
        "//submodules/TelegramUI:ExteralessPlayerNativeTests",
        "//submodules/TelegramUI:ExteralessAppearanceRootTests",
        "//submodules/AvatarNode:ExteralessAppearanceAvatarTests",
        "//submodules/Display:ExteralessFontFamilyTests",
        ":FontFamilyConsumerTests",
        "//submodules/Display:ExteralessLayoutModeTests",
        "//submodules/TelegramUI/Components/DCTMultiAnimationRendererImpl:ExteralessDCTTimingTests",
        "//submodules/TelegramUI/Components/SubcodecMultiAnimationRendererImpl:ExteralessSubcodecTimingTests",
        "//submodules/TelegramPresentationData:ExteralessAppearancePresentationTests",
        "//submodules/TelegramStringFormatting:ExteralessAppearancePresenceTests",
        "//submodules/TelegramUI/Components/NavigationExpansionTransition:ExteralessGlassTests",
        "//submodules/TelegramUI/Components/SwitchComponent:ExteralessAppearanceSwitchTests",
        "//submodules/Postbox:ExteralessRetentionMediaTests",
        "//submodules/MTProtoRustEngine:ExteralessPassivePingTests",
        "//submodules/TextFormat:ExteralessComposerTests",
        "//Tests/ComposerHarness:ExteralessComposerSelectionTests",
        "//Tests/ComposerHarness:ExteralessComposerPasteTests",
        "//submodules/TelegramUI/Components/RichTextEditor:ExteralessComposerMetadataTests",
        "//submodules/TelegramUI/Components/RichTextEditor:ExteralessComposerUIKitTests",
        "//submodules/TelegramUI/Components/RichTextEditor:ExteralessComposerMapperTests",
        "//submodules/TelegramUI/Components/RichTextEditor:ExteralessComposerInputDecTests",
    ],
)
