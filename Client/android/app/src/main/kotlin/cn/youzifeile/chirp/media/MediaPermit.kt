package cn.youzifeile.chirp.media

import android.os.SystemClock
import cn.youzifeile.chirp.data.verify

internal class MediaPermit(
    val groupID: String,
    val wallDeadline: Long,
    private val monotonicDeadline: Long,
    val keyEpoch: ULong = 0UL,
) {
    fun remaining(): Long = remaining(System.currentTimeMillis(), SystemClock.elapsedRealtime())

    fun remaining(wall: Long, monotonic: Long): Long =
        minOf(wallDeadline - wall, monotonicDeadline - monotonic).coerceAtLeast(0)
}

internal class MediaGate(val groupID: String, private val wall: () -> Long = System::currentTimeMillis,
    private val monotonic: () -> Long = { SystemClock.elapsedRealtime() }) {
    private data class Leases(val current: MediaPermit, val previous: MediaPermit? = null, val overlapUntil: Long = 0)
    @Volatile private var leases: Leases? = null
    private var revoked = false
    @Volatile var micAllowed = false
    @Volatile var systemMuted = false

    fun remainingIfGranted(): Long? = leases?.current?.remaining(wall(), monotonic())
    fun remaining(): Long = remainingIfGranted() ?: 0

    fun maySend(epoch: Long): Boolean {
        val permit = leases?.current ?: return false
        return permit.keyEpoch.toLong() == epoch && permit.remaining(wall(), monotonic()) > 0
    }

    /** Queued frames may use the previous receive key only within its own lease and the one-second overlap. */
    fun receiveEpoch(index: Int): Long? {
        val state = leases ?: return null
        val now = wall()
        val elapsed = monotonic()
        val current = state.current
        if (current.remaining(now, elapsed) == 0L) return null
        if ((current.keyEpoch % 2UL).toInt() == index) return current.keyEpoch.toLong()
        val previous = state.previous ?: return null
        return previous.keyEpoch.toLong().takeIf {
            (previous.keyEpoch % 2UL).toInt() == index && elapsed < state.overlapUntil && previous.remaining(now, elapsed) > 0
        }
    }

    @Synchronized fun grant(permit: MediaPermit) {
        check(permit.groupID == groupID)
        val now = wall()
        val elapsed = monotonic()
        val state = leases
        verify(!revoked && (state?.current?.remaining(now, elapsed) ?: 1) > 0 && permit.remaining(now, elapsed) > 0,
            "GROUP_LEASE_LOST")
        leases = when {
            state == null -> {
                verify(permit.keyEpoch == 0UL, "GROUP_LEASE_LOST")
                Leases(permit)
            }
            state.current.keyEpoch == permit.keyEpoch -> state.copy(current = permit)
            else -> {
                verify(state.current.keyEpoch < ULong.MAX_VALUE && permit.keyEpoch == state.current.keyEpoch + 1UL,
                    "GROUP_LEASE_LOST")
                Leases(permit, state.current, elapsed + 1_000)
            }
        }
    }

    @Synchronized fun revoke() {
        revoked = true
        leases = null
        micAllowed = false
    }
}
