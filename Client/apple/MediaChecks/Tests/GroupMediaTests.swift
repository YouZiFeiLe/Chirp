import ChirpMLS
import Foundation
import LiveKitWebRTC
import Testing
@testable import LiveKit
@testable import LiveKitNanopb

@Test func externalICEServersAreIgnoredBeforeJoinAndAfterJoinOrReconnect() {
    let room = Room(connectOptions: ConnectOptions(
        iceServers: [IceServer(urls: ["stun:client.invalid:3478"], username: nil, credential: nil)],
        iceTransportPolicy: .relay, isDscpEnabled: true))
    let server = Livekit_ICEServer.with { $0.urls = ["turn:server.invalid:3478"] }
    let policy = Livekit_ClientConfiguration.with { $0.forceRelay = .enabled }
    let responses: [SignalClient.ConnectResponse?] = [
        nil,
        .join(.with { $0.iceServers = [server]; $0.clientConfiguration = policy }),
        .reconnect(.with { $0.iceServers = [server]; $0.clientConfiguration = policy }),
    ]
    for response in responses {
        let configuration = room.makeRTCConfiguration(connectResponse: response)
        #expect(configuration.iceServers.isEmpty)
        #expect(configuration.iceTransportPolicy == .all)
        #expect(configuration.enableDscp)
    }
}

private func provider(keyRingSize: Int32 = 1) -> BaseKeyProvider {
    BaseKeyProvider(options: KeyProviderOptions(sharedKey: false, ratchetWindowSize: 0,
        uncryptedMagicBytes: Data(), keyRingSize: keyRingSize, discardFrameWhenCryptorNotReady: true,
        keyDerivationAlgorithm: .hkdf))
}

private func encryptedPacket(_ plaintext: Data, identity: String, using keys: BaseKeyProvider) throws -> LKRTCEncryptedPacket {
    let cryptor = try #require(LKRTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: keys.rtcKeyProvider))
    return try #require(cryptor.encrypt(identity, keyIndex: 0, data: plaintext))
}

@Test func chatPacketsPinTheirOriginalProviderAndLeaseAndNeverFallBackToPlaintext() async throws {
    let room = Room()
    let manager = E2EEManager(options: EncryptionOptions(keyProvider: provider()))
    manager.setup(room: room)
    defer { withExtendedLifetime(room) { manager.cleanUp() } }
    let pair = DataChannelPair()
    pair.set(e2eeManager: manager)
    let first = provider()
    let identity = "a.login.entry"
    first.setKey(keyData: Data(repeating: 31, count: 32), participantId: identity, index: 0)
    await manager.chirpReplaceKeyProvider(first)
    let plaintext = Data("ephemeral chat message".utf8)
    let packet = Livekit_DataPacket.with {
        $0.kind = .reliable
        $0.participantIdentity = identity
        $0.destinationIdentities = [identity, "b.login.entry"]
        $0.user = .with {
            $0.participantIdentity = identity
            $0.topic = "chirp.room-chat.v1"
            $0.payload = plaintext
        }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    let expiry = Date().addingTimeInterval(60)
    let encrypted = try pair.chirpEncrypt(packet, using: first, authorization: { deadline > .now && expiry > Date() })
    #expect(encrypted.encryptedPacketOrNil != nil)
    #expect(encrypted.destinationIdentities == packet.destinationIdentities)
    let wire = try encrypted.serializedData()
    #expect(wire.range(of: plaintext) == nil)
    let decrypted = try manager.handle(encryptedData: encrypted.encryptedPacket.toRTCEncryptedPacket(), participantIdentity: identity)
    let decoded = try Livekit_EncryptedPacketPayload(serializedBytes: decrypted)
    #expect(decoded.user.payload == plaintext && decoded.user.topic == "chirp.room-chat.v1")
    #expect(throws: LiveKitError.self) { try pair.chirpEncrypt(packet, using: first, authorization: { false }) }
    #expect(throws: LiveKitError.self) { try pair.chirpEncrypt(packet, using: first, authorization: { expiry < Date() }) }

    let next = provider()
    next.setKey(keyData: Data(repeating: 33, count: 32), participantId: identity, index: 0)
    await manager.chirpReplaceKeyProvider(next)
    #expect(throws: LiveKitError.self) { try pair.chirpEncrypt(packet, using: first, authorization: { deadline > .now && expiry > Date() }) }
    #expect(throws: LiveKitError.self) { try manager.handle(encryptedData: encrypted.encryptedPacket.toRTCEncryptedPacket(), participantIdentity: identity) }
    let fresh = try pair.chirpEncrypt(packet, using: next, authorization: { deadline > .now && expiry > Date() })
    #expect(fresh.encryptedPacketOrNil != nil)
    await manager.chirpReplaceKeyProvider(provider())
    #expect(throws: LiveKitError.self) { try pair.chirpEncrypt(packet, using: next, authorization: { deadline > .now && expiry > Date() }) }
    pair.set(e2eeManager: nil)
    #expect(throws: LiveKitError.self) { try pair.chirpEncrypt(packet, using: next, authorization: { deadline > .now && expiry > Date() }) }
}

@Test func encryptedRoomSetupStartsWithEmptyKeysAndStaysEncrypted() throws {
    let bootstrap = provider()
    let room = Room()
    let manager = E2EEManager(options: EncryptionOptions(keyProvider: bootstrap))
    defer { withExtendedLifetime(room) { manager.cleanUp() } }

    // Room.connect calls this before connecting to the server or starting audio.
    manager.setup(room: room)
    #expect(manager.keyProvider === bootstrap)
    #expect(manager.frameEncryptionType == .gcm)
    #expect(manager.dataChannelEncryptionType == .gcm)

    let sender = provider()
    sender.setKey(keyData: Data(repeating: 3, count: 32), participantId: "a.login_test", index: 0)
    let packet = try encryptedPacket(Data("keys have not arrived".utf8), identity: "a.login_test", using: sender)
    #expect(throws: LiveKitError.self) { try manager.handle(encryptedData: packet, participantIdentity: "a.login_test") }
}

@Test func initializedRoomRekeyUsesFreshDataCryptorAndRejectsRetiredKeys() async throws {
    let room = Room()
    let manager = E2EEManager(options: EncryptionOptions(keyProvider: provider()))
    defer { withExtendedLifetime(room) { manager.cleanUp() } }
    manager.setup(room: room)

    let identity = "a.login_test"
    let plaintext = Data("initialized room rekey".utf8)
    let first = provider()
    first.setKey(keyData: Data(repeating: 5, count: 32), participantId: identity, index: 0)
    await manager.chirpReplaceKeyProvider(first)
    let oldPacket = try encryptedPacket(plaintext, identity: identity, using: first)
    #expect(try manager.handle(encryptedData: oldPacket, participantIdentity: identity) == plaintext)

    let next = provider()
    next.setKey(keyData: Data(repeating: 7, count: 32), participantId: identity, index: 0)
    await manager.chirpReplaceKeyProvider(next)
    #expect(manager.keyProvider === next)
    #expect(first.chirpIsRetired)
    #expect(throws: LiveKitError.self) { try manager.handle(encryptedData: oldPacket, participantIdentity: identity) }
    let newPacket = try encryptedPacket(plaintext, identity: identity, using: next)
    #expect(try manager.handle(encryptedData: newPacket, participantIdentity: identity) == plaintext)
    #expect(manager.frameEncryptionType == .gcm)
    #expect(manager.dataChannelEncryptionType == .gcm)
}

@Test(arguments: [false, true])
func encryptedRoomCanSetupAgainAfterCleanup(useNewRoom: Bool) async throws {
    let room = Room()
    let manager = E2EEManager(options: EncryptionOptions(keyProvider: provider()))
    manager.setup(room: room)
    let identity = "a.login_test"
    let plaintext = Data("room setup after cleanup".utf8)
    let first = provider()
    first.setKey(keyData: Data(repeating: 11, count: 32), participantId: identity, index: 0)
    await manager.chirpReplaceKeyProvider(first)
    let oldPacket = try encryptedPacket(plaintext, identity: identity, using: first)
    #expect(try manager.handle(encryptedData: oldPacket, participantIdentity: identity) == plaintext)

    manager.cleanUp()
    #expect(first.chirpIsRetired)
    #expect(throws: LiveKitError.self) { try manager.handle(encryptedData: oldPacket, participantIdentity: identity) }
    let nextRoom = useNewRoom ? Room() : room
    defer { withExtendedLifetime((room, nextRoom)) { manager.cleanUp() } }
    manager.setup(room: nextRoom)
    #expect(throws: LiveKitError.self) { try manager.handle(encryptedData: oldPacket, participantIdentity: identity) }

    let next = provider()
    next.setKey(keyData: Data(repeating: 13, count: 32), participantId: identity, index: 0)
    await manager.chirpReplaceKeyProvider(next)
    let newPacket = try encryptedPacket(plaintext, identity: identity, using: next)
    #expect(try manager.handle(encryptedData: newPacket, participantIdentity: identity) == plaintext)
    #expect(manager.dataChannelEncryptionType == .gcm)
}

private func establish(_ clients: [MLSClient], id: String) async throws -> [MLSPeer] {
    let members = try await V5TestIdentity.peers(clients, groupID: id)
    let welcome = try await clients[0].create(groupID: id, members: members)
    for client in clients.dropFirst() {
        #expect(try await client.join(groupID: id, members: members, welcome: welcome.welcome) == welcome.confirmation)
    }
    return members
}

@Test func mlsBytesInteroperateWithNativeWebRTCCryptoAndRejectOldRounds() async throws {
    let alice = try MLSClient(identity: "a.login_test")
    let bob = try MLSClient(identity: "b.login_test")
    let members = try await establish([alice, bob], id: "media/1")
    let sender = provider(), receiver = provider()
    for member in members {
        var key = try await alice.senderKey(for: member.identity)
        let expected = key
        sender.setKey(keyData: key, participantId: member.identity, index: 0)
        key.resetBytes(in: 0..<key.count)
        #expect(sender.exportKey(participantId: member.identity, index: 0) == expected)
        receiver.setKey(keyData: try await bob.senderKey(for: member.identity), participantId: member.identity, index: 0)
    }
    let encryptor = try #require(LKRTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: sender.rtcKeyProvider))
    let decryptor = try #require(LKRTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: receiver.rtcKeyProvider))
    let plain = Data("native WebRTC AEAD payload".utf8)
    let oldPacket = try #require(encryptor.encrypt(alice.identity, keyIndex: 0, data: plain))
    #expect(decryptor.decrypt(alice.identity, encryptedPacket: oldPacket) == plain)
    #expect(decryptor.decrypt(bob.identity, encryptedPacket: oldPacket) == nil)
    var changed = oldPacket.data
    changed[changed.startIndex] ^= 1
    let tampered = LKRTCEncryptedPacket(data: changed, iv: oldPacket.iv, keyIndex: oldPacket.keyIndex)
    #expect(decryptor.decrypt(alice.identity, encryptedPacket: tampered) == nil)
    let empty = provider()
    let paused = try #require(LKRTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: empty.rtcKeyProvider))
    #expect(paused.decrypt(alice.identity, encryptedPacket: oldPacket) == nil)

    _ = try await establish([alice], id: "media/2")
    let fresh = provider()
    fresh.setKey(keyData: try await alice.senderKey(for: alice.identity), participantId: alice.identity, index: 0)
    let next = try #require(LKRTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: fresh.rtcKeyProvider))
    let newPacket = try #require(next.encrypt(alice.identity, keyIndex: 0, data: plain))
    #expect(decryptor.decrypt(alice.identity, encryptedPacket: newPacket) == nil)
    #expect(next.decrypt(alice.identity, encryptedPacket: oldPacket) == nil)
    #expect(next.decrypt(alice.identity, encryptedPacket: newPacket) == plain)
}

@Test func orderedSDKRekeyReleasesRetiredProvidersAndKeepsGCM() async throws {
    let bootstrap = provider()
    let manager = E2EEManager(options: EncryptionOptions(keyProvider: bootstrap))
    var first: BaseKeyProvider? = provider()
    weak let retired = first
    first?.setKey(keyData: Data(repeating: 9, count: 32), participantId: "a.login_test", index: 0)
    await manager.chirpReplaceKeyProvider(try #require(first))
    #expect(manager.keyProvider === first)
    first = nil
    #expect(retired != nil)
    let paused = provider()
    await manager.chirpReplaceKeyProvider(paused)
    #expect(manager.keyProvider === paused)
    #expect(retired == nil)
    #expect(manager.frameEncryptionType == .gcm)
    // This SDK returns empty Data for a missing native key.
    #expect(manager.keyProvider.exportKey(participantId: "a.login_test", index: 0)?.isEmpty != false)
    #expect(manager.keyProvider.options.uncryptedMagicBytes.isEmpty)
    #expect(manager.keyProvider.options.discardFrameWhenCryptorNotReady)
    #expect(!manager.keyProvider.options.sharedKey)
}

@Test func nativeRTPSenderRequiresAnInstalledCryptorAndStaysMutedDuringPreparation() async throws {
    let room = Room()
    let keys = provider()
    let identity = Participant.Identity(from: "a.login_test")
    keys.setKey(keyData: Data(repeating: 7, count: 32), participantId: identity.stringValue, index: 0)
    let manager = E2EEManager(options: EncryptionOptions(keyProvider: keys))
    let track = await LocalAudioTrack.createTrack()
    try await track.mute()
    let publication = LocalTrackPublication(info: .with {
        $0.sid = "TR_prepared"
        $0.type = .audio
        $0.source = .microphone
        $0.encryption = .gcm
    }, participant: room.localParticipant)
    await publication.set(track: track)
    // A publication flag alone is insufficient: there is no native sender yet.
    #expect(await manager.chirpPrepareLocalTrack(publication, identity: identity) == false)
    let (peer, sender) = try await RTC.run {
        let config = LKRTCConfiguration()
        config.iceServers = []
        let peer = try #require(RTC.createPeerConnection(config, constraints: .defaultPCConstraints))
        let options = LKRTCRtpTransceiverInit()
        options.direction = .sendOnly
        let transceiver = try #require(peer.addTransceiver(with: track.mediaTrack.raw, init: options))
        return (RTCBox(peer), RTCSender(transceiver.sender))
    }
    await track.set(transport: nil, rtpSender: sender)
    #expect(await manager.chirpPrepareLocalTrack(publication, identity: identity))
    // Repeated publish callbacks must retain a prepared sender. Preparation
    // never grants permission to unmute or starts the microphone capture.
    #expect(await manager.chirpPrepareLocalTrack(publication, identity: identity))
    #expect(publication.isMuted)
    #expect(await RTC.run { !track.mediaTrack.raw.isEnabled })
    #expect(track.trackState == .stopped)
    let plaintext = LocalTrackPublication(info: .with {
        $0.sid = "TR_plaintext"
        $0.type = .audio
        $0.encryption = .none
    }, participant: room.localParticipant)
    await plaintext.set(track: track)
    #expect(await manager.chirpPrepareLocalTrack(plaintext, identity: identity) == false)
    await track.set(transport: nil, rtpSender: nil)
    #expect(await manager.chirpPrepareLocalTrack(publication, identity: identity) == false)
    let replacement = try await RTC.run {
        let options = LKRTCRtpTransceiverInit()
        options.direction = .sendOnly
        return RTCSender(try #require(peer.value.addTransceiver(with: track.mediaTrack.raw, init: options)).sender)
    }
    await track.set(transport: nil, rtpSender: replacement)
    #expect(await manager.chirpPrepareLocalTrack(publication, identity: identity) == false)
    // A complete reconnect retires the provider. Muted SDK re-publication is
    // allowed; the application's unmute barrier must still reject old keys.
    manager.cleanUp(isFullReconnect: true)
    #expect(await manager.chirpPrepareMutedLocalTrack(publication, identity: identity))
    #expect(await manager.chirpPrepareLocalTrack(publication, identity: identity) == false)
    await RTC.run { peer.value.close() }
}

@Test func rekeyRetiresMaterialStillHeldByNativeCryptors() async throws {
    let keys = provider()
    let identity = "a.login_test"
    let secret = Data(repeating: 17, count: 32)
    keys.setKey(keyData: secret, participantId: identity, index: 0)
    let retained = try #require(LKRTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: keys.rtcKeyProvider))
    let payload = Data("retired native material".utf8)
    let packet = try #require(retained.encrypt(identity, keyIndex: 0, data: payload))
    #expect(retained.decrypt(identity, encryptedPacket: packet) == payload)
    let manager = E2EEManager(options: EncryptionOptions(keyProvider: provider()))
    await manager.chirpReplaceKeyProvider(keys)
    await manager.chirpReplaceKeyProvider(provider())
    #expect(keys.exportKey(participantId: identity, index: 0) != secret)
    #expect(retained.decrypt(identity, encryptedPacket: packet) == nil)
}

@Test func nativeKeySlotsStageWithoutChangingSendingAndRetireAcrossSlotReuse() async throws {
    let room = Room()
    let keys = BaseKeyProvider(options: KeyProviderOptions(sharedKey: false, ratchetWindowSize: 0,
        uncryptedMagicBytes: Data(), keyRingSize: 2, discardFrameWhenCryptorNotReady: true, keyDerivationAlgorithm: .hkdf))
    let identity = "a.login.entry"
    keys.setKey(keyData: Data(repeating: 41, count: 32), participantId: identity, index: 0)
    let manager = E2EEManager(options: EncryptionOptions(keyProvider: provider()))
    manager.setup(room: room)
    await manager.chirpReplaceKeyProvider(keys)
    defer { withExtendedLifetime(room) { manager.cleanUp() } }
    let plaintext = Data("audio-key epoch overlap".utf8)
    var previous = try manager.chirpEncrypt(data: plaintext, participantIdentity: identity, using: keys)
    #expect(await manager.chirpActivateKeyIndex(1, using: keys) == false)
    for (cycle, index) in [Int32(1), 0, 1].enumerated() {
        let oldIndex = keys.getCurrentKeyIndex()
        #expect(manager.chirpStageKeys([identity: Data(repeating: 99, count: 32)], index: oldIndex, using: keys) == false)
        #expect(manager.chirpStageKeys([identity: Data(repeating: UInt8(51 + cycle), count: 32)], index: index, using: keys))
        #expect(keys.getCurrentKeyIndex() == oldIndex)
        let duringPreparation = try manager.chirpEncrypt(data: plaintext, participantIdentity: identity, using: keys)
        #expect(duringPreparation.keyIndex == UInt32(oldIndex))
        #expect(try manager.handle(encryptedData: previous, participantIdentity: identity) == plaintext)
        #expect(await manager.chirpActivateKeyIndex(index, using: keys))
        #expect(manager.keyProvider === keys && !keys.chirpIsRetired)
        let next = try manager.chirpEncrypt(data: plaintext, participantIdentity: identity, using: keys)
        #expect(next.keyIndex == UInt32(index))
        #expect(try manager.handle(encryptedData: next, participantIdentity: identity) == plaintext)
        #expect(try manager.handle(encryptedData: previous, participantIdentity: identity) == plaintext)
        #expect(manager.chirpRetireKeyIndex(index, using: keys) == false)
        #expect(manager.chirpRetireKeyIndex(oldIndex, using: keys))
        #expect(throws: LiveKitError.self) { try manager.handle(encryptedData: previous, participantIdentity: identity) }
        #expect(await manager.chirpActivateKeyIndex(oldIndex, using: keys) == false)
        #expect(try manager.handle(encryptedData: next, participantIdentity: identity) == plaintext)
        previous = next
    }
    // Full revocation also retires the staged/active native slots retained by
    // any third-party cryptor, rather than merely dropping Swift references.
    let retained = try #require(LKRTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: keys.rtcKeyProvider))
    manager.cleanUp()
    #expect(keys.chirpIsRetired)
    #expect(retained.decrypt(identity, encryptedPacket: previous) == nil)
    #expect(manager.chirpStageKeys([identity: Data(repeating: 99, count: 32)], index: 0, using: keys) == false)
}

@Test func providerReplacementMovesIndexObserversAndOrderedActivationRejectsStaleGenerations() async throws {
    let room = Room()
    let previous = provider(keyRingSize: 2)
    let manager = E2EEManager(options: EncryptionOptions(keyProvider: previous))
    for _ in 0..<3 { previous.setCurrentKeyIndex(0) }
    let old = previous.currentKeyIndexWithGeneration()
    manager.setSenderKeyIndex(old.index, generation: old.generation)
    #expect(previous.keyIndexObserverCount == 1)

    let keys = provider(keyRingSize: 2)
    let identity = "a.login.entry"
    keys.setKey(keyData: Data(repeating: 61, count: 32), participantId: identity, index: 0)
    await manager.chirpReplaceKeyProvider(keys)
    #expect(previous.keyIndexObserverCount == 0)
    #expect(keys.keyIndexObserverCount == 1)

    let publication = LocalTrackPublication(info: .with { $0.sid = "TR_index_rotation" },
                                            participant: room.localParticipant)
    let (peer, cryptor) = try await RTC.run {
        let config = LKRTCConfiguration()
        config.iceServers = []
        let peer = try #require(RTC.createPeerConnection(config, constraints: .defaultPCConstraints))
        let track = RTC.createAudioTrack(source: RTC.createAudioSource(nil))
        let sender = try #require(peer.add(track, streamIds: [identity]))
        let cryptor = try #require(LKRTCFrameCryptor(factory: RTC.peerConnectionFactory,
            rtpSender: sender, participantId: identity, algorithm: .aesGcm, keyProvider: keys.rtcKeyProvider))
        manager.install(frameCryptor: cryptor, for: publication, participantIdentity: Participant.Identity(from: identity))
        return (RTCBox(peer), RTCBox(cryptor))
    }
    defer { manager.cleanUp() }
    #expect(await RTC.run { cryptor.value.keyIndex } == 0)
    #expect(manager.chirpStageKeys([identity: Data(repeating: 62, count: 32)], index: 1, using: keys))
    #expect(await RTC.run { cryptor.value.keyIndex } == 0)
    #expect(await manager.chirpActivateKeyIndex(1, using: keys))
    let activated = keys.currentKeyIndexWithGeneration()
    #expect(activated.index == 1 && activated.generation == 1)
    #expect(await RTC.run { cryptor.value.keyIndex } == 1)

    // A notification copied before the activation barrier cannot roll RTP back.
    manager.setSenderKeyIndex(0, generation: activated.generation - 1)
    #expect(await RTC.run { cryptor.value.keyIndex } == 1)
    previous.setCurrentKeyIndex(0)
    #expect(await RTC.run { cryptor.value.keyIndex } == 1)

    // Installing a remote participant's key never changes the local send index.
    keys.setKey(keyData: Data(repeating: 63, count: 32), participantId: "b.login.entry", index: 0)
    #expect(keys.getCurrentKeyIndex() == 1)
    #expect(await RTC.run { cryptor.value.keyIndex } == 1)
    keys.setCurrentKeyIndex(0)
    #expect(await RTC.run { cryptor.value.keyIndex } == 0)
    await RTC.run { peer.value.close() }
}

@Test func oldNativeReceiveSlotExpiresWithoutServerCompletion() async throws {
    let keys = provider(keyRingSize: 2), sender = "expiry.peer"
    let old = Data(repeating: 41, count: 32), fresh = Data(repeating: 42, count: 32)
    keys.setKey(keyData: old, participantId: sender, index: 0)
    keys.setKey(keyData: fresh, participantId: sender, index: 1)
    let cryptor = try #require(LKRTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: keys.rtcKeyProvider))
    let plain = Data("old authorized frame".utf8)
    let packet = try #require(cryptor.encrypt(sender, keyIndex: 0, data: plain))
    #expect(cryptor.decrypt(sender, encryptedPacket: packet) == plain)
    #expect(keys.chirpActivateKeyIndex(1))
    keys.chirpExpireKeyIndex(0, at: .now.advanced(by: .milliseconds(40)))
    try await Task.sleep(for: .milliseconds(150))
    #expect(cryptor.decrypt(sender, encryptedPacket: packet) == nil)
    #expect(keys.exportKey(participantId: sender, index: 1) == fresh)
}

@Test func delayedSlotRetirementCannotEraseANewerCandidate() async throws {
    let keys = provider(keyRingSize: 2), sender = "expiry.reused"
    keys.setKey(keyData: Data(repeating: 41, count: 32), participantId: sender, index: 0)
    keys.setKey(keyData: Data(repeating: 42, count: 32), participantId: sender, index: 1)
    #expect(keys.chirpActivateKeyIndex(1))
    keys.chirpExpireKeyIndex(0, at: .now.advanced(by: .milliseconds(40)))
    let next = Data(repeating: 43, count: 32)
    #expect(keys.chirpStageKeys([sender: next], index: 0))
    try await Task.sleep(for: .milliseconds(150))
    #expect(keys.exportKey(participantId: sender, index: 0) == next)
}
