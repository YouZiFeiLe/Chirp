package cn.youzifeile.chirp.media

import org.junit.Assert.*
import org.junit.Test

class VoiceKeysTest {
    // WebRTC M150 HKDF-SHA256 and AES-128-GCM. Plain Opus is f8 ff fe.
    private val first = "f8b1da3285d1b49a75b87464a233efe1f25c700000000000000000000000010c00".hexToByteArray()
    private val second = "f87c624d442c7488134062139d879cdcc467950000000000000000000000020c00".hexToByteArray()
    private val staged = "f8b1a2e9c4710abc9d74624752a1cfabd066ef0000000000000000000000010c01".hexToByteArray()
    private val material = ByteArray(32) { it.toByte() }
    private val plain = "f8fffe".hexToByteArray()

    @Test fun rtpEgressRequiresAnAuthenticatedFrameForThisSenderSsrcAndLeasedSlot() {
        val keys = VoiceKeys({ true }, { 0 })
        keys.install("alice", 0, material)
        keys.activate(0)
        fun accept(frame: ByteArray, identity: String = "alice", ssrc: Int = 0, slot: Int = 0) =
            keys.authenticatesOutgoing(identity, ssrc, frame) { it == slot }
        assertFalse(accept(plain))
        assertFalse(accept(first.copyOf().apply { this[1] = (this[1].toInt() xor 1).toByte() }))
        assertFalse(accept(first, "bob"))
        assertFalse(accept(first, ssrc = 1))
        assertFalse(accept(first, slot = 1))
        var checks = 0
        assertFalse(keys.authenticatesOutgoing("alice", 0, first) { ++checks == 1 })
        assertTrue(accept(first))
        assertFalse(accept(first))
        assertArrayEquals(plain, keys.open("alice", first))
    }

    @Test fun authenticatesBeforeMarkingNonceAndRetainsHistoryOnReinstall() {
        val keys = VoiceKeys({ true }, { 0 })
        keys.install("alice",0,material); keys.activate(0)
        val forged = second.copyOf().apply { this[0] = 0 }
        assertNull(keys.open("alice", forged))
        assertNull(keys.open("bob", first))
        assertArrayEquals(plain,keys.open("alice",second))
        assertArrayEquals(plain,keys.open("alice",first))
        keys.install("alice",0,material)
        assertNull(keys.open("alice",first))
        keys.install("alice",1,material); keys.activate(1)
        assertNull(keys.open("alice",first.copyOf().apply { this[lastIndex] = 1 }))
    }
    @Test fun recoveryCountsOnlyPersistentFailureOnTheSameReceivingTrack() {
        val recovery = DecryptionRecovery()
        fun observe(now: Long, packets: Long, failure: VoiceFailure? = VoiceFailure.MissingKey) =
            recovery.observe(listOf(
                TrackDiagnostic("alice", true, false, "GOOD", null, null, null, packets, null, true, "left", failure),
                TrackDiagnostic("alice", true, false, "GOOD", null, null, null, packets, 0, true, "right")
            ), now)
        assertNull(observe(0, 1))
        assertNull(observe(5_000, 1))
        assertNull(observe(5_100, 2, null))
        assertNull(observe(6_000, 3))
        assertEquals(DecryptionRecovery.Action.Recover, observe(11_000, 6))
        assertNull(observe(12_000, 1))
        assertEquals(DecryptionRecovery.Action.Recover, observe(17_000, 2))
        assertNull(observe(18_000, 1))
        assertEquals(DecryptionRecovery.Action.Stop, observe(23_000, 2))
        assertNull(observe(80_000, 1))
        assertEquals(DecryptionRecovery.Action.Recover, observe(85_000, 2))
    }

    @Test fun aSuccessfulFrameOnOneReceiverOnlyClearsThatTracksFailure() {
        var now = 100L
        val keys = VoiceKeys({ true }, { now })
        assertNull(keys.open("alice", first, "mic"))
        assertEquals(VoiceFailure.MissingKey, keys.failure("mic"))
        keys.install("alice", 0, material)
        keys.activate(0)
        val damaged = first.copyOf().apply { this[1] = (this[1].toInt() xor 1).toByte() }
        assertNull(keys.open("alice", damaged, "other"))
        assertEquals(VoiceFailure.DecryptionFailed, keys.failure("other"))
        assertArrayEquals(plain, keys.open("alice", first, "mic"))
        assertNull(keys.failure("mic"))
        assertEquals(now, keys.lastDecryption("mic"))
        assertEquals(now, keys.firstDecryption("mic"))
        assertNull(keys.firstDecryption("other"))
        assertEquals(VoiceFailure.DecryptionFailed, keys.failure("other"))
        now += 2_001
        assertArrayEquals(plain, keys.open("alice", second, "mic"))
        assertEquals(100L, keys.firstDecryption("mic"))
        assertEquals(now, keys.lastDecryption("mic"))
        assertNull(keys.failure("other"))
        keys.retire(0)
        assertNull(keys.open("alice", second, "mic"))
        assertNull(keys.failure("mic"))
        keys.clear()
        assertNull(keys.firstDecryption("mic"))
    }

    @Test fun needsLeaseForNewSlotAndBoundsOldSlotByOriginalPermit() {
        var now = 100L
        var allowed = true
        val keys = VoiceKeys({ allowed }, { now })
        keys.install("alice",0,material)
        assertNull(keys.open("alice", first))
        keys.activate(0)
        keys.install("alice",1,ByteArray(32) { (32 + it).toByte() })
        keys.expire(0,150)
        assertNull(keys.open("alice", staged))
        keys.activate(1)
        assertArrayEquals(plain,keys.open("alice", first))
        now += 150
        assertNull(keys.open("alice", second))
        allowed = false
        assertNull(keys.open("alice",staged))
        allowed = true
        assertArrayEquals(plain,keys.open("alice", staged))
        keys.clear()
        assertNull(keys.open("alice",second))
    }
}
