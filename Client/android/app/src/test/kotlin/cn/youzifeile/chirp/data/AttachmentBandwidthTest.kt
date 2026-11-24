package cn.youzifeile.chirp.data

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AttachmentBandwidthTest {
    @Test fun directionsHaveSeparateBudgetsAndPausedRequestsAreCancellable() = runTest {
        val budget = AttachmentBandwidth({ testScheduler.currentTime }, { delay(it) })
        budget.policy = AttachmentPolicy.Constrained
        budget.acquire(NETWORK_CHUNK, true)
        budget.acquire(NETWORK_CHUNK, false)
        assertEquals(0, testScheduler.currentTime)
        budget.acquire(NETWORK_CHUNK, true)
        assertEquals(2000, testScheduler.currentTime)
        budget.policy = AttachmentPolicy.Paused
        var sent = false
        val pending = launch { budget.acquire(NETWORK_CHUNK, false); sent = true }
        advanceTimeBy(3000); assertFalse(sent)
        pending.cancelAndJoin()
        budget.policy = AttachmentPolicy.Normal
        budget.acquire(NETWORK_CHUNK, false)
        assertFalse(sent)
    }
}
