package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.LogEvent
import cn.youzifeile.chirp.data.AttachmentDescriptor
import cn.youzifeile.chirp.data.AttachmentInfo
import cn.youzifeile.chirp.data.Friend
import cn.youzifeile.chirp.data.verify
import cn.youzifeile.chirp.data.wireJson
import java.util.UUID
import kotlinx.serialization.Serializable

internal const val CHAT_TOPIC = "chirp.room-chat.v1"
internal const val MAX_CHAT_TEXT = 4096
private const val MAX_PACKET = 12 * 1024
private val chatID = Regex("[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}")

@Serializable
internal data class ChatPacket(
    val version: Int,
    val id: String,
    val groupID: String,
    val sender: String,
    val sequence: ULong,
    val text: String,
    val attachment: AttachmentDescriptor? = null,
)

internal enum class Delivery { Sending, Sent, Failed, Received }

internal data class ChatMessage(
    val id: String,
    val name: String,
    val text: String,
    val own: Boolean,
    val time: Long = System.currentTimeMillis(),
    val delivery: Delivery = Delivery.Received,
    val attachment: AttachmentInfo? = null,
)

internal fun validChatText(text: String): Boolean =
    text.isNotBlank() && text.encodeToByteArray().size <= MAX_CHAT_TEXT &&
        text.none { it.isISOControl() && it != '\n' && it != '\t' }

internal fun roomDisplayName(identity: String, root: String?, friends: List<Friend>,
    profiles: Map<String, String>, fallback: String): String {
    val accountID = identity.substringBefore('.')
    return friends.firstOrNull { it.id == accountID && it.root == root }?.name ?: profiles[accountID] ?: fallback
}

internal class RoomChat(private val identity: String,
    private val displayName: (String, String) -> String = { _, fallback -> fallback }) {
    private var sequence = 0UL
    private val seen = mutableMapOf<String, ULong>()
    private val history = ArrayDeque<ChatMessage>()
    val messages: List<ChatMessage> get() = history.toList()

    fun install(media: RoomMedia) {
        seen.keys.retainAll(media.roster.keys)
    }

    fun prepare(media: RoomMedia, text: String, descriptor: AttachmentDescriptor? = null): Pair<String, ByteArray> {
        verify(if (descriptor == null) validChatText(text) else text.isEmpty() &&
            descriptor.info.sender == identity && descriptor.info.roomID == media.group.position.room, "INVALID_CHAT_TEXT")
        verify(sequence < ULong.MAX_VALUE && media.gate.remaining() > 0, "CHAT_NOT_READY")
        val id = UUID.randomUUID().toString()
        val packet = ChatPacket(if (descriptor == null) 1 else 2, id, media.gate.groupID, identity, ++sequence, text, descriptor)
        val bytes = wireJson.encodeToString(ChatPacket.serializer(), packet).encodeToByteArray()
        verify(bytes.size <= MAX_PACKET, "INVALID_CHAT_TEXT")
        add(ChatMessage(id, displayName(identity, media.roster.getValue(identity)), text, own = true, delivery = Delivery.Sending, attachment = descriptor?.info))
        return id to bytes
    }

    fun finish(id: String, ok: Boolean) {
        val index = history.indexOfFirst { it.own && it.id == id }
        if (index >= 0) history[index] = history[index].copy(delivery = if (ok) Delivery.Sent else Delivery.Failed)
    }

    fun receive(groupID: String, roster: Map<String, String>, sender: String, bytes: ByteArray,
        acceptAttachment: (AttachmentDescriptor) -> Boolean): Boolean {
        if (sender == identity || sender !in roster || bytes.size !in 1..MAX_PACKET) return false
        val packet = runCatching {
            wireJson.decodeFromString<ChatPacket>(bytes.decodeToString(throwOnInvalidSequence = true))
        }.getOrNull() ?: return false
        if (packet.groupID != groupID || packet.sender != sender ||
            !chatID.matches(packet.id) || packet.sequence <= (seen[sender] ?: 0UL)
        ) return false
        val messageID = "$sender:${packet.id.lowercase()}"
        if (history.any { it.id == messageID }) return false
        val descriptor = packet.attachment
        val valid = when (packet.version) {
            1 -> descriptor == null && validChatText(packet.text)
            2 -> packet.text.isEmpty() && descriptor != null && descriptor.info.sender == sender &&
                descriptor.info.roomID == groupID.substringBefore('/') && acceptAttachment(descriptor)
            else -> false
        }
        if (!valid) return false
        (if (descriptor == null) LogEvent.receiveMessage else LogEvent.receiveAttachment).record()
        seen[sender] = packet.sequence
        add(ChatMessage(messageID, displayName(sender, roster.getValue(sender)), packet.text, own = false,
            attachment = descriptor?.info))
        return true
    }

    private fun add(message: ChatMessage) {
        if (history.size == 1000) history.removeFirst()
        history.addLast(message)
    }
}
