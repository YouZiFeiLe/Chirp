package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.ChirpException
import cn.youzifeile.chirp.data.base64
import cn.youzifeile.chirp.data.parseObject
import cn.youzifeile.chirp.data.text
import cn.youzifeile.chirp.data.verify
import cn.youzifeile.chirp.data.toWire
import kotlinx.serialization.json.JsonPrimitive
import java.io.Closeable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal interface MlsClient : Closeable {
    val publicKey: String
    fun sign(bytes: ByteArray): String
    fun keyPackage(): String
    fun clear()
    fun authorize(room: MutualRoom)
    fun approve(group: String, members: List<GroupMember>, authority: String)
    fun stagedKeyPackage(): String
    fun activateStaged(groupID: String)
    fun createStaged(groupID: String, members: List<GroupMember>): JsonObject
    fun joinStaged(groupID: String, members: List<GroupMember>, welcome: String): String
    fun create(group: GroupSnapshot): JsonObject
    fun join(group: GroupSnapshot): String
    fun key(identity: String, staged: Boolean = false): ByteArray
    fun keyLifetimeMillis(staged: Boolean = false): Long
}

internal class MlsNative(identity: String) : MlsClient {
    private var handle = open(identity).also { verify(it != 0L, "MLS_UNAVAILABLE") }

    override val publicKey: String get() = call("identity").text("public_key")
    override fun sign(bytes: ByteArray): String = call("sign") { put("message", base64(bytes)) }.text("signature")
    override fun keyPackage(): String = call("key_package").text("key_package")
    override fun clear() { call("clear") }
    override fun authorize(room: MutualRoom) {
        call("authorize") { put("origin",room.origin); put("room_id",room.room); put("trusted_owner",""); put("policy",room.wire) }
    }
    override fun approve(group: String, members: List<GroupMember>, authority: String) {
        call("approve") { put("group_id",group); put("members",nativeRoster(members)); put("authorization_hash",authority) }
    }
    override fun stagedKeyPackage(): String = call("staged_key_package").text("key_package")
    override fun activateStaged(groupID: String) { call("activate_staged") { put("group_id", groupID) } }
    override fun createStaged(groupID: String, members: List<GroupMember>): JsonObject = call("staged_create") {
        put("key_epoch",JsonPrimitive(groupID.substringAfterLast("/key/").toULong()))
        put("group_id", groupID); put("members", nativeRoster(members))
    }
    override fun joinStaged(groupID: String, members: List<GroupMember>, welcome: String): String = call("staged_join") {
        put("key_epoch",JsonPrimitive(groupID.substringAfterLast("/key/").toULong()))
        put("group_id", groupID); put("members", nativeRoster(members)); put("welcome", welcome)
    }.text("confirmation")

    override fun create(group: GroupSnapshot): JsonObject = call("create") {
        put("group_id", group.position.groupID)
        put("members", nativeRoster(group.members))
    }

    override fun join(group: GroupSnapshot): String = call("join") {
        put("group_id", group.position.groupID)
        put("members", nativeRoster(group.members))
        put("welcome", group.welcome)
    }.text("confirmation")

    @Synchronized
    override fun key(identity: String, staged: Boolean): ByteArray {
        verify(handle != 0L, "MLS_UNAVAILABLE")
        return senderKey(handle, identity, staged) ?: throw ChirpException("MLS_KEY_MISSING")
    }

    override fun keyLifetimeMillis(staged: Boolean): Long {
        val value = call(if (staged) "staged_lifetime" else "lifetime").text("milliseconds").toLongOrNull()
        return value?.takeIf { it in 1..120_000 } ?: throw ChirpException("MEDIA_KEY_REJECTED")
    }

    @Synchronized
    override fun close() {
        if (handle != 0L) {
            close(handle)
            handle = 0
        }
    }

    @Synchronized
    internal fun call(operation: String, fields: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit = {}): JsonObject {
        verify(handle != 0L, "MLS_UNAVAILABLE")
        val input = buildJsonObject { put("operation", operation); fields() }.toString().encodeToByteArray()
        verify(input.size <= 256 * 1024, "MLS_REQUEST_TOO_LARGE")
        val output = try { request(handle, input) ?: throw ChirpException("MLS_FAILED") } finally { input.fill(0) }
        val value = try { parseObject(output) } finally { output.fill(0) }
        verify("error" !in value, "MLS_FAILED")
        return value
    }

    private fun nativeRoster(members: List<GroupMember>) = JsonArray(members.map { member ->
        buildJsonObject {
            put("identity", member.identity)
            put("public_key", member.publicKey)
            put("key_package", member.keyPackage)
            put("binding", member.requireBinding().toWire())
            member.offer?.let { put("offer",it) }
            member.ready?.let { put("ready",it) }
        }
    })

    private external fun open(identity: String): Long
    fun security(action: String, vararg fields: Pair<String, String>): JsonObject = call("security") {
        put("security", buildJsonObject {
            put("action", action)
            fields.forEach { (name, value) -> put(name, value) }
        })
    }

    private external fun request(handle: Long, request: ByteArray): ByteArray?
    private external fun senderKey(handle: Long, identity: String, staged: Boolean): ByteArray?
    private external fun close(handle: Long)

    companion object {
        init { System.loadLibrary("chirp_mls") }
    }
}
