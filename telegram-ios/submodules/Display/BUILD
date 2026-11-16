load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

filegroup(
    name = "ClientHarnessFinalVisualFingerprintSources",
    srcs = [
        "Source/ImageNode.swift",
        "Source/DisplayLinkDispatcher.swift",
        "Source/TransformImageNode.swift",
        "Source/Navigation/NavigationContainer.swift",
        "Source/NavigationTransitionCoordinator.swift",
        "Source/NavigationTransitionSpring.swift",
        "Source/NavigationInteractivePopTracker.swift",
    ],
    visibility = ["//Tests/ExteralessHarness:__pkg__"],
)

swift_library(
    name = "Display",
    module_name = "Display",
    srcs = glob([
        "Source/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//third-party/exteraless:ExteralessCore",
    	"//submodules/ObjCRuntimeUtils:ObjCRuntimeUtils",
    	"//submodules/UIKitRuntimeUtils:UIKitRuntimeUtils",
        "//submodules/AppBundle:AppBundle",
    	"//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Markdown:Markdown",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "DisplayTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ], exclude = ["Tests/ExteralessFontFamilyTests.swift"]),
    deps = [
        ":Display",
        "//third-party/exteraless:ExteralessCore",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
)

# The runner MUST pin a real device/OS: the default runner picks an invalid
# device and the test process exits 15.
ios_test_runner(
    name = "DisplayTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "DisplayTests",
    minimum_os_version = "15.0",
    runner = ":DisplayTestRunner",
    deps = [
        ":DisplayTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Flat, process-main-bundle resources. Registration is explicit in Display;
# keep the unmodified OFL beside both fonts in every consuming bundle.
filegroup(
    name = "ExteralessFontResources",
    srcs = [
        "Resources/Fonts/ExteralessRoboto/ExteralessRoboto-Regular.ttf",
        "Resources/Fonts/ExteralessRoboto/ExteralessRoboto-Italic.ttf",
        "Resources/Fonts/ExteralessRoboto/ExteralessRoboto-OFL.txt",
    ],
    visibility = ["//visibility:public"],
)

swift_library(
    name = "ExteralessFontFamilyTestsLib",
    testonly = True,
    module_name = "ExteralessFontFamilyTests",
    srcs = ["Tests/ExteralessFontFamilyTests.swift"],
    copts = ["-swift-version", "6"],
    deps = [
        ":Display",
        "//third-party/exteraless:ExteralessCore",
    ],
)

ios_unit_test(
    name = "ExteralessFontFamilyTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = "//Tests/Exteraless:Runner",
    test_host = "//Tests/Exteraless:NativeTestHost",
    linkopts = ["-framework", "MediaPlayer"],
    deps = [":ExteralessFontFamilyTestsLib"],
    visibility = ["//visibility:public"],
)

swift_library(
    name = "ExteralessLayoutModeTestsLib",
    testonly = True,
    module_name = "ExteralessLayoutModeTests",
    srcs = ["Tests/AppearanceLayoutModeTests.swift"],
    copts = ["-swift-version", "6"],
    deps = [
        ":Display",
        "//third-party/exteraless:ExteralessCore",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
)

ios_unit_test(
    name = "ExteralessLayoutModeTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = "//Tests/Exteraless:Runner",
    test_host = "//Tests/Exteraless:NativeTestHost",
    deps = [":ExteralessLayoutModeTestsLib"],
    visibility = ["//visibility:public"],
)
