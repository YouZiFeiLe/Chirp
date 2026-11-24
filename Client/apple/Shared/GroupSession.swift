import Foundation
import ChirpMLS

@MainActor
final class GroupSession {
    typealias Pause = @MainActor () async throws -> Void
    typealias Install = @MainActor (MLSClient, [MLSPeer]) async throws -> Void
    typealias Ready = @MainActor ([MLSPeer]) async throws -> Void
    typealias Prepare = @MainActor (MLSClient, [MLSPeer], Int32) async throws -> Void
    typealias Switch = @MainActor (Int32) async throws -> Void
    private let native: MLSClient
    private let login: ClientSession
    private let admission: RoomAdmission
    private let baseURL: URL
    private let identity: DeviceIdentityStore?
    private var identityPolicy: V5RoomPolicy?
    private var ownBinding: V5EntryBinding?
    private var identityDeadline: Int64 = 0
    private var readiesVerified = false
    private let approveRoster: (@MainActor @Sendable ([MLSPeer]) throws -> String?)?
    private let authorizationDeadline: (@MainActor @Sendable () -> ContinuousClock.Instant?)?
    private let authorizeMedia: (@MainActor @Sendable (ContinuousClock.Instant?, Int32?) -> Void)?
    private var keyLifetime = KeyLifetime()
    private var candidateLifetime = KeyLifetime()
    private var candidateStarted: ContinuousClock.Instant?
    private var rotationRequested = false
    private var rosterApproved = false
    private let onPause: Pause
    private let onInstall: Install
    private let onReady: Ready
    private let onPrepare: Prepare?
    private let onSwitch: Switch?
    private let onRetire: Switch?
    private let onReconnect: (@MainActor @Sendable () -> Void)?
    private let onRoomInformation: (@MainActor @Sendable (RoomPublicInformation?) -> Void)?
    private let onFailure: @MainActor (ClientFailure) async -> Void
    private var transport: GroupTransport?
    private var preparedConfiguration: Result<GroupConfiguration, Error>?
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var failurePause: Task<Void, Never>?
    private var closingKeys: Task<Void, Never>?
    private var activation: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var leasing: Task<Void, Never>?
    private var leaseWakeup: AsyncStream<Void>.Continuation?
    private var leaseRequest: Task<(GroupPulse, ContinuousClock.Instant), Error>?
    private var watching: Task<Void, Never>?
    private var connection: HTTPEventConnection?
    private var current: GroupSnapshot?
    private var lease = MediaLease()
    private var installed = false
    private var isReady = false
    private var stopped = false
    private var mediaSuspended = false
    private var streamConnected = false
    private var blockedGroupID: String?
    private var needsRefresh = false
    private var needsSnapshot = false
    private var requestedRevision: UInt64 = 0
    private var preparedGroupID = ""
    private var confirmation = ""
    private var transitionStarted: ContinuousClock.Instant? = .now
    private var authorityPausedAt: ContinuousClock.Instant?
    private var pendingFailure: ClientFailure?
    private var pausing: Task<Void, Error>?
    private var mediaLifetime: UInt64 = 0
    private var keyEpoch: UInt64 = 0
    private var requestedRotationRevision: UInt64 = 0
    private var candidateEpoch: UInt64?
    private var candidateConfirmation = ""
    private var candidateInstalled = false
    private var candidateConfirmed = false
    private var candidateActivated = false
    private var leaseRefreshRequested = false
    private var rotationRetirement: Task<Void, Never>?
    private var activationComplete = false
    private var smoothRotationEnabled = false
    private let wakeups = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    private var hasCurrentIdentityAuthority: Bool {
        if let policy = identityPolicy, policy.isMutual { return policy == .mutual(origin: ServerAddress.identityOrigin(login.connection.passkeyOrigin), roomID: admission.roomID) }
        guard let identity, let policy = identityPolicy,
              let pinned = try? identity.roomPolicy(origin: policy.origin, roomID: policy.roomID) else { return false }
        return pinned.digest == policy.digest
    }
    var maySend: Bool { !stopped && pendingFailure == nil && !mediaSuspended && streamConnected && isReady && readiesVerified && hasCurrentIdentityAuthority && identityDeadline > Int64(Date().timeIntervalSince1970) && lease.isValid() && keyLifetime.isValid() && rosterApproved && (authorizationDeadline?().map { $0 > .now } ?? false) && login.expiresAt > Date() }
    var groupID: String? { current?.groupID }
    var sendingDeadline: ContinuousClock.Instant? {
        guard maySend, let deadline = lease.deadline else { return nil }
        let remaining = min(Double(identityDeadline) - Date().timeIntervalSince1970, login.expiresAt.timeIntervalSinceNow)
        guard remaining > 0 else { return nil }
        guard let keyDeadline = keyLifetime.deadline, let authorityDeadline = authorizationDeadline?() else { return nil }
        return min(deadline, keyDeadline, authorityDeadline, ContinuousClock.now.advanced(by: .seconds(remaining)))
    }

    init(baseURL: URL, login: ClientSession, admission: RoomAdmission, identity: DeviceIdentityStore? = nil, onPause: @escaping Pause, onInstall: @escaping Install,
         onReady: @escaping Ready, onFailure: @escaping @MainActor (ClientFailure) async -> Void,
         onPrepare: Prepare? = nil, onSwitch: Switch? = nil, onRetire: Switch? = nil,
         onReconnect: (@MainActor @Sendable () -> Void)? = nil,
         approveRoster: (@MainActor @Sendable ([MLSPeer]) throws -> String?)? = nil,
         authorizationDeadline: (@MainActor @Sendable () -> ContinuousClock.Instant?)? = nil,
         authorizeMedia: (@MainActor @Sendable (ContinuousClock.Instant?, Int32?) -> Void)? = nil,
         onRoomInformation: (@MainActor @Sendable (RoomPublicInformation?) -> Void)? = nil) throws {
        self.baseURL = baseURL; self.login = login; self.admission = admission
        self.identity = identity
        native = try MLSClient(identity: admission.identity)
        self.onPause = onPause; self.onInstall = onInstall; self.onReady = onReady; self.onFailure = onFailure
        self.onPrepare = onPrepare; self.onSwitch = onSwitch; self.onRetire = onRetire
        self.onReconnect = onReconnect
        self.onRoomInformation = onRoomInformation
        self.approveRoster = approveRoster; self.authorizationDeadline = authorizationDeadline; self.authorizeMedia = authorizeMedia
    }

    // Fetch configuration during ICE/DTLS. The signed membership request and
    // key agreement begin in start(), after the media transport connects.
    func prepareConfiguration() async {
        do {
            let transport = try await makeTransport()
            preparedConfiguration = .success(try await transport.configuration())
        } catch { preparedConfiguration = .failure(error) }
    }

    private func makeTransport() async throws -> GroupTransport {
        if let transport { return transport }
        let publicKey = try await native.publicKey()
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let transport = GroupTransport(baseURL: baseURL, login: login, admission: admission, native: native, publicKey: publicKey)
        self.transport = transport
        return transport
    }

    func start() {
        guard task == nil, !stopped else { return }
        task = Task { [weak self] in await self?.run() }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, !stopped else { return }
                wake()
                if let current {
                    rosterApproved = (try? approveRoster?(current.members)) != nil
                    if !rosterApproved, !preparedGroupID.isEmpty, blockedGroupID != current.groupID {
                        blockCurrent(); needsRefresh = true; try? await pause()
                    }
                }
                if let candidateStarted, candidateStarted.duration(to: .now) >= .seconds(15) {
                    await workerFailed(ClientFailure(.groupUpdateTimedOut)); continue
                }
                if installed && !keyLifetime.isValid() {
                    await workerFailed(ClientFailure(.groupUpdateTimedOut)); continue
                }
                if pendingFailure == nil && identityPolicy != nil && !hasCurrentIdentityAuthority {
                    await workerFailed(ClientFailure(.identityChanged))
                } else if pendingFailure == nil && identityDeadline > 0 && (login.expiresAt <= Date() || identityDeadline <= Int64(Date().timeIntervalSince1970)) {
                    await workerFailed(ClientFailure(.identityExpired))
                } else if isReady && !lease.isValid() {
                    // Expiry stops sending immediately, but a valid admission
                    // can recover with fresh keys without ending the call.
                    do { try await networkLost() }
                    catch { await workerFailed(error) }
                }
            }
        }
    }

    func cancel() {
        onRoomInformation?(nil)
        stopped = true; lease.revoke(); isReady = false; authorizeMedia?(nil, nil)
        if closingKeys == nil {
            mediaLifetime &+= 1
            closingKeys = Task { [native] in try? await native.clear() }
        }
        task?.cancel(); watchdog?.cancel(); activation?.cancel()
        heartbeat?.cancel(); leasing?.cancel(); watching?.cancel(); connection?.cancel(); wake()
        rotationRetirement?.cancel()
    }

    func stop() async {
        let pending = task, pendingActivation = activation
        cancel()
        await closingKeys?.value
        await pendingActivation?.value; await pending?.value
        await failurePause?.value
        await stopWorkers()
        let closingTransport = transport, closingState = current
        transport = nil; current = nil; activation = nil
        if let closingTransport, let closingState {
            _ = try? await closingTransport.snapshot(makeRequest("leave", closingState))
        }
        closingTransport?.close()
        try? await native.clear()
    }

    /// Transport-start only retires the current media lifetime. It does not
    /// initiate a round until the caller confirms reconnection has completed.
    func suspend() async throws {
        mediaSuspended = true; blockCurrent()
        try await pause(); wake()
    }

    func refresh() async throws {
        mediaSuspended = false; blockCurrent(); needsRefresh = true; needsSnapshot = true
        try await pause(); wake()
    }

    private func wake() {
        wakeups.continuation.yield(())
        leaseWakeup?.yield(())
    }
    private func blockCurrent() {
        if installed || isReady || blockedGroupID == nil || preparedGroupID == current?.groupID {
            blockedGroupID = current?.groupID
        }
    }

    private func pause() async throws {
        onRoomInformation?(nil)
        mediaLifetime &+= 1
        rotationRetirement?.cancel(); rotationRetirement = nil
        activationComplete = false
        leaseRefreshRequested = false
        lease.revoke(); isReady = false; installed = false; authorizeMedia?(nil, nil)
        keyLifetime = KeyLifetime(); candidateLifetime = KeyLifetime(); candidateStarted = nil; rotationRequested = false
        preparedGroupID = ""; confirmation = ""
        candidateEpoch = nil; candidateConfirmation = ""
        candidateInstalled = false; candidateConfirmed = false; candidateActivated = false
        readiesVerified = false
        if let pausing { try await pausing.value; return }
        let pending = activation; pending?.cancel(); activation = nil
        let action = Task { @MainActor [native, onPause] in
            // Erase both MLS rounds even if the media device is busy or fails to mute.
            try await native.clear()
            try await onPause()
            await pending?.value
        }
        pausing = action
        defer { pausing = nil }
        try await action.value
        try Task.checkCancellation()
    }

    private func networkLost() async throws {
        blockCurrent(); needsRefresh = true; needsSnapshot = true
        try await pause(); wake()
    }

    private func retry<T>(_ action: () async throws -> T) async throws -> T {
        for attempt in 0..<3 {
            var delay = Duration.seconds(1)
            do { return try await action() }
            catch is URLError {
                try Task.checkCancellation(); try await networkLost()
                if attempt == 2 { throw ClientFailure(.groupConnectionLost) }
            } catch GroupRequestError.unavailable {
                try await networkLost()
                if attempt == 2 { throw ClientFailure(.groupMembersUnverified) }
            } catch GroupRequestError.throttled(let seconds) {
                try await networkLost()
                if attempt == 2 { throw ClientFailure(.groupRequestRejected, retryAfter: seconds) }
                delay = .seconds(seconds)
            }
            try await Task.sleep(for: delay)
        }
        throw CancellationError()
    }

    private struct Restart: Error { let configuration: GroupConfiguration }

    private func configuration(_ transport: GroupTransport) async throws -> GroupConfiguration {
        let value = try await retry {
            if let preparedConfiguration {
                self.preparedConfiguration = nil
                return try preparedConfiguration.get()
            }
            return try await transport.configuration()
        }
        guard value.roomID == admission.roomID, value.protocolName == VoiceRooms.keyProtocol,
              value.maxLeaseMS == 3_000, value.heartbeatMS == 2_000, value.leaseRefreshMS == 1_000,
              !value.serverID.isEmpty else { throw ClientFailure(.groupProtocolMismatch) }
        return value
    }

    private func snapshot(_ request: GroupRequest) async throws -> GroupSnapshot {
        guard let transport else { throw CancellationError() }
        return try await retry { try await transport.snapshot(request) }
    }

    private func resynchronize() async throws {
        guard let current, let transport else { throw CancellationError() }
        do { try accept(await snapshot(makeRequest("snapshot", current))) }
        catch GroupRequestError.conflict(let code) {
            guard code == "GROUP_CHANGED" else { throw ClientFailure(.groupMembershipLost) }
            let next = try await configuration(transport)
            guard next.serverID != current.serverID else { throw ClientFailure(.groupMembershipLost) }
            throw Restart(configuration: next)
        }
    }

    private func accept(_ snapshot: GroupSnapshot) throws {
        try Task.checkCancellation()
        if let pendingFailure { throw pendingFailure }
        guard !stopped, snapshot.roomID == admission.roomID, snapshot.protocolName == VoiceRooms.keyProtocol,
              snapshot.serverID == current?.serverID || current == nil,
              !snapshot.serverID.isEmpty, !snapshot.sessionID.isEmpty, snapshot.generation > 0, snapshot.revision > 0,
              !snapshot.members.isEmpty, Set(snapshot.members.map(\.identity)).count == snapshot.members.count,
              snapshot.members.contains(where: { $0.identity == admission.identity }),
              snapshot.members.contains(where: { $0.identity == snapshot.leader }),
              ["collecting", "welcoming", "confirming", "ready"].contains(snapshot.phase) else {
            throw ClientFailure(.groupMembershipLost)
        }
        if let current, snapshot.revision < current.revision ||
            (snapshot.revision == current.revision && (snapshot.rotationRevision ?? 0) < (current.rotationRevision ?? 0)) { needsSnapshot = true; return }
        if let current, snapshot.sessionID != current.sessionID || snapshot.generation < current.generation {
            throw ClientFailure(.groupMembershipLost)
        }
        guard hasCurrentIdentityAuthority, let policy = identityPolicy, snapshot.identityPolicy?.digest == policy.digest,
              let ownBinding, snapshot.members.contains(where: { $0.identity == admission.identity && $0.binding?.digest == ownBinding.digest }) else { throw V5IdentityError.changed }
        let ready = snapshot.phase == "ready"
        let firstReady = ready && !readiesVerified
        readiesVerified = false
        identityDeadline = try V5Crypto.validateRoster(snapshot.members, policy: policy, groupID: snapshot.groupID, epoch: 0,
                                                       confirmation: ready ? snapshot.confirmation : nil)
        readiesVerified = ready
        rosterApproved = try approveRoster?(snapshot.members) != nil
        current = snapshot
        publishInformation(snapshot.roomInformation, state: snapshot, started: snapshot.requestStartedAt ?? .now)
        needsSnapshot = requestedRevision > snapshot.revision || requestedRotationRevision > (snapshot.rotationRevision ?? 0)
        if firstReady { leaseRefreshRequested = true; leaseWakeup?.yield(()) }
    }

    private func run() async {
        do {
            let transport = try await makeTransport()
            let publicKey = transport.publicKey
            var config = try await configuration(transport)
            var retriedJoinConfiguration = false
            configure: while !stopped {
                if let pendingFailure { throw pendingFailure }
                guard let identity, let policy = config.identityPolicy else { throw V5IdentityError.notEnrolled }
                let trusted = try identity.acceptRoomPolicy(policy, origin: policy.isMutual ? ServerAddress.identityOrigin(login.connection.passkeyOrigin) : ServerAddress.normalized(login.connection.apiURL), roomID: admission.roomID)
                identityPolicy = trusted
                ownBinding = try identity.entryBinding(login: login, admission: admission, mlsKey: publicKey, policy: trusted)
                try await native.authorize(policy: trusted, trustedOwner: trusted.isMutual ? "" : identity.roomPolicy(origin: trusted.origin, roomID: trusted.roomID).ownerKey, origin: trusted.origin, roomID: trusted.roomID)
                smoothRotationEnabled = config.smoothRotation == true && onPrepare != nil && onSwitch != nil && onRetire != nil
                current = nil; preparedGroupID = ""; confirmation = ""; requestedRevision = 0
                requestedRotationRevision = 0
                needsSnapshot = false; streamConnected = false
                let started = ContinuousClock.now
                while true {
                    do {
                        var join = GroupRequest(roomID: admission.roomID, entryID: admission.entryID, serverID: config.serverID, operation: "join")
                        join.binding = ownBinding
                        if smoothRotationEnabled { join.smoothRotation = true }
                        let joined = try await snapshot(join)
                        guard joined.serverID == config.serverID,
                              joined.members.contains(where: { $0.identity == admission.identity && $0.publicKey == publicKey }) else {
                            throw ClientFailure(.groupMembershipLost)
                        }
                        try accept(joined); retriedJoinConfiguration = false; break
                    } catch GroupRequestError.conflict("GROUP_CHANGED") {
                        // The coordinator may restart while the media handshake is in flight.
                        guard !retriedJoinConfiguration else { throw ClientFailure(.groupMembershipLost) }
                        let fresh = try await configuration(transport)
                        guard fresh.serverID != config.serverID else { throw ClientFailure(.groupMembershipLost) }
                        config = fresh; retriedJoinConfiguration = true
                        continue configure
                    } catch GroupRequestError.conflict("IDENTITY_KEY_CHANGED") {
                        guard started.duration(to: .now) < .seconds(8) else { throw ClientFailure(.previousGroupActive) }
                        try await Task.sleep(for: .milliseconds(500))
                    }
                }
                transitionStarted = .now
                startWorkers(config, publicKey: publicKey)
                do { try await drive(publicKey: publicKey) }
                catch let restart as Restart {
                    if let pendingFailure { throw pendingFailure }
                    blockCurrent(); try await pause(); await stopWorkers()
                    if let pendingFailure { throw pendingFailure }
                    config = restart.configuration; continue
                }
            }
        } catch {
            if !stopped && !(error is CancellationError) {
                stopped = true; lease.revoke(); isReady = false; authorizeMedia?(nil, nil); watchdog?.cancel(); activation?.cancel()
                try? await native.clear()
                await onFailure(pendingFailure ?? ClientFailure.capture(error, fallback: .groupCryptoFailed))
            }
        }
        await stopWorkers()
        await failurePause?.value
        try? await native.clear()
    }

    private func drive(publicKey: String) async throws {
        var iterator = wakeups.stream.makeAsyncIterator()
        while !stopped {
            try Task.checkCancellation()
            if let pendingFailure { throw pendingFailure }
            if needsSnapshot { try await resynchronize(); if needsSnapshot { continue } }
            // A lease/watch worker can fail while the snapshot request is in
            // flight. Preserve that cause instead of reporting the old round's
            // transition timer as a new group-update timeout.
            if let pendingFailure { throw pendingFailure }
            if isReady && !lease.isValid() { try await networkLost(); continue }
            guard let state = current,
                  state.members.contains(where: { $0.identity == admission.identity && $0.publicKey == publicKey }) else {
                throw ClientFailure(.groupMembershipLost)
            }
            if state.suspended {
                if authorityPausedAt == nil { authorityPausedAt = .now; blockCurrent(); try await pause() }
                guard authorityPausedAt!.duration(to: .now) < .seconds(25) else { throw ClientFailure(.groupAuthorizationLost) }
            } else if !mediaSuspended {
                authorityPausedAt = nil
                if needsRefresh || blockedGroupID == state.groupID {
                    if blockedGroupID == state.groupID {
                        needsRefresh = false
                        try await perform(makeRequest("refresh", state)); continue
                    }
                    needsRefresh = false
                }
                guard let approval = try approveRoster?(state.members) else {
                    rosterApproved = false; transitionStarted = .now
                    guard await iterator.next() != nil else { return }; continue
                }
                rosterApproved = true
                if preparedGroupID != state.groupID {
                    try await pause()
                    guard !stopped, !mediaSuspended, pendingFailure == nil, !needsRefresh,
                          blockedGroupID != state.groupID, current?.groupID == state.groupID else { continue }
                    keyEpoch = 0; preparedGroupID = state.groupID; blockedGroupID = nil
                    transitionStarted = .now
                    let lifetime = mediaLifetime
                    var request = makeRequest("package", state); request.keyPackage = try await native.keyPackage()
                    guard lifetime == mediaLifetime else { continue }
                    request.offer = try await offer(for: request.keyPackage!, state: state, epoch: 0)
                    guard lifetime == mediaLifetime else { continue }
                    try await perform(request); continue
                }
                let lifetime = mediaLifetime
                do {
                    if try await advanceRound(state, approval: approval, lifetime: lifetime) { continue }
                } catch {
                    if mediaLifetime != lifetime, !stopped, pendingFailure == nil { continue }
                    throw error
                }
            }
            guard await iterator.next() != nil else { return }
        }
    }

    private func advanceRound(_ state: GroupSnapshot, approval: String, lifetime: UInt64) async throws -> Bool {
        try await native.approve(groupID: state.groupID, members: state.members, authorizationHash: approval)
        guard lifetime == mediaLifetime else { return true }
        if state.phase == "welcoming", state.leader == admission.identity, confirmation.isEmpty {
            keyLifetime.begin()
            let welcome = try await native.create(groupID: state.groupID, members: state.members)
            guard lifetime == mediaLifetime else { return true }
            confirmation = welcome.confirmation
            var request = makeRequest("publish", state); request.welcome = welcome.welcome; request.confirmation = confirmation
            try await perform(request); return true
        }
        if state.phase == "confirming" || state.phase == "ready" {
            if confirmation.isEmpty {
                keyLifetime.begin()
                let joined = try await native.join(groupID: state.groupID, members: state.members, welcome: state.welcome)
                guard lifetime == mediaLifetime else { return true }
                confirmation = joined
            }
            guard confirmation == state.confirmation else { throw ClientFailure(.groupConfirmationMismatch) }
            if !installed {
                try await onInstall(native, state.members); try Task.checkCancellation()
                if mediaLifetime != lifetime || mediaSuspended {
                    blockedGroupID = state.groupID; needsRefresh = true; needsSnapshot = true
                    try await pause(); return true
                }
                installed = true
                var request = makeRequest("ack", state); request.confirmation = confirmation
                request.ready = try await ready(for: state, epoch: 0, confirmation: confirmation)
                guard lifetime == mediaLifetime else { return true }
                try await perform(request); return true
            }
        }
        if !isReady, let transitionStarted, transitionStarted.duration(to: .now) > .seconds(25) {
            throw ClientFailure(.groupUpdateTimedOut)
        }
        if isReady && activationComplete && keyLifetime.shouldRotate() && !rotationRequested {
            rotationRequested = true
            // Refresh is an existing signed membership-generation operation.
            // Any client may demand fresh secrets; a frozen server cannot
            // extend the local hard deadline while this request is pending.
            blockCurrent(); needsRefresh = true
            try await pause(); return true
        }
        guard isReady && activationComplete else { return false }
        return try await processRotation(state)
    }

    @discardableResult
    private func perform(_ request: GroupRequest) async throws -> Bool {
        do { try accept(await snapshot(request)); return true }
        catch GroupRequestError.conflict(let code) {
            guard code == "GROUP_CHANGED" || code == "GROUP_CONFLICT" else { throw ClientFailure(.groupMembershipLost) }
            needsSnapshot = true
            return false
        }
    }

    // Keep the admission generation and chat audience stable while rotating
    // media keys. Membership/authority changes still pause and retire all keys.
    private func processRotation(_ state: GroupSnapshot) async throws -> Bool {
        guard smoothRotationEnabled, let onPrepare, let onSwitch, let onRetire else { return false }
        guard let rotation = state.rotation else {
            guard (state.keyEpoch ?? 0) == keyEpoch else { throw ClientFailure(.groupConfirmationMismatch) }
            if candidateActivated, let epoch = candidateEpoch {
                let lifetime = mediaLifetime, groupID = state.groupID
                candidateEpoch = nil; candidateConfirmation = ""
                candidateInstalled = false; candidateConfirmed = false; candidateActivated = false
                leaseRefreshRequested = true; leaseWakeup?.yield(())
                rotationRetirement?.cancel()
                rotationRetirement = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(1))
                        guard let self, !stopped, isReady, mediaLifetime == lifetime,
                              current?.groupID == groupID, keyEpoch == epoch else { return }
                        try await onRetire(Int32((epoch - 1) % 2))
                    } catch { if !Task.isCancelled { await self?.workerFailed(error) } }
                }
            }
            return false
        }
        guard rotation.epoch > 0, rotation.epoch == keyEpoch + 1 || rotation.epoch == keyEpoch,
              ["collecting", "welcoming", "confirming", "ready", "switching"].contains(rotation.phase),
              rotation.members.count == state.members.count,
              Set(rotation.members.map(\.identity)).count == rotation.members.count,
              Dictionary(uniqueKeysWithValues: rotation.members.map { ($0.identity, $0.publicKey) }) ==
                Dictionary(uniqueKeysWithValues: state.members.map { ($0.identity, $0.publicKey) }) else { throw ClientFailure(.groupConfirmationMismatch) }
        guard let policy = identityPolicy else { throw V5IdentityError.untrusted }
        _ = try V5Crypto.validateRoster(rotation.members, policy: policy, groupID: rotation.groupID(in: state), epoch: rotation.epoch)
        guard let approval = try approveRoster?(rotation.members) else { throw V5IdentityError.untrusted }
        let lifetime = mediaLifetime
        func valid() -> Bool { !Task.isCancelled && !stopped && isReady && lease.isValid() && mediaLifetime == lifetime && current?.groupID == state.groupID && !needsRefresh && blockedGroupID != state.groupID }
        try await native.approve(groupID: rotation.groupID(in: state), members: rotation.members, authorizationHash: approval)
        guard valid() else { return false }
        func request(_ operation: String) -> GroupRequest {
            var value = makeRequest(operation, state); value.keyEpoch = rotation.epoch; return value
        }
        if candidateEpoch != rotation.epoch {
            guard rotation.epoch == keyEpoch + 1, rotation.phase == "collecting" else { throw ClientFailure(.groupConfirmationMismatch) }
            rotationRetirement?.cancel(); rotationRetirement = nil
            var value = request("rotation_package")
            value.keyPackage = try await native.stagedKeyPackage()
            value.offer = try await offer(for: value.keyPackage!, state: state, epoch: rotation.epoch)
            guard valid() else { return false }
            candidateEpoch = rotation.epoch; candidateConfirmation = ""; candidateStarted = .now; candidateLifetime = KeyLifetime()
            candidateInstalled = false; candidateConfirmed = false; candidateActivated = false
            try await perform(value); return true
        }
        if rotation.phase == "welcoming", state.leader == admission.identity, candidateConfirmation.isEmpty {
            candidateLifetime.begin()
            let welcome = try await native.createStaged(groupID: rotation.groupID(in: state), members: rotation.members, keyEpoch: rotation.epoch)
            guard valid() else { return false }
            candidateConfirmation = welcome.confirmation
            var value = request("rotation_publish"); value.welcome = welcome.welcome; value.confirmation = welcome.confirmation
            try await perform(value); return true
        }
        if ["confirming", "ready", "switching"].contains(rotation.phase), !candidateConfirmed {
            if candidateConfirmation.isEmpty {
                candidateLifetime.begin()
                candidateConfirmation = try await native.joinStaged(groupID: rotation.groupID(in: state), members: rotation.members, welcome: rotation.welcome, keyEpoch: rotation.epoch)
            }
            guard valid() else { return false }
            guard candidateConfirmation == rotation.confirmation else { throw ClientFailure(.groupConfirmationMismatch) }
            if !candidateInstalled {
                do { try await onPrepare(native, rotation.members, rotation.keyIndex) }
                catch {
                    if !valid() { return false }
                    if error is CancellationError { throw ClientFailure(.groupCryptoFailed) }
                    throw error
                }
                guard valid() else { return false }
                candidateInstalled = true
            }
            var value = request("rotation_ack"); value.confirmation = candidateConfirmation
            value.ready = try await ready(for: state, epoch: rotation.epoch, confirmation: candidateConfirmation)
            try await perform(value); candidateConfirmed = true; return true
        }
        if rotation.phase == "switching", !candidateActivated {
            _ = try V5Crypto.validateRoster(rotation.members, policy: policy, groupID: rotation.groupID(in: state), epoch: rotation.epoch, confirmation: candidateConfirmation)
            guard candidateInstalled, candidateConfirmed, rotation.confirmation == candidateConfirmation else { throw ClientFailure(.groupConfirmationMismatch) }
            do { try await onSwitch(rotation.keyIndex) }
            catch {
                if !valid() { return false }
                if error is CancellationError { throw ClientFailure(.groupCryptoFailed) }
                throw error
            }
            guard valid() else { return false }
            try await native.activateStaged(groupID: rotation.groupID(in: state))
            guard valid() else { return false }
            var value = request("rotation_activate"); value.confirmation = candidateConfirmation
            // Keep renewing the server's currently acknowledged epoch while
            // activation is in flight. Advancing it early discards valid
            // in-flight leases and races the server's activation barrier.
            let acknowledged = try await perform(value)
            guard valid() else { return false }
            guard acknowledged else {
                blockCurrent(); needsRefresh = true
                try await pause(); return true
            }
            keyEpoch = rotation.epoch
            keyLifetime = candidateLifetime; candidateStarted = nil; rotationRequested = false
            // Capture can use the remaining membership lease. Only the reply
            // to a lease for this epoch can open its voice receive slot.
            authorizeMedia?(sendingDeadline, nil)
            candidateActivated = true; leaseRefreshRequested = true; leaseWakeup?.yield(())
            // An old-epoch HTTP response must not block the first new lease.
            leaseRequest?.cancel()
            return true
        }
        return false
    }

    private func startWorkers(_ config: GroupConfiguration, publicKey: String) {
        heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(config.heartbeatMS))
                    guard let self, !stopped, let transport, let state = current else { return }
                    let (reply, started) = try await retry { try await transport.pulse(makeRequest("heartbeat", state)) }
                    try Task.checkCancellation()
                    try await observe(reply, expected: state, grantingLease: false, requestStartedAt: started)
                    wake()
                } catch { await self?.workerFailed(error); return }
            }
        }
        let leaseEvents = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        leaseWakeup = leaseEvents.continuation
        leasing = Task { @MainActor [weak self] in
            var next = ContinuousClock.now
            // Ready snapshots and the first verified stream event wake the same
            // single lease worker. The watchdog supplies subsequent deadline ticks.
            for await _ in leaseEvents.stream {
                do {
                    guard let self, !stopped, !Task.isCancelled else { return }
                    guard ContinuousClock.now >= next || leaseRefreshRequested else { continue }
                    guard pendingFailure == nil, streamConnected, !mediaSuspended, !needsRefresh,
                          installed, readiesVerified, let state = current, state.phase == "ready", !state.suspended, blockedGroupID != state.groupID,
                          requestedRevision <= state.revision, let transport else { continue }
                    leaseRefreshRequested = false
                    next = .now.advanced(by: .milliseconds(config.leaseRefreshMS))
                    let requestedEpoch = keyEpoch
                    let lifetime = mediaLifetime
                    var request = makeRequest("lease", state); request.confirmation = confirmation; request.revision = state.revision
                    if smoothRotationEnabled { request.keyEpoch = requestedEpoch }
                    let (reply, started) = try await retry { try await requestLease(request, transport: transport) }
                    try Task.checkCancellation()
                    try await observe(reply, expected: state, grantingLease: true, expectedKeyEpoch: requestedEpoch, requestStartedAt: started)
                    guard lifetime == mediaLifetime, pendingFailure == nil, hasCurrentIdentityAuthority, identityDeadline > Int64(Date().timeIntervalSince1970),
                          requestedEpoch == keyEpoch, current?.groupID == state.groupID, current?.revision == reply.revision,
                          readiesVerified, rosterApproved, !needsRefresh, blockedGroupID != state.groupID,
                          requestedRevision <= reply.revision, !mediaSuspended, streamConnected,
                          installed, !reply.suspended, reply.phase == "ready", reply.leaseMS > 0 else { continue }
                    try lease.renew(requestStartedAt: started, milliseconds: reply.leaseMS)
                    guard lease.isValid() else { try await networkLost(); continue }
                    // Rotation can truncate a lease below the usual 3 seconds.
                    // Renew those earlier, accounting for transit time, while
                    // retaining the ordinary one-second steady-state cadence.
                    next = min(next, started.advanced(by: .milliseconds(reply.leaseMS / 3)))
                    let firstLease = !isReady
                    isReady = true; transitionStarted = nil
                    authorizeMedia?(sendingDeadline, Int32(requestedEpoch % 2))
                    if firstLease { activate(state.members) }
                } catch GroupRequestError.conflict {
                    self?.needsSnapshot = true; self?.wake()
                } catch is CancellationError {
                    guard let self, !stopped, !Task.isCancelled else { return }
                    if leaseRefreshRequested || !installed { continue }
                    await workerFailed(ClientFailure(.groupConnectionLost)); return
                } catch { await self?.workerFailed(error); return }
            }
        }
        watching = Task { @MainActor [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, !stopped, let transport, let state = current else { return }
                do {
                    let stream = try await transport.events(makeRequest("watch", state)); connection = stream
                    defer { stream.cancel() }
                    for try await event in stream.events {
                        try Task.checkCancellation()
                        if event.name == "revoked" { throw ClientFailure(.groupMembershipLost) }
                        guard event.name == "state" else { throw ClientFailure(.invalidGroupResponse) }
                        struct Change: Decodable { let room_id: String; let server_id: String; let revision: UInt64; let rotation_revision: UInt64? }
                        let change = try JSONDecoder().decode(Change.self, from: event.data)
                        guard change.room_id == admission.roomID, change.server_id == state.serverID, change.revision > 0 else { throw ClientFailure(.invalidGroupResponse) }
                        if failures > 0 { onReconnect?() }
                        failures = 0; streamConnected = true
                        try await changed(change.revision, rotationRevision: change.rotation_revision ?? 0); wake()
                    }
                    throw URLError(.networkConnectionLost)
                } catch {
                    if Task.isCancelled || stopped { return }
                    streamConnected = false
                    if error is APIError { await workerFailed(error); return }
                    if let failure = error as? ClientFailure, failure.code == ClientErrorCode.groupMembershipLost.rawValue { await workerFailed(error); return }
                    do { try await networkLost() } catch { await workerFailed(error); return }
                    failures += 1
                    if failures >= 3 { await workerFailed(ClientFailure(.groupConnectionLost)); return }
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                }
            }
        }
    }

    private func requestLease(_ request: GroupRequest, transport: GroupTransport) async throws -> (GroupPulse, ContinuousClock.Instant) {
        let pending = Task { try await transport.pulse(request) }
        leaseRequest = pending
        defer { leaseRequest = nil }
        return try await withTaskCancellationHandler {
            try await pending.value
        } onCancel: { pending.cancel() }
    }

    private func observe(_ reply: GroupPulse, expected: GroupSnapshot, grantingLease: Bool, expectedKeyEpoch: UInt64? = nil,
                         requestStartedAt: ContinuousClock.Instant = .now) async throws {
        try reply.validate(expected: expected, grantingLease: grantingLease, expectedKeyEpoch: expectedKeyEpoch ?? keyEpoch)
        if let current, reply.groupID == current.groupID, reply.revision == current.revision,
           (reply.rotationRevision ?? 0) == (current.rotationRevision ?? 0) {
            publishInformation(reply.roomInformation, state: current, started: requestStartedAt)
        }
        try await changed(reply.revision, rotationRevision: reply.rotationRevision ?? 0)
    }

    private func publishInformation(_ information: GroupRoomInformation?, state: GroupSnapshot, started: ContinuousClock.Instant) {
        guard let information, information.isValid, information.memberCount == state.members.count,
              information.keyEpoch == (state.keyEpoch ?? 0), information.rotationPhase == state.rotation?.phase,
              information.rotationEpoch == state.rotation?.epoch else { onRoomInformation?(nil); return }
        onRoomInformation?(RoomPublicInformation(groupID: state.groupID, information: information, requestStartedAt: started,
                                                unavailable: state.suspended))
    }

    private func changed(_ revision: UInt64, rotationRevision: UInt64 = 0) async throws {
        guard let current else { return }
        let authorizationChanged = revision > current.revision
        guard authorizationChanged || rotationRevision > (current.rotationRevision ?? 0) else { return }
        requestedRevision = max(requestedRevision, revision)
        requestedRotationRevision = max(requestedRotationRevision, rotationRevision); needsSnapshot = true
        if isReady && authorizationChanged { blockCurrent(); try await pause() }
        wake()
    }

    private func workerFailed(_ error: Error) async {
        guard !Task.isCancelled, !stopped else { return }
        if case GroupRequestError.conflict = error { needsSnapshot = true; wake(); return }
        if pendingFailure == nil { pendingFailure = ClientFailure.capture(error, fallback: .groupConnectionLost) }
        lease.revoke(); isReady = false; authorizeMedia?(nil, nil); wake()
        if failurePause == nil {
            // Retire actual media immediately, even while the coordinator is
            // awaiting an untrusted server. A separate task avoids waiting for
            // this same activation task if its callback reported the failure.
            let pendingActivation = activation
            pendingActivation?.cancel(); activation = nil
            failurePause = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await pause()
                await pendingActivation?.value
                wake()
            }
        }
    }

    private func stopWorkers() async {
        let tasks = [heartbeat, leasing, watching]
        heartbeat = nil; leasing = nil; watching = nil
        leaseWakeup?.finish(); leaseWakeup = nil
        for task in tasks { task?.cancel() }
        connection?.cancel(); connection = nil; streamConnected = false
        for task in tasks { await task?.value }
    }

    private func makeRequest(_ operation: String, _ snapshot: GroupSnapshot) -> GroupRequest {
        GroupRequest(roomID: admission.roomID, entryID: admission.entryID, serverID: snapshot.serverID,
                     sessionID: snapshot.sessionID, generation: snapshot.generation, operation: operation)
    }

    private func offer(for package: String, state: GroupSnapshot, epoch: UInt64) async throws -> V5RoundProof {
        guard let policy = identityPolicy, let bytes = Data(base64Encoded: package) else { throw V5IdentityError.invalid }
        let members = epoch == 0 ? state.members : (state.rotation?.members ?? [])
        let bindings = try members.map { peer -> V5EntryBinding in guard let value = peer.binding else { throw V5IdentityError.invalid }; return value }
        var result = V5RoundProof(groupID: epoch == 0 ? state.groupID : "\(state.groupID)/key/\(epoch)", keyEpoch: epoch,
            policyHash: policy.digest, rosterHash: V5Crypto.rosterHash(bindings), keyPackageHash: V5Crypto.hash(bytes))
        result.signature = try await native.sign(result.message)
        return result
    }

    private func ready(for state: GroupSnapshot, epoch: UInt64, confirmation: String) async throws -> V5ReadyProof {
        guard let policy = identityPolicy else { throw V5IdentityError.invalid }
        let members = epoch == 0 ? state.members : (state.rotation?.members ?? [])
        let bindings = try members.map { peer -> V5EntryBinding in guard let value = peer.binding else { throw V5IdentityError.invalid }; return value }
        var result = V5ReadyProof(groupID: epoch == 0 ? state.groupID : "\(state.groupID)/key/\(epoch)", keyEpoch: epoch,
            policyHash: policy.digest, rosterHash: V5Crypto.rosterHash(bindings), confirmation: confirmation)
        result.signature = try await native.sign(result.message)
        return result
    }

    private func activate(_ members: [MLSPeer]) {
        activation?.cancel()
        activation = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation(); try await onReady(members)
                try Task.checkCancellation(); activationComplete = true; wake()
            }
            catch { await workerFailed(error) }
        }
    }
}
