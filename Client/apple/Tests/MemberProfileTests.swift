import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

private func profileFixture(_ revision: Int64, avatar: String? = nil, name: String = "朋友 😀") -> MemberProfile {
    MemberProfile(id: "member_test", displayName: name, profileRevision: revision, avatarRevision: avatar)
}

private func avatarPNG() throws -> Data {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 6, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(try #require(CGColor(colorSpace: colorSpace, components: [1, 0, 0, 1])))
    context.fill(CGRect(x: 0, y: 0, width: 6, height: 2))
    context.setFillColor(try #require(CGColor(colorSpace: colorSpace, components: [0, 1, 0, 1])))
    context.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Test func avatarPreparationBoundsInputAndProducesOnlySquarePixels() throws {
    let data = try AvatarImage.prepare(avatarPNG())
    let image = try #require(AvatarImage.decoded(data))
    #expect(image.width == 512 && image.height == 512)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    // ImageIO may generate fresh EXIF pixel dimensions; private source EXIF
    // and GPS must not be copied. Generated dimensions are harmless metadata.
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    #expect(exif[kCGImagePropertyExifDateTimeOriginal] == nil)
    #expect(exif[kCGImagePropertyExifUserComment] == nil)
    // The center square of the source is entirely green.
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let pixel = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    pixel.draw(try #require(image.cropping(to: CGRect(x: 255, y: 255, width: 1, height: 1))),
               in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let bytes = try #require(pixel.data?.assumingMemoryBound(to: UInt8.self))
    let centerPixel = Array(UnsafeBufferPointer(start: bytes, count: 4))
    #expect(centerPixel == [0, 255, 0, 255])
    #expect(throws: ClientFailure(.avatarTooLarge)) { try AvatarImage.prepare(Data(count: 5_000_000)) }
    #expect(throws: ClientFailure(.avatarInvalid)) { try AvatarImage.prepare(Data("forged-image".utf8)) }
    #expect(AvatarImage.decoded(try avatarPNG()) == nil) // A server avatar must be normalized.
}

@Test func profileResponsesRejectDuplicateMembersAndUnsafeAvatarPaths() throws {
    let valid = profileFixture(2, avatar: String(repeating: "a", count: 64))
    #expect(try valid.validated() == valid)
    #expect(MemberProfile.memberID(for: "member_test.login_second.entry_third") == "member_test")
    #expect(throws: (any Error).self) { try MemberProfilesResponse(members: [valid, valid]).validatedMembers() }
    for revision in ["", "../private", String(repeating: "g", count: 64)] {
        #expect(throws: (any Error).self) { try profileFixture(1, avatar: revision).validated() }
    }
    #expect(throws: (any Error).self) { try profileFixture(-1).validated() }
    #expect(throws: (any Error).self) { try profileFixture(1, name: "含\n换行").validated() }
}

@Test func avatarPreparationRemovesPhotoLocationAndCameraMetadata() throws {
    let sourcePNG = try avatarPNG()
    let source = try #require(CGImageSourceCreateWithData(sourcePNG as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let original = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(original, UTType.jpeg.identifier as CFString, 1, nil))
    let metadata: [CFString: Any] = [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 22.5, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 114.0, kCGImagePropertyGPSLongitudeRef: "E"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "private-camera", kCGImagePropertyTIFFImageDescription: "private-description"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private-comment"],
    ]
    CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let tagged = try #require(CGImageSourceCreateWithData(original as CFData, nil))
    let taggedProperties = try #require(CGImageSourceCopyPropertiesAtIndex(tagged, 0, nil) as? [CFString: Any])
    #expect(taggedProperties[kCGImagePropertyGPSDictionary] != nil)
    let data = try AvatarImage.prepare(original as Data)
    let normalized = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(normalized, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    #expect(properties[kCGImagePropertyTIFFDictionary] == nil)
    #expect(!data.contains(Data("private-comment".utf8)))
    #expect(!data.contains(Data("private-camera".utf8)))
}

@MainActor @Test func profileRevisionsProtectSavedNamesDeletionAndAccountChanges() {
    let profiles = MemberProfiles()
    profiles.reset(credential: "first", server: testServerConnection.apiURL)
    profiles.apply(profileFixture(4, avatar: String(repeating: "a", count: 64)), credential: "first")
    profiles.apply(profileFixture(3, name: "旧昵称"), credential: "first")
    #expect(profiles.members["member_test"]?.profileRevision == 4)
    profiles.apply(profileFixture(5, name: "已移除头像"), credential: "first")
    profiles.apply(profileFixture(4, avatar: String(repeating: "a", count: 64)), credential: "first")
    #expect(profiles.members["member_test"]?.avatarRevision == nil)
    #expect(profiles.displayName(for: "member_test.login_new.entry_new", fallback: "snapshot") == "已移除头像")
    profiles.reset(credential: "second", server: testServerConnection.apiURL)
    profiles.apply(profileFixture(99, name: "迟到响应"), credential: "first")
    #expect(profiles.members.isEmpty)
    profiles.reset(credential: nil, server: testServerConnection.apiURL)
}

private final class ProfileURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { let status: Int; let body: Data; var contentType = "application/json" }
    struct Record: Sendable { let method: String; let path: String; let type: String?; let authorization: String?; let body: Data }
    static let state = Mutex((replies: [Reply](), records: [Record]()))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let reply = Self.state.withLock { state -> Reply? in
            state.records.append(Record(method: request.httpMethod!, path: request.url!.path,
                type: request.value(forHTTPHeaderField: "Content-Type"),
                authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": reply.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct ProfileNetworkTests {
    private func configuration(_ replies: [ProfileURLProtocol.Reply]) -> URLSessionConfiguration {
        ProfileURLProtocol.state.withLock { $0 = (replies, []) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProfileURLProtocol.self]
        return config
    }

    @MainActor @Test func avatarUploadAndDownloadUseAuthenticatedBinaryAndFailuresKeepCurrentImage() async throws {
        let png = try AvatarImage.prepare(avatarPNG())
        let revision = String(repeating: "a", count: 64)
        let profile = try JSONEncoder().encode(profileFixture(1, avatar: revision))
        let failure = Data(#"{"error":{"code":"AVATAR_TOO_LARGE"}}"#.utf8)
        let profiles = MemberProfiles()
        profiles.reset(credential: "test-credential", server: testServerConnection.apiURL, configuration: configuration([
            .init(status: 200, body: profile), .init(status: 200, body: png, contentType: "image/png"),
            .init(status: 413, body: failure), .init(status: 200, body: try JSONEncoder().encode(profileFixture(2))),
        ]))
        defer { profiles.reset(credential: nil, server: testServerConnection.apiURL) }
        try await profiles.setAvatar(png)
        #expect(profiles.image(for: "member_test.login_other.entry_other") != nil)
        do { try await profiles.setAvatar(png); Issue.record("Failed upload was accepted") }
        catch let failure as ClientFailure { #expect(failure.code == "AVATAR_TOO_LARGE") }
        #expect(profiles.members["member_test"]?.avatarRevision == revision)
        #expect(profiles.image(for: "member_test") != nil)
        try await profiles.deleteAvatar()
        #expect(profiles.image(for: "member_test") == nil)
        let records = ProfileURLProtocol.state.withLock { $0.records }
        #expect(records.map(\.method) == ["PUT", "GET", "PUT", "DELETE"])
        #expect(records[0].body == png && records[0].type == "image/png")
        #expect(records[1].path == "/v1/members/member_test/avatar/" + revision)
        #expect(records.allSatisfy { $0.authorization == "Bearer test-credential" })
    }

    @MainActor @Test func nicknameUsesOnlyDisplayNameAndFailurePreservesCurrentProfile() async throws {
        let profiles = MemberProfiles()
        let saved = profileFixture(8, name: "新昵称 😀")
        profiles.reset(credential: "nickname-test", server: testServerConnection.apiURL, configuration: configuration([
            .init(status: 200, body: try JSONEncoder().encode(saved)),
            .init(status: 400, body: Data(#"{"error":{"code":"INVALID_DISPLAY_NAME"}}"#.utf8)),
        ]))
        defer { profiles.reset(credential: nil, server: testServerConnection.apiURL) }
        try await profiles.rename(saved.displayName)
        do { try await profiles.rename("\n"); Issue.record("Invalid nickname was accepted") }
        catch let failure as ClientFailure { #expect(failure.code == "INVALID_DISPLAY_NAME") }
        #expect(profiles.members["member_test"] == saved)
        let records = ProfileURLProtocol.state.withLock { $0.records }
        #expect(records.allSatisfy { $0.method == "PATCH" && $0.path == "/v1/me" })
        let object = try #require(try JSONSerialization.jsonObject(with: records[0].body) as? [String: String])
        #expect(object == ["display_name": saved.displayName])
    }

    @MainActor @Test func avatarDownloadRetriesWithoutANewStateEventAndLoadedVersionIsReused() async throws {
        let png = try AvatarImage.prepare(avatarPNG())
        let profile = profileFixture(1, avatar: String(repeating: "b", count: 64))
        let profiles = MemberProfiles()
        profiles.reset(credential: "download-test", server: testServerConnection.apiURL, configuration: configuration([
            .init(status: 200, body: try JSONEncoder().encode(profile)),
            .init(status: 503, body: Data(#"{"error":{"code":"INTERNAL_ERROR"}}"#.utf8)),
            .init(status: 200, body: png, contentType: "image/png"),
        ]))
        defer { profiles.reset(credential: nil, server: testServerConnection.apiURL) }
        try await profiles.setAvatar(png)
        #expect(profiles.image(for: profile.id) != nil)
        #expect(ProfileURLProtocol.state.withLock { $0.records.map(\.method) } == ["PUT", "GET", "GET"])
        profiles.applySnapshot([profile], credential: "download-test")
        for _ in 0..<200 {
            if profiles.image(for: profile.id) != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(profiles.image(for: profile.id) != nil)
        let readsBefore = ProfileURLProtocol.state.withLock { $0.records.count }
        profiles.applySnapshot([profile], credential: "download-test")
        for _ in 0..<10 { await Task.yield() }
        #expect(ProfileURLProtocol.state.withLock { $0.records.count } == readsBefore)
        profiles.reset(credential: "another-account", server: testServerConnection.apiURL)
        #expect(profiles.image(for: profile.id) == nil && profiles.members.isEmpty)
    }
}
