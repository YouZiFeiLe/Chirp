import Foundation
import Network
import Observation

struct NetworkTimeSample: Sendable {
    let utc: Date
    let received: ContinuousClock.Instant
    let roundTrip: Duration

    func utc(at instant: ContinuousClock.Instant) -> Date {
        utc.addingTimeInterval(received.duration(to: instant) / .seconds(1))
    }
}

@MainActor @Observable
final class NetworkClock {
    enum Status: Equatable { case checking, ready, outOfSync(TimeInterval), unavailable }
    private static let tolerance: TimeInterval = 2
    private static let referenceLifetime: Duration = .seconds(900)
    private static let refreshInterval: Duration = .seconds(600)
    private static let retryInterval: Duration = .seconds(60)
    private static let manualRetryInterval: Duration = .seconds(16)
    private(set) var status: Status = .checking
    private(set) var canRetry = false
    private var reference: NetworkTimeSample?
    private var lastAttempt: ContinuousClock.Instant?
    private var lastAttemptSucceeded = false
    private var inFlight: Task<Void, Never>?
    private let wallNow: () -> Date
    private let instant: () -> ContinuousClock.Instant
    private let query: @MainActor () async -> [NetworkTimeSample]

    init(wallNow: @escaping () -> Date = { Date() }, instant: @escaping () -> ContinuousClock.Instant = { .now },
         query: @escaping @MainActor () async -> [NetworkTimeSample] = NTPTime.query) {
        self.wallNow = wallNow
        self.instant = instant
        self.query = query
    }

    func monitor() async {
        while !Task.isCancelled {
            await check()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func check(manual: Bool = false) async {
        updateReading()
        if let inFlight { await inFlight.value; return }
        let now = instant()
        let interval = manual ? Self.manualRetryInterval : (lastAttemptSucceeded ? Self.refreshInterval : Self.retryInterval)
        if let lastAttempt, lastAttempt.duration(to: now) < interval { return }
        lastAttempt = now
        // All windows share one bounded query, even if the initiating view disappears.
        let measurement = Task {
            let samples = await query()
            let end = instant()
            lastAttemptSucceeded = !samples.isEmpty
            if samples.count == 2 {
                reference = samples.min { $0.roundTrip < $1.roundTrip }
            } else if !samples.isEmpty {
                reference = samples.sorted { $0.utc(at: end) < $1.utc(at: end) }[samples.count / 2]
            }
            inFlight = nil
            updateReading()
        }
        inFlight = measurement
        updateReading()
        await measurement.value
    }

    func isReadyNow() -> Bool {
        updateReading()
        return status == .ready
    }

    func requireReady() throws {
        guard isReadyNow() else { throw ClientFailure(.networkTimeRequired) }
    }

    private func updateReading() {
        let now = instant()
        let reading: Status
        if let reference, reference.received.duration(to: now) < Self.referenceLifetime {
            let offset = wallNow().timeIntervalSince(reference.utc(at: now))
            reading = abs(offset) <= Self.tolerance ? .ready : .outOfSync(offset)
        } else {
            reading = lastAttempt == nil || inFlight != nil ? .checking : .unavailable
        }
        let retry = inFlight == nil && lastAttempt.map { $0.duration(to: now) >= Self.manualRetryInterval } == true
        if reading != status { status = reading }
        if retry != canRetry { canRetry = retry }
    }
}

enum NTPTime {
    private static let servers = ["time.windows.com", "ntp.aliyun.com", "time.cloudflare.com"]
    private static let timeout: TimeInterval = 4
    private static let queue = DispatchQueue(label: "cn.youzifeile.chirp.network-time")

    static func query() async -> [NetworkTimeSample] {
        await withTaskGroup(of: NetworkTimeSample?.self) { group in
            for server in servers {
                group.addTask { await sample(host: NWEndpoint.Host(server), port: 123) }
            }
            var samples: [NetworkTimeSample] = []
            for await sample in group { if let sample { samples.append(sample) } }
            return samples
        }
    }

    static func sample(host: NWEndpoint.Host, port: NWEndpoint.Port) async -> NetworkTimeSample? {
        let connection = NWConnection(host: host, port: port, using: .udp)
        let (replies, result) = AsyncStream<NetworkTimeSample>.makeStream()
        var request = Data(repeating: 0, count: 48)
        request[0] = 0x23 // NTPv4 client. The server echoes our transmit nonce as its origin.
        let nonce = withUnsafeBytes(of: UInt64.random(in: 1 ... .max)) { Data($0) }
        request.replaceSubrange(40..<48, with: nonce)
        connection.stateUpdateHandler = { [weak connection, request] state in
            switch state {
            case .ready:
                guard let connection else { return }
                let start = ContinuousClock.now
                connection.send(content: request, completion: .contentProcessed { if $0 != nil { result.finish() } })
                connection.receiveMessage { data, _, _, error in
                    let end = ContinuousClock.now
                    let roundTrip = start.duration(to: end)
                    if error == nil, let data, let utc = estimateUTC(reply: data, nonce: nonce, roundTrip: roundTrip) {
                        result.yield(NetworkTimeSample(utc: utc, received: end, roundTrip: roundTrip))
                    }
                    result.finish()
                }
            case .failed, .cancelled: result.finish()
            default: break
            }
        }
        // Bound DNS, connection setup and the UDP reply. Cancellation also ends the stream wait.
        let deadline = DispatchWorkItem { result.finish() }
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        connection.start(queue: queue)
        defer { deadline.cancel(); connection.cancel() }
        var iterator = replies.makeAsyncIterator()
        return await iterator.next()
    }

    static func estimateUTC(reply: Data, nonce: Data, roundTrip: Duration) -> Date? {
        let bytes = Array(reply.prefix(48))
        guard bytes.count == 48, bytes[0] & 7 == 4, (3...4).contains((bytes[0] >> 3) & 7),
              bytes[0] >> 6 != 3, (1...15).contains(bytes[1]), bytes[24..<32].elementsEqual(nonce),
              roundTrip >= .zero, roundTrip <= .seconds(timeout) else { return nil }
        func timestamp(at offset: Int) -> TimeInterval? {
            let bits = bytes[offset..<offset + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard bits != 0 else { return nil }
            // Unfold the 2036 rollover into 1970–2106 independently of the local wall clock.
            let seconds = UInt32(bits >> 32) &- 2_208_988_800
            return Double(seconds) + Double(UInt32(truncatingIfNeeded: bits)) / 4_294_967_296
        }
        guard let received = timestamp(at: 32), let sent = timestamp(at: 40), received <= sent else { return nil }
        let transit = roundTrip / .seconds(1) - (sent - received)
        guard transit >= 0 else { return nil }
        return Date(timeIntervalSince1970: sent + transit / 2)
    }
}
