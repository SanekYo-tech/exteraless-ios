// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SettingsSearchClosureCohort",
    products: [.library(name: "ExteralessCore", targets: ["ExteralessCore"])],
    targets: [
        .target(name: "ExteralessCore", path: "Sources/ExteralessCore", sources: [
            "ClientAPIFeatures.swift", "ClientSecrets.swift", "ClientSettingDefinition.swift",
            "ClientSettingValue.swift", "ClientSettings.swift", "ClientSettingsObservation.swift",
            "ClientSettingsSearchIndex.swift", "ClientSettingsSourceRoutes.swift", "ExteraConfigCompatibility.swift"
        ]),
        .testTarget(name: "ExteralessCoreTests", dependencies: ["ExteralessCore"], path: "Tests/ExteralessCoreTests", sources: [
            "ClientSettingsSearchTests.swift", "ClientSettingsSearchClosureTests.swift"
        ])
    ]
)
