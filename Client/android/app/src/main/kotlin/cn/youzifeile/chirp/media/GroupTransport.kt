package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.LogEvent
import cn.youzifeile.chirp.data.Admission
import cn.youzifeile.chirp.data.ChirpException
import cn.youzifeile.chirp.data.GROUP_PROTOCOL
import cn.youzifeile.chirp.data.SessionRepository
import cn.youzifeile.chirp.data.base64Bytes
import cn.youzifeile.chirp.data.bool
import cn.youzifeile.chirp.data.entryIdentityPattern
import cn.youzifeile.chirp.data.int
import cn.youzifeile.chirp.data.jsonPost
import cn.youzifeile.chirp.data.nowSeconds
import cn.youzifeile.chirp.data.parseObject
import cn.youzifeile.chirp.data.path
import cn.youzifeile.chirp.data.sha256
import cn.youzifeile.chirp.data.text
import cn.youzifeile.chirp.data.unsigned
import cn.youzifeile.chirp.data.validName
import cn.youzifeile.chirp.data.verify
import cn.youzifeile.chirp.data.base64
import cn.youzifeile.chirp.data.decode
import cn.youzifeile.chirp.data.digest
import cn.youzifeile.chirp.data.identityOrigin
import cn.youzifeile.chirp.data.obj
import cn.youzifeile.chirp.data.randomBytes
import cn.youzifeile.chirp.data.toWire
import java.util.UUID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.transform
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.Request

internal data class GroupPosition(
    val room: String,
    val server: String,
    val session: String = "",
    val generation: ULong = 0UL,
) {
    val groupID: String get() = "$room/$server/$session/$generation"
}

internal data class GroupMember(val identity: String, val name: String, val publicKey: String, val keyPackage: String,
    val binding: EntryBinding? = null, val offer: JsonObject? = null, val ready: JsonObject? = null)
internal data class GroupStatus(
    val position: GroupPosition,
    val revision: ULong,
    val phase: String,
    val suspended: Boolean,
    val keyEpoch: ULong = 0UL,
    val rotationRevision: ULong = 0UL,
)
internal data class GroupRotation(val epoch: ULong, val phase: String, val members: List<GroupMember>,
    val welcome: String, val confirmation: String) {
    val index: Int get() = (epoch % 2UL).toInt()
}
internal data class GroupSnapshot(
    val status: GroupStatus,
    val leader: String,
    val members: List<GroupMember>,
    val welcome: String,
    val confirmation: String,
    val rotation: GroupRotation? = null,
) {
    val position: GroupPosition get() = status.position
}

internal data class GroupPulse(val status: GroupStatus, val leaseMillis: Int)

internal interface GroupServing {
    val smoothRotation: Boolean
    val trustReady: Flow<Boolean>
    suspend fun approve(state: GroupSnapshot, rotation: GroupRotation? = null): Boolean
    fun contentMillis(members: List<GroupMember>): Long
    suspend fun config(): GroupPosition
    suspend fun snapshot(position: GroupPosition, action: String, fields: JsonObject = JsonObject(emptyMap())): GroupSnapshot
    suspend fun pulse(state: GroupSnapshot, action: String, epoch: ULong = state.status.keyEpoch): GroupPulse
    fun watch(position: GroupPosition): Flow<Pair<ULong, ULong>>
}

internal class GroupTransport(
    private val session: SessionRepository,
    private val admission: Admission,
    private val native: MlsClient,
    private val roomTrust: RoomTrust,
    private val onInformation: (RoomPublicInformation?) -> Unit = {},
) : GroupServing {
    override val trustReady: Flow<Boolean> get() = roomTrust.ready
    override var smoothRotation = false
        private set
    private val publicKey = native.publicKey.also { it.base64Bytes(32) }
    private val groupPart = Regex("[A-Za-z0-9_-]{32}")
    private val base = session.connection.group.path("rooms", admission.room.id, "")
    private val context = MutualRoom(session.connection.passkeyOrigin.identityOrigin, admission.room.id)
    private val account = session.accountIdentity
    private val localBinding = EntryBinding(account.local.device, context.origin, context.room, context.trust, context.hash,
        admission.identity, publicKey, base64(randomBytes(32)), nowSeconds(),
        minOf(nowSeconds() + 20 * 3600, session.login.expiresAt, account.local.device.deadline)).let {
            it.copy(signature = account.local.sign(it.message()))
        }
    private var current: GroupSnapshot? = null
    override suspend fun approve(state: GroupSnapshot, rotation: GroupRotation?): Boolean {
        val members = rotation?.members ?: state.members
        roomTrust.update(members)
        if (roomTrust.remaining(members) <= 0) return false
        val group = state.position.groupID + (rotation?.let { "/key/${it.epoch}" } ?: "")
        native.approve(group, members, account.authorizationHash(members.map { it.requireBinding().device.accountKey }))
        return true
    }
    override fun contentMillis(members: List<GroupMember>): Long = roomTrust.remaining(members)

    override suspend fun config(): GroupPosition = with(session) {
        val (_, value) = http.json(base.path("config").authorized().build(), timeout = 3_000, operation = LogEvent.groupConfig)
        val server = value.text("server_id")
        verify(value.text("room_id") == admission.room.id && value.text("protocol") == GROUP_PROTOCOL &&
            groupPart.matches(server) && value.int("heartbeat_ms") == 2000 &&
            value.int("lease_refresh_ms") == 1000 && value.int("max_lease_ms") == 3000)
        smoothRotation = value["smooth_rotation"] == JsonPrimitive(true)
        verify(value.obj("identity_policy") == context.wire, "IDENTITY_INVALID")
        native.authorize(context)
        GroupPosition(admission.room.id, server)
    }

    override suspend fun snapshot(position: GroupPosition, action: String, fields: JsonObject): GroupSnapshot {
        val started = android.os.SystemClock.elapsedRealtime()
        val (_, value) = session.http.json(request(position, action, fields), limit = 256 * 1024, timeout = 3_000, operation = groupLogEvent(action))
        val status = readStatus(position, value)
        fun members(source: JsonObject, phase: String): List<GroupMember> = (source["members"] as? JsonArray)?.map { element ->
            val member = element as? JsonObject ?: throw ChirpException("INVALID_GROUP")
            GroupMember(member.text("identity"), member.text("name"), member.text("public_key"), member.text("key_package"),
                member.obj("binding").decode<EntryBinding>(), member["offer"] as? JsonObject, member["ready"] as? JsonObject)
                .also {
                    verify(entryIdentityPattern.matches(it.identity) && validName(it.name))
                    it.publicKey.base64Bytes(32)
                    if (it.keyPackage.isNotEmpty()) it.keyPackage.base64Bytes(32, 16_384)
                    else verify(phase != "welcoming")
                }
        } ?: throw ChirpException("INVALID_GROUP")
        val members = members(value, status.phase)
        val leader = value.text("leader")
        val welcome = value.text("welcome")
        val confirmation = value.text("confirmation")
        verify(members.any { it.identity == leader } && members.any { it.identity == admission.identity && it.publicKey == publicKey } &&
            members.map { it.identity }.toSet().size == members.size && members.map { it.publicKey }.toSet().size == members.size)
        if (welcome.isNotEmpty()) welcome.base64Bytes(32, 131_072)
        if (status.phase in setOf("ready", "confirming")) confirmation.base64Bytes(32)
        else verify(confirmation.isEmpty())
        val rotation = (value["rotation"] as? JsonObject)?.let { candidate ->
            val phase = candidate.text("phase")
            val epoch = candidate.unsigned("epoch")
            val peers = members(candidate, phase)
            val stagedWelcome = candidate.text("welcome")
            val stagedConfirmation = candidate.text("confirmation")
            verify(smoothRotation && epoch > 0UL && phase in setOf("collecting", "welcoming", "confirming", "ready", "switching") &&
                peers.size == members.size && peers.map { it.identity }.toSet().size == peers.size &&
                peers.associate { it.identity to it.publicKey } == members.associate { it.identity to it.publicKey }, "INVALID_GROUP")
            if (stagedWelcome.isNotEmpty()) stagedWelcome.base64Bytes(32, 131_072)
            if (phase in setOf("confirming", "ready", "switching")) stagedConfirmation.base64Bytes(32)
            else verify(stagedConfirmation.isEmpty())
            GroupRotation(epoch, phase, peers, stagedWelcome, stagedConfirmation)
        }
        verify(smoothRotation || status.keyEpoch == 0UL && rotation == null, "INVALID_GROUP")
        verify(value.obj("identity_policy") == context.wire &&
            members.single { it.identity == admission.identity }.binding == localBinding, "IDENTITY_INVALID")
        validateRoster(context, status.position.groupID, 0UL, members, confirmation.takeIf { status.phase == "ready" })
        rotation?.let { r ->
            verify(r.members.associate { it.identity to it.binding } == members.associate { it.identity to it.binding })
            validateRoster(context, "${status.position.groupID}/key/${r.epoch}", r.epoch, r.members,
                r.confirmation.takeIf { r.phase in setOf("ready","switching") })
        }
        return GroupSnapshot(status, leader, members, welcome, confirmation, rotation).also {
            current = it
            onInformation(RoomPublicInformation.read(value, it, started))
        }
    }

    override suspend fun pulse(state: GroupSnapshot, action: String, epoch: ULong): GroupPulse {
        val started = android.os.SystemClock.elapsedRealtime()
        val fields = buildJsonObject {
            if (action == "lease") {
                put("revision", JsonPrimitive(state.status.revision))
                put("confirmation", state.confirmation)
                if (smoothRotation) put("key_epoch", JsonPrimitive(epoch))
            }
        }
        val (_, value) = session.http.json(request(state.position, action, fields), limit = 4096, timeout = 2_500, operation = groupLogEvent(action))
        val duration = value.int("lease_ms")
        verify(duration in 0..3000 && (action == "lease" || duration == 0))
        val status = readStatus(state.position, value)
        if (status == state.status && current?.status == status) onInformation(RoomPublicInformation.read(value,state,started))
        return GroupPulse(status, duration)
    }

    override fun watch(position: GroupPosition): Flow<Pair<ULong, ULong>> =
        session.http.events(request(position, "watch", JsonObject(emptyMap())), operation = LogEvent.groupEvents).transform { event ->
            if (event.name == "revoked") throw ChirpException("GROUP_CHANGED")
            if (event.name == "state") {
                val value = parseObject(event.data.encodeToByteArray())
                val revision = value.unsigned("revision")
                verify(value.text("server_id") == position.server && value.text("room_id") == position.room && revision > 0UL)
                emit(revision to if ("rotation_revision" in value) value.unsigned("rotation_revision") else 0UL)
            }
        }

    private fun readStatus(position: GroupPosition, value: JsonObject): GroupStatus {
        val generation = value.unsigned("generation")
        val revision = value.unsigned("revision")
        val sessionID = value.text("session_id")
        val phase = value.text("phase")
        verify(value.text("protocol") == GROUP_PROTOCOL && value.text("room_id") == position.room &&
            value.text("server_id") == position.server && groupPart.matches(sessionID) &&
            generation > 0UL && revision > 0UL && phase in setOf("collecting", "welcoming", "confirming", "ready"))
        return GroupStatus(position.copy(session = sessionID, generation = generation), revision, phase, value.bool("suspended"),
            if ("key_epoch" in value) value.unsigned("key_epoch") else 0UL,
            if ("rotation_revision" in value) value.unsigned("rotation_revision") else 0UL)
    }

    private fun request(position: GroupPosition, action: String, fields: JsonObject): Request = with(session) {
        val endpoint = if (action == "watch") "events" else "action"
        val value = buildJsonObject {
            put("room_id", position.room)
            put("entry_id", admission.entryID)
            put("server_id", position.server)
            put("session_id", position.session)
            put("generation", JsonPrimitive(position.generation))
            put("operation", action)
            if (action == "join" && smoothRotation) put("smooth_rotation", true)
            if (action == "join") put("binding",localBinding.toWire())
            if (action in setOf("package","ack","rotation_package","rotation_ack")) {
                val state = requireNotNull(current)
                verify(state.position == position)
                val epoch = if ("key_epoch" in fields) fields.unsigned("key_epoch") else 0UL
                val members = if (epoch == 0UL) state.members else requireNotNull(state.rotation).members
                val group = position.groupID + if (epoch == 0UL) "" else "/key/$epoch"
                val ack = action.endsWith("ack")
                val proofValue = if (ack) fields.text("confirmation") else digest(fields.text("key_package").base64Bytes(32,16384))
                put(if (ack) "ready" else "offer", roundProof(ack,group,epoch,context.hash,rosterHash(members),proofValue,native::sign))
            }
            fields.forEach { (key, field) -> put(key, field) }
        }
        val body = value.toString().encodeToByteArray()
        verify(body.size <= 256 * 1024)
        val time = nowSeconds().toString()
        val nonce = UUID.randomUUID().toString()
        val hash = sha256(body).toHexString()
        val proof = "Chirp group request v5\n${admission.identity}\nPOST\n/v1/group/rooms/${position.room}/$endpoint\n$time\n$nonce\n$hash"
        base.path(endpoint).authorized().jsonPost(value)
            .header("Accept", if (action == "watch") "text/event-stream" else "application/json")
            .header("X-Chirp-Time", time).header("X-Chirp-Nonce", nonce).header("X-Chirp-Key", publicKey)
            .header("X-Chirp-Signature", native.sign(proof.encodeToByteArray())).build()
    }
}


private fun groupLogEvent(action: String): LogEvent = when (action) {
    "join" -> LogEvent.groupJoin
    "snapshot" -> LogEvent.groupSnapshot
    "refresh" -> LogEvent.groupRefresh
    "package" -> LogEvent.groupPackage
    "publish" -> LogEvent.groupPublish
    "ack" -> LogEvent.groupAck
    "heartbeat" -> LogEvent.groupHeartbeat
    "lease" -> LogEvent.mediaLease
    "rotation_package" -> LogEvent.rotationPackage
    "rotation_publish" -> LogEvent.rotationPublish
    "rotation_ack" -> LogEvent.rotationAck
    "rotation_activate" -> LogEvent.rotationActivate
    else -> LogEvent.groupAction
}
