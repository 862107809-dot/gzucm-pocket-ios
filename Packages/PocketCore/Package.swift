// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PocketCore",
    platforms: [.iOS("18.0"), .macOS(.v14)],
    products: [.library(name: "PocketCore", targets: ["PocketCore"])],
    targets: [
        .target(name: "PocketCore"),
        .testTarget(name: "PocketCoreTests", dependencies: ["PocketCore"], resources: [.process("Fixtures")])
    ]
)
