import CryptoKit
import Foundation

/// Shared by every receiver for this MLS provider, including resubscriptions.
/// WebRTC's authenticated Opus envelope is TOC | ciphertext | tag | IV | 12 | key index.
final class ChirpVoiceKeys: @unchecked Sendable {
    enum Result: Equatable {
        case audio(Data), duplicate, inactive, invalid
    }

    private struct Nonce: Hashable {
        let first: UInt64
        let last: UInt32

        init(_ iv: Data.SubSequence) {
            (first, last) = iv.withUnsafeBytes {
                ($0.loadUnaligned(as: UInt64.self), $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            }
        }
    }

    private final class Epoch {
        let key: SymmetricKey
        var seen: Set<Nonce> = []
        init(_ key: SymmetricKey) { self.key = key }
    }

    private struct Slot {
        let epoch: Epoch
        var active: Bool
        var withinGrace: (@Sendable () -> Bool)?
    }

    private let lock = NSLock()
    private var timingGeneration: UInt64 = 0
    private var timing: (frames: UInt64, totalNS: UInt64, maxNS: UInt64) = (0, 0, 0)

    // The room monitor drains counters. Audio callbacks do no logging, allocation
    // for metrics, or additional locking; zero disables clock reads as well.
    func takeTiming(generation: UInt64) -> (frames: UInt64, totalNS: UInt64, maxNS: UInt64)? {
        lock.withLock {
            defer { timing = (0, 0, 0); timingGeneration = generation }
            guard generation != 0, generation == timingGeneration, timing.frames > 0 else { return nil }
            return timing
        }
    }

    private let salt: Data
    private let authorized: @Sendable () -> Bool
    private var slots: [String: [Int32: Slot]] = [:]

    init(salt: Data, authorized: @escaping @Sendable () -> Bool) {
        self.salt = salt
        self.authorized = authorized
    }

    func install(_ material: Data, for identity: String, index: Int32, staged: Bool = false) {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: salt,
            info: Data(repeating: 0, count: 128), outputByteCount: 16)
        lock.lock(); defer { lock.unlock() }
        let epoch = slots[identity]?.values.first(where: { $0.epoch.key == key })?.epoch ?? Epoch(key)
        // An idempotent installation must preserve both the grant and the nonce set.
        if !staged, slots[identity]?[index]?.epoch === epoch { return }
        slots[identity, default: [:]][index] = Slot(epoch: epoch, active: false)
    }

    func activate(_ index: Int32) {
        lock.lock(); defer { lock.unlock() }
        for identity in Array(slots.keys) { slots[identity]?[index]?.active = true }
    }

    func expire(_ index: Int32, withinGrace: @escaping @Sendable () -> Bool) {
        lock.lock(); defer { lock.unlock() }
        for identity in Array(slots.keys) { slots[identity]?[index]?.withinGrace = withinGrace }
    }

    func retire(_ index: Int32? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let index {
            for identity in Array(slots.keys) { slots[identity]?[index] = nil }
        } else { slots.removeAll() }
    }

    func permitsPlayout(for identity: String) -> Bool {
        guard authorized() else { return false }
        lock.lock(); defer { lock.unlock() }
        return slots[identity]?.values.contains(where: { $0.active && ($0.withinGrace?() ?? true) }) == true
    }

    // Called under lock so slot reuse cannot be mistaken for the original key.
    private func activeEpoch(_ identity: String, _ index: Int32) -> Epoch? {
        guard let slot = slots[identity]?[index], slot.active, slot.withinGrace?() ?? true else { return nil }
        return slot.epoch
    }

    func open(_ frame: Data, from identity: String) -> Result {
        // A lease check can synchronously retire this provider. Keep it outside the lock.
        guard authorized() else { return .inactive }
        guard frame.count >= 31, frame[frame.endIndex - 2] == 12, let keyIndex = frame.last else { return .invalid }
        let index = Int32(keyIndex)
        let (candidate, generation) = lock.withLock { (activeEpoch(identity, index), timingGeneration) }
        guard let epoch = candidate else { return .inactive }

        let ivStart = frame.endIndex - 14
        let iv = frame[ivStart..<(ivStart + 12)]
        let toc = frame.prefix(1)
        let started = generation == 0 ? nil : DispatchTime.now().uptimeNanoseconds
        let payload: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                ciphertext: frame[(frame.startIndex + 1)..<(ivStart - 16)], tag: frame[(ivStart - 16)..<ivStart])
            payload = try AES.GCM.open(box, using: epoch.key, authenticating: toc)
        } catch { return .invalid }

        let elapsed = started.map { DispatchTime.now().uptimeNanoseconds - $0 }
        guard authorized() else { return .inactive }
        let nonce = Nonce(iv)
        lock.lock(); defer { lock.unlock() }
        guard activeEpoch(identity, index) === epoch else { return .inactive }
        guard !epoch.seen.contains(nonce) else { return .duplicate }
        // Enough for 120 s of 2.5 ms Opus frames. Never evict a nonce while its key is accepted.
        guard epoch.seen.count < 65_536 else { return .inactive }
        epoch.seen.insert(nonce)
        if let elapsed, generation == timingGeneration {
            timing.frames &+= 1
            timing.totalNS &+= elapsed
            timing.maxNS = max(timing.maxNS, elapsed)
        }
        return .audio(toc + payload)
    }
}

extension BaseKeyProvider {
    @nonobjc public func chirpTakeVoiceDecryptionTiming(generation: UInt64) -> (frames: UInt64, totalNS: UInt64, maxNS: UInt64)? {
        chirpVoice?.takeTiming(generation: generation)
    }
}
