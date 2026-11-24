package io.livekit.android.room

import com.google.protobuf.ByteString
import livekit.LivekitModels.DataPacket
import livekit.LivekitModels.EncryptedPacketPayload
import livekit.LivekitModels.Encryption
import livekit.LivekitModels.UserPacket
import livekit.org.webrtc.DataChannel
import org.junit.Assert.*
import org.junit.Test

class ChirpUserPacketTest {
    private val sender = "alice.login.entry"
    private val sid = "PA_alice"
    private val recipients = listOf("bob.login.entry", "carol.login.entry")
    private val topic = "chirp.room-chat.v1"

    @Test fun anOpenPublisherCanSendDuringInitialConnectionButNeverDuringRecovery() {
        val open = DataChannel.State.OPEN
        assertTrue(ConnectionState.CONNECTING.chirpPublisherReady(true, open))
        assertTrue(ConnectionState.CONNECTED.chirpPublisherReady(true, open))
        for (state in listOf(ConnectionState.DISCONNECTED, ConnectionState.RESUMING, ConnectionState.RECONNECTING)) {
            assertFalse(state.chirpPublisherReady(true, open))
        }
        assertFalse(ConnectionState.CONNECTING.chirpPublisherReady(false, open))
        for (channel in listOf(DataChannel.State.CONNECTING, DataChannel.State.CLOSING, DataChannel.State.CLOSED)) {
            assertFalse(ConnectionState.CONNECTED.chirpPublisherReady(true, channel))
        }
    }

    @Test fun publishBindsTheSenderInsideTheCiphertextAndRoutesToTheRequestedPeers() {
        val body = "room message".encodeToByteArray()
        fun outgoing(identity: String?) = chirpUserDataPacket(identity, sid, DataPacket.Kind.RELIABLE, body, topic, recipients)
        assertNull(outgoing(null))
        assertNull(outgoing(""))
        val packet = requireNotNull(outgoing(sender))
        val inner = EncryptedPacketPayload.parseFrom(requireNotNull(packet.asEncryptedPacketPayload()).toByteArray()).user
        assertEquals(sender, packet.participantIdentity)
        assertEquals(sid, packet.participantSid)
        assertEquals(recipients, packet.destinationIdentitiesList)
        assertEquals(packet.participantIdentity, inner.participantIdentity)
        assertEquals(topic, inner.topic)
        assertArrayEquals(body, inner.payload.toByteArray())
    }

    @Test fun receiveRequiresTheEncryptedUserIdentityToMatchTheDecryptionIdentity() {
        // Apple and Windows put the sender identity, topic and payload in the encrypted user packet.
        val user = UserPacket.newBuilder().setParticipantIdentity(sender).setTopic(topic)
            .setPayload(ByteString.copyFromUtf8("message")).build()
        val packet = DataPacket.newBuilder().setParticipantIdentity(sender).setKind(DataPacket.Kind.RELIABLE).setUser(user).build()
        val gcm = Encryption.Type.GCM
        assertEquals(user, packet.chirpEncryptedUser(gcm))
        assertNull(packet.toBuilder().setParticipantIdentity("other").build().chirpEncryptedUser(gcm))
        val sidOnly = packet.toBuilder().setUser(user.toBuilder().clearParticipantIdentity().setParticipantSid(sid))
        assertNull(sidOnly.build().chirpEncryptedUser(gcm))
        assertNull(sidOnly.clearParticipantIdentity().build().chirpEncryptedUser(gcm))
        assertNull(packet.chirpEncryptedUser(Encryption.Type.NONE))
        assertNull(packet.toBuilder().setKind(DataPacket.Kind.LOSSY).build().chirpEncryptedUser(gcm))
    }
}
