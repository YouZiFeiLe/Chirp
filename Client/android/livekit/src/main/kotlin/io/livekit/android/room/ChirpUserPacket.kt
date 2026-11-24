package io.livekit.android.room

import com.google.protobuf.ByteString
import livekit.LivekitModels.DataPacket
import livekit.LivekitModels.Encryption
import livekit.LivekitModels.UserPacket
import livekit.org.webrtc.DataChannel

internal fun ConnectionState.chirpPublisherReady(signalConnected: Boolean, channel: DataChannel.State): Boolean =
    // The primary subscriber can still be connecting when the publisher's data channel is already open.
    (this == ConnectionState.CONNECTING || this == ConnectionState.CONNECTED) &&
        signalConnected && channel == DataChannel.State.OPEN

internal fun chirpUserDataPacket(
    identity: String?,
    sid: String,
    kind: DataPacket.Kind,
    data: ByteArray,
    topic: String?,
    destinations: List<String>,
): DataPacket? {
    if (identity.isNullOrEmpty()) return null
    val user = UserPacket.newBuilder().setParticipantIdentity(identity).setPayload(ByteString.copyFrom(data))
    if (topic != null) user.setTopic(topic)
    // The SFU routes the outer packet. Peers also verify the identity inside the ciphertext.
    return DataPacket.newBuilder()
        .setKind(kind)
        .setParticipantIdentity(identity)
        .setParticipantSid(sid)
        .addAllDestinationIdentities(destinations)
        .setUser(user)
        .build()
}

internal fun DataPacket.chirpEncryptedUser(encryptionType: Encryption.Type): UserPacket? {
    if (kind != DataPacket.Kind.RELIABLE || encryptionType != Encryption.Type.GCM) return null
    return user.takeIf { participantIdentity.isNotEmpty() && it.participantIdentity == participantIdentity }
}
