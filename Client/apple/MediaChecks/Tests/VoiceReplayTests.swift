import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import LiveKit

private let alice = "alice", bob = "bob"
private let first = Data(0..<32), next = Data(32..<64)

private func provider(_ permitted: @escaping @Sendable () -> Bool = { true }) -> BaseKeyProvider {
    BaseKeyProvider(chirpAudioAuthorization: permitted)
}

private func opus(_ material: Data, sequence: UInt32, index: UInt8 = 0) throws -> Data {
    let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material),
        salt: Data("LKFrameEncryptionKey".utf8), info: Data(repeating: 0, count: 128), outputByteCount: 16)
    let iv = withUnsafeBytes(of: sequence.bigEndian) { Data(repeating: 0, count: 8) + $0 }
    let header = Data([0xf8])
    let box = try AES.GCM.seal(Data([0xff, 0xfe]), using: key, nonce: AES.GCM.Nonce(data: iv), authenticating: header)
    return header + box.ciphertext + box.tag + iv + Data([12, index])
}

@Test func authenticatedVoiceAllowsReorderingAndRejectsDuplicatesAcrossReceiverBindings() async throws {
    let keys = provider()
    keys.setKey(keyData: first, participantId: alice, index: 0)
    keys.setKey(keyData: next, participantId: bob, index: 0)
    keys.chirpAuthorizeVoiceKeyIndex(0)
    let voice = try #require(keys.chirpVoice)
    let original = try opus(first, sequence: 7), earlier = try opus(first, sequence: 2)
    let plain = ChirpVoiceKeys.Result.audio(Data([0xf8, 0xff, 0xfe]))
    var damaged = original
    damaged[5] ^= 1
    #expect(voice.open(damaged, from: alice) == .invalid)
    #expect(voice.open(original, from: bob) == .invalid)
    // All tracks of a participant share the same decision, even under simultaneous delivery.
    let delivered = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<24 { group.addTask { voice.open(original, from: alice) == plain } }
        return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
    }
    #expect(delivered == 1)
    #expect(voice.open(earlier, from: alice) == plain)
    #expect(voice.open(try opus(next, sequence: 7), from: bob) == plain)
    keys.setKey(keyData: first, participantId: alice, index: 0)
    #expect(voice.open(original, from: alice) == .duplicate)
    for size in 0..<31 { #expect(voice.open(Data(repeating: 0, count: size), from: alice) == .invalid) }
}

@Test func voiceBindsConfirmationLeaseAndReplayHistoryToTheActualEpoch() throws {
    let lease = Mutex(false)
    let keys = provider { lease.withLock { $0 } }
    keys.setKey(keyData: first, participantId: alice, index: 0)
    let voice = try #require(keys.chirpVoice)
    let old = try opus(first, sequence: 1), late = try opus(first, sequence: 2)
    let fresh = try opus(next, sequence: 1, index: 1)
    let plain = ChirpVoiceKeys.Result.audio(Data([0xf8, 0xff, 0xfe]))
    #expect(!voice.permitsPlayout(for: alice))
    #expect(voice.open(old, from: alice) == .inactive)
    lease.withLock { $0 = true }
    #expect(voice.open(old, from: alice) == .inactive)
    keys.chirpAuthorizeVoiceKeyIndex(0)
    #expect(voice.open(old, from: alice) == plain)
    #expect(keys.chirpStageKeys([alice: next], index: 1))
    #expect(voice.open(fresh, from: alice) == .inactive)
    #expect(keys.chirpActivateKeyIndex(1))
    keys.chirpAuthorizeVoiceKeyIndex(0) // Late old-epoch lease
    #expect(voice.open(fresh, from: alice) == .inactive)
    keys.chirpAuthorizeVoiceKeyIndex(1)
    #expect(voice.open(fresh, from: alice) == plain)
    #expect(voice.open(old, from: alice) == .duplicate)
    #expect(voice.open(late, from: alice) == plain)
    keys.chirpExpireKeyIndex(0, at: .now)
    #expect(voice.open(try opus(first, sequence: 3), from: alice) == .inactive)
    let third = Data(64..<96)
    #expect(keys.chirpStageKeys([alice: third], index: 0))
    #expect(keys.chirpActivateKeyIndex(0))
    keys.chirpAuthorizeVoiceKeyIndex(0)
    #expect(voice.open(old, from: alice) == .invalid)
    #expect(voice.open(try opus(third, sequence: 1), from: alice) == plain)
    lease.withLock { $0 = false }
    #expect(voice.open(try opus(third, sequence: 2), from: alice) == .inactive)
    keys.chirpRetireKeys()
    lease.withLock { $0 = true }
    #expect(!voice.permitsPlayout(for: alice))
    #expect(voice.open(fresh, from: alice) == .inactive)
}

@Test func reinstallingTheSameVoiceKeyInAnotherSlotPreservesItsHistory() throws {
    let keys = provider()
    keys.setKey(keyData: first, participantId: alice, index: 0)
    keys.chirpAuthorizeVoiceKeyIndex(0)
    let voice = try #require(keys.chirpVoice)
    #expect(voice.open(try opus(first, sequence: 19), from: alice) == .audio(Data([0xf8, 0xff, 0xfe])))
    #expect(keys.chirpStageKeys([alice: first], index: 1))
    #expect(keys.chirpActivateKeyIndex(1))
    keys.chirpAuthorizeVoiceKeyIndex(1)
    #expect(voice.open(try opus(first, sequence: 19, index: 1), from: alice) == .duplicate)
}

@Test func fullVoiceReplayHistoryKeepsTheFirstNonceUntilRetirement() throws {
    let keys = provider()
    keys.setKey(keyData: first, participantId: alice, index: 0)
    keys.chirpAuthorizeVoiceKeyIndex(0)
    let voice = try #require(keys.chirpVoice)
    let plain = ChirpVoiceKeys.Result.audio(Data([0xf8, 0xff, 0xfe]))
    for sequence: UInt32 in 0..<65_536 {
        guard voice.open(try opus(first, sequence: sequence), from: alice) == plain else {
            Issue.record("Fresh voice frame rejected at \(sequence)")
            return
        }
    }
    #expect(voice.open(try opus(first, sequence: 65_536), from: alice) == .inactive)
    #expect(voice.open(try opus(first, sequence: 0), from: alice) == .duplicate)
}

@Test func voiceRetiredDuringAuthenticationCannotEnterTheDecoder() throws {
    let checks = Mutex(0)
    let onCommit = Mutex<(@Sendable () -> Void)?>(nil)
    let keys = provider {
        let finalCheck = checks.withLock { $0 += 1; return $0 == 2 }
        if finalCheck { onCommit.withLock { $0 }?() }
        return true
    }
    keys.setKey(keyData: first, participantId: alice, index: 0)
    keys.chirpAuthorizeVoiceKeyIndex(0)
    let voice = try #require(keys.chirpVoice)
    onCommit.withLock { $0 = { [weak keys] in keys?.chirpRetireKeys() } }
    #expect(voice.open(try opus(first, sequence: 8), from: alice) == .inactive)
}

@Test func voiceDecryptionTimingRequiresConsentAndDropsEarlierGenerations() throws {
    let keys = provider()
    keys.setKey(keyData: first, participantId: alice, index: 0)
    keys.chirpAuthorizeVoiceKeyIndex(0)
    let voice = try #require(keys.chirpVoice)
    let plain = ChirpVoiceKeys.Result.audio(Data([0xf8, 0xff, 0xfe]))
    #expect(voice.open(try opus(first, sequence: 1), from: alice) == plain)
    #expect(keys.chirpTakeVoiceDecryptionTiming(generation: 1) == nil)
    let frame = try opus(first, sequence: 2)
    #expect(voice.open(frame, from: alice) == plain)
    #expect(voice.open(frame, from: alice) == .duplicate)
    #expect(voice.open(try opus(first, sequence: 3), from: alice) == plain)
    let sample = try #require(keys.chirpTakeVoiceDecryptionTiming(generation: 1))
    #expect(sample.frames == 2 && sample.totalNS >= sample.maxNS && sample.maxNS > 0)
    #expect(keys.chirpTakeVoiceDecryptionTiming(generation: 1) == nil)
    #expect(voice.open(try opus(first, sequence: 4), from: alice) == plain)
    #expect(keys.chirpTakeVoiceDecryptionTiming(generation: 3) == nil)
    #expect(voice.open(try opus(first, sequence: 5), from: alice) == plain)
    #expect(keys.chirpTakeVoiceDecryptionTiming(generation: 0) == nil)
}
