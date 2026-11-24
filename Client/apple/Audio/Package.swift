// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ChirpAudio",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [.library(name: "ChirpAudio", targets: ["ChirpAudio"])],
    dependencies: [.package(path: "../Vendor/rnnoise-0.2")],
    targets: [
        .target(name: "CChirpAudio", dependencies: [.product(name: "RNNoise", package: "rnnoise-0.2")]),
        .target(name: "ChirpAudio", dependencies: ["CChirpAudio"], resources: [.copy("RNNoise-LICENSE.txt")]),
        .testTarget(name: "ChirpAudioTests", dependencies: ["ChirpAudio", "CChirpAudio", .product(name: "RNNoise", package: "rnnoise-0.2")]),
    ]
)
