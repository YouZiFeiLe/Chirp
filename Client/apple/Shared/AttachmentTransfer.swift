import Foundation

enum RemoteAttachmentState: String, Decodable, Sendable { case reserved, uploading, paused, completed, delivered, cancelled, expired
    var isTerminal: Bool { self == .cancelled || self == .expired }
    var isUploaded: Bool { self == .completed || self == .delivered }
}

struct RemoteAttachment: Decodable, Sendable {
    let id: String
    let room_id: String
    let ciphertext_size: Int64
    let uploaded_chunks: Int
    let ciphertext_sha256: String
    let state: RemoteAttachmentState
    let revision: UInt64
    let updated_at: Int64
    let completed_at: Int64
    let expires_at: Int64
    let protocol_version: Int
    let chunk_bytes: Int
    let chunk_sha256: [String]?
    var chunkCount: Int { Int((ciphertext_size + Int64(AttachmentTransport.chunkBytes) - 1) / Int64(AttachmentTransport.chunkBytes)) }

    func validate(_ info: AttachmentInfo, requireDigests: Bool = false) throws {
        guard protocol_version == 3, chunk_bytes == AttachmentTransport.chunkBytes,
              id == info.id, room_id == info.roomID, ciphertext_size == info.ciphertextSize,
              ciphertext_sha256 == info.digest, revision > 0, updated_at > 0, expires_at > 0,
              (0...chunkCount).contains(uploaded_chunks), completed_at >= 0,
              state != .reserved || uploaded_chunks == 0,
              !state.isUploaded || (uploaded_chunks == chunkCount && completed_at > 0),
              state != .cancelled || completed_at == 0,
              completed_at == 0 || (state.isUploaded || state == .expired),
              state.isTerminal || state == .delivered || expires_at > Int64(Date().timeIntervalSince1970) else { throw ClientFailure(.attachmentInvalid) }
        if requireDigests {
            let hashes = chunk_sha256 ?? []
            guard hashes.count == uploaded_chunks, hashes.allSatisfy(Self.validDigest) else { throw ClientFailure(.attachmentIntegrity) }
        }
    }
    static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func requireActive() throws {
        if state == .cancelled { throw ClientFailure(.attachmentCancelled) }
        if state == .expired { throw ClientFailure(.attachmentExpired) }
    }
}

struct AttachmentCatalog: Decodable, Sendable {
    let server_id: String
    let room_id: String
    let revision: UInt64
    let attachments: [RemoteAttachment]
    func validate(room: String) throws {
        guard !server_id.isEmpty, server_id.utf8.count <= 128, room_id == room, revision > 0,
              attachments.count <= 4096, Set(attachments.map(\.id)).count == attachments.count else { throw ClientFailure(.attachmentInvalid) }
    }
}

struct AttachmentEventSubscription: Sendable {
    let events: AsyncThrowingStream<HTTPEvent, Error>
    let cancel: @Sendable () -> Void
}

enum AttachmentTransferPhase: Equatable, Sendable {
    case waiting, reserving, uploading, waitingForUpload, downloading, verifying, completed
    case retryableFailure, failed, cancelling, cancelled, expired, downloadPaused
    var busy: Bool { [.reserving, .uploading, .waitingForUpload, .downloading, .verifying, .cancelling].contains(self) }
}
struct AttachmentTransferState: Equatable {
    var phase: AttachmentTransferPhase = .waiting
    var progress: Double = 0
    var cached = false
    var remoteState: RemoteAttachmentState?
    var remoteRevision: UInt64 = 0
    var completedAt: Int64 = 0
    var outgoing = false
    var busy: Bool { phase.busy }
    var failed: Bool { phase == .retryableFailure || phase == .failed }
}

protocol AttachmentServing: Sendable {
    func create(_ info: AttachmentInfo, recipients: [String]) async throws -> RemoteAttachment
    func status(_ info: AttachmentInfo) async throws -> RemoteAttachment
    func catalog() async throws -> AttachmentCatalog
    func events() -> AttachmentEventSubscription
    func upload(_ info: AttachmentInfo, lease: AttachmentLease, authorize: @escaping @Sendable () async throws -> Void,
                progress: @escaping @Sendable (Double) async -> Void) async throws -> RemoteAttachment
    func download(_ info: AttachmentInfo, lease: AttachmentLease, authorize: @escaping @Sendable () async throws -> Void,
                  progress: @escaping @Sendable (Double) async -> Void) async throws
    func cancel(_ info: AttachmentInfo) async throws -> RemoteAttachment
    func received(_ info: AttachmentInfo) async throws -> RemoteAttachment
    func pause(_ id: String) async
    func reportCancellation(_ ids: [String]) async
    func close()
}
