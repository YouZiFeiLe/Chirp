import Foundation
import Synchronization

struct MediaLease: Sendable {
    private(set) var deadline: ContinuousClock.Instant?

    mutating func renew(requestStartedAt: ContinuousClock.Instant, milliseconds: Int) throws {
        guard milliseconds > 0, milliseconds <= 3_000 else { throw ClientFailure(.invalidMediaLease) }
        // Transit time consumes the lease. A delayed response cannot restart it.
        deadline = requestStartedAt.advanced(by: .milliseconds(milliseconds))
    }

    mutating func revoke() { deadline = nil }
    func isValid(at instant: ContinuousClock.Instant = .now) -> Bool {
        // ContinuousClock includes system sleep; a sleeping Mac cannot retain
        // an apparently fresh authorization when it wakes much later.
        deadline.map { $0 > instant } ?? false
    }
}

/// A local secret's age is never renewed by server leases or installation.
struct KeyLifetime: Sendable {
    private(set) var createdAt: ContinuousClock.Instant?
    var deadline: ContinuousClock.Instant? { createdAt?.advanced(by: .seconds(120)) }
    mutating func begin(now: ContinuousClock.Instant = .now) { if createdAt == nil { createdAt = now } }
    func isValid(now: ContinuousClock.Instant = .now) -> Bool { deadline.map { now < $0 } ?? false }
    func shouldRotate(now: ContinuousClock.Instant = .now) -> Bool { createdAt.map { $0.duration(to: now) >= .seconds(90) } ?? false }
}

/// Read on WebRTC's capture thread for every PCM frame, independently of the UI.
/// Once a lease expires this key context cannot be renewed; install fresh keys.
final class MediaContentGate: Sendable {
    private struct State {
        var keyDeadline: ContinuousClock.Instant?
        var deadline: ContinuousClock.Instant?
        var revoked = true
        var microphone = false
        var onExpiry: (@Sendable () -> Void)?
    }
    private let state = Mutex(State())
    var leaseDeadline: ContinuousClock.Instant? { state.withLock { $0.deadline } }
    private let timer: DispatchSourceTimer
    init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "cn.youzifeile.chirp.media-expiry", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in _ = self?.permitsCapture() }
        timer.resume()
    }
    deinit { timer.cancel() }
    func install(keyDeadline: ContinuousClock.Instant, onExpiry: (@Sendable () -> Void)? = nil) {
        state.withLock { $0 = State(keyDeadline: keyDeadline, revoked: false, onExpiry: onExpiry) }
    }
    @discardableResult
    func authorize(until deadline: ContinuousClock.Instant?, now: ContinuousClock.Instant = .now) -> Bool {
        let result = state.withLock { value -> (Bool, (@Sendable () -> Void)?) in
            guard let deadline, !value.revoked, let hard = value.keyDeadline, hard > now,
                  value.deadline.map({ $0 > now }) ?? true, deadline > now else {
                return (false, Self.close(&value))
            }
            value.deadline = min(deadline, hard)
            return (true, nil)
        }
        result.1?()
        return result.0
    }
    func microphone(_ enabled: Bool) { state.withLock { $0.microphone = enabled } }
    private static func close(_ value: inout State) -> (@Sendable () -> Void)? {
        value.revoked = true; value.microphone = false; value.deadline = nil
        let action = value.onExpiry; value.onExpiry = nil
        return action
    }
    func revoke() {
        let action = state.withLock { Self.close(&$0) }
        action?()
    }
    func permitsCapture(now: ContinuousClock.Instant = .now) -> Bool { permitsContent(capture: true, now: now) }
    func permitsReceiving(now: ContinuousClock.Instant = .now) -> Bool { permitsContent(capture: false, now: now) }
    private func permitsContent(capture: Bool, now: ContinuousClock.Instant) -> Bool {
        let result = state.withLock { value -> (Bool, (@Sendable () -> Void)?) in
            guard !value.revoked, let hard = value.keyDeadline, hard > now else { return (false, Self.close(&value)) }
            guard let deadline = value.deadline else { return (false, nil) }
            guard deadline > now else { return (false, Self.close(&value)) }
            return (!capture || value.microphone, nil)
        }
        result.1?()
        return result.0
    }
}
