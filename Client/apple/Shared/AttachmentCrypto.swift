import Foundation
import CryptoKit

struct AttachmentInfo: Codable, Equatable, Sendable, Identifiable {
    let version: Int
    let id: String
    let roomID: String
    let sender: String
    let name: String
    let mimeType: String
    let size: Int64
    var digest: String
    let hasThumbnail: Bool

    static let chunkBytes = 256 * 1024
    static let maxFileBytes: Int64 = 100 * 1024 * 1024
    static let maxImageBytes: Int64 = 20 * 1024 * 1024
    static let maxThumbnailBytes = 6 * 1024
    var chunkCount: Int { max(1, Int((size + Int64(Self.chunkBytes) - 1) / Int64(Self.chunkBytes))) }
    var ciphertextSize: Int64 { size + Int64(chunkCount * 16) }
    var isImage: Bool { ["image/jpeg", "image/png", "image/heic", "image/heif", "image/webp", "image/gif"].contains(mimeType) }
    static func validID(_ id: String) -> Bool { id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    var isValid: Bool {
        version == 1 && Self.validID(id) && !roomID.isEmpty && roomID.utf8.count <= 80
            && sender.utf8.count <= 256 && sender.split(separator: ".").count == 3
            && !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".."
            && !name.contains(where: { $0 == "/" || $0 == "\\" || $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true })
            && mimeType.utf8.count <= 100 && size >= 0 && size <= Self.maxFileBytes
            && (!isImage || size <= Self.maxImageBytes)
            && digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

// This wire object is transient. ChatMessage retains only `info`; keys live in
// a revocable lease, and encrypted thumbnails are written to the private cache.
struct AttachmentDescriptor: Codable, Sendable {
    let info: AttachmentInfo
    var key: Data
    let thumbnail: Data?
    var isValid: Bool {
        info.isValid && key.count == 32 && (thumbnail?.count ?? 0) <= AttachmentInfo.maxThumbnailBytes
            && info.hasThumbnail == (thumbnail != nil)
    }
}

enum AttachmentCrypto {
    // A fresh random 256-bit key is generated for every immutable object. Each
    // AES-GCM nonce is a 96-bit counter unique under that key. Retries resend
    // ciphertext and NEVER encrypt different plaintext under an existing key.
    // AAD binds room, sender admission, object, total length and record position.
    private static func aad(_ info: AttachmentInfo, index: Int) -> Data {
        Data("Chirp attachment AES256GCM v1\n\(info.roomID)\n\(info.sender)\n\(info.id)\n\(info.size)\n\(info.chunkCount)\n\(index)\n".utf8)
    }
    private static func nonce(_ index: Int) throws -> AES.GCM.Nonce {
        var value = UInt64(index).bigEndian
        var bytes = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: bytes)
    }

    static func encrypt(source: URL, info: AttachmentInfo, lease: AttachmentLease) throws -> AttachmentInfo {
        try ClientLog.shared.measure(.crypto, "attachmentEncrypt") {
            try lease.claimEncryption(info.id)
            let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
            let destination = try lease.url(info.id)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ClientFailure(.attachmentCacheFailed) }
            let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
            var digest = SHA256()
            for index in 0..<info.chunkCount {
                try lease.check()
                let count = min(AttachmentInfo.chunkBytes, Int(info.size) - index * AttachmentInfo.chunkBytes)
                var plaintext = try read(input, count: count)
                defer { plaintext.resetBytes(in: 0..<plaintext.count) }
                let encrypted = try lease.withKey(info.id) { key in
                    let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce(index), authenticating: aad(info, index: index))
                    return box.ciphertext + box.tag
                }
                try output.write(contentsOf: encrypted); digest.update(data: encrypted)
            }
            guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw ClientFailure(.attachmentInvalid) }
            try lease.check(); try output.synchronize()
            var result = info; result.digest = digest.finalize().map { String(format: "%02x", $0) }.joined()
            return result
        }
    }

    static func decrypt(info: AttachmentInfo, lease: AttachmentLease, source: URL? = nil, consume: (Data) throws -> Void) throws {
        try ClientLog.shared.measure(.crypto, "attachmentDecrypt") {
            guard info.isValid else { throw ClientFailure(.attachmentInvalid) }
            let input = try FileHandle(forReadingFrom: source ?? lease.url(info.id)); defer { try? input.close() }
            var digest = SHA256()
            for index in 0..<info.chunkCount {
                let count = min(AttachmentInfo.chunkBytes, Int(info.size) - index * AttachmentInfo.chunkBytes)
                let encrypted = try read(input, count: count + 16)
                digest.update(data: encrypted)
                var plaintext = try lease.withKey(info.id) { key in
                    let box = try AES.GCM.SealedBox(nonce: nonce(index), ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
                    return try AES.GCM.open(box, using: key, authenticating: aad(info, index: index))
                }
                defer { plaintext.resetBytes(in: 0..<plaintext.count) }
                try lease.check(); try consume(plaintext)
            }
            guard (try input.read(upToCount: 1) ?? Data()).isEmpty,
                  digest.finalize().map({ String(format: "%02x", $0) }).joined() == info.digest else { throw ClientFailure(.attachmentInvalid) }
            try lease.check()
        }
    }

    static func validateCiphertext(info: AttachmentInfo, lease: AttachmentLease, source: URL? = nil) throws {
        // Authenticate each record and the complete file before displaying or exporting.
        try decrypt(info: info, lease: lease, source: source) { _ in }
    }

    static func thumbnail(_ data: Data, info: AttachmentInfo, lease: AttachmentLease, decrypt: Bool) throws -> Data {
        try ClientLog.shared.measure(.crypto, decrypt ? "thumbnailDecrypt" : "thumbnailEncrypt") {
            guard data.count <= AttachmentInfo.maxThumbnailBytes else { throw ClientFailure(.attachmentInvalid) }
            return try lease.withKey(info.id) { key in
                let subkey = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(info.id.utf8), info: Data("Chirp attachment thumbnail v1".utf8), outputByteCount: 32)
                let context = aad(info, index: -1)
                if decrypt { return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: subkey, authenticating: context) }
                guard let combined = try AES.GCM.seal(data, using: subkey, authenticating: context).combined,
                      combined.count <= AttachmentInfo.maxThumbnailBytes else { throw ClientFailure(.attachmentInvalid) }
                return combined
            }
        }
    }

    static func read(_ file: FileHandle, count: Int) throws -> Data {
        var data = Data(); data.reserveCapacity(count)
        while data.count < count {
            let next = try file.read(upToCount: count - data.count) ?? Data()
            guard !next.isEmpty else { throw ClientFailure(.attachmentInvalid) }; data.append(next)
        }
        return data
    }
}
