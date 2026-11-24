import Foundation
import UniformTypeIdentifiers

/// The provider owns the plaintext file. Only encrypted bytes leave its callback.
/// NSItemProvider's asynchronous APIs are thread-safe; mutable request state is locked.
final class AttachmentPhotoSource: @unchecked Sendable {
    private let provider: NSItemProvider
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AttachmentDescriptor, any Error>?
    private var progress: Progress?
    private var finished = false

    init(provider: NSItemProvider) { self.provider = provider }

    func prepare(lease: AttachmentLease, admission: RoomAdmission) async throws -> AttachmentDescriptor {
        guard let identifier = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }),
              let type = UTType(identifier) else { throw ClientFailure(.attachmentInvalid) }
        var name = provider.suggestedName.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Photo"
        if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension { name += "." + ext }
        let filename = name
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let start = lock.withLock {
                    guard !finished else { return false }
                    self.continuation = continuation
                    return true
                }
                guard start else { continuation.resume(throwing: CancellationError()); return }
                let progress = provider.loadFileRepresentation(forTypeIdentifier: identifier) { [self] url, error in
                    do {
                        guard !lock.withLock({ finished }) else { return }
                        if let error { throw error }
                        guard let url else { throw ClientFailure(.attachmentInvalid) }
                        // Do not copy the provider's plaintext into Caches/tmp or load a full Data/UIImage.
                        var descriptor = try RoomAttachmentController.prepareFile(
                            source: url, lease: lease, admission: admission, contentType: type, name: filename)
                        if !finish(.success(descriptor)) {
                            lease.discard(descriptor.info)
                            descriptor.key.resetBytes(in: 0..<descriptor.key.count)
                        }
                    } catch { _ = finish(.failure(error)) }
                }
                let cancel = lock.withLock {
                    guard !finished else { return true }
                    self.progress = progress
                    return false
                }
                if cancel { progress.cancel() }
            }
        } onCancel: { self.cancel() }
    }

    private func finish(_ result: Result<AttachmentDescriptor, any Error>) -> Bool {
        let continuation = lock.withLock {
            guard !finished else { return nil as CheckedContinuation<AttachmentDescriptor, any Error>? }
            finished = true
            let continuation = self.continuation
            self.continuation = nil; progress = nil
            return continuation
        }
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }

    private func cancel() {
        let pending = lock.withLock {
            finished = true
            let pending = (continuation, progress)
            continuation = nil; progress = nil
            return pending
        }
        pending.0?.resume(throwing: CancellationError())
        pending.1?.cancel()
    }
}
