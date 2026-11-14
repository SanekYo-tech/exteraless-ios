// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PluginHooks",
    platforms: [.macOS(.v10_13), .iOS(.v13)],
    products: [
        .library(name: "PluginHooks", targets: ["PluginHooks"]),
    ],
    targets: [
        .target(name: "CPluginHookShims"),
        .target(name: "PluginHooks", dependencies: ["CPluginHookShims"]),
        .testTarget(name: "PluginHooksTests", dependencies: ["PluginHooks"]),
    ]
)
