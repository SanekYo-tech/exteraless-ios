// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NativeElyxCandidateFixture",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "NativeElyxCandidate", targets: ["NativeElyxCandidate"])],
    dependencies: [.package(path: "../../../../../swift/PluginHost")],
    targets: [.executableTarget(name: "NativeElyxCandidate",
        dependencies: [.product(name: "PluginHost", package: "PluginHost")],
        path: ".", sources: ["CandidateProbe.swift"])])
