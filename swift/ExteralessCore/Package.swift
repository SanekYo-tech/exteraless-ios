// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ExteralessCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ExteralessCore", targets: ["ExteralessCore"])
    ],
    targets: [
        .target(name: "ExteralessCore"),
        .testTarget(name: "ExteralessCoreTests", dependencies: ["ExteralessCore"])
    ]
)
