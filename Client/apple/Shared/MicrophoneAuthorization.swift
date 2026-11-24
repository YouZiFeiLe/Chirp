import AVFoundation
import Synchronization

enum MicrophoneAuthorization {
    /// The system alert may outlive its caller. Cancelling a call or local test
    /// must release that caller without waiting for the person's response.
    static func request(using request: @Sendable (@escaping @Sendable (Bool) -> Void) -> Void = {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0)
    }) async -> Bool {
        let pending = MicrophoneAccessRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard pending.prepare(continuation) else {
                    continuation.resume(returning: false)
                    return
                }
                guard !Task.isCancelled else { pending.finish(false); return }
                request { pending.finish($0) }
            }
        } onCancel: { pending.finish(false) }
    }
}

private final class MicrophoneAccessRequest: Sendable {
    private struct State {
        var finished = false
        var continuation: CheckedContinuation<Bool, Never>?
    }
    private let state = Mutex(State())

    func prepare(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
        state.withLock {
            guard !$0.finished else { return false }
            $0.continuation = continuation
            return true
        }
    }

    func finish(_ allowed: Bool) {
        let continuation = state.withLock {
            guard !$0.finished else { return nil as CheckedContinuation<Bool, Never>? }
            $0.finished = true
            defer { $0.continuation = nil }
            return $0.continuation
        }
        continuation?.resume(returning: allowed)
    }
}
