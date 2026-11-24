package cn.youzifeile.chirp.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class MediaPermitTest {
    @Test fun receiveOverlapKeepsItsOriginalDeadlinesAcrossRenewalsAndSlotReuse() {
        var wall = 100L
        var mono = 200L
        val gate = MediaGate("group", { wall }, { mono })
        fun grant(epoch: ULong, duration: Long) =
            gate.grant(MediaPermit("group", wall + duration, mono + duration, epoch))
        grant(0UL, 500)
        assertNull(gate.receiveEpoch(1))
        grant(1UL, 3000)
        assertFalse(gate.maySend(0))
        assertEquals(0L, gate.receiveEpoch(0))
        wall += 500
        grant(1UL, 3000)
        assertNull(gate.receiveEpoch(0))
        grant(2UL, 3000)
        assertEquals(2L, gate.receiveEpoch(0))
        assertEquals(1L, gate.receiveEpoch(1))
        mono += 1000
        assertNull(gate.receiveEpoch(1))
        gate.revoke()
        assertNull(gate.receiveEpoch(0))
    }

    @Test
    fun expiresOnEitherClockAndSurvivesBackwardWallClockChanges() {
        val lease = MediaPermit("room/server/session/1", wallDeadline = 10_000, monotonicDeadline = 4_000)
        assertEquals(1_000L, lease.remaining(wall = 8_500, monotonic = 3_000))
        assertEquals(0L, lease.remaining(wall = 10_001, monotonic = 2_000))
        assertEquals(0L, lease.remaining(wall = 7_000, monotonic = 4_000))
    }
}
