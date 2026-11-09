// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TunnelKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TunnelKit", targets: ["TunnelKit"]),
    ],
    targets: [
        .target(name: "TunnelKit"),
        .testTarget(name: "TunnelKitTests", dependencies: ["TunnelKit"]),
    ]
)
