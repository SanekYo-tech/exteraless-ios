load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

package(default_visibility = ["//visibility:public"])

# New cohort; the historical 36-target / 410-test / 8-frame receipt is untouched.
# The narrowly scoped source filegroup is in the coordinator handoff document.
swift_library(
    name = "ManagerCustomAliasTestsLib",
    testonly = True,
    module_name = "ManagerCustomAliasTests",
    srcs = [
        "ManagerCustomAliasNativeTests.swift",
        "//submodules/TelegramUI:ExteralessManagerCustomAliasSources",
    ],
    copts = ["-swift-version", "6"],
    deps = [
        "//submodules/AppBundle:AppBundle",
        "//submodules/Display:Display",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//third-party/exteraless:PluginHost",
    ],
)

ios_unit_test(
    name = "ManagerCustomAliasTests",
    timeout = "short",
    minimum_os_version = "15.0",
    runner = "//Tests/Exteraless:Runner",
    test_host = "//Tests/Exteraless:NativeTestHost",
    linkopts = ["-framework", "MediaPlayer"],
    deps = [":ManagerCustomAliasTestsLib"],
)
