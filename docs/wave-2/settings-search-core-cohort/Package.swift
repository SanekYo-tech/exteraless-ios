// swift-tools-version:6.0
import PackageDescription

// Standalone, dependency-free snapshot for the 16 settings-search Core fixtures.
// The archive carries unchanged bytes from the source paths listed in cohort.json.
let package = Package(
    name: "SettingsSearchCoreCohort",
    products: [.library(name: "ExteralessCore", targets: ["ExteralessCore"])],
    targets: [
        .target(name: "ExteralessCore", path: "Sources/ExteralessCore", sources: [
            "ClientAPIFeatures.swift",
            "ClientSecrets.swift",
            "ClientSettingDefinition.swift",
            "ClientSettingValue.swift",
            "ClientSettings.swift",
            "ClientSettingsObservation.swift",
            "ClientSettingsSearchIndex.swift",
            "ClientSettingsSourceRoutes.swift",
            "ExteraConfigCompatibility.swift"
        ]),
        .testTarget(name: "ExteralessCoreTests", dependencies: ["ExteralessCore"],
            path: "Tests/ExteralessCoreTests", sources: ["ClientSettingsSearchTests.swift"])
    ]
)
