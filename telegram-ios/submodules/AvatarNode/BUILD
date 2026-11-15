load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")

swift_library(
    name = "AvatarNode",
    module_name = "AvatarNode",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//third-party/exteraless:ExteralessCore",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/Postbox",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/AnimationUI:AnimationUI",
        "//submodules/AppBundle:AppBundle",
        "//submodules/AccountContext:AccountContext",
        "//submodules/Emoji:Emoji",
        "//submodules/TinyThumbnail:TinyThumbnail",
        "//submodules/FastBlur:FastBlur",
        "//submodules/ComponentFlow",
        "//submodules/TelegramUI/Components/Stories/AvatarStoryIndicatorComponent",
        "//submodules/DirectMediaImageCache",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ExteralessAppearanceAvatarTestsLib",
    testonly = True,
    module_name = "ExteralessAppearanceAvatarTests",
    srcs = ["Tests/AppearanceAvatarRenderingTests.swift"],
    copts = ["-swift-version", "6"],
    deps = [
        ":AvatarNode",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/ComponentFlow:ComponentFlow",
        "//submodules/TelegramUI/Components/Stories/AvatarStoryIndicatorComponent:AvatarStoryIndicatorComponent",
        "//third-party/exteraless:ExteralessCore",
    ],
)

ios_unit_test(
    name = "ExteralessAppearanceAvatarTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = "//Tests/Exteraless:Runner",
    test_host = "//Tests/Exteraless:NativeTestHost",
    linkopts = ["-framework", "MediaPlayer"],
    deps = [":ExteralessAppearanceAvatarTestsLib"],
    visibility = ["//visibility:public"],
)
