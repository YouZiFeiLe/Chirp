package cn.youzifeile.chirp.media

import org.junit.Assert.*
import org.junit.Test

class RoomPresenceTrackerTest {
    @Test fun announcesOnlyConfirmedMembershipAndDoesNotReplayAfterResuming() {
        val tracker = RoomPresenceTracker()
        assertEquals(emptyList<PresenceSound>(), tracker.confirm(setOf("other"), "self"))
        assertEquals(listOf(PresenceSound.Joined), tracker.confirm(setOf("self", "a", "b"), "self"))
        assertEquals(emptyList<PresenceSound>(), tracker.confirm(setOf("self", "a", "b"), "self"))
        assertEquals(listOf(PresenceSound.Left, PresenceSound.Joined), tracker.confirm(setOf("self", "a", "c"), "self"))
        tracker.resynchronize()
        assertEquals(emptyList<PresenceSound>(), tracker.confirm(setOf("self", "d"), "self"))
        assertEquals(listOf(PresenceSound.Left), tracker.confirm(setOf("self"), "self"))
    }
}
