load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")

swift_library(
    name = "DCTMultiAnimationRendererImpl",
    module_name = "DCTMultiAnimationRendererImpl",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/TelegramUI/Components/AnimationCache:AnimationCache",
        "//submodules/TelegramUI/Components/MultiAnimationRenderer:MultiAnimationRenderer",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ExteralessDCTTimingTestsLib",
    testonly = True,
    module_name = "ExteralessDCTTimingTests",
    srcs = ["Tests/ToolsDCTRendererTimingTests.swift"],
    copts = ["-swift-version", "6"],
    deps = [
        ":DCTMultiAnimationRendererImpl",
        "//submodules/TelegramUI/Components/DCTAnimationCacheImpl:DCTAnimationCacheImpl",
        "//submodules/TelegramUI/Components/AnimationCache:AnimationCache",
        "//submodules/TelegramUI/Components/MultiAnimationRenderer:MultiAnimationRenderer",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//third-party/exteraless:ExteralessCore",
    ],
)

ios_unit_test(
    name = "ExteralessDCTTimingTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = "//Tests/Exteraless:Runner",
    test_host = "//Tests/Exteraless:NativeTestHost",
    deps = [":ExteralessDCTTimingTestsLib"],
    visibility = ["//visibility:public"],
)
