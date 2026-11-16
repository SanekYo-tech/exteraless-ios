load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application")
load("@rules_cc//cc:objc_library.bzl", "objc_library")

# Build through ClientUIHarness, never :all or either bare swift_library.
# Integration/production-hooks.patch and docs/wave-2/ui-harness.md describe the
# small production seams and visibility additions owned by the coordinator.
swift_library(
    name = "ClientHarnessAccount",
    module_name = "ClientHarnessAccount",
    # Compile only the verified constructor/retainer, not Composer's unrelated
    # AccountContext conformers (which may lag new protocol requirements).
    srcs = ["//Tests/ComposerHarness:DisposableAccountSources"],
    deps = [
        "//submodules/OpenSSLEncryptionProvider:OpenSSLEncryptionProvider",
        "//submodules/PasscodeCore:PasscodeCore",
        "//submodules/Postbox:Postbox",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
    ],
    visibility = ["//Telegram:__pkg__"],
)

genrule(
    name = "ContextStubs",
    srcs = [
        "Tools/generate_context_stubs.py",
        "//submodules/AccountContext:ClientHarnessProtocolSource",
    ],
    outs = ["ClientHarnessContext+Generated.swift"],
    cmd = "python3 $(location Tools/generate_context_stubs.py) $(location //submodules/AccountContext:ClientHarnessProtocolSource) > $@",
)

swift_library(
    name = "ClientHarnessAppContext",
    module_name = "ClientHarnessAppContext",
    srcs = glob(["AppContext/*.swift"]) + [":ContextStubs"],
    deps = [
        # Reuse only the already-hermetic disposable Account constructor.
        ":ClientHarnessAccount",
        "//submodules/AccountContext:AccountContext",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/DeviceLocationManager:DeviceLocationManager",
        "//submodules/Display:Display",
        "//submodules/InAppPurchaseManager:InAppPurchaseManager",
        "//submodules/LottieSettings:LottieSettings",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
        "//submodules/MusicAlbumArtResources:MusicAlbumArtResources",
        "//submodules/Postbox:Postbox",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramAudio:TelegramAudio",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/TelegramUI/Components/AnimationCache:AnimationCache",
        "//submodules/TelegramUI/Components/DCTAnimationCacheImpl:DCTAnimationCacheImpl",
        "//submodules/TelegramUI/Components/DCTMultiAnimationRendererImpl:DCTMultiAnimationRendererImpl",
        "//submodules/TelegramUI/Components/MultiAnimationRenderer:MultiAnimationRenderer",
        "//submodules/TemporaryCachedPeerDataManager:TemporaryCachedPeerDataManager",
        "//submodules/TextFormat:TextFormat",
        "//submodules/Utils/RangeSet:RangeSet",
        "//submodules/WalletContext:WalletContext",
    ],
    visibility = ["//Telegram:__pkg__"],
)

swift_library(
    name = "ClientUIHarnessLib",
    module_name = "ClientUIHarnessLib",
    srcs = glob(["Sources/*.swift"]) + [
        "//Tests/Exteraless:SettingsSearchUIViewRouteChecks.swift",
        "//Tests/Exteraless:SettingsResetNavigationChecks.swift",
    ],
    deps = [
        ":ClientHarnessAppContext",
        ":ClientHarnessAccount",
        "//submodules/AccountContext:AccountContext",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/AvatarNode:AvatarNode",
        "//submodules/DirectMediaImageCache:DirectMediaImageCache",
        "//submodules/ChatPresentationInterfaceState:ChatPresentationInterfaceState",
        "//submodules/Display:Display",
        "//submodules/LocationUI:LocationUI",
        "//submodules/Postbox:Postbox",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUI:TelegramUI",
        "//submodules/TelegramUI/Components/Chat/ChatInputTextNode:ChatInputTextNode",
        "//submodules/TelegramUI/Components/Chat/ChatRichTextEditorComposer:ChatRichTextEditorComposer",
        "//submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode:ChatTextInputPanelNode",
        "//submodules/TelegramUI/Components/RichTextEditor:RichTextEngineEditor",
        "//submodules/TelegramUI/Components/RichTextEditorMediaView:RichTextEditorMediaView",
        "//submodules/UIKitRuntimeUtils:UIKitRuntimeUtils",
        "//third-party/exteraless:ExteralessCore",
        "//third-party/exteraless:PluginHost",
    ],
    visibility = ["//Telegram:__pkg__"],
)

filegroup(
    name = "DomainFingerprintInputs",
    srcs = glob(["Sources/*.swift", "AppContext/*.swift", "Main/*.m", "Tools/*.py"]) + [
        "BUILD",
        "Info.plist",
        "Fixtures/client_ui_fixture.plugin",
        "Fixtures/native_plugin_probe.py",
        "Fixtures/map-attribution-grid.png",
        ":ContextStubs",
        "//submodules/AccountContext:ClientHarnessProtocolSource",
        "//Tests/ComposerHarness:DisposableAccountSources",
        "//submodules/TelegramUI:ClientHarnessDomainFingerprintSources",
        "//submodules/TelegramUI:ClientHarnessSDKFollowupSources",
        "//submodules/SettingsUI:ClientHarnessSettingsSearchSources",
        "//submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen:ClientHarnessSettingsSearchSources",
        "//Tests/Exteraless:SettingsSearchUIViewRouteChecks.swift",
        "//Tests/Exteraless:SettingsResetNavigationChecks.swift",
        "//submodules/TelegramCore:ClientHarnessDomainFingerprintSources",
        "//submodules/AccountContext:ClientHarnessDomainFingerprintSources",
        "//submodules/PhotoResources:ClientHarnessDomainFingerprintSources",
        "//submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode:ClientHarnessDomainFingerprintSources",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemImpl:ClientHarnessDomainFingerprintSources",
        "//submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode:ClientHarnessDomainFingerprintSources",
        "//submodules/TelegramUI/Components/Chat/ChatMessageInteractiveMediaNode:ClientHarnessDomainFingerprintSources",
        "@exteraless//swift/ExteralessCore:ClientHarnessDomainFingerprintSources",
        "//submodules/AvatarNode:ClientHarnessFinalVisualFingerprintSources",
        "//submodules/DirectMediaImageCache:ClientHarnessFinalVisualFingerprintSources",
        "//submodules/Display:ClientHarnessFinalVisualFingerprintSources",
        "//submodules/LocationUI:ClientHarnessMapFingerprintSources",
        "@exteraless//swift/ExteralessCore:ClientHarnessMapFingerprintSources",
        "//submodules/TelegramUI:ClientHarnessFinalVisualFingerprintSources",
        "//submodules/TelegramCore:ClientHarnessFinalVisualFingerprintSources",
        "//submodules/ChatPresentationInterfaceState:ClientHarnessFinalVisualFingerprintSources",
        "//submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode:ClientHarnessFinalVisualFingerprintSources",
        "//submodules/TelegramUI/Components/Chat/ChatRichTextEditorComposer:ClientHarnessFinalVisualFingerprintSources",
        "//submodules/TelegramUI/Components/Chat/ChatInputTextNode:ClientHarnessFinalVisualFingerprintSources",
        "//submodules/TelegramUI/Components/RichTextEditorMessageConversion:ClientHarnessFinalVisualFingerprintSources",
        "//submodules/TelegramUI/Components/RichTextEditorMediaView:ClientHarnessFinalVisualFingerprintSources",
        "//submodules/TextFormat:ClientHarnessFinalVisualFingerprintSources",
        "//submodules/TelegramUI/Components/RichTextEditor:ClientHarnessFinalVisualFingerprintSources",
        "//submodules/Display:ExteralessFontResources",
        "//submodules/TelegramPresentationData:ExteralessMonetNotices",
    ],
)

genrule(
    name = "DomainSourceManifest",
    srcs = [":DomainFingerprintInputs", "Tools/domain_source_manifest.py"],
    outs = ["client-ui-domain-sources.json"],
    cmd = "python3 $(location Tools/domain_source_manifest.py) --output $@ $(locations :DomainFingerprintInputs)",
)

# TelegramUI contains @objc(AppDelegate) and @objc(SceneDelegate). Tests/Common's
# main.m would run the real application delegate. Unique names are essential.
objc_library(
    name = "MainApp",
    srcs = ["Main/main.m"],
)

ios_application(
    name = "ClientUIHarness",
    bundle_id = "org.exteraless.ClientUIHarness",
    families = ["iphone"],
    minimum_os_version = "15.0",
    infoplists = ["Info.plist"],
    linkopts = ["-framework", "MediaPlayer"],
    frameworks = [
        "//Telegram:MtProtoKitFramework",
        "//Telegram:SwiftSignalKitFramework",
        "//Telegram:PostboxFramework",
        "//Telegram:TelegramCoreFramework",
        "//Telegram:TelegramUIFramework",
    ],
    resources = [
        "//submodules/Display:ExteralessFontResources",
        ":DomainSourceManifest",
        "Fixtures/client_ui_fixture.plugin",
        "Fixtures/native_plugin_probe.py",
        "Fixtures/map-attribution-grid.png",
        "//Telegram:AppStringResources",
        "//Telegram:GeneratedPresentationStrings/Resources/PresentationStrings.data",
        "//submodules/TelegramUI:TelegramUIAssets",
        "//submodules/TelegramUI:TelegramUIResources",
        "//submodules/LegacyComponents:LegacyComponentsAssets",
        "//submodules/LegacyComponents:LegacyComponentsResources",
        # structured_resources preserve python/ and python-stdlib/, not basenames.
        "//third-party/exteraless:RuntimeResources",
    ],
    deps = [
        ":MainApp",
        ":ClientUIHarnessLib",
        # Includes Python and every PEP 730 extension, including dlopen-only ones.
        "//third-party/exteraless:RuntimeFrameworks",
    ],
    tags = ["manual"],
    visibility = ["//visibility:public"],
)
