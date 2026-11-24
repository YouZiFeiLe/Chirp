package cn.youzifeile.chirp.media

import org.junit.Assert.assertEquals
import org.junit.Test

class PendingRoomDataTest {
    @Test fun stagedMessagesWaitForTheirOwnLeaseAndKeepDeliveryOrder() {
        var leased = mapOf(0 to 0L)
        var staged = mapOf(1 to 1L)
        val inbox = PendingRoomData({ leased[it] }, { staged[it] })
        val opened = mutableListOf<Pair<String, Long>>()
        fun receive(slot: Int, name: String) = inbox.receive(slot, 100) { opened += name to it }
        receive(1, "first")
        receive(0, "current")
        receive(1, "second")
        assertEquals(listOf("current" to 0L), opened)
        staged = emptyMap()
        leased = mapOf(0 to 0L, 1 to 1L)
        receive(1, "third")
        assertEquals(listOf("current" to 0L, "first" to 1L, "second" to 1L, "third" to 1L), opened)
    }

    @Test fun reusedSlotsAndRevocationDiscardQueuedCiphertextAndTheBacklogIsBounded() {
        var staged: Long? = 1
        var leased: Long? = null
        val inbox = PendingRoomData({ leased }, { staged })
        val opened = mutableListOf<Long>()
        inbox.receive(1, 100) { opened += it }
        staged = null
        leased = 3
        inbox.drain()
        assertEquals(emptyList<Long>(), opened)
        leased = null
        staged = 5
        inbox.receive(1, 65536) { error("oversized packet") }
        repeat(40) { inbox.receive(1, 65535) { opened += it } }
        leased = 5
        inbox.drain()
        assertEquals(List(32) { 5L }, opened)
        leased = null
        staged = 7
        inbox.receive(1, 100) { error("revoked room") }
        inbox.clear()
        leased = 7
        inbox.drain()
    }
}
