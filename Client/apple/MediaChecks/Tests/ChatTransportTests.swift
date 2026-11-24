import AVFAudio
import ChirpMLS
import Foundation
import Synchronization
@testable import LiveKit
@testable import LiveKitNanopb
import Testing

@MainActor
private final class ChatTransportPeer: NSObject, RoomDelegate {
    let identity: String
    let native: MLSClient
    private(set) var messages: [String] = []
    private(set) var decryptFailures = 0
    private(set) var keys: BaseKeyProvider
    private var acceptsMessages = true
    lazy var room = Room(delegate: self, roomOptions: RoomOptions(encryptionOptions: EncryptionOptions(keyProvider: keys)))

    init(_ identity: String) throws {
        self.identity = identity
        native = try MLSClient(identity: identity)
        keys = Self.emptyKeys()
        super.init()
    }

    static func emptyKeys(authorized: @escaping @Sendable () -> Bool = { true }) -> BaseKeyProvider {
        BaseKeyProvider(chirpAudioAuthorization: authorized)
    }

    func connect(url: String, token: String) async throws {
        print("Chat fixture connecting: \(identity)")
        try await room.connect(url: url, token: token, connectOptions: ConnectOptions(autoSubscribe: false, enableMicrophone: false))
        print("Chat fixture connected: \(identity)")
    }

    func install(_ members: [MLSPeer]) async throws {
        let next = Self.emptyKeys()
        for peer in members {
            var bytes = try await native.senderKey(for: peer.identity)
            next.setKey(keyData: bytes, participantId: peer.identity, index: 0)
            bytes.resetBytes(in: 0..<bytes.count)
        }
        try await replaceKeys(next)
    }

    func replaceKeys(_ next: BaseKeyProvider) async throws {
        let manager = try #require(room.e2eeManager)
        next.chirpAuthorizeVoiceKeyIndex(next.getCurrentKeyIndex())
        await manager.chirpReplaceKeyProvider(next)
        keys = next
    }

    func send(_ text: String, to peers: [ChatTransportPeer]) async throws {
        try await send(text, toIdentities: peers.map(\.identity))
    }

    func send(_ text: String, toIdentities identities: [String]) async throws {
        try await room.localParticipant.chirpPublishEncrypted(data: Data(text.utf8), topic: "chirp.room-chat.v1",
            destinations: identities.map { Participant.Identity(from: $0) }, keyProvider: keys, authorization: { true })
        messages.append(text)
    }

    func close() async {
        acceptsMessages = false
        messages.removeAll()
        if let manager = room.e2eeManager { await manager.chirpReplaceKeyProvider(Self.emptyKeys()) }
        await room.disconnect()
        try? await native.clear()
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data,
                          forTopic topic: String, encryptionType: EncryptionType) {
        let sender = participant?.identity?.stringValue
        print("Chat fixture data callback: receiver=\(identity), sender=\(sender ?? "nil"), encryption=\(encryptionType), bytes=\(data.count)")
        Task { @MainActor [weak self] in
            guard let self, acceptsMessages, self.room === room, sender != nil, sender != identity,
                  topic == "chirp.room-chat.v1", encryptionType == .gcm,
                  let text = String(data: data, encoding: .utf8) else { return }
            messages.append(text)
        }
    }

    nonisolated func room(_ room: Room, didFailToDecryptDataWithEror error: LiveKitError) {
        print("Chat fixture decrypt failure: \(identity), \(error.localizedDescription)")
        Task { @MainActor [weak self] in
            guard let self, acceptsMessages, self.room === room else { return }
            decryptFailures += 1
        }
    }
}

@MainActor
private func chatRound(_ peers: [ChatTransportPeer], id: String) async throws {
    let members = try await V5TestIdentity.peers(peers.map(\.native), groupID: id)
    let leader = peers[0]
    let welcome = try await leader.native.create(groupID: id, members: members)
    for peer in peers.dropFirst() {
        #expect(try await peer.native.join(groupID: id, members: members, welcome: welcome.welcome) == welcome.confirmation)
    }
    for peer in peers { try await peer.install(members) }
}

@MainActor
private func waitForChat(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !condition() && .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    try #require(condition())
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_CHAT_TEST_CONFIG"] != nil))
@MainActor
func chatLiveKitTransportIntegration() async throws {
    struct Configuration: Decodable { let url: String; let tokens: [String: String] }
    let path = try #require(ProcessInfo.processInfo.environment["CHIRP_CHAT_TEST_CONFIG"])
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    var peers: [ChatTransportPeer] = []
    func connect(_ identity: String) async throws -> ChatTransportPeer {
        let peer = try ChatTransportPeer(identity)
        peers.append(peer)
        try await peer.connect(url: config.url, token: try #require(config.tokens[identity]))
        return peer
    }
    do {
        let a = try await connect("a.login.entry1")
        try await chatRound([a], id: "friends/local/session/1")
        try await a.send("消息 1", to: [a])
        let b = try await connect("b.login.entry1")
        try await waitForChat { a.room.remoteParticipants[Participant.Identity(from: b.identity)] != nil }
        try await chatRound([a, b], id: "friends/local/session/2")
        try await b.send("消息 2", to: [a, b])
        try await waitForChat { a.messages.count == 2 }
        try await a.send("消息 3", to: [a, b])
        try await waitForChat { b.messages.count == 2 }
        // An admitted peer knows group exporter materials, so bind the inner
        // claimed sender to the identity asserted by the SFU, not just to GCM.
        let forged = Livekit_DataPacket.with {
            $0.kind = .reliable
            $0.user = .with {
                $0.participantIdentity = a.identity
                $0.topic = "chirp.room-chat.v1"
                $0.payload = Data("forged sender".utf8)
            }
        }
        try await b.room.send(dataPacket: forged)
        try await waitForChat { a.decryptFailures > 0 }
        #expect(a.messages == ["消息 1", "消息 2", "消息 3"])
        let c = try await connect("c.login.entry1")
        try await waitForChat { a.room.remoteParticipants[Participant.Identity(from: c.identity)] != nil && b.room.remoteParticipants[Participant.Identity(from: c.identity)] != nil }
        try await chatRound([a, b, c], id: "friends/local/session/3")
        try await c.send("消息 4", to: [a, b, c])
        try await waitForChat { a.messages.count == 4 && b.messages.count == 3 }
        #expect(a.messages == ["消息 1", "消息 2", "消息 3", "消息 4"])
        #expect(b.messages == ["消息 2", "消息 3", "消息 4"])
        #expect(c.messages == ["消息 4"])

        await c.close()
        try await chatRound([a, b], id: "friends/local/session/4")
        let c2 = try await connect("c.login.entry2")
        try await chatRound([a, b, c2], id: "friends/local/session/5")
        #expect(c.messages.isEmpty && c2.messages.isEmpty)
        try await a.send("重新加入后的消息", to: [a, b, c2])
        try await waitForChat { c2.messages == ["重新加入后的消息"] }
        await a.close(); await b.close(); await c2.close()
        let a2 = try await connect("a.login.entry2")
        try await chatRound([a2], id: "friends/local/new-session/1")
        try await Task.sleep(for: .milliseconds(200))
        #expect(a2.messages.isEmpty)
    } catch {
        for peer in peers { await peer.close() }
        throw error
    }
    for peer in peers { await peer.close() }
}

private final class ProbeAudioSink: NSObject, AudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private let threshold: Float
    private var count = 0
    private var firstSignal: ContinuousClock.Instant?
    init(threshold: Float = 0.025) { self.threshold = threshold }
    var firstSignalAt: ContinuousClock.Instant? { lock.withLock { firstSignal } }
    var voicedBuffers: Int { lock.withLock { count } }
    var hasSignal: Bool { voicedBuffers > 0 }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let count = Int(pcmBuffer.frameLength)
        let stride = pcmBuffer.stride
        let detected: Bool
        if let floats = pcmBuffer.floatChannelData {
            detected = (0..<count).contains { abs(floats[0][$0 * stride]) > threshold }
        } else if let samples = pcmBuffer.int16ChannelData {
            let level = Int(threshold * 32_768)
            detected = (0..<count).contains { abs(Int(samples[0][$0 * stride])) > level }
        } else { detected = false }
        if detected {
            lock.withLock {
                if self.count == 0 { firstSignal = .now }
                self.count += 1
            }
        }
    }
}

@MainActor
private func syntheticVoice(amplitude: Float = 0.3) throws -> Task<Void, Error> {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    return Task {
        var frame = 0
        while !Task.isCancelled {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
            buffer.frameLength = 480
            let samples = try #require(buffer.floatChannelData?[0])
            for index in 0..<480 {
                samples[index] = Float(sin(Double(frame + index) * 2 * .pi * 528 / 48_000)) * amplitude
            }
            frame += 480
            AudioManager.shared.mixer.capture(appAudio: buffer)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_WINDOWS_MEDIA_CONFIG"] != nil))
@MainActor
func windowsMediaInteroperability() async throws {
    struct Configuration: Decodable {
        let url: String
        let tokens: [String: String]
        let appleDirectory: String
    }
    let path = try #require(ProcessInfo.processInfo.environment["CHIRP_WINDOWS_MEDIA_CONFIG"])
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let directory = URL(fileURLWithPath: config.appleDirectory, isDirectory: true)
    let local = "a.login.entry1", remote = "b.login.entry1"
    let peer = try ChatTransportPeer(local)
    let sink = ProbeAudioSink()
    let input = ProbeAudioSink()
    try AudioManager.shared.setManualRenderingMode(true)
    defer { try? AudioManager.shared.setManualRenderingMode(false) }
    try AudioManager.shared.setEngineAvailability(.default)
    AudioManager.shared.mixer.appVolume = 1
    AudioManager.shared.add(localAudioRenderer: input)
    defer { AudioManager.shared.remove(localAudioRenderer: input) }
    var oscillator: Task<Void, Error>?
    do {
        try await peer.connect(url: config.url, token: try #require(config.tokens[local]))
        let provider = ChatTransportPeer.emptyKeys()
        provider.setKey(keyData: Data(1...32), participantId: local, index: 0)
        provider.setKey(keyData: Data(33...64), participantId: remote, index: 0)
        try await peer.replaceKeys(provider)
        try Data().write(to: directory.appendingPathComponent("apple-ready"), options: .atomic)
        let remoteID = Participant.Identity(from: remote)
        try await waitForChat { peer.room.remoteParticipants[remoteID] != nil }
        try Data().write(to: directory.appendingPathComponent("apple-peer-ready"), options: .atomic)
        try await waitForChat { peer.messages.contains("Chromium → Swift") || peer.decryptFailures > 0 }
        try #require(peer.messages.contains("Chromium → Swift"))
        try await peer.send("Swift → Chromium", toIdentities: [remote])

        let track = await LocalAudioTrack.createTrack(options: .noProcessing, reportStatistics: true)
        try await track.mute()
        let localPublication = try await peer.room.localParticipant.publish(audioTrack: track, options: AudioPublishOptions(dtx: false, red: false))
        let manager = try #require(peer.room.e2eeManager)
        try #require(await manager.chirpPrepareLocalTrack(localPublication, identity: Participant.Identity(from: local)))
        try await track.unmute()
        oscillator = try syntheticVoice()
        try await waitForChat { peer.room.remoteParticipants[remoteID]?.audioTracks.first != nil }
        let publication = try #require(peer.room.remoteParticipants[remoteID]?.audioTracks.first as? RemoteTrackPublication)
        try await publication.set(subscribed: true)
        try await waitForChat { publication.track is RemoteAudioTrack }
        try #require(await manager.chirpPrepareRemoteTrack(publication, identity: remoteID))
        let remoteTrack = try #require(publication.track as? RemoteAudioTrack)
        remoteTrack.add(audioRenderer: sink)
        defer { remoteTrack.remove(audioRenderer: sink) }
        try await waitForChat { input.hasSignal }
        print("Apple media probe measured synthetic local PCM")
        try await waitForChat { sink.hasSignal }
        print("Apple media probe received Chromium PCM")
        try await waitForChat { track.statistics?.outboundRtpStream.contains { ($0.packetsSent ?? 0) > 10 } == true }
        print("Apple media probe sent RTP packets")
        try await waitForChat { FileManager.default.fileExists(atPath: directory.appendingPathComponent("web-done").path) }
    } catch {
        oscillator?.cancel()
        _ = await oscillator?.result
        await peer.close()
        throw error
    }
    oscillator?.cancel()
    _ = await oscillator?.result
    await peer.close()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_CHAT_TEST_CONFIG"] != nil))
@MainActor func subscribedVoiceWaitsForLeaseAcrossRekey() async throws {
    struct Configuration: Decodable { let url: String; let tokens: [String: String] }
    let path = try #require(ProcessInfo.processInfo.environment["CHIRP_CHAT_TEST_CONFIG"])
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let sender = try ChatTransportPeer("a.login.entry1"), listener = try ChatTransportPeer("b.login.entry1")
    let senderID = Participant.Identity(from: sender.identity), sink = ProbeAudioSink()
    try AudioManager.shared.setManualRenderingMode(true)
    defer { try? AudioManager.shared.setManualRenderingMode(false) }
    try AudioManager.shared.setEngineAvailability(.default)
    AudioManager.shared.mixer.appVolume = 1
    var tone: Task<Void, Error>?
    do {
        for peer in [sender, listener] {
            let started = ContinuousClock.now
            try await peer.connect(url: config.url, token: try #require(config.tokens[peer.identity]))
            print("VOICE_STARTUP media_connect=\(started.duration(to: .now))")
        }
        try await chatRound([sender, listener], id: "voice/local/1")
        let microphoneStart = ContinuousClock.now
        let local = await LocalAudioTrack.createTrack(options: .noProcessing)
        try await local.mute()
        let publication = try await sender.room.localParticipant.publish(audioTrack: local, options: AudioPublishOptions(dtx: false, red: false))
        let manager = try #require(sender.room.e2eeManager)
        try #require(await manager.chirpPrepareLocalTrack(publication, identity: senderID))
        try await local.unmute()
        tone = try syntheticVoice()
        try await waitForChat { listener.room.remoteParticipants[senderID]?.audioTracks.first != nil }
        let subscribed = try #require(listener.room.remoteParticipants[senderID]?.audioTracks.first as? RemoteTrackPublication)
        try await subscribed.set(subscribed: true)
        try await waitForChat { subscribed.track is RemoteAudioTrack }
        let remote = try #require(subscribed.track as? RemoteAudioTrack)
        remote.add(audioRenderer: sink)
        defer { remote.remove(audioRenderer: sink) }
        try await waitForChat { sink.hasSignal }
        print("VOICE_STARTUP publish_to_first_remote_pcm=\(microphoneStart.duration(to: try #require(sink.firstSignalAt)))")

        let participant = try #require(listener.room.remoteParticipants[senderID])
        let mismatched = RemoteTrackPublication(info: .with {
            $0.sid = "TR_mismatched"; $0.type = .video; $0.source = .microphone; $0.encryption = .gcm
        }, participant: participant)
        await mismatched.set(track: remote)
        let receiverManager = try #require(listener.room.e2eeManager)
        #expect(await receiverManager.chirpPrepareRemoteTrack(mismatched, identity: senderID) == false)

        let lease = Mutex((valid: false, deniedChecks: 0))
        let next = ChatTransportPeer.emptyKeys {
            lease.withLock {
                if !$0.valid { $0.deniedChecks += 1 }
                return $0.valid
            }
        }
        try await listener.replaceKeys(ChatTransportPeer.emptyKeys { false })
        let fresh = try await V5TestIdentity.peers([sender.native, listener.native], groupID: "voice/local/2")
        let welcome = try await sender.native.create(groupID: "voice/local/2", members: fresh)
        _ = try await listener.native.join(groupID: "voice/local/2", members: fresh, welcome: welcome.welcome)
        for member in fresh {
            next.setKey(keyData: try await listener.native.senderKey(for: member.identity), participantId: member.identity)
        }
        try await sender.install(fresh)
        #expect(subscribed.track === remote && remote.trackState == .started)
        #expect(await RTC.run { !remote.mediaTrack.raw.isEnabled })
        #expect(try await remote.enable() == false)
        try await Task.sleep(for: .milliseconds(250))
        let silent = sink.voicedBuffers
        try await Task.sleep(for: .milliseconds(350))
        #expect(sink.voicedBuffers == silent)

        lease.withLock { $0.valid = true }
        try await listener.replaceKeys(next)
        #expect(subscribed.track === remote)
        #expect(await RTC.run { remote.mediaTrack.raw.isEnabled })
        try await waitForChat { sink.voicedBuffers > silent + 3 }

        // A receive-side lease expiry also stops decryption on an enabled track.
        lease.withLock { $0 = (false, 0) }
        try await Task.sleep(for: .milliseconds(500))
        let expired = sink.voicedBuffers
        try await Task.sleep(for: .milliseconds(350))
        let rendered = sink.voicedBuffers
        let denied = lease.withLock { $0.deniedChecks }
        print("VOICE_EXPIRY denied_checks=\(denied) voiced_buffers_after_drain=\(rendered - expired)")
        #expect(denied > 0)
        #expect(rendered == expired)

        // This louder signal only exists after expiry. Its arrival on renewal
        // also verifies that the sender and the level probe stayed operational.
        let marker = ProbeAudioSink(threshold: 0.6)
        remote.add(audioRenderer: marker)
        defer { remote.remove(audioRenderer: marker) }
        tone?.cancel(); _ = await tone?.result
        tone = try syntheticVoice(amplitude: 0.9)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!marker.hasSignal)
        lease.withLock { $0.valid = true }
        try await waitForChat { marker.hasSignal }
    } catch {
        tone?.cancel(); _ = await tone?.result
        await listener.close(); await sender.close(); throw error
    }
    tone?.cancel(); _ = await tone?.result
    await listener.close(); await sender.close()
}
