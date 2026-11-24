import Foundation
import Network
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@MainActor private final class ClockFixture {
    let origin = Date(timeIntervalSince1970: 1_800_000_000)
    let start = ContinuousClock.now
    var elapsed: Duration = .zero
    var offset: TimeInterval = 0
    var samples: [NetworkTimeSample] = []
    var attempts = 0
    var now: ContinuousClock.Instant { start.advanced(by: elapsed) }
    var wall: Date { origin.addingTimeInterval(elapsed / .seconds(1) + offset) }

    func sample(offset: TimeInterval = 0, rtt: Int = 20) -> NetworkTimeSample {
        NetworkTimeSample(utc: origin.addingTimeInterval(elapsed / .seconds(1) + offset),
                          received: now, roundTrip: .milliseconds(rtt))
    }

    func clock() -> NetworkClock {
        NetworkClock(wallNow: { self.wall }, instant: { self.now }, query: {
            self.attempts += 1
            return self.samples
        })
    }
}

private func ntpReply(nonce: Data) -> Data {
    var reply = Data(repeating: 0, count: 48)
    reply[0] = 0x24
    reply[1] = 2
    reply.replaceSubrange(24..<32, with: nonce)
    // Received 0.25 s before the 2036 rollover and sent 0.25 s after it.
    reply.replaceSubrange(32..<40, with: [255, 255, 255, 255, 192, 0, 0, 0])
    reply[44] = 64
    return reply
}

@Suite @MainActor struct NetworkClockTests {
    @Test func startupOutageBlocksUntilTheAutomaticRetrySucceeds() async throws {
        let fixture = ClockFixture(), clock = fixture.clock()
        #expect(clock.status == .checking)
        #expect(throws: ClientFailure(.networkTimeRequired)) { try clock.requireReady() }
        await clock.check()
        #expect(clock.status == .unavailable && !clock.canRetry)
        fixture.elapsed = .seconds(59)
        await clock.check()
        #expect(clock.canRetry && fixture.attempts == 1)
        fixture.elapsed = .seconds(60)
        fixture.samples = [fixture.sample()]
        await clock.check()
        #expect(clock.status == .ready && fixture.attempts == 2)
        try clock.requireReady()
    }

    @Test func signedOffsetUsesTheMedianAtACommonInstantAndUnlocksAfterCorrection() async throws {
        let fixture = ClockFixture(), clock = fixture.clock()
        let early = fixture.sample()
        fixture.elapsed = .seconds(3)
        fixture.samples = [fixture.sample(offset: -2.5), early, fixture.sample(offset: 50)]
        await clock.check()
        fixture.elapsed = .seconds(25)
        for sign in [-1.0, 1.0] {
            fixture.offset = sign * 2
            try clock.requireReady()
            fixture.offset = sign * 2.125
            #expect(throws: ClientFailure(.networkTimeRequired)) { try clock.requireReady() }
            #expect(clock.status == .outOfSync(fixture.offset))
        }
        fixture.offset = 0
        await clock.check()
        try clock.requireReady()
        #expect(fixture.attempts == 1)
    }

    @Test func failedRefreshKeepsTheFasterOfTwoSamplesOnlyUntilItExpires() async throws {
        let fixture = ClockFixture(), clock = fixture.clock()
        fixture.samples = [fixture.sample(offset: 60, rtt: 250), fixture.sample(rtt: 10)]
        await clock.check()
        try clock.requireReady()
        fixture.samples = []
        fixture.elapsed = .seconds(599)
        await clock.check()
        #expect(fixture.attempts == 1)
        fixture.elapsed = .seconds(600)
        await clock.check()
        #expect(fixture.attempts == 2 && clock.isReadyNow())
        fixture.elapsed = .seconds(900)
        #expect(!clock.isReadyNow() && clock.status == .unavailable)
        await clock.check()
        fixture.elapsed += .seconds(15)
        await clock.check(manual: true)
        #expect(!clock.canRetry && fixture.attempts == 3)
        fixture.elapsed += .seconds(1)
        fixture.samples = [fixture.sample()]
        await clock.check(manual: true)
        #expect(fixture.attempts == 4 && clock.isReadyNow())
    }

    @Test func multipleWindowsShareAnInFlightQuery() async {
        let fixture = ClockFixture()
        let (replies, sender) = AsyncStream<[NetworkTimeSample]>.makeStream()
        let clock = NetworkClock(wallNow: { fixture.wall }, instant: { fixture.now }, query: {
            fixture.attempts += 1
            var iterator = replies.makeAsyncIterator()
            return await iterator.next() ?? []
        })
        let first = Task.immediate { await clock.check() }
        let second = Task.immediate { await clock.check(manual: true) }
        #expect(clock.status == .checking && !clock.canRetry)
        sender.yield([fixture.sample()])
        sender.finish()
        await first.value
        await second.value
        #expect(fixture.attempts == 1 && clock.isReadyNow())
    }

    @Test func validatesTheReplyAndAccountsForServerProcessingAcrossTheRollover() {
        let nonce = Data(1...8)
        let valid = ntpReply(nonce: nonce)
        func estimate(_ reply: Data, rtt: Duration = .seconds(1)) -> Date? {
            NTPTime.estimateUTC(reply: reply, nonce: nonce, roundTrip: rtt)
        }
        #expect(estimate(valid) == Date(timeIntervalSince1970: 2_085_978_496.5))
        for (index, value): (Int, UInt8) in [(0, 0xe4), (0, 0x23), (0, 0x0c), (1, 0), (1, 16), (24, 0)] {
            var invalid = valid
            invalid[index] = value
            #expect(estimate(invalid) == nil)
        }
        for range in [32..<40, 40..<48] {
            var invalid = valid
            invalid.replaceSubrange(range, with: repeatElement(UInt8(0), count: 8))
            #expect(estimate(invalid) == nil)
        }
        var reversed = valid
        reversed.replaceSubrange(32..<40, with: valid[40..<48])
        reversed.replaceSubrange(40..<48, with: valid[32..<40])
        #expect(estimate(reversed) == nil)
        #expect(estimate(valid.prefix(47)) == nil)
        #expect(estimate(valid, rtt: .milliseconds(499)) == nil)
        #expect(estimate(valid, rtt: .milliseconds(4001)) == nil)
    }

    @Test func exchangesAnActualUDPDatagramAndChecksTheEchoedNonce() async throws {
        let queue = DispatchQueue(label: "chirp.test.ntp")
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let (ports, ready) = AsyncStream<NWEndpoint.Port>.makeStream()
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                if let port = listener?.port { ready.yield(port) }
                ready.finish()
            case .failed, .cancelled: ready.finish()
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receiveMessage { data, _, _, _ in
                guard let data, data.count == 48, data[0] == 0x23 else { connection.cancel(); return }
                var reply = ntpReply(nonce: Data(data[40..<48]))
                reply.replaceSubrange(32..<40, with: reply[40..<48]) // Immediate server reply.
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        queue.asyncAfter(deadline: .now() + 4) { ready.finish() }
        listener.start(queue: queue)
        defer { listener.cancel() }
        var iterator = ports.makeAsyncIterator()
        let port = try #require(await iterator.next())
        let sample = try #require(await NTPTime.sample(host: "127.0.0.1", port: port))
        let expected = Date(timeIntervalSince1970: 2_085_978_496.25 + sample.roundTrip / .seconds(1) / 2)
        #expect(sample.utc == expected)
    }
}
