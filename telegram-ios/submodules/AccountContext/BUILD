load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

filegroup(
    name = "ClientHarnessProtocolSource",
    srcs = ["Sources/AccountContext.swift"],
    visibility = ["//Tests/ExteralessHarness:__pkg__"],
)

filegroup(
    name = "ClientHarnessDomainFingerprintSources",
    srcs = [
        "Sources/AccountContext.swift",
        "Sources/ExteralessContentOcclusions.swift",
        "Sources/ExteralessPillEntry.swift",
    ],
    visibility = ["//Tests/ExteralessHarness:__pkg__"],
)

swift_library(
    name = "AccountContext",
    module_name = "AccountContext",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//third-party/exteraless:ExteralessCore",
        "//submodules/ComponentFlow:ComponentFlow",
        "//submodules/TelegramAudio:TelegramAudio",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/TemporaryCachedPeerDataManager:TemporaryCachedPeerDataManager",
        "//submodules/DeviceLocationManager:DeviceLocationManager",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/MusicAlbumArtResources:MusicAlbumArtResources",
        "//submodules/Utils/RangeSet:RangeSet",
        "//submodules/InAppPurchaseManager:InAppPurchaseManager",
        "//submodules/TextFormat:TextFormat",
        "//submodules/TelegramUI/Components/AnimationCache:AnimationCache",
        "//submodules/TelegramUI/Components/MultiAnimationRenderer:MultiAnimationRenderer",
        "//submodules/WalletContext",
        "//submodules/LottieSettings:LottieSettings",
        "//submodules/TelegramCore/FlatBuffers",
        "//submodules/TelegramCore/FlatSerialization",
    ],
    visibility = [
        "//visibility:public",
    ],
)
