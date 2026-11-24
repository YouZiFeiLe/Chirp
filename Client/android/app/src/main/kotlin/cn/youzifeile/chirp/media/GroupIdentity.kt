package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.*
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

internal class MutualRoom(val origin: String, val room: String) {
    val trust = digest(message("Chirp mutual room v5", origin, room))
    private val emptySigner = DeviceIdentity("", emptyList())
    val wire = buildJsonObject {
        put("origin", origin); put("room_id", room); put("trust_id", trust); put("owner_key","")
        put("version",1); put("previous_hash",""); put("members",JsonArray(emptyList()))
        put("revoked_devices",JsonArray(emptyList())); put("not_before",1); put("not_after",253402300799L)
        put("signer",emptySigner.toWire()); put("signature","")
    }
    val hash = signedDigest("Chirp room policy digest v5", message("Chirp room policy v5",
        origin,room,trust,"","1","","0","0","1","253402300799",emptySigner.hash()), "")
}

@Serializable internal data class EntryBinding(val device: DeviceIdentity, val origin: String,
    @SerialName("room_id") val room: String, @SerialName("trust_id") val trust: String,
    @SerialName("policy_hash") val policy: String, val identity: String,
    @SerialName("mls_key") val mls: String, val nonce: String,
    @SerialName("not_before") val start: Long, @SerialName("not_after") val end: Long, val signature: String = "") {
    fun message() = message("Chirp admission binding v5", device.hash(),origin,room,trust,policy,identity,mls,nonce,start.toString(),end.toString())
    fun hash() = signedDigest("Chirp admission binding digest v5",message(),signature)
    fun validate(context: MutualRoom, peer: GroupMember, now: Long) {
        verify(origin == context.origin && room == context.room && trust == context.trust && policy == context.hash &&
            identity == peer.identity && mls == peer.publicKey && start > 0 && start <= now + 60 &&
            end > maxOf(start, now) && end - start <= 20 * 3600, "IDENTITY_INVALID")
        nonce.base64Bytes(32); device.validate(now); verifySignature(device.leaf,signature,message())
    }
}

internal fun GroupMember.requireBinding() = binding ?: throw ChirpException("DEVICE_IDENTITY_REQUIRED")
internal fun rosterHash(members: List<GroupMember>) = digest(message("Chirp roster digest v5", members.size.toString(),
    *members.map { it.requireBinding().hash() }.sorted().toTypedArray()))

internal fun roundProof(ready: Boolean, group: String, epoch: ULong, policy: String, roster: String,
    value: String, sign: (ByteArray) -> String): JsonObject {
    val domain = if (ready) "Chirp epoch ready v5" else "Chirp round offer v5"
    val signature = sign(message(domain, group, epoch.toString(),policy,roster,value))
    return buildJsonObject {
        put("group_id",group); put("key_epoch",JsonPrimitive(epoch)); put("policy_hash",policy); put("roster_hash",roster)
        put(if (ready) "confirmation" else "key_package_hash",value); put("signature",signature)
    }
}

internal fun validateRoster(context: MutualRoom, group: String, epoch: ULong, members: List<GroupMember>, confirmation: String?) {
    val now = nowSeconds()
    val hash = rosterHash(members)
    verify(members.map { it.requireBinding().device.leaf }.distinct().size == members.size)
    for (peer in members) {
        peer.requireBinding().validate(context,peer,now)
        fun check(proof: JsonObject?, ready: Boolean, value: String) {
            verify(proof != null, "IDENTITY_INVALID")
            val signature = requireNotNull(proof).text("signature")
            val expected = roundProof(ready,group,epoch,context.hash,hash,value) { msg ->
                verifySignature(peer.publicKey,signature,msg); signature
            }
            verify(proof == expected, "IDENTITY_INVALID")
        }
        if (peer.keyPackage.isNotEmpty()) check(peer.offer,false,digest(peer.keyPackage.base64Bytes(32,16384)))
        if (confirmation != null) check(peer.ready,true,confirmation)
    }
}
