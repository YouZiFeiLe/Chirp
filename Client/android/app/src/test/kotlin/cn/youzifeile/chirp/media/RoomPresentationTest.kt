package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.Directory
import cn.youzifeile.chirp.data.Friend
import cn.youzifeile.chirp.data.Profile
import cn.youzifeile.chirp.data.wireJson
import cn.youzifeile.chirp.ui.withKnownProfiles
import org.junit.Assert.*
import org.junit.Test

class RoomPresentationTest {
    @Test fun oldDirectoryEventsCannotRevertNewerProfilesOrBringBackDepartedMembers() {
        val login = Profile("me", "Login", 1)
        val peer = Profile("peer", "Previous", 2)
        val old = Directory("server", 2UL, emptyList(), listOf(login, peer, Profile("gone", "Gone", 1)))
        val edited = login.copy(name = "Saved", revision = 3)
        val incoming = old.copy(revision = 3UL, members = listOf(login, peer.copy(name = "Stale", revision = 1)))
        assertEquals(listOf(edited, peer), incoming.withKnownProfiles(old, edited).members)
        val newer = peer.copy(name = "Newer", revision = 4)
        assertEquals(listOf(newer), incoming.copy(members = listOf(newer)).withKnownProfiles(old, edited).members)
    }

    @Test fun nicknameChecksTheBoundRootAndIsCapturedWhenEachMessageArrives() {
        val identity = "peer.device"
        var root: String? = null
        var names = mapOf("peer" to "Directory")
        val friends = listOf(Friend("peer", "verified-root", "Friend"))
        val roster = mapOf(identity to "At entry")
        val group = "room/group"
        val chat = RoomChat("self") { id, fallback -> roomDisplayName(id, root, friends, names, fallback) }
        fun receive(sequence: Int) {
            val id = "00112233-4455-6677-8899-" + sequence.toString().padStart(12, '0')
            val packet = ChatPacket(1, id, group, identity, sequence.toULong(), "Hi")
            assertTrue(chat.receive(group, roster, identity, wireJson.encodeToString(packet).encodeToByteArray()) { false })
        }
        receive(1)
        root = "different-root"
        names = mapOf("peer" to "Updated directory name")
        receive(2)
        root = "verified-root"
        receive(3)
        root = null
        names = emptyMap()
        receive(4)
        assertEquals(listOf("Directory", "Updated directory name", "Friend", "At entry"), chat.messages.map { it.name })
    }

    @Test fun muteRestoresTheLastPositiveLevelForEachMemberAndResetBecomesTheNewLevel() {
        val start = CallState().withMemberVolume("alice", 1.65f).withMemberVolume("bob", .4f)
        fun CallState.toggle(id: String) = withMemberVolume(id, toggledVolume(id))
        val muted = start.toggle("alice").toggle("bob")
        assertEquals(mapOf("alice" to 0f, "bob" to 0f), muted.volumes)
        assertEquals(mapOf("alice" to 1.65f, "bob" to .4f), muted.toggle("bob").toggle("alice").volumes)
        assertEquals(1f, muted.withMemberVolume("alice", 1f).toggle("alice").toggledVolume("alice"))
        assertEquals(1f, start.toggle("new member").toggledVolume("new member"))
    }

    @Test fun oversizedPastePreservesTheDraftAndNextValidEditDismissesItsError() {
        val text = "🍊".repeat(MAX_CHAT_TEXT / 4)
        val accepted = CallState(chatVisible = true, phase = CallPhase.Connected).editDraft(text)
        assertEquals(text, accepted.draft)
        val rejected = accepted.editDraft(text + "a")
        assertEquals(text, rejected.draft)
        assertTrue(rejected.draftTooLong)
        val edited = rejected.editDraft("新草稿")
        assertFalse(edited.draftTooLong)
        assertEquals("新草稿", edited.draft)
        assertEquals(CallState(), CallState().editDraft(text))
        val held = edited.copy(held = true, phase = CallPhase.Securing)
        assertEquals(held, held.editDraft("changed while held"))
    }

    @Test fun countdownUsesMonotonicElapsedTimeAndDistinguishesDueFromStale() {
        val info = RoomPublicInformation(10_000, 3_000, 0UL, 1, "initial_connection",
            10_000, null, 13_000, null, 0, 0, started = 100)
        assertEquals(3L, info.countdown(100))
        assertEquals(1L, info.countdown(3_099))
        assertEquals(0L, info.countdown(3_100))
        assertFalse(info.fresh(6_100))
        assertNull(info.copy(next = 20_000).countdown(6_100))
    }
}
