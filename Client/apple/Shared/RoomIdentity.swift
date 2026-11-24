import ChirpMLS
import Foundation
import Observation

struct IdentitySignal: Codable, Sendable {
    let id: String
    let origin: String
    let roomID: String
    let sender: String
    let recipient: String
    let senderEntry: String
    let recipientEntry: String
    let kind: String
    let payload: String
    let expiresAt: Int64
    let device: V5Device
    var signature = ""
    var message: Data { V5Crypto.message("Chirp identity signal v5", [id, origin, roomID, sender, recipient, senderEntry, recipientEntry, kind, payload, String(expiresAt), device.digest]) }
    enum CodingKeys: String, CodingKey { case id, origin, roomID = "room_id", sender, recipient, senderEntry = "sender_entry", recipientEntry = "recipient_entry", kind, payload, expiresAt = "expires_at", device, signature }
}
struct RoutedIdentitySignal: Decodable, Sendable { let sequence: Int64; let signal: IdentitySignal }
private struct MutualTrustStatement: Codable { let roster: String; let version: Int64; let trustedKeys: [String] }
struct SASVerification: Identifiable {
    let id: String
    let peer: MLSPeer
    let initiator: String
    let commitment: String?
    var accepted = false
    var decimals: [Int] = []
    var confirmed = false

    var awaitingPeerAcceptance: Bool { initiator != peer.identity && decimals.isEmpty }
}

/// Keeps the explanation and result visible independently of the cryptographic transaction.
struct SASVerificationPresentation: Identifiable {
    enum EndReason: Equatable { case cancelled, mismatch, peerCancelled, peerBusy, roomChanged, timedOut, failed(String) }
    enum Phase: Equatable { case preparation, active, savingTrust, trustPending, completed, ended(EndReason) }
    let id = UUID()
    let peer: MLSPeer
    var transaction: String?
    var phase: Phase = .preparation
}

@MainActor @Observable
final class RoomIdentity {
    enum VoiceTrust: Equatable { case solo, pending, rebuilding, trusted, stopped }
    typealias Security = @MainActor @Sendable (MLSClient, [String: String]) async throws -> Data
    private let identity: DeviceIdentityStore
    private let configuration: URLSessionConfiguration?
    private let security: Security
    let social: SocialIdentity
    private var login: ClientSession?
    private var admission: RoomAdmission?
    private var api: APIClient?
    private var roster: [MLSPeer] = []
    private var rosterDigest = ""
    private var statements: [String: (MutualTrustStatement, Int64)] = [:]
    private var task: Task<Void, Never>?
    private var native: MLSClient?
    private var lifetime = UUID()
    private var seenSignals: Set<String> = []
    private var observedSocialRevision: UInt64 = 0
    private var syncRequested = false
    private var pollDelay: Task<Void, Never>?
    private var fastPollUntil = ContinuousClock.Instant.now
    private var trustedRoster = ""
    private let verificationTimeout: Duration
    private var verificationTimer: Task<Void, Never>?
    private(set) var trust: VoiceTrust = .solo
    private(set) var verification: SASVerification?
    private(set) var verificationPresentation: SASVerificationPresentation?
    private(set) var failure: String?
    var onStop: (@MainActor (ClientFailure) -> Void)?
    var onMute: (@MainActor () -> Void)?
    var onChange: (@MainActor () -> Void)?
    init(identity: DeviceIdentityStore, social: SocialIdentity, configuration: URLSessionConfiguration? = nil,
         verificationTimeout: Duration = .seconds(120),
         security: Security? = nil) {
        self.identity = identity; self.social = social; self.configuration = configuration
        self.verificationTimeout = verificationTimeout
        self.security = security ?? { native, parameters in try await native.security(parameters) }
    }
    func begin(login: ClientSession, admission: RoomAdmission) {
        end(); self.login = login; self.admission = admission
        do { native = try MLSClient(identity: "sas-" + admission.entryID) }
        catch { failure = error.localizedDescription; onStop?(ClientFailure(.groupCryptoFailed)); return }
        let lifetime = self.lifetime
        let api = APIClient(baseURL: login.connection.apiURL, credential: login.credential, configuration: configuration)
        self.api = api
        observedSocialRevision = social.revision
        task = Task { [weak self] in
            var after: Int64 = 0
            var sentRoster = "", sentRevision: UInt64?
            var nextBroadcast = ContinuousClock.now
            var networkInterrupted = false
            while !Task.isCancelled {
                guard let self, self.lifetime == lifetime else { return }
                syncRequested = false
                do {
                    if roster.count > 1 {
                        let signals = try await api.identitySignals(after: after)
                        guard self.lifetime == lifetime, !Task.isCancelled else { return }
                        if networkInterrupted { networkInterrupted = false; await social.refresh() }
                        for routed in signals {
                            guard self.lifetime == lifetime, !Task.isCancelled else { return }
                            after = max(after, routed.sequence); try await receive(routed.signal)
                        }
                        guard self.lifetime == lifetime, !Task.isCancelled else { return }
                        let digest = rosterDigest, revision = social.revision
                        if digest != sentRoster || revision != sentRevision || .now >= nextBroadcast {
                            try await broadcastTrust()
                            guard self.lifetime == lifetime, !Task.isCancelled else { return }
                            sentRoster = digest; sentRevision = revision
                            nextBroadcast = .now.advanced(by: .seconds(10))
                        }
                    }
                } catch {
                    if Task.isCancelled || self.lifetime != lifetime { return }
                    failure = error.localizedDescription
                    // A rejected SAS packet does not constitute a transport reconnection.
                    if Self.isConnectionFailure(error) { networkInterrupted = true }
                }
                guard self.lifetime == lifetime, !Task.isCancelled else { return }
                evaluate()
                guard self.lifetime == lifetime, !Task.isCancelled else { return }
                if syncRequested { continue }
                let fastPoll = !networkInterrupted && trust == .pending && .now < fastPollUntil
                let delay = Task<Void, Never> { try? await Task.sleep(for: fastPoll ? .milliseconds(200) : .seconds(1)) }
                pollDelay = delay
                await delay.value
                guard self.lifetime == lifetime else { return }
                pollDelay = nil
            }
        }
    }
    func end() {
        lifetime = UUID(); task?.cancel(); task = nil; pollDelay?.cancel(); pollDelay = nil; api?.close(); api = nil
        verificationTimer?.cancel(); verificationTimer = nil; native = nil; login = nil; admission = nil
        roster = []; rosterDigest = ""; statements = [:]; seenSignals = []; verification = nil; verificationPresentation = nil
        trust = .solo; trustedRoster = ""; failure = nil; onChange?()
    }
    private func requestSignalSync() {
        syncRequested = true
        fastPollUntil = .now.advanced(by: .seconds(2))
        pollDelay?.cancel()
    }
    func updateRoster(_ peers: [MLSPeer], reconnected: Bool = false) throws {
        guard let login else { return }
        for peer in peers {
            guard let binding = peer.binding, !social.blocked(accountID: MemberProfile.memberID(for: peer.identity), device: binding.device) else { throw IdentitySetupError.invalid("房间包含已撤销的身份。") }
            try binding.device.validate()
        }
        guard peers.contains(where: { $0.binding?.device == login.deviceIdentity }) else { throw V5IdentityError.wrongDevice }
        if roster != peers {
            roster = peers; social.observe(peers)
            let digest = V5Crypto.hash(V5Crypto.message("Chirp mutual trust roster v5", peers.compactMap { $0.binding?.digest }.sorted()))
            if digest != rosterDigest {
                rosterDigest = digest; statements = [:]; cancelVerification(reason: .roomChanged); trustedRoster = ""
                if verificationPresentation?.phase == .preparation { verificationPresentation?.phase = .ended(.roomChanged) }
                requestSignalSync()
            }
        }
        evaluate()
    }
    func approveRoster(_ peers: [MLSPeer]) throws -> String? {
        try updateRoster(peers)
        guard social.voiceAllowed, peers.allSatisfy({ $0.binding.map { social.deviceAuthorized($0.device) } == true }),
              peers.count == 1 || allMutuallyTrusted else { return nil }
        return try social.authorizationHash(for: peers)
    }
    func keysReady() throws {
        guard social.voiceAllowed, roster.count == 1 || allMutuallyTrusted else { throw V5IdentityError.untrusted }
        trustedRoster = rosterDigest; evaluate()
    }
    func localTrustChanged() {
        if login != nil, observedSocialRevision != social.revision {
            observedSocialRevision = social.revision
            if roster.count > 1 { requestSignalSync() }
        }
        evaluate()
    }
    static func isConnectionFailure(_ error: any Error) -> Bool {
        let issue = ClientFailure.capture(error)
        return [ClientErrorCode.networkUnavailable.rawValue, ClientErrorCode.networkTimeout.rawValue, ClientErrorCode.networkFailure.rawValue].contains(issue.code)
            || issue.httpStatus.map { $0 >= 500 } == true
    }
    private func locallyTrusted(_ peer: MLSPeer) -> Bool {
        guard let device = peer.binding?.device else { return false }
        if peer.identity == admission?.identity { return true }
        return social.trusts(accountID: MemberProfile.memberID(for: peer.identity), device: device)
    }
    private var allMutuallyTrusted: Bool {
        guard roster.count > 1, roster.allSatisfy(locallyTrusted), let admission else { return false }
        let keys = Set(roster.compactMap { $0.binding?.device.leafKey })
        return roster.filter { $0.identity != admission.identity }.allSatisfy { peer in
            guard let (statement, expires) = statements[peer.identity], expires > Int64(Date().timeIntervalSince1970), statement.roster == rosterDigest else { return false }
            return keys.isSubset(of: Set(statement.trustedKeys))
        }
    }
    private func evaluate() {
        guard login != nil else { return }
        if let presentation = verificationPresentation, presentation.phase == .trustPending,
           let device = presentation.peer.binding?.device,
           social.trusts(accountID: MemberProfile.memberID(for: presentation.peer.identity), device: device) {
            verificationPresentation?.phase = .completed
        }
        let previous = trust
        if !social.voiceAllowed { trust = .stopped; onMute?(); onStop?(ClientFailure(.authorizationStale)); onChange?(); return }
        for peer in roster { if let d = peer.binding?.device, social.blocked(accountID: MemberProfile.memberID(for: peer.identity), device: d) { trust = .stopped; onMute?(); onStop?(ClientFailure(.identityBlacklisted)); onChange?(); return } }
        if roster.count <= 1 { trust = .solo }
        else if allMutuallyTrusted {
            trust = trustedRoster == rosterDigest ? .trusted : .rebuilding
        } else {
            // Waiting is a control-only state. It has no microphone/chat exception.
            trust = .pending; trustedRoster = ""
        }
        if previous != trust && trust != .trusted && trust != .solo { onMute?() }
        onChange?()
    }
    private func broadcastTrust() async throws {
        guard let admission else { return }
        let lifetime = self.lifetime, digest = rosterDigest
        let statement = MutualTrustStatement(roster: rosterDigest, version: social.socialVersion, trustedKeys: roster.filter(locallyTrusted).compactMap { $0.binding?.device.leafKey }.sorted())
        let payload = String(decoding: try JSONEncoder().encode(statement), as: UTF8.self)
        for peer in roster where peer.identity != admission.identity {
            guard self.lifetime == lifetime, rosterDigest == digest, !Task.isCancelled else { return }
            try await send(kind: "trust", payload: payload, to: peer)
        }
    }
    private func send(kind: String, payload: String, to peer: MLSPeer, id: String? = nil) async throws {
        guard let login, let admission, let api else { throw V5IdentityError.invalid }
        var signal = IdentitySignal(id: id ?? V5Crypto.random().base64EncodedString(), origin: ServerAddress.identityOrigin(login.connection.passkeyOrigin), roomID: admission.roomID,
            sender: login.member.id, recipient: MemberProfile.memberID(for: peer.identity), senderEntry: admission.identity, recipientEntry: peer.identity, kind: kind,
            payload: payload, expiresAt: Int64(Date().timeIntervalSince1970) + 120, device: try identity.requireDevice())
        signal.signature = try identity.signIdentityMessage(signal.message)
        try await api.sendIdentitySignal(signal)
    }
    private func context(id: String, initiator: MLSPeer, responder: MLSPeer) throws -> String {
        guard let login, let admission, let a = initiator.binding?.device, let b = responder.binding?.device else { throw V5IdentityError.invalid }
        return V5Crypto.message("Chirp SAS session v5", [id, ServerAddress.identityOrigin(login.connection.passkeyOrigin), admission.roomID,
            initiator.identity, a.accountKey, a.leafKey, responder.identity, b.accountKey, b.leafKey]).base64EncodedString()
    }
    func addFriend(_ peer: MLSPeer) async {
        guard let device = peer.binding?.device else { return }
        await social.change(operation: "friend", friendID: MemberProfile.memberID(for: peer.identity), device: device, name: peer.name)
    }

    var peersNeedingVerification: [MLSPeer] {
        guard trust == .pending, let admission else { return [] }
        return roster.filter { $0.identity != admission.identity && $0.binding != nil && !locallyTrusted($0) }
    }

    func presentPendingVerification(for entry: String) {
        guard trust == .pending, let peer = remotePeer(for: entry), !locallyTrusted(peer) else { return }
        presentVerification(peer)
    }

    func remotePeer(for entry: String) -> MLSPeer? { entry == admission?.identity ? nil : peer(for: entry) }
    func peer(for entry: String) -> MLSPeer? { roster.first { $0.identity == entry } }
    func canVerify(_ peer: MLSPeer) -> Bool {
        guard peer.binding != nil, peer.identity != admission?.identity else { return false }
        return roster.contains { $0.identity == peer.identity && $0.binding?.device == peer.binding?.device }
    }
    func presentVerification(_ peer: MLSPeer) {
        ClientLog.shared.record(.identity)
        guard verificationPresentation == nil, verification == nil, canVerify(peer) else { return }
        failure = nil
        verificationPresentation = SASVerificationPresentation(peer: peer)
    }
    func dismissVerification() {
        ClientLog.shared.record(.identity)
        cancelVerification()
        verificationPresentation = nil
    }
    func prepareVerificationAgain() {
        guard let presentation = verificationPresentation, verification == nil, canVerify(presentation.peer) else { return }
        failure = nil
        verificationPresentation?.phase = .preparation
    }
    private func activateVerification(_ next: SASVerification) {
        verification = next
        if verificationPresentation?.peer != next.peer { verificationPresentation = SASVerificationPresentation(peer: next.peer) }
        verificationPresentation?.transaction = next.id
        verificationPresentation?.phase = .active
        failure = nil
        scheduleVerificationTimeout(next.id)
    }
    private var hasPendingVerificationTrust: Bool {
        social.hasPendingTrustWrite || verificationPresentation?.phase == .savingTrust || verificationPresentation?.phase == .trustPending
    }
    private func scheduleVerificationTimeout(_ transaction: String) {
        verificationTimer?.cancel()
        verificationTimer = Task { [weak self, verificationTimeout] in
            do { try await Task.sleep(for: verificationTimeout) } catch { return }
            guard let self, self.verification?.id == transaction else { return }
            self.cancelVerification(reason: .timedOut)
        }
    }
    func startVerification(_ peer: MLSPeer) async {
        ClientLog.shared.record(.identity)
        guard verification == nil, let native, let admission, peer.identity != admission.identity,
              !hasPendingVerificationTrust, canVerify(peer),
              let own = roster.first(where: { $0.identity == admission.identity }) else { return }
        let id = V5Crypto.random().base64EncodedString(), lifetime = self.lifetime
        // Reserve the transaction before suspending. Leaving or cancelling
        // invalidates it even if the native operation has not returned yet.
        activateVerification(SASVerification(id: id, peer: peer, initiator: admission.identity, commitment: nil, accepted: true))
        do {
            let data = try await security(native, ["action": "sas_start", "id": id, "context": context(id: id, initiator: own, responder: peer)])
            try await processSecurityResult(data, transaction: id, lifetime: lifetime)
        } catch { verificationFailed(error, transaction: id, lifetime: lifetime) }
    }
    func acceptVerification() async {
        ClientLog.shared.record(.identity)
        guard var v = verification, !v.accepted, let commitment = v.commitment, let native, let admission,
              let own = roster.first(where: { $0.identity == admission.identity }) else { return }
        let lifetime = self.lifetime
        v.accepted = true; verification = v; failure = nil
        do {
            let data = try await security(native, ["action": "sas_accept", "id": v.id, "context": context(id: v.id, initiator: v.peer, responder: own), "commitment": commitment])
            try await processSecurityResult(data, transaction: v.id, lifetime: lifetime)
        } catch { verificationFailed(error, transaction: v.id, lifetime: lifetime) }
    }
    func cancelVerification(reason: SASVerificationPresentation.EndReason = .cancelled) {
        ClientLog.shared.record(.identity)
        guard let v = verification else { return }
        // Dismiss locally before native work or network I/O. Cancellation must
        // remain available when the peer or room has already disconnected.
        verification = nil
        verificationTimer?.cancel(); verificationTimer = nil
        verificationPresentation?.phase = .ended(reason)
        guard let native else { return }
        let lifetime = self.lifetime
        Task { [weak self, security] in
            do {
                let data = try await security(native, ["action": "sas_cancel", "id": v.id])
                guard reason != .peerBusy, reason != .peerCancelled, let self, self.lifetime == lifetime else { return }
                let result = try JSONDecoder().decode(SecurityResult.self, from: data)
                if let message = result.message { try await sendSAS(message, transaction: v.id, to: v.peer) }
            } catch { /* Peer notification is best-effort; local cancellation is final. */ }
        }
    }
    func confirmVerification(matches: Bool) async {
        ClientLog.shared.record(.identity, matches ? "verificationMatches" : "verificationMismatch")
        if !matches { cancelVerification(reason: .mismatch); return }
        guard let v = verification, let native, v.accepted, v.decimals.count == 3, !v.confirmed else { return }
        let lifetime = self.lifetime
        verification?.confirmed = true
        do {
            let data = try await security(native, ["action": "sas_confirm", "id": v.id])
            try await processSecurityResult(data, transaction: v.id, lifetime: lifetime)
        } catch { verificationFailed(error, transaction: v.id, lifetime: lifetime) }
    }
    private struct SecurityResult: Decodable { var message: String?; var decimals: [Int]?; var complete: Bool?; var cancelled: Bool? }
    private func ownsVerification(_ transaction: String, lifetime: UUID) -> Bool {
        guard self.lifetime == lifetime, !Task.isCancelled, let v = verification, v.id == transaction else { return false }
        return roster.contains { $0.identity == v.peer.identity && $0.binding?.device == v.peer.binding?.device }
    }
    private func verificationFailed(_ error: Error, transaction: String, lifetime: UUID) {
        ClientLog.shared.record(.identity, "verification", outcome: .failed, failure: ClientFailure.capture(error))
        guard ownsVerification(transaction, lifetime: lifetime) else { return }
        failure = error.localizedDescription; cancelVerification(reason: .failed(error.localizedDescription))
    }
    func retryVerificationTrustSync() async {
        ClientLog.shared.record(.identity)
        guard let presentation = verificationPresentation, presentation.phase == .trustPending else { return }
        let lifetime = self.lifetime
        verificationPresentation?.phase = .savingTrust
        await social.refresh()
        guard self.lifetime == lifetime, verificationPresentation?.id == presentation.id else { return }
        if let device = presentation.peer.binding?.device, !social.trusts(accountID: MemberProfile.memberID(for: presentation.peer.identity), device: device) {
            await social.change(operation: "trust", friendID: MemberProfile.memberID(for: presentation.peer.identity), device: device, name: presentation.peer.name)
            guard self.lifetime == lifetime, verificationPresentation?.id == presentation.id else { return }
        }
        finishTrustSync(for: presentation.peer)
        try? await broadcastTrust(); evaluate()
    }
    private func finishTrustSync(for peer: MLSPeer) {
        guard let device = peer.binding?.device else { return }
        verificationPresentation?.phase = social.trusts(accountID: MemberProfile.memberID(for: peer.identity), device: device) ? .completed : .trustPending
    }
    private func sendSAS(_ message: String, transaction: String, to peer: MLSPeer) async throws {
        struct Envelope: Encodable { let transaction: String; let message: String }
        let lifetime = self.lifetime
        try await send(kind: "sas", payload: String(decoding: JSONEncoder().encode(Envelope(transaction: transaction, message: message)), as: UTF8.self), to: peer)
        if self.lifetime == lifetime { requestSignalSync() }
    }
    private func processSecurityResult(_ data: Data, transaction: String, lifetime: UUID) async throws {
        guard ownsVerification(transaction, lifetime: lifetime), let peer = verification?.peer else { return }
        let result = try JSONDecoder().decode(SecurityResult.self, from: data)
        if let message = result.message { try await sendSAS(message, transaction: transaction, to: peer) }
        guard ownsVerification(transaction, lifetime: lifetime) else { return }
        if let decimals = result.decimals { verification?.decimals = decimals }
        if result.cancelled == true { cancelVerification(reason: .peerCancelled) }
        if result.complete == true, let device = peer.binding?.device {
            let presentationID = verificationPresentation?.id
            verification = nil
            verificationTimer?.cancel(); verificationTimer = nil
            verificationPresentation?.phase = .savingTrust
            await social.change(operation: "trust", friendID: MemberProfile.memberID(for: peer.identity), device: device, name: peer.name)
            guard self.lifetime == lifetime, verificationPresentation?.id == presentationID else { return }
            finishTrustSync(for: peer)
            try await broadcastTrust(); evaluate()
        }
    }
    private func receive(_ signal: IdentitySignal) async throws {
        guard let login, let admission, signal.recipient == login.member.id, signal.recipientEntry == admission.identity,
              signal.origin == ServerAddress.identityOrigin(login.connection.passkeyOrigin), signal.roomID == admission.roomID,
              signal.expiresAt > Int64(Date().timeIntervalSince1970), signal.expiresAt <= Int64(Date().timeIntervalSince1970) + 600,
              !seenSignals.contains(signal.id), let peer = roster.first(where: { $0.identity == signal.senderEntry }),
              signal.sender == MemberProfile.memberID(for: peer.identity), signal.device == peer.binding?.device,
              !social.blocked(accountID: signal.sender, device: signal.device) else { return }
        try signal.device.validate(); try V5Crypto.verify(key: signal.device.leafKey, signature: signal.signature, message: signal.message)
        seenSignals.insert(signal.id); if seenSignals.count > 8192 { seenSignals = [signal.id] }
        if signal.kind == "trust" {
            let value = try JSONDecoder().decode(MutualTrustStatement.self, from: Data(signal.payload.utf8))
            if value.roster == rosterDigest {
                if let old = statements[peer.identity], value.version < old.0.version { return }
                statements[peer.identity] = (value, signal.expiresAt)
            }; return
        }
        guard signal.kind == "sas" else { return }
        struct Envelope: Decodable { let transaction: String; let message: String }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(signal.payload.utf8))
        let packet = try JSONSerialization.jsonObject(with: Data(envelope.message.utf8)) as? [String: String]
        if packet?["kind"] == "Request" {
            guard let commitment = packet?["commitment"] else { return }
            if let presentation = verificationPresentation, presentation.peer.identity == peer.identity,
               presentation.transaction == envelope.transaction { return }
            let crossedInvitation = verification.map { $0.peer.identity == peer.identity && $0.awaitingPeerAcceptance } ?? false
            if hasPendingVerificationTrust || (verification != nil && !crossedInvitation) {
                // The requester may already have left. Reply only on their transaction.
                try? await sendSAS(#"{"kind":"Busy"}"#, transaction: envelope.transaction, to: peer)
                return
            }
            if crossedInvitation {
                // Crossed invitations keep the lower entry identity's outgoing transaction.
                guard peer.identity < admission.identity else { return }
                cancelVerification()
            }
            activateVerification(SASVerification(id: envelope.transaction, peer: peer, initiator: peer.identity, commitment: commitment))
            return
        }
        guard let current = verification, current.id == envelope.transaction, current.peer.identity == peer.identity, let native else { return }
        if packet?["kind"] == "Busy" {
            if current.awaitingPeerAcceptance { cancelVerification(reason: .peerBusy) }
            return
        }
        if packet?["kind"] == "Cancel" {
            cancelVerification(reason: .peerCancelled)
            return
        }
        let lifetime = self.lifetime
        do {
            let data = try await security(native, ["action": "sas_receive", "id": envelope.transaction, "message": envelope.message])
            try await processSecurityResult(data, transaction: envelope.transaction, lifetime: lifetime)
        } catch { verificationFailed(error, transaction: envelope.transaction, lifetime: lifetime) }
    }
}
