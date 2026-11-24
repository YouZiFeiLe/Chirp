import Foundation

struct ClientIdentity: Codable, Equatable, Sendable {
    let platform: String
    let version: String
    let build: Int

    static func validVersion(_ version: String) -> Bool {
        version.range(of: #"^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$"#, options: .regularExpression) == (version.startIndex..<version.endIndex)
    }

    // Call only with validated numeric versions and positive builds.
    static func compare(version: String, build: Int, to otherVersion: String, build otherBuild: Int) -> ComparisonResult {
        let left = version.split(separator: ".").map { Int($0)! }
        let right = otherVersion.split(separator: ".").map { Int($0)! }
        for (a, b) in zip(left, right) where a != b {
            return a < b ? .orderedAscending : .orderedDescending
        }
        if build == otherBuild { return .orderedSame }
        return build < otherBuild ? .orderedAscending : .orderedDescending
    }

    var isValid: Bool { ["ios", "macos"].contains(platform) && Self.validVersion(version) && (1...2_147_483_647).contains(build) }

    static func current(bundle: Bundle = .main) throws -> Self {
        #if os(iOS)
        let platform = "ios"
        #elseif os(macOS)
        let platform = "macos"
        #else
        throw ClientFailure(.clientVersionInvalid)
        #endif
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let raw = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let build = Int(raw), String(build) == raw else { throw ClientFailure(.clientVersionInvalid) }
        let client = Self(platform: platform, version: version, build: build)
        guard client.isValid else { throw ClientFailure(.clientVersionInvalid) }
        return client
    }

    func apply(to request: inout URLRequest) {
        request.setValue(platform, forHTTPHeaderField: "X-Chirp-Platform")
        request.setValue(version, forHTTPHeaderField: "X-Chirp-Version")
        request.setValue(String(build), forHTTPHeaderField: "X-Chirp-Build")
    }
}

struct ClientVersionPolicy: Codable, Equatable, Sendable {
    let platform: String
    let latestVersion: String
    let latestBuild: Int
    let minimumVersion: String
    let minimumBuild: Int
    enum CodingKeys: String, CodingKey {
        case platform, latestVersion = "latest_version", latestBuild = "latest_build", minimumVersion = "minimum_version", minimumBuild = "minimum_build"
    }

    var isValid: Bool {
        ["ios", "macos"].contains(platform) && ClientIdentity.validVersion(latestVersion) && ClientIdentity.validVersion(minimumVersion)
            && (1...2_147_483_647).contains(minimumBuild) && (1...2_147_483_647).contains(latestBuild)
            && ClientIdentity.compare(version: minimumVersion, build: minimumBuild, to: latestVersion, build: latestBuild) != .orderedDescending
    }

    func validate(for client: ClientIdentity) throws {
        guard isValid, client.isValid, client.platform == platform else { throw ClientFailure(.invalidServerConfiguration) }
        guard ClientIdentity.compare(version: client.version, build: client.build, to: minimumVersion, build: minimumBuild) != .orderedAscending else {
            throw ClientFailure(.clientUpdateRequired, clientPolicy: self)
        }
    }

    func localizedDescription(in locale: Locale) -> String {
        // Treat the validated version as a string argument, never as a format.
        let version = latestVersion
        let build = String(latestBuild)
        let minimumVersion = self.minimumVersion
        let minimum = String(minimumBuild)
        let text: LocalizedMessage = "最新版本：\(version)（构建 \(build)）；最低支持版本：\(minimumVersion)（构建 \(minimum)）"
        return text.localized(in: locale)
    }
}
