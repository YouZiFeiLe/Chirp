package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.wireJson
import org.junit.Assert.*
import org.junit.Test

class RoomChatTest {
    @Test fun ignoresRepeatIdFromOneSenderButAcceptsSameIdFromDifferentSender() {
        val room = RoomChat("self")
        val id = "00112233-4455-6677-8899-AABBCCDDEEFF"
        val group = "friends/server/session/1"
        val peers = mapOf("one" to "First", "two" to "Second")
        fun receive(sender: String, uuid: String, sequence: ULong): Boolean {
            val packet = ChatPacket(1, uuid, group, sender, sequence, "Hello")
            val bytes = wireJson.encodeToString(ChatPacket.serializer(), packet).encodeToByteArray()
            return room.receive(group, peers, sender, bytes) { false }
        }
        assertTrue(receive("one", id, 1UL))
        assertFalse(receive("one", id.lowercase(), 3UL))
        assertTrue(receive("one", "00112233-4455-6677-8899-000000000002", 2UL))
        assertTrue(receive("two", id, 1UL))
        assertEquals(3, room.messages.map { it.id }.distinct().size)
    }
}
