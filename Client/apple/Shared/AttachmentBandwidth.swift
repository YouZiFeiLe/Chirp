import Foundation

enum AttachmentNetworkPolicy: Sendable { case normal, constrained, paused
    static func forCall(phase: CallPhase, tracks: [CallTrackDiagnostic]) -> Self {
        guard phase == .active else { return .paused }
        let audible = tracks.filter { $0.subscribed && !$0.muted }
        if audible.contains(where: { $0.quality == .lost }) { return .paused }
        if audible.contains(where: { $0.quality == .poor || ($0.jitterMS ?? 0) >= 40 }) { return .constrained }
        return .normal
    }
}

enum AttachmentDirection: Sendable, Hashable { case upload, download }

/// Per-direction admission budgets include retries. Uploads do not consume the
/// download allowance; unused time never accumulates burst credit.
actor AttachmentBandwidth {
    private var policy: AttachmentNetworkPolicy = .normal
    private var queues: [AttachmentDirection: [UUID]] = [.upload: [], .download: []]
    private var next: [AttachmentDirection: ContinuousClock.Instant] = [.upload: .now, .download: .now]
    private let normalRate: Int
    private let constrainedRate: Int
    init(normalRate: Int = 8 * 1_024 * 1_024, constrainedRate: Int = 512 * 1_024) {
        self.normalRate = max(1, normalRate); self.constrainedRate = max(1, constrainedRate)
    }
    func update(_ policy: AttachmentNetworkPolicy) {
        self.policy = policy
        // Re-evaluate queued work promptly after a route/quality change, with
        // no stored burst credit and no reservation for a canceled request.
        if policy == .paused {
            next[.upload] = .now.advanced(by: .milliseconds(100))
            next[.download] = .now.advanced(by: .milliseconds(100))
        }
    }
    func acquire(_ bytes: Int, direction: AttachmentDirection = .upload, deadline: ContinuousClock.Instant) async throws {
        guard bytes > 0, bytes <= AttachmentTransport.chunkBytes, queues[direction, default: []].count < 8 else { throw ClientFailure(.attachmentBusy) }
        let id = UUID(); queues[direction, default: []].append(id)
        defer { queues[direction]?.removeAll { $0 == id } }
        while true {
            try Task.checkCancellation()
            let now = ContinuousClock.now
            guard now < deadline else { throw URLError(.timedOut) }
            if policy != .paused, queues[direction]?.first == id, now >= next[direction, default: now] {
                let rate = policy == .constrained ? constrainedRate : normalRate
                next[direction] = now.advanced(by: .seconds(Double(bytes) / Double(rate)))
                return
            }
            let remaining = now.duration(to: deadline)
            try await Task.sleep(for: min(.milliseconds(25), remaining))
        }
    }
}
