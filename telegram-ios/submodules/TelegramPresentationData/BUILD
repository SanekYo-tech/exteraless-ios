load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")

swift_library(
    name = "TelegramPresentationData",
    module_name = "TelegramPresentationData",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//third-party/exteraless:ExteralessCore",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/Postbox:Postbox",
        "//submodules/Display:Display",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/MediaResources:MediaResources",
        "//submodules/AppBundle:AppBundle",
        "//submodules/StringPluralization:StringPluralization",
        "//submodules/Sunrise:Sunrise",
        "//submodules/TinyThumbnail:TinyThumbnail",
        "//submodules/FastBlur:FastBlur",
        "//Telegram:PresentationStrings",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ExteralessAppearancePresentationTestsLib",
    testonly = True,
    module_name = "ExteralessAppearancePresentationTests",
    srcs = [
        "Tests/AppearancePresentationRevisionTests.swift",
        "Tests/AppearanceMonetPresentationTests.swift",
    ],
    copts = ["-swift-version", "6"],
    deps = [
        ":TelegramPresentationData",
        "//third-party/exteraless:ExteralessCore",
        "//submodules/Display:Display",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
)

ios_unit_test(
    name = "ExteralessAppearancePresentationTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = "//Tests/Exteraless:Runner",
    test_host = "//Tests/Exteraless:NativeTestHost",
    linkopts = ["-framework", "MediaPlayer"],
    deps = [":ExteralessAppearancePresentationTestsLib"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "ExteralessMonetNotices",
    srcs = [
        "Sources/MonetColorUtilities/ExteralessMonet-NOTICE.txt",
        "Sources/MonetColorUtilities/MaterialColorUtilities-LICENSE.txt",
        "Sources/MonetColorUtilities/exteraGram-LICENSE.txt",
    ],
    visibility = ["//visibility:public"],
)
