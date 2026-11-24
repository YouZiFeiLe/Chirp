import ChirpMLS
import CryptoKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
#if os(iOS) && !SWIFT_PACKAGE
import UIKit
#endif
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@MainActor private final class PairingTestRelay {
    var state: DevicePairingState?
    var lostResponseFor: String?
    var tamper: ((inout DevicePairingState) -> Void)?
    var onApproverPoll: (() async -> Void)?
    var clockReady = true
    var onAuthorize: (() -> Void)?
    var authorizationChecks = 0

    func requireClock() throws {
        guard clockReady else { throw ClientFailure(.networkTimeRequired) }
    }

    func post(_ path: String, _ data: Data) async throws -> DevicePairingState {
        if path.hasSuffix("/start") {
            struct Start: Decodable { let request: DevicePairingRequest }
            let request = try JSONDecoder().decode(Start.self, from: data).request
            try request.validate(); state = DevicePairingState(request: request)
        } else {
            let action = try JSONDecoder().decode(DevicePairingAction.self, from: data)
            if action.action == "poll-old" { await onApproverPoll?() }
            var value = try #require(state)
            try action.validate(request: value.request, expectedAction: action.action)
            switch action.action {
            case "offer": if value.offer == nil { value.offer = action }
            case "reveal": if value.reveal == nil { value.reveal = action }
            case "new-confirm": if value.newConfirmation == nil { value.newConfirmation = action }
            case "old-confirm": if value.oldConfirmation == nil { value.oldConfirmation = action }
            case "approve":
                guard value.newConfirmation != nil, value.oldConfirmation != nil else { throw V5IdentityError.untrusted }
                if value.approval == nil { value.approval = action }
            case "cancel-new", "cancel-old": value.cancelled = true
            case "poll-new", "poll-old": break
            default: throw V5IdentityError.invalid
            }
            state = value
            if lostResponseFor == action.action { lostResponseFor = nil; throw URLError(.networkConnectionLost) }
        }
        var response = try #require(state)
        tamper?(&response)
        return response
    }
}

@MainActor private struct PairingTestDevices {
    let oldIdentity: DeviceIdentityStore
    let newIdentity: DeviceIdentityStore
    let new: DevicePairingSession
    let old: DevicePairingSession
    let relay: PairingTestRelay

    static func make(importedImage: Bool = true, lostResponseFor: String? = nil, expiresIn: Int64 = 300) async throws -> Self {
        let relay = PairingTestRelay()
        relay.lostResponseFor = lostResponseFor
        let origin = ServerAddress.identityOrigin(testServerConnection.passkeyOrigin), account = "member_pairing"
        let oldIdentity = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
        try oldIdentity.select(origin: origin, accountID: account)
        let device = try oldIdentity.makeCandidate(rootSeed: V5Crypto.random()); try oldIdentity.markBound()
        let newIdentity = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
        try newIdentity.select(origin: origin, accountID: account)
        let auth = AuthenticatedIdentitySetup(token: "setup_pairing", accountID: account, username: "Pairing", origin: origin,
            accountKey: device.accountKey, expiresAt: Int64(Date().timeIntervalSince1970) + expiresIn)
        let transport: DevicePairingSession.Transport = { path, data in try await relay.post(path, data) }
        let new = try await DevicePairingSession.newDevice(identity: newIdentity, authentication: auth, verifier: "fixture",
            connection: testServerConnection, requireClock: relay.requireClock, transport: transport)
        let old = try await DevicePairingSession.approvingDevice(code: new.request.code, identity: oldIdentity,
            connection: testServerConnection, importedImage: importedImage, requireClock: relay.requireClock, transport: transport,
            authorize: { relay.authorizationChecks += 1; relay.onAuthorize?() })
        return Self(oldIdentity: oldIdentity, newIdentity: newIdentity, new: new, old: old, relay: relay)
    }

    func handshake() async throws {
        await new.poll(); await old.poll()
        #expect(new.decimals.count == 3 && new.decimals == old.decimals)
        #expect(new.failure == nil && old.failure == nil)
        #expect(!new.completed && !old.completed && relay.state?.approval == nil)
    }

    func complete() async throws {
        await old.approve(enteredCode: new.safetyCode, canEnroll: false)
        #expect(relay.state?.approval == nil)
        await new.poll()
        await new.confirmNewDevice()
        await old.poll(); await new.poll()
        #expect(new.completed && old.completed)
        #expect(new.failure == nil && old.failure == nil)
    }
}

@Suite @MainActor struct DevicePairingTests {
    #if os(iOS) && !SWIFT_PACKAGE
    @Test func groupedCodeEntryHandlesBatchedEditsAndPreservesNeighboringDigits() {
        let editor = PairingCodeEditor()
        func edit(_ group: Int, _ range: NSRange, _ text: String) {
            let field = editor.fields[group]
            if editor.textField(field, shouldChangeCharactersInRanges: [NSValue(range: range)], replacementString: text) {
                field.text = ((field.text ?? "") as NSString).replacingCharacters(in: range, with: text)
            }
        }

        #expect(editor.fields.allSatisfy { $0.keyboardType == .asciiCapableNumberPad })
        edit(0, NSRange(location: 0, length: 0), "0123 4567 890")
        #expect(editor.fields.compactMap(\.text) == ["0123", "4567", "890"])
        #expect(editor.completeCode.isEmpty)
        edit(2, NSRange(location: 3, length: 0), "1")
        edit(1, NSRange(location: 4, length: 0), "8")
        #expect(editor.completeCode == "012345678901")
        edit(1, NSRange(location: 1, length: 1), "")
        #expect(editor.completeCode.isEmpty)
        edit(1, NSRange(location: 0, length: 0), "9876-5432-1098")
        #expect(editor.fields.compactMap(\.text) == ["9876", "5432", "1098"])
        #expect(editor.completeCode == "987654321098")
    }
    #endif

    @Test func importedImageRequiresFreshCodeAndBothNativeMACs() async throws {
        let f = try await PairingTestDevices.make()
        try await f.handshake()
        await f.old.approve(enteredCode: "", canEnroll: true)
        #expect(!f.old.localConfirmed && f.relay.authorizationChecks == 0 && f.relay.state?.oldConfirmation == nil)
        #expect(f.old.failure != nil)
        await f.old.poll()
        #expect(f.old.failure != nil)
        try await f.complete()
        #expect(f.relay.authorizationChecks == 1)
        let approval = try #require(f.new.approval)
        try f.newIdentity.acceptPairedDevice(approval, request: f.new.request, issuer: f.new.issuer)
        #expect(f.newIdentity.device?.accountKey == f.oldIdentity.device?.accountKey)
        #expect(f.newIdentity.device?.leafKey == f.new.request.deviceKey && !f.newIdentity.canEnroll)
        #expect(throws: (any Error).self) { try f.newIdentity.acceptPairedDevice(approval, request: f.new.request, issuer: f.new.issuer) }
    }

    @Test func clockChangeDuringDeviceOwnerAuthenticationStopsApproval() async throws {
        let devices = try await PairingTestDevices.make(importedImage: false)
        defer { devices.new.stop(); devices.old.stop() }
        try await devices.handshake()
        devices.relay.onAuthorize = { [weak relay = devices.relay] in relay?.clockReady = false }
        await devices.old.approve(enteredCode: "", canEnroll: true)
        #expect(devices.relay.authorizationChecks == 1)
        #expect(!devices.old.localConfirmed && devices.relay.state?.oldConfirmation == nil)
        #expect(devices.relay.state?.approval == nil)
    }

    @Test func cameraUsesTheSameMutualAuthenticationProtocol() async throws {
        let f = try await PairingTestDevices.make(importedImage: false)
        try await f.handshake()
        await f.old.approve(enteredCode: "", canEnroll: true)
        await f.new.poll()
        #expect(f.new.peerConfirmed && !f.new.localConfirmed && !f.new.completed)
        #expect(f.relay.state?.approval == nil)
        await f.new.confirmNewDevice(); await f.old.poll(); await f.new.poll()
        #expect(f.new.completed && f.old.completed && f.new.approval?.device.certificates.last?.canEnroll == true)
    }

    @Test func cameraApprovalCanStartDuringABackgroundPoll() async throws {
        let f = try await PairingTestDevices.make(importedImage: false)
        try await f.handshake()
        var submission: Task<Void, Never>?
        f.relay.onApproverPoll = {
            #expect(f.old.canConfirm && !f.old.isConfirming)
            submission = Task.immediate { await f.old.approve(enteredCode: "", canEnroll: true) }
            #expect(f.old.isConfirming && !f.old.canConfirm)
            #expect(f.relay.authorizationChecks == 0)
        }
        await f.old.poll()
        f.relay.onApproverPoll = nil
        let approval = try #require(submission)
        await approval.value
        #expect(f.old.localConfirmed && !f.old.isConfirming && f.relay.authorizationChecks == 1)
        await f.new.confirmNewDevice(); await f.old.poll(); await f.new.poll()
        #expect(f.old.completed && f.new.completed)
    }

    @Test func approvalExpiresWhileAPollIsStillInFlight() async throws {
        let f = try await PairingTestDevices.make(importedImage: false, expiresIn: 16)
        try await f.handshake()
        var pendingReply: CheckedContinuation<Void, Never>?
        f.relay.onApproverPoll = { await withCheckedContinuation { pendingReply = $0 } }
        async let poll: Void = f.old.poll()
        await f.old.stopAtExpiration()
        #expect(f.old.stopped && !f.old.canConfirm)
        let reply = try #require(pendingReply)
        reply.resume()
        await poll
        #expect(f.old.failure == DevicePairingError.expired.localizedDescription)
        await f.old.approve(enteredCode: "", canEnroll: true)
        #expect(f.relay.authorizationChecks == 0)
        f.new.stop()
    }

    @Test func wrongCodeNeverInvokesDeviceAuthenticationAndThreeFailuresStopPairing() async throws {
        let f = try await PairingTestDevices.make()
        try await f.handshake()
        let wrong = f.new.safetyCode == "0000 0000 0000" ? "0001 0000 0000" : "0000 0000 0000"
        for _ in 0..<3 { await f.old.approve(enteredCode: wrong, canEnroll: true) }
        #expect(f.old.stopped && !f.old.localConfirmed && f.relay.authorizationChecks == 0 && f.relay.state?.approval == nil)
    }

    @Test func everyDecimalGroupIsRequiredAndUnicodeDigitsAreRejected() {
        let values = [0, 1234, 8191]
        #expect(DevicePairingSession.matches("0000 1234 8191", decimals: values))
        #expect(DevicePairingSession.matches("0000-1234-8191", decimals: values))
        for code in ["1234", "0000 1234", "0000 1234 8190", "００００１２３４８１９１", "0000a12348191"] {
            #expect(!DevicePairingSession.matches(code, decimals: values))
        }
    }

    @Test func maliciousRelayCannotSubstituteTheOfferedAgreementKey() async throws {
        let f = try await PairingTestDevices.make()
        f.relay.tamper = { $0.offer?.payload = "{\"kind\":\"Accept\",\"key\":\"substituted\"}" }
        await f.new.poll()
        #expect(f.new.stopped && f.new.failure != nil && f.new.approval == nil && f.newIdentity.device == nil)
        f.old.stop()
    }

    @Test func maliciousRelayCannotReplaceThePinnedRequestOrApprover() async throws {
        let f = try await PairingTestDevices.make()
        f.relay.tamper = { state in
            state.offer?.issuer.accountKey = V5Crypto.random().base64EncodedString()
        }
        await f.new.poll()
        #expect(f.new.stopped && f.new.approval == nil)
        f.old.stop()
    }

    @Test func reflectedConfirmationIsRejectedEvenWithAValidSignature() async throws {
        let f = try await PairingTestDevices.make()
        try await f.handshake()
        await f.new.confirmNewDevice()
        var reflected = try #require(f.relay.state?.newConfirmation)
        reflected.action = "old-confirm"
        reflected.signature = try f.oldIdentity.signIdentityMessage(reflected.message)
        // The envelope really is signed by the expected old device. Only the
        // native responder-role MAC check can reject the reflected payload.
        try reflected.validate(request: f.new.request, expectedAction: "old-confirm")
        f.relay.tamper = { $0.oldConfirmation = reflected }
        await f.new.poll()
        #expect(f.new.stopped && f.new.approval == nil)
        f.old.stop()
    }

    @Test(arguments: ["offer", "reveal", "new-confirm", "old-confirm", "approve"])
    func responseLossRetriesImmutableMessagesWithoutRestartingSAS(_ phase: String) async throws {
        let f = try await PairingTestDevices.make(lostResponseFor: phase)
        await f.new.poll(); await f.new.poll(); await f.old.poll(); await f.old.poll()
        #expect(f.new.decimals == f.old.decimals && f.new.failure == nil)
        await f.old.approve(enteredCode: f.new.safetyCode, canEnroll: false)
        await f.new.poll(); await f.new.confirmNewDevice()
        await f.old.poll(); await f.old.poll(); await f.new.poll(); await f.new.poll()
        #expect(f.new.completed && f.old.completed && f.new.failure == nil && f.old.failure == nil)
    }

    @Test func accountScopeChangesStopSigningAndAuthorization() async throws {
        let f = try await PairingTestDevices.make()
        try await f.handshake()
        try f.oldIdentity.select(origin: f.old.request.origin, accountID: "different-member")
        await f.old.approve(enteredCode: f.new.safetyCode, canEnroll: true)
        #expect(f.old.stopped && f.relay.authorizationChecks == 0 && f.relay.state?.approval == nil)
        f.new.stop()
    }

    @Test func PNGExportRoundTripsLocallyAndContainsOnlyTheSignedPublicRequest() async throws {
        let f = try await PairingTestDevices.make()
        let png = try DevicePairingImages.png(request: f.new.request)
        let decoded = try DevicePairingImages.request(fromImage: png)
        #expect(decoded == f.new.request)
        #expect(decoded.digest == f.new.request.digest && decoded.deviceKey == f.new.request.deviceKey)
        #expect(!png.isEmpty && png.count < DevicePairingImages.maxBytes)
        f.new.stop(); f.old.stop()
    }

    @Test(arguments: [UTType.jpeg, .heic, .gif, .tiff])
    func imageImportDecodesTranscodedQR(_ type: UTType) async throws {
        let f = try await PairingTestDevices.make()
        defer { f.new.stop(); f.old.stop() }
        let png = try DevicePairingImages.png(request: f.new.request)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try (encoded as Data).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try DevicePairingImages.request(fromImage: url) == f.new.request)
    }

    @Test func imageImportRejectsInvalidAndOversizedInputs() {
        #expect(throws: (any Error).self) { try DevicePairingImages.request(fromImage: Data("not an image".utf8)) }
        #expect(throws: (any Error).self) { try DevicePairingImages.request(fromImage: Data(repeating: 0, count: DevicePairingImages.maxBytes + 1)) }
    }

    @Test func substitutedValidPNGStillRequiresTheRealNewDevicesCode() async throws {
        let real = try await PairingTestDevices.make()
        try await real.handshake()
        let relay = PairingTestRelay()
        let candidate = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
        try candidate.select(origin: real.new.request.origin, accountID: real.new.request.accountID)
        let auth = AuthenticatedIdentitySetup(token: "attacker_setup", accountID: real.new.request.accountID, username: "Pairing",
            origin: real.new.request.origin, accountKey: real.new.request.accountKey, expiresAt: Int64(Date().timeIntervalSince1970) + 300)
        let post: DevicePairingSession.Transport = { path, data in try await relay.post(path, data) }
        let attacker = try await DevicePairingSession.newDevice(identity: candidate, authentication: auth, verifier: "fixture", connection: testServerConnection, requireClock: relay.requireClock, transport: post)
        let substituted = try DevicePairingImages.request(fromImage: DevicePairingImages.png(request: attacker.request))
        let old = try await DevicePairingSession.approvingDevice(code: substituted.code, identity: real.oldIdentity,
            connection: testServerConnection, importedImage: true, requireClock: relay.requireClock, transport: post, authorize: { relay.authorizationChecks += 1 })
        await attacker.poll(); await old.poll()
        #expect(old.decimals.count == 3 && old.safetyCode != real.new.safetyCode)
        await old.approve(enteredCode: real.new.safetyCode, canEnroll: true)
        #expect(!old.localConfirmed && relay.authorizationChecks == 0 && relay.state?.approval == nil)
        old.stop(); attacker.stop(); real.old.stop(); real.new.stop()
    }

    @Test func aValidFakeRootAndFakeApproverCannotReplaceTheUsersLocalConfirmation() async throws {
        let relay = PairingTestRelay(), origin = ServerAddress.identityOrigin(testServerConnection.passkeyOrigin), account = "member_root_attack"
        let honest = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
        let fake = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
        let candidate = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
        for value in [honest, fake, candidate] { try value.select(origin: origin, accountID: account) }
        _ = try honest.makeCandidate(rootSeed: V5Crypto.random()); try honest.markBound()
        let fakeDevice = try fake.makeCandidate(rootSeed: V5Crypto.random()); try fake.markBound()
        let auth = AuthenticatedIdentitySetup(token: "compromised_server_setup", accountID: account, username: "Victim", origin: origin,
            accountKey: fakeDevice.accountKey, expiresAt: Int64(Date().timeIntervalSince1970) + 300)
        let post: DevicePairingSession.Transport = { path, data in try await relay.post(path, data) }
        let new = try await DevicePairingSession.newDevice(identity: candidate, authentication: auth, verifier: "fixture", connection: testServerConnection, requireClock: relay.requireClock, transport: post)
        do {
            _ = try await DevicePairingSession.approvingDevice(code: new.request.code, identity: honest, connection: testServerConnection,
                importedImage: false, requireClock: relay.requireClock, transport: post, authorize: {})
            Issue.record("Honest old device accepted a substituted account root")
        } catch {}
        let attacker = try await DevicePairingSession.approvingDevice(code: new.request.code, identity: fake,
            connection: testServerConnection, importedImage: true, requireClock: relay.requireClock, transport: post, authorize: {})
        await new.poll(); await attacker.poll()
        await attacker.approve(enteredCode: new.safetyCode, canEnroll: true)
        await new.poll()
        #expect(new.peerConfirmed && !new.localConfirmed && !new.completed && candidate.device == nil)
        #expect(relay.state?.approval == nil)
        new.stop(); attacker.stop()
    }

    @Test func PNGRejectsExcessPixelsAmbiguousCodesAndForeignURLs() async throws {
        func encode(_ image: CIImage) throws -> Data {
            let cg = try #require(CIContext().createCGImage(image, from: image.extent))
            let result = NSMutableData()
            let out = try #require(CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(out, cg, nil); #expect(CGImageDestinationFinalize(out))
            return result as Data
        }
        let oversized = try encode(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 4097, height: 1)))
        #expect(throws: (any Error).self) { try DevicePairingImages.request(fromImage: oversized) }
        let blank = try encode(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)))
        #expect(throws: (any Error).self) { try DevicePairingImages.request(fromImage: blank) }
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data("https://evil.test/approve".utf8)
        let qr = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 5, y: 5))
        let foreign = try encode(qr.composited(over: CIImage(color: .white).cropped(to: qr.extent.insetBy(dx: -20, dy: -20))))
        #expect(throws: (any Error).self) { try DevicePairingImages.request(fromImage: foreign) }
        let shifted = qr.transformed(by: CGAffineTransform(translationX: qr.extent.width + 80, y: 0))
        let extent = qr.extent.union(shifted.extent).insetBy(dx: -20, dy: -20)
        let both = try encode(shifted.composited(over: qr.composited(over: CIImage(color: .white).cropped(to: extent))))
        #expect(throws: (any Error).self) { try DevicePairingImages.request(fromImage: both) }
    }

    // Public fixed vector generated by Go, independently verified by CryptoKit.
    @Test func goAndSwiftAgreeOnPairingSignaturesAndFramedMessages() throws {
        struct Vector: Decodable {
            let request: DevicePairingRequest
            let action: DevicePairingAction
            let context: String
            let request_message: String
            let request_digest: String
            let action_message: String
        }
        let data = Data(#"""
        {
          "action": {
            "request_id": "95ntCkmuHLj4sa5f1RIjdkLyD3fo92MxS9JOzwalQjM=",
            "action": "reveal",
            "issuer": {
              "account_key": "",
              "certificates": []
            },
            "payload": "{\"kind\":\"Key\",\"key\":\"ephemeral-public-key\"}",
            "nonce": "lHOvsP4aYV/DJ21GkVFaG8YMO2h553X7JTH4VZwLrMU=",
            "created_at": 1700000001,
            "signature": "xkTHDPPXpnj41jb4HCLa20mpK/tCVuGSIgOTZe2BkvQb1pg7HeNwCiblYCy4DMbNYIwuvVQtiGV49GB50Z0sBw=="
          },
          "action_message": "AAAAHkNoaXJwIGRldmljZSBwYWlyaW5nIGFjdGlvbiB2MQAAACw5NW50Q2ttdUhMajRzYTVmMVJJamRrTHlEM2ZvOTJNeFM5Sk96d2FsUWpNPQAAAAZyZXZlYWwAAAAsQ3lReGM4ZlBTbjJoMGw0NFVjVXQyZW83QVhaVzRzRUxUWlRpekQveHkvbz0AAAAsL0ZHeFdMTkhDVHZJeW16UnBFWmNWblhINU1weVNhTFZLNnFzZUE5eXVQZz0AAAAsbEhPdnNQNGFZVi9ESjIxR2tWRmFHOFlNTzJoNTUzWDdKVEg0Vlp3THJNVT0AAAAKMTcwMDAwMDAwMQ==",
          "context": "F5gSGU5uZOP3zQ6T1ZspgYI2c/P44iqMKC/ABT40RDo=",
          "request": {
            "version": 1,
            "origin": "https://fixture.test:443",
            "account_id": "member_pairing_vector",
            "account_key": "hxPdfTQBFuM3xJzs0LZ/Oyl6sxB05ehHQksJ14Y54Yg=",
            "device_key": "E4vu+vYZ9/Mbjvi0gyXDe7UzT1YkE6WRJ/LihCdSmo8=",
            "nonce": "tDCOViQ/jOnJ51sKy65LEh/3j8ke/wze4UuCVJj1/aE=",
            "expires_at": 1700000297,
            "commitment": "LUuDyLZtdq8yur/TkrPO/5Jbi7OB7WFUQFWaAMP5nMw=",
            "signature": "cqUKYZKIEj+HUn+u21bQxcLSRUgyxcM+ZsMv+sKDdsByJgRZE6Cq6ViGMx9AIKLovCdbAjq5OVHoxxQuHc1sDg=="
          },
          "request_digest": "95ntCkmuHLj4sa5f1RIjdkLyD3fo92MxS9JOzwalQjM=",
          "request_message": "AAAAH0NoaXJwIGRldmljZSBwYWlyaW5nIHJlcXVlc3QgdjEAAAAsRjVnU0dVNXVaT1AzelE2VDFac3BnWUkyYy9QNDRpcU1LQy9BQlQ0MFJEbz0AAAAsTFV1RHlMWnRkcTh5dXIvVGtyUE8vNUpiaTdPQjdXRlVRRldhQU1QNW5Ndz0="
        }
        """#.utf8)
        let value = try JSONDecoder().decode(Vector.self, from: data)
        try value.request.validate(now: 1_700_000_010)
        try value.action.validate(request: value.request, expectedAction: "reveal", now: 1_700_000_010)
        #expect(value.request.context == value.context && value.request.digest == value.request_digest)
        #expect(value.request.message.base64EncodedString() == value.request_message)
        #expect(value.action.message.base64EncodedString() == value.action_message)
    }

}
