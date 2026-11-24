// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ChirpMLS",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [.library(name: "ChirpMLS", targets: ["ChirpMLS"])],
    targets: [
        .binaryTarget(name: "ChirpMLSNative", path: "Artifacts/ChirpMLSNative.xcframework"),
        .target(name: "ChirpMLS", dependencies: ["ChirpMLSNative"], resources: [.copy("Resources/ThirdPartyNotices.txt")]),
        .testTarget(name: "ChirpMLSTests", dependencies: ["ChirpMLS"], resources: [.copy("Fixtures")]),
    ]
)
