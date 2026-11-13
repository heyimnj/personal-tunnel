// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TunnelCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TunnelCore", targets: ["TunnelCore"]),
    ],
    targets: [
        .target(name: "TunnelCore"),
        .executableTarget(name: "tunnelcore-fixtures", dependencies: ["TunnelCore"]),
        .testTarget(name: "TunnelCoreTests", dependencies: ["TunnelCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
