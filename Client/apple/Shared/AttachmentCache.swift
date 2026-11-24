import Foundation
import CryptoKit

// Only ciphertext belongs in this directory. Neither keys nor recoverable key
// wrappers are persisted. One process owns the cache; multiple windows get
// separate leases, all revoked synchronously by the global clear action.
final class AttachmentCache: @unchecked Sendable {
    static let shared = AttachmentCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ChirpRoomAttachments", isDirectory: true))
    static let didClear = Notification.Name("ChirpAttachmentCacheDidClear")
    let directory: URL
    private let lock = NSLock()
    private var leases: [UUID: AttachmentLease] = [:]
    private var startupError: Error?

    init(directory: URL) {
        self.directory = directory
        do {
            try Self.validateDirectory(directory)
            // A terminated process has lost its in-memory keys. Never restore
            // its folders or create a persistent attachment history.
            try Self.removeContents(directory)
        } catch { startupError = error }
    }

    private static func validateDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ClientFailure(.attachmentCacheFailed) }
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private static func removeContents(_ url: URL) throws {
        for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            // Removing a symlink removes the link itself; never enumerate its target.
            try FileManager.default.removeItem(at: child)
        }
    }

    func begin() throws -> AttachmentLease {
        lock.lock(); defer { lock.unlock() }
        if startupError != nil { throw ClientFailure(.attachmentCacheFailed) }
        let id = UUID(), folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let lease = AttachmentLease(id: id, directory: folder)
        leases[id] = lease
        return lease
    }

    func end(_ lease: AttachmentLease) {
        lock.lock(); defer { lock.unlock() }
        lease.revoke()
        leases[lease.id] = nil
        try? FileManager.default.removeItem(at: lease.directory)
    }

    func clearAll() throws {
        lock.lock(); defer { lock.unlock() }
        // Revocation precedes disk IO, and waits for any bounded cryptographic
        // operation holding a lease lock. No task can subsequently fetch a key.
        for lease in leases.values { lease.revoke() }
        leases.removeAll()
        do {
            try Self.validateDirectory(directory)
            try Self.removeContents(directory)
            startupError = nil
        } catch { startupError = error; throw ClientFailure(.attachmentCacheFailed) }
    }

    func size() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard startupError == nil,
              (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return 0 }
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return 0 }
        var size: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { enumerator.skipDescendants(); continue }
            if values.isRegularFile == true { size += Int64(values.fileSize ?? 0) }
        }
        return size
    }
}

final class AttachmentLease: @unchecked Sendable {
    let id: UUID
    let directory: URL
    private let lock = NSLock()
    private var active = true
    private var keys: [String: SymmetricKey] = [:]
    private var encrypted = Set<String>()
    private var reserved: Int64 = 0
    static let maxBytes: Int64 = 512 * 1024 * 1024

    init(id: UUID, directory: URL) { self.id = id; self.directory = directory }

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        guard active, !Task.isCancelled else { throw CancellationError() }
    }

    func register(_ info: AttachmentInfo, key: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard active, !Task.isCancelled else { throw CancellationError() }
        guard info.isValid, key.count == 32, keys[info.id] == nil,
              keys.count < RoomChat.maxMessages, reserved + info.ciphertextSize <= Self.maxBytes else { throw ClientFailure(.attachmentInvalid) }
        keys[info.id] = SymmetricKey(data: key)
        reserved += info.ciphertextSize
    }

    func contains(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return active && keys[id] != nil
    }

    func withKey<T>(_ id: String, _ body: (SymmetricKey) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard active, !Task.isCancelled, let key = keys[id] else { throw CancellationError() }
        return try body(key)
    }

    func claimEncryption(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard active, !Task.isCancelled, keys[id] != nil, encrypted.insert(id).inserted else { throw ClientFailure(.attachmentInvalid) }
    }

    func discard(_ info: AttachmentInfo) {
        lock.lock(); defer { lock.unlock() }
        if keys.removeValue(forKey: info.id) != nil { reserved -= info.ciphertextSize }
        encrypted.remove(info.id)
        for suffix in [".cipher", ".thumb", ".download"] { try? FileManager.default.removeItem(at: directory.appendingPathComponent(info.id + suffix)) }
    }

    func revoke() {
        lock.lock(); defer { lock.unlock() }
        active = false; keys.removeAll(); encrypted.removeAll(); reserved = 0
    }

    func url(_ id: String, thumbnail: Bool = false) throws -> URL {
        try check()
        guard AttachmentInfo.validID(id) else { throw ClientFailure(.attachmentInvalid) }
        return directory.appendingPathComponent(id + (thumbnail ? ".thumb" : ".cipher"))
    }
    func partialURL(_ id: String) throws -> URL {
        try check()
        guard AttachmentInfo.validID(id) else { throw ClientFailure(.attachmentInvalid) }
        return directory.appendingPathComponent(id + ".download")
    }
}
