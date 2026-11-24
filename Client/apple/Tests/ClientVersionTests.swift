import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

#if !SWIFT_PACKAGE
@Test func installedApplicationContainsVersionPermissionsAndPrivacyManifest() throws {
    let bundle = Bundle.main
    #expect(try ClientIdentity.current(bundle: bundle).isValid)
    for key in ["NSMicrophoneUsageDescription", "NSCameraUsageDescription", "NSLocalNetworkUsageDescription"] {
        #expect((bundle.object(forInfoDictionaryKey: key) as? String)?.isEmpty == false)
    }
    let url = try #require(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
    let manifest = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    #expect(manifest["NSPrivacyTracking"] as? Bool == false)
    let apis = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
    let reasons = apis.reduce(into: [String: Set<String>]()) { result, api in
        if let type = api["NSPrivacyAccessedAPIType"] as? String,
           let values = api["NSPrivacyAccessedAPITypeReasons"] as? [String] { result[type] = Set(values) }
    }
    #expect(reasons["NSPrivacyAccessedAPICategoryUserDefaults"] == ["CA92.1"])
    #expect(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"] == ["C617.1", "3B52.1"])
    #expect(reasons["NSPrivacyAccessedAPICategorySystemBootTime"] == ["35F9.1"])
}
#endif

@Test func versionMetadataUsesTheActualBundleAndRejectsMalformedNumbers() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let info: [String: Any] = ["CFBundleIdentifier": "test.chirp.version", "CFBundleShortVersionString": "1.23.4", "CFBundleVersion": "123"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: directory.appendingPathComponent("Info.plist"))
    let bundle = try #require(Bundle(path: directory.path))
    let identity = try ClientIdentity.current(bundle: bundle)
    #if os(iOS)
    #expect(identity.platform == "ios")
    #else
    #expect(identity.platform == "macos")
    #endif
    #expect(identity.version == "1.23.4" && identity.build == 123)
    for version in ["0.11", "01.11.0", "0.11.0\n", " 0.11.0", "0.11.0-beta", "1000000.0.0"] {
        #expect(!ClientIdentity(platform: "macos", version: version, build: 25).isValid)
    }
    for build in [0, -1, 2_147_483_648] {
        #expect(!ClientIdentity(platform: "ios", version: "0.11.0", build: build).isValid)
    }
}

@Test func numericVersionTakesPriorityOverTheBuildNumber() {
    let cases: [(String, Int, String, Int, ComparisonResult)] = [
        ("0.11.1", 1, "0.11.0", 25, .orderedDescending),
        ("0.11.0", 2_147_483_647, "0.11.1", 1, .orderedAscending),
        ("0.11.1", 1, "0.11.1", 2, .orderedAscending),
        ("0.11.1", 2, "0.11.1", 1, .orderedDescending),
        ("0.11.1", 1, "0.11.1", 1, .orderedSame),
        ("0.10.0", 1, "0.9.999999", 2_147_483_647, .orderedDescending),
        ("1.0.0", 1, "0.999999.999999", 2_147_483_647, .orderedDescending),
    ]
    for (version, build, other, otherBuild, expected) in cases {
        #expect(ClientIdentity.compare(version: version, build: build, to: other, build: otherBuild) == expected)
    }
}

@Test func versionPolicySupportsBuildResetAndRejectsOlderVersionsWithLargeBuilds() throws {
    let policy = ClientVersionPolicy(platform: "ios", latestVersion: "0.11.1", latestBuild: 1, minimumVersion: "0.11.0", minimumBuild: 25)
    #expect(policy.isValid)
    for (version, build) in [("0.11.0", 25), ("0.11.1", 1), ("0.12.0", 1)] {
        try policy.validate(for: ClientIdentity(platform: "ios", version: version, build: build))
    }
    for (version, build) in [("0.11.0", 24), ("0.10.99", 2_147_483_647)] {
        #expect(throws: ClientFailure.self) { try policy.validate(for: ClientIdentity(platform: "ios", version: version, build: build)) }
    }
    let minimum = ClientVersionPolicy(platform: "ios", latestVersion: "0.11.1", latestBuild: 1, minimumVersion: "0.11.1", minimumBuild: 1)
    #expect(throws: ClientFailure.self) { try minimum.validate(for: ClientIdentity(platform: "ios", version: "0.11.0", build: 2_147_483_647)) }
    try minimum.validate(for: ClientIdentity(platform: "ios", version: "0.11.1", build: 1))
    #expect(policy.localizedDescription(in: Locale(identifier: "en")).contains("minimum supported version: 0.11.0 (build 25)"))
}

@Test func versionPolicyRequiresMinimumVersionAndValidatesBothPairs() throws {
    let missing = Data(#"{"platform":"ios","latest_version":"0.11.1","latest_build":1,"minimum_build":1}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ClientVersionPolicy.self, from: missing) }
    for policy in [
        ClientVersionPolicy(platform: "ios", latestVersion: "0.11.1", latestBuild: 1, minimumVersion: "", minimumBuild: 1),
        ClientVersionPolicy(platform: "ios", latestVersion: "0.11.1", latestBuild: 1, minimumVersion: "0.11.2", minimumBuild: 1),
        ClientVersionPolicy(platform: "ios", latestVersion: "0.11.1", latestBuild: 1, minimumVersion: "0.11.1", minimumBuild: 2),
        ClientVersionPolicy(platform: "ios", latestVersion: "0.11.1", latestBuild: 1, minimumVersion: "0.11.0\n", minimumBuild: 1),
        ClientVersionPolicy(platform: "ios", latestVersion: "0.11.1", latestBuild: 1, minimumVersion: "0.11.0", minimumBuild: 2_147_483_648),
    ] { #expect(!policy.isValid) }
}
