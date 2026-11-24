import Foundation
import Synchronization
import Testing
@testable import LiveKit
@testable import LiveKitNanopb

private final class ChatQueueChannel: DrainSendChannel, Sendable {
    struct State {
        var open = false
        var packets: [Data] = []
    }
    let state = Mutex(State())
    var isOpen: Bool { state.withLock { $0.open } }
    func send(_ payload: Data) -> Bool {
        state.withLock { $0.packets.append(payload) }
        return true
    }
}

private final class ChatQueueAuthorization: Sendable {
    struct State {
        var allowed = true
        var deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var checks = 0
        var finished = false
    }
    let state = Mutex(State())
    func check() -> Bool {
        state.withLock { $0.checks += 1; return $0.allowed && $0.deadline > .now }
    }
}

private func waitForQueue(_ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private func queuePacket(_ text: String) -> Livekit_DataPacket {
    .with { $0.kind = .reliable; $0.user = .with { $0.payload = Data(text.utf8) } }
}

@Test(arguments: ["revoked", "expired", "cancelled", "retired"])
func queuedChatChecksAuthorizationAtTheTransportBoundary(reason: String) async throws {
    let channel = ChatQueueChannel(), authorization = ChatQueueAuthorization()
    let keys = BaseKeyProvider(options: KeyProviderOptions(sharedKey: false))
    let drain = DataChannelDrain(label: "chirp-queue-test", lowWaterMark: 1024,
                                overflow: .park, stage: ReliableStage(retryFloor: 1024))
    drain.attach(sendTarget: channel)
    defer { drain.reset() }
    let sending = Task {
        defer { authorization.state.withLock { $0.finished = true } }
        do {
            try await drain.send(queuePacket("stale chat"), chirpAuthorization: {
                authorization.check() && !keys.chirpIsRetired
            })
            return false
        } catch { return true }
    }
    do {
        try await waitForQueue { authorization.state.withLock { $0.checks > 0 } }
        switch reason {
        case "revoked": authorization.state.withLock { $0.allowed = false }
        case "expired": authorization.state.withLock { $0.deadline = .now.advanced(by: .seconds(-1)) }
        case "retired": keys.chirpRetireKeys()
        default: sending.cancel()
        }
        if reason != "cancelled" {
            channel.state.withLock { $0.open = true }
            drain.attach(sendTarget: channel)
        }
        // Cancellation must complete even while the transport stays closed.
        try await waitForQueue { authorization.state.withLock { $0.finished } }
        #expect(await sending.value)
        #expect(channel.state.withLock { $0.packets.isEmpty })
    } catch {
        drain.reset()
        _ = await sending.value
        throw error
    }
}

@Test(arguments: [false, true])
func reliableReplayRetainsTheOriginalSendingAuthorization(revoked: Bool) async throws {
    let channel = ChatQueueChannel(), authorization = ChatQueueAuthorization()
    channel.state.withLock { $0.open = true }
    let drain = DataChannelDrain(label: "chirp-replay-test", lowWaterMark: 1024,
                                overflow: .park, stage: ReliableStage(retryFloor: 1024))
    drain.attach(sendTarget: channel)
    defer { drain.reset() }
    try await drain.send(queuePacket("original chat"), chirpAuthorization: { authorization.check() })
    authorization.state.withLock { $0.allowed = !revoked }
    drain.submit(command: .replay(after: 0))
    // FIFO completion proves the replay command has been processed.
    try await drain.send(queuePacket("barrier"))
    let packets = channel.state.withLock { $0.packets }
    #expect(packets.count == (revoked ? 2 : 3))
    #expect(packets.filter { $0.range(of: Data("original chat".utf8)) != nil }.count == (revoked ? 1 : 2))
}
