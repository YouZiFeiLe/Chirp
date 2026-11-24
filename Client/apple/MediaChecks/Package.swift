// swift-tools-version: 6.4
import PackageDescription

// Test-only integration with the exact SDK/WebRTC binaries used by the app.
let package = Package(
    name: "ChirpMediaChecks",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    dependencies: [
        .package(path: "../Vendor/client-sdk-swift-2.19.0"),
        .package(path: "../MLS"),
    ],
    targets: [
        .testTarget(name: "ChirpMediaTests", dependencies: [
            .product(name: "LiveKit", package: "client-sdk-swift-2.19.0"),
            .product(name: "ChirpMLS", package: "MLS"),
        ], path: "Tests"),
    ]
)
