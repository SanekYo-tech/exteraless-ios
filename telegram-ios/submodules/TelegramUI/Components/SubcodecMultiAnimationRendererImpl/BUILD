load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")

swift_library(
    name = "SubcodecMultiAnimationRendererImpl",
    module_name = "SubcodecMultiAnimationRendererImpl",
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
        "//third-party/exteraless:ExteralessCore",
        "//submodules/TelegramUI/Components/SubcodecAnimationCacheImpl:SubcodecAnimationCacheImpl",
        "//third-party/subcodec:SubcodecObjC",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ExteralessSubcodecTimingTestsLib",
    testonly = True,
    module_name = "ExteralessSubcodecTimingTests",
    srcs = ["Tests/ToolsSubcodecRendererTimingTests.swift"],
    copts = ["-swift-version", "6"],
    deps = [
        ":SubcodecMultiAnimationRendererImpl",
        "//submodules/TelegramUI/Components/SubcodecAnimationCacheImpl:SubcodecAnimationCacheImpl",
        "//submodules/TelegramUI/Components/MultiAnimationRenderer:MultiAnimationRenderer",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//third-party/subcodec:SubcodecObjC",
        "//third-party/exteraless:ExteralessCore",
    ],
)

ios_unit_test(
    name = "ExteralessSubcodecTimingTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = "//Tests/Exteraless:Runner",
    test_host = "//Tests/Exteraless:NativeTestHost",
    deps = [":ExteralessSubcodecTimingTestsLib"],
    visibility = ["//visibility:public"],
)
