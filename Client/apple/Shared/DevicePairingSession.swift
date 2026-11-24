import ChirpMLS
import Foundation
import LocalAuthentication
import Observation

/// The relay never decides whether an identity is trusted. Both native clients
/// verify the signed transcript and the full vodozemac SAS with key confirmation.
@MainActor @Observable
final class DevicePairingSession: Identifiable {
    nonisolated let id = UUID()
    enum Role: Equatable { case newDevice, approvingDevice(importedImage: Bool) }
    typealias Transport = @MainActor (String, Data) async throws -> DevicePairingState

    let role: Role
    let request: DevicePairingRequest
    private(set) var decimals: [Int] = []
    private(set) var localConfirmed = false
    private(set) var peerConfirmed = false
    private(set) var completed = false
    private(set) var stopped = false
    private(set) var isConfirming = false
    private(set) var failure: String?
    private(set) var approval: DevicePairingApproval?
    private(set) var issuer = V5Device(accountKey: "", certificates: [])
    private let identity: DeviceIdentityStore
    private let scope: String
    private let native: MLSClient
    private let transport: Transport
    private let requireClock: @MainActor () throws -> Void
    private let authorize: @MainActor () async throws -> Void
    private let deadline: ContinuousClock.Instant
    @ObservationIgnored private var isPolling = false
    private var outbox: [DevicePairingAction] = []
    private var receivedOffer: DevicePairingAction?
    private var receivedReveal: DevicePairingAction?
    private var receivedMAC: DevicePairingAction?
    private var cryptographicComplete = false
    private var approvalRequested = false
    private var approvalQueued = false
    private var permitEnrollment = true
    private var mismatches = 0
    private var transientFailure = false

    var safetyCode: String { decimals.map { String(format: "%04d", $0) }.joined(separator: " ") }
    var importedImage: Bool { role == .approvingDevice(importedImage: true) }
    var canConfirm: Bool { decimals.count == 3 && !localConfirmed && active && !isConfirming }
    var active: Bool { !completed && !stopped }

    private init(role: Role, request: DevicePairingRequest, identity: DeviceIdentityStore, native: MLSClient,
                 transport: @escaping Transport, requireClock: @escaping @MainActor () throws -> Void,
                 authorize: (@MainActor () async throws -> Void)?) {
        self.role = role; self.request = request; self.identity = identity; scope = identity.currentScope
        self.native = native; self.transport = transport
        self.requireClock = requireClock
        self.authorize = authorize ?? { try await Self.authenticateLocal() }
        deadline = .now.advanced(by: .seconds(max(0, min(300, request.expirationDate.timeIntervalSinceNow))))
    }

    static func newDevice(identity: DeviceIdentityStore, authentication: AuthenticatedIdentitySetup, verifier: String,
                          connection: ServerConnection, requireClock: @escaping @MainActor () throws -> Void, configuration: URLSessionConfiguration? = nil,
                          transport: Transport? = nil) async throws -> DevicePairingSession {
        ClientLog.shared.record(.identity, "newDevicePairing")
        try requireClock()
        let scope = identity.currentScope
        let key = try identity.preparePairingKey()
        var request = DevicePairingRequest(origin: authentication.origin, accountID: authentication.accountID,
            accountKey: authentication.accountKey, deviceKey: key, nonce: V5Crypto.random().base64EncodedString(),
            expiresAt: min(authentication.expiresAt - 3, Int64(Date().timeIntervalSince1970) + 297))
        guard request.expiresAt > Int64(Date().timeIntervalSince1970) + 10 else { throw DevicePairingError.expired }
        let native = try MLSClient(identity: "device-pairing-" + UUID().uuidString)
        let result = try await security(native, ["action": "sas_start", "id": request.nonce, "context": request.context])
        try requireClock()
        guard let message = result.message,
              let packet = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: String],
              let commitment = packet["commitment"], packet["kind"] == "Request", identity.currentScope == scope else { throw V5IdentityError.invalid }
        request.commitment = commitment; request.signature = try identity.signIdentityMessage(request.message)
        try request.validate()
        let post: Transport = transport ?? { path, body in
            try await IdentitySetupAPI.post(path, connection: connection, body: body, configuration: configuration)
        }
        let session = DevicePairingSession(role: .newDevice, request: request, identity: identity, native: native,
                                          transport: post, requireClock: requireClock, authorize: nil)
        struct Start: Encodable { let setup_token: String; let code_verifier: String; let request: DevicePairingRequest }
        let state = try await post("api/client/identity/pairing/start", JSONEncoder().encode(Start(setup_token: authentication.token, code_verifier: verifier, request: request)))
        try session.checkActive(); try await session.receive(state)
        return session
    }

    static func approvingDevice(code: String, identity: DeviceIdentityStore, connection: ServerConnection, importedImage: Bool,
                                requireClock: @escaping @MainActor () throws -> Void, configuration: URLSessionConfiguration? = nil, transport: Transport? = nil,
                                authorize: (@MainActor () async throws -> Void)? = nil) async throws -> DevicePairingSession {
        ClientLog.shared.record(.identity, "openPairingRequest")
        try requireClock()
        let request = try DevicePairingRequest.parse(code), issuer = try identity.requireDevice()
        guard request.origin == ServerAddress.identityOrigin(connection.passkeyOrigin),
              identity.currentScope == request.origin + "|" + request.accountID,
              issuer.accountKey == request.accountKey, issuer.certificates.last?.canEnroll == true,
              issuer.certificates.count < V5Crypto.maxChain, issuer.leafKey != request.deviceKey else { throw V5IdentityError.untrusted }
        let native = try MLSClient(identity: "device-pairing-" + UUID().uuidString)
        let result = try await security(native, ["action": "sas_accept", "id": request.nonce, "context": request.context, "commitment": request.commitment])
        try requireClock()
        guard let message = result.message else { throw V5IdentityError.invalid }
        let post: Transport = transport ?? { path, body in
            try await IdentitySetupAPI.post(path, connection: connection, body: body, configuration: configuration)
        }
        let session = DevicePairingSession(role: .approvingDevice(importedImage: importedImage), request: request,
            identity: identity, native: native, transport: post, requireClock: requireClock, authorize: authorize)
        session.issuer = issuer
        try session.enqueue("offer", payload: message)
        do { try await session.flush() }
        catch {
            if Task.isCancelled {
                session.stop()
                throw CancellationError()
            }
            guard let networkError = error as? URLError else { throw error }
            session.failure = networkError.localizedDescription
            session.transientFailure = true
        }
        return session
    }

    func poll() async {
        guard active, !isPolling, !isConfirming else { return }
        isPolling = true; defer { isPolling = false }
        do {
            try checkActive(); try await flush()
            guard active else { return }
            let action = try signedAction(role == .newDevice ? "poll-new" : "poll-old")
            let state = try await transport("api/client/identity/pairing/action", JSONEncoder().encode(action))
            try checkActive(); try await receive(state); try await flush()
            if transientFailure { failure = nil; transientFailure = false }
        } catch { handle(error) }
    }

    // New-device confirmation is essential: a fresh device must not accept a
    // replacement root supplied by a malicious server, even with valid signatures.
    func confirmNewDevice() async {
        ClientLog.shared.record(.identity, "confirmNewDevice")
        guard role == .newDevice, canConfirm else { return }
        isConfirming = true; defer { isConfirming = false }
        guard await waitForPoll() else { return }
        do { try checkActive(); try await confirm(); try await flush(); failure = nil }
        catch { handle(error) }
    }

    func approve(enteredCode: String, canEnroll: Bool) async {
        ClientLog.shared.record(.identity, "approveDevice")
        guard role != .newDevice, canConfirm else { return }
        isConfirming = true; defer { isConfirming = false }
        guard await waitForPoll() else { return }
        if importedImage && !Self.matches(enteredCode, decimals: decimals) {
            mismatches += 1; failure = DevicePairingError.codeMismatch.localizedDescription
            if mismatches >= 3 { stop() }
            return
        }
        do {
            try checkActive(); try await authorize(); try checkActive()
            approvalRequested = true; permitEnrollment = canEnroll
            try await confirm(); try await flush(); failure = nil
        } catch { handle(error) }
    }

    static func matches(_ text: String, decimals: [Int]) -> Bool {
        guard decimals.count == 3, text.utf8.allSatisfy({ (48...57).contains($0) || [9, 10, 13, 32, 45].contains($0) }) else { return false }
        let digits = text.utf8.filter { (48...57).contains($0) }
        return digits.count == 12 && String(decoding: digits, as: UTF8.self) == decimals.map { String(format: "%04d", $0) }.joined()
    }

    private func waitForPoll() async -> Bool {
        while isPolling && active {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return active && !Task.isCancelled
    }

    func stopAtExpiration() async {
        do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
        handle(DevicePairingError.expired)
    }

    func stop() {
        ClientLog.shared.record(.identity, "stopPairing")
        guard !stopped, !completed else { return }
        // Cancellation is best effort; expiry and local teardown are mandatory.
        let action = identity.currentScope == scope ? try? signedAction(role == .newDevice ? "cancel-new" : "cancel-old") : nil
        stopped = true; outbox.removeAll(); decimals.removeAll()
        let transport = transport, native = native
        Task {
            if let action { _ = try? await transport("api/client/identity/pairing/action", JSONEncoder().encode(action)) }
            try? await native.clear()
        }
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        try requireClock()
        guard !stopped, identity.currentScope == scope, scope == request.origin + "|" + request.accountID else { throw DevicePairingError.scopeChanged }
        let now = Int64(Date().timeIntervalSince1970)
        guard ContinuousClock.now < deadline, now < request.expiresAt else { throw DevicePairingError.expired }
        try request.validate(now: now)
    }

    private func signedAction(_ kind: String, payload: String = "") throws -> DevicePairingAction {
        var action = DevicePairingAction(requestID: request.digest, action: kind, issuer: issuer, payload: payload)
        action.signature = try identity.signIdentityMessage(action.message)
        return action
    }

    private func enqueue(_ kind: String, payload: String) throws { outbox.append(try signedAction(kind, payload: payload)) }

    private func flush() async throws {
        while let action = outbox.first, active {
            try checkActive()
            let state = try await transport("api/client/identity/pairing/action", JSONEncoder().encode(action))
            try checkActive(); outbox.removeFirst()
            try await receive(state)
        }
    }

    private func receive(_ state: DevicePairingState) async throws {
        try checkActive()
        guard state.request == request else { throw V5IdentityError.changed }
        try state.validate(expected: request)
        if state.cancelled { throw DevicePairingError.cancelled }
        if let offer = state.offer {
            if issuer.leafKey.isEmpty { issuer = offer.issuer }
            guard offer.issuer == issuer else { throw V5IdentityError.changed }
            if role == .newDevice {
                if let receivedOffer { guard receivedOffer == offer else { throw V5IdentityError.changed } }
                else {
                    let result = try await Self.security(native, ["action": "sas_receive", "id": request.nonce, "message": offer.payload])
                    try checkActive(); receivedOffer = offer; try accept(result)
                    guard let reveal = result.message else { throw V5IdentityError.invalid }
                    try enqueue("reveal", payload: reveal)
                }
            }
        }
        if role != .newDevice, let reveal = state.reveal {
            if let receivedReveal { guard receivedReveal == reveal else { throw V5IdentityError.changed } }
            else {
                let result = try await Self.security(native, ["action": "sas_receive", "id": request.nonce, "message": reveal.payload])
                try checkActive(); receivedReveal = reveal; try accept(result)
            }
        }
        let peerMAC = role == .newDevice ? state.oldConfirmation : state.newConfirmation
        if let peerMAC {
            if let receivedMAC { guard receivedMAC == peerMAC else { throw V5IdentityError.changed } }
            else {
                let result = try await Self.security(native, ["action": "sas_receive", "id": request.nonce, "message": peerMAC.payload])
                try checkActive(); receivedMAC = peerMAC; try accept(result); peerConfirmed = true
            }
        }
        try issueIfVerified()
        if let signed = state.approval {
            guard cryptographicComplete, localConfirmed, peerConfirmed else { throw V5IdentityError.untrusted }
            let value = try JSONDecoder().decode(DevicePairingApproval.self, from: Data(signed.payload.utf8))
            try value.validate(request: request, issuer: issuer)
            approval = value; completed = true; failure = nil; transientFailure = false
            try? await native.clear()
        }
    }

    private func confirm() async throws {
        let result = try await Self.security(native, ["action": "sas_confirm", "id": request.nonce])
        try checkActive(); try accept(result)
        guard let message = result.message else { throw V5IdentityError.invalid }
        localConfirmed = true
        try enqueue(role == .newDevice ? "new-confirm" : "old-confirm", payload: message)
        try issueIfVerified()
    }

    private func issueIfVerified() throws {
        guard role != .newDevice, cryptographicComplete, localConfirmed, peerConfirmed, approvalRequested, !approvalQueued else { return }
        let device = try identity.issuePairedDevice(request, issuer: issuer, canEnroll: permitEnrollment)
        let value = DevicePairingApproval(device: device)
        try enqueue("approve", payload: String(decoding: JSONEncoder().encode(value), as: UTF8.self))
        approvalQueued = true
    }

    private func accept(_ result: SecurityResult) throws {
        if result.cancelled == true { throw DevicePairingError.cancelled }
        if let values = result.decimals {
            guard values.count == 3, values.allSatisfy({ (1000...9191).contains($0) }), decimals.isEmpty || decimals == values else { throw V5IdentityError.invalid }
            decimals = values
        }
        if result.complete == true { cryptographicComplete = true }
    }

    private func handle(_ error: Error) {
        ClientLog.shared.record(.identity, "devicePairing", outcome: .failed, failure: ClientFailure.capture(error))
        guard active, !(error is CancellationError) else { return }
        failure = error.localizedDescription
        // A lost HTTP response may already have committed the immutable message.
        // Keep the outbox for an exact retry; protocol errors fail closed.
        if error is URLError { transientFailure = true; return }
        if (error as? LAError)?.code == .userCancel { return }
        stop()
    }

    private struct SecurityResult: Decodable {
        let message: String?
        let decimals: [Int]?
        let complete: Bool?
        let cancelled: Bool?
    }
    private static func security(_ native: MLSClient, _ parameters: [String: String]) async throws -> SecurityResult {
        try JSONDecoder().decode(SecurityResult.self, from: await native.security(parameters))
    }
    private static func authenticateLocal() async throws {
        let context = LAContext()
        let reason: LocalizedMessage = "批准新设备访问此账号。请仅授权您本人持有的设备。"
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason.localized(in: AppLanguage.load().locale)) else {
            throw LAError(.authenticationFailed)
        }
    }

    #if DEBUG
    /// Offline visual fixture; it has no server or production identity and
    /// cannot complete an authorization.
    static func designPreview(identity: DeviceIdentityStore, authentication: AuthenticatedIdentitySetup) async throws -> DevicePairingSession {
        let key = try identity.preparePairingKey()
        var request = DevicePairingRequest(origin: authentication.origin, accountID: authentication.accountID,
            accountKey: authentication.accountKey, deviceKey: key, nonce: V5Crypto.random().base64EncodedString(),
            expiresAt: Int64(Date().timeIntervalSince1970) + 297)
        let native = try MLSClient(identity: "pairing-preview-" + UUID().uuidString)
        let result = try await security(native, ["action": "sas_start", "id": request.nonce, "context": request.context])
        guard let message = result.message,
              let packet = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: String],
              let commitment = packet["commitment"] else { throw V5IdentityError.invalid }
        request.commitment = commitment; request.signature = try identity.signIdentityMessage(request.message)
        let snapshot = DevicePairingState(request: request)
        return DevicePairingSession(role: .newDevice, request: request, identity: identity, native: native,
            transport: { _, _ in snapshot }, requireClock: {}, authorize: nil)
    }
    #endif
}
