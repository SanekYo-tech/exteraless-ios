load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")

swift_library(
    name = "SwitchComponent",
    module_name = "SwitchComponent",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//third-party/exteraless:ExteralessCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/ContextUI:ContextUI",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/ComponentFlow:ComponentFlow",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ExteralessAppearanceSwitchTestsLib",
    testonly = True,
    module_name = "ExteralessAppearanceSwitchTests",
    srcs = ["Tests/AppearanceSwitchTests.swift"],
    copts = ["-swift-version", "6"],
    deps = [
        ":SwitchComponent",
        "//submodules/ComponentFlow:ComponentFlow",
        "//third-party/exteraless:ExteralessCore",
    ],
)

ios_unit_test(
    name = "ExteralessAppearanceSwitchTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = "//Tests/Exteraless:Runner",
    test_host = "//Tests/Exteraless:NativeTestHost",
    linkopts = ["-framework", "MediaPlayer"],
    deps = [":ExteralessAppearanceSwitchTestsLib"],
    visibility = ["//visibility:public"],
)
