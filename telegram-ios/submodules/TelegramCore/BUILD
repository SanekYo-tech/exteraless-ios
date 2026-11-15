load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

filegroup(
    name = "ExteralessTLContractSources",
    srcs = [
        "Sources/ExteralessRuntime/TLCodec.swift",
        "Sources/ExteralessRuntime/TLSchemaGenerated.swift",
        "Sources/ExteralessRuntime/TLRequestRegistry.swift",
    ],
    visibility = ["//Tests/Exteraless:__pkg__"],
)

filegroup(
    name = "ClientHarnessDomainFingerprintSources",
    srcs = ["Sources/Account/Account.swift"] + glob([
        "Sources/ExteralessClientAPI/*.swift",
        "Sources/ExteralessRetention/*.swift",
        "Sources/TelegramEngine/Messages/ExteralessFeed*.swift",
    ]),
    visibility = ["//Tests/ExteralessHarness:__pkg__"],
)

filegroup(
    name = "ClientHarnessFinalVisualFingerprintSources",
    srcs = glob(["Sources/ChatInputContent/**/*.swift"]) + [
        "Sources/SyncCore/SyncCore_CloudFileMediaResource.swift",
        "Sources/SyncCore/SyncCore_AppConfiguration.swift",
        "Sources/TelegramEngine/Resources/TelegramEngineResources.swift",
    ],
    visibility = ["//Tests/ExteralessHarness:__pkg__"],
)

swift_library(
    name = "TelegramCore",
    module_name = "TelegramCore",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/sqlcipher:sqlcipher",
        "//third-party/exteraless:ExteralessCore",
        "//third-party/exteraless:PluginHooks",
        "//submodules/TelegramApi:TelegramApi",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/MediaPreuploadRegistry:MediaPreuploadRegistry",
        "//submodules/WebProxyTransport:WebProxyTransport",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/CloudData:CloudData",
        "//submodules/EncryptionProvider:EncryptionProvider",
        "//submodules/CryptoUtils:CryptoUtils",
        "//submodules/NetworkLogging:NetworkLogging",
        "//submodules/Reachability:Reachability",
        "//submodules/ManagedFile:ManagedFile",
        "//submodules/Utils/RangeSet:RangeSet",
        "//submodules/Utils/DarwinDirStat",
        "//submodules/Emoji",
        "//submodules/TelegramCore/FlatBuffers",
        "//submodules/TelegramCore/FlatSerialization",
        "//submodules/MurMurHash32",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "TelegramCoreTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":TelegramCore",
        "//third-party/exteraless:ExteralessCore",
        "//third-party/exteraless:PluginHooks",
        "//submodules/sqlcipher:sqlcipher",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramApi:TelegramApi",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/Postbox:Postbox",
        "//submodules/WebProxyTransport:WebProxyTransport",
        # InstantPageButtonLinkStyleTests round-trips through the flatc-generated TelegramCore_* types.
        "//submodules/TelegramCore/FlatBuffers",
        "//submodules/TelegramCore/FlatSerialization",
    ],
)

ios_test_runner(
    name = "TelegramCoreTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "TelegramCoreTests",
    minimum_os_version = "15.0",
    runner = ":TelegramCoreTestRunner",
    deps = [
        ":TelegramCoreTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ExteralessPrivacyTestsLib",
    testonly = True,
    srcs = [
        "Tests/ExteralessPrivacyAdmissionTests.swift",
        "Tests/ExteralessPrivacyHistoryLifetimeTests.swift",
        "Tests/ExteralessPrivacySignalTests.swift",
        "Tests/ExteralessProxyNameTests.swift",
    ],
    deps = [
        ":TelegramCore",
        "//third-party/exteraless:ExteralessCore",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramApi:TelegramApi",
        "//submodules/Postbox:Postbox",
    ],
)

ios_unit_test(
    name = "ExteralessPrivacyTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = "//Tests/Exteraless:Runner",
    test_host = "//Tests/Exteraless:NativeTestHost",
    linkopts = ["-framework", "MediaPlayer"],
    deps = [":ExteralessPrivacyTestsLib"],
    visibility = ["//visibility:public"],
)

# Owner-authored native value/transport/storage fixtures, with same-package
# TelegramApi/Postbox visibility; named classes retain independent logic budgets.
swift_library(
    name = "ExteralessNativeCoreTestsLib",
    testonly = True,
    module_name = "ExteralessNativeCoreTests",
    srcs = [
        "Tests/ClientAPIRequestMetadataTests.swift",
        "Tests/CloudTransportTests.swift",
        "Tests/CloudLegacyTransportTests.swift",
        "Tests/EnqueueAdmissionTests.swift",
        "Tests/ExteralessAINativeTests.swift",
        "Tests/ExteralessDialogReviewTests.swift",
        "Tests/ExteralessOutgoingChatTextTests.swift",
        "Tests/ExteralessPassivePingForwardingTests.swift",
        "Tests/ExteralessPrivacyExtrasRemediationTests.swift",
        "Tests/ExteralessResolverConnectionTests.swift",
        "Tests/ExteralessRetentionTests.swift",
        "Tests/ExteralessStickerReviewTests.swift",
        "Tests/ExteralessTLReviewTests.swift",
        "Tests/FinalAppNotificationAdmissionTests.swift",
        "Tests/NetworkCredentialLogTests.swift",
        "Tests/PFRAppIntegrationTests.swift",
        "Tests/PlayerSavedMusicTests.swift",
        "Tests/RetentionNativeIntegrationTests.swift",
        "Tests/RetentionReviewRemediationTests.swift",
    ],
    copts = ["-swift-version", "6"],
    deps = [
        ":TelegramCore",
        "//third-party/exteraless:ExteralessCore",
        "//third-party/exteraless:PluginHooks",
        "//submodules/TelegramApi:TelegramApi",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/Postbox:Postbox",
        "//submodules/sqlcipher:sqlcipher",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
)

ios_unit_test(
    name = "ExteralessNativeCoreTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = "//Tests/Exteraless:Runner",
    test_host = "//Tests/Exteraless:NativeTestHost",
    linkopts = ["-framework", "MediaPlayer"],
    deps = [":ExteralessNativeCoreTestsLib"],
    visibility = ["//visibility:public"],
)
