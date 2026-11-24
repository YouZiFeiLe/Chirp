package cn.youzifeile.chirp.data

import java.io.IOException
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.produceIn
import kotlinx.coroutines.supervisorScope
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

@Serializable
internal data class Profile(
    val id: String,
    @SerialName("display_name") val name: String,
    @SerialName("profile_revision") val revision: Long,
    @SerialName("avatar_revision") val avatar: String? = null,
) {
    fun validate() {
        verify(memberIDPattern.matches(id) && validName(name) && revision >= 0 &&
            (avatar == null || avatar.matches(Regex("[0-9a-f]{64}"))))
    }
}

@Serializable
internal data class DirectoryMember(
    val id: String,
    @SerialName("display_name") val name: String,
)

@Serializable
internal data class RoomInfo(
    @SerialName("room_id") val id: String,
    @SerialName("display_name") val name: String,
    @SerialName("password_required") val passwordRequired: Boolean,
    @SerialName("is_default") val isDefault: Boolean,
    @SerialName("key_protocol") val keyProtocol: String,
    @SerialName("max_participants") val maxParticipants: Int,
    @SerialName("media_status") val mediaStatus: String,
    val participants: List<DirectoryMember>?,
    val description: String? = null,
)

@Serializable
internal data class Directory(
    @SerialName("server_id") val serverID: String,
    val revision: ULong,
    val rooms: List<RoomInfo>,
    val members: List<Profile>,
    val fresh: Boolean = true,
) {
    companion object {
        fun loading(defaultRoom: String) = Directory("", 0UL,
            listOf(RoomInfo(defaultRoom, "", false, true, GROUP_PROTOCOL, 0, "loading", null)), emptyList(), fresh = false)
    }
}

internal data class MediaAccess(val token: String, val deadline: Long)
internal data class Admission(
    val room: RoomInfo,
    val entryID: String,
    val identity: String,
    val deadline: Long,
    val signaling: String,
    val access: MediaAccess,
)

internal class SessionRepository(
    val connection: ServerConnection,
    val login: Login,
    val http: ChirpHttp,
) {
    fun api(vararg path: String): HttpUrl = connection.api.path("v1", *path)
    lateinit var accountIdentity: AccountIdentity
    private var lastJoinSequence = 0L

    @Synchronized internal fun reserveJoinSequence(serverSequence: Long): Long {
        val previous = maxOf(serverSequence, lastJoinSequence)
        verify(previous < Long.MAX_VALUE, "JOIN_SEQUENCE_EXHAUSTED")
        return (previous + 1).also { lastJoinSequence = it }
    }

    fun HttpUrl.authorized(): Request.Builder = request(login.credential)

    fun followDirectory(): Flow<Directory?> = channelFlow {
        var previous: Directory? = null
        var backoff = 500L
        suspend fun snapshot(server: String? = null, revision: ULong = 0UL) {
            val next = readDirectory()
            val current = previous
            verify((server == null || next.serverID == server) && next.revision >= revision &&
                (current == null || next.serverID != current.serverID || next.revision >= current.revision))
            previous = next
            send(next)
        }
        while (true) {
            try {
                supervisorScope {
                    val request = api("events").authorized().header("Accept", "text/event-stream").build()
                    val events = http.events(request, operation = LogEvent.directoryEvents).produceIn(this)
                    try {
                        // Buffer hints during the full read, including on reconnect.
                        snapshot()
                        for (event in events) {
                            when (event.name) {
                                "revoked" -> throw ChirpException("SESSION_EXPIRED", 401)
                                "state" -> {
                                    val hint = parseObject(event.data.encodeToByteArray())
                                    val server = hint.text("server_id")
                                    val revision = hint.unsigned("revision")
                                    verify(server.matches(Regex("[a-f0-9]{48}")) && revision > 0UL)
                                    backoff = 500L
                                    val current = previous
                                    if (current == null || server != current.serverID || revision > current.revision) {
                                        snapshot(server, revision)
                                    }
                                }
                                else -> throw ChirpException("SERVER_UNAVAILABLE", 503)
                            }
                        }
                    } finally {
                        events.cancel()
                    }
                }
            } catch (e: IOException) {
                if (e is ChirpException && e.sessionFailure != null) throw e
                if (nowSeconds() >= login.expiresAt) throw ChirpException("SESSION_EXPIRED", 401)
            }
            previous = previous?.copy(fresh = false)
            send(previous)
            delay(backoff)
            backoff = (backoff * 2).coerceAtMost(5_000)
        }
    }

    private suspend fun readDirectory(): Directory {
        val (_, value) = http.json(api("state").authorized().build(), limit = 2L * 1024 * 1024, operation = LogEvent.directorySnapshot)
        val directory = try {
            wireJson.decodeFromJsonElement(Directory.serializer(), value)
        } catch (_: IllegalArgumentException) {
            throw ChirpException("INVALID_RESPONSE")
        }
        verify(directory.serverID.matches(Regex("[a-f0-9]{48}")) && directory.revision > 0UL &&
            directory.rooms.firstOrNull()?.id == connection.defaultRoom && directory.rooms.first().isDefault &&
            directory.rooms.map { it.id }.toSet().size == directory.rooms.size &&
            directory.members.map { it.id }.toSet().size == directory.members.size)
        directory.members.forEach(Profile::validate)
        directory.rooms.forEach { room ->
            verify(roomIDPattern.matches(room.id) && validName(room.name) &&
                room.isDefault == (room.id == connection.defaultRoom) && room.keyProtocol == GROUP_PROTOCOL &&
                room.maxParticipants == 0)
            val participants = room.participants
            when (room.mediaStatus) {
                "available" -> verify(participants != null &&
                    participants.map { it.id }.toSet().size == participants.size &&
                    participants.all { entryIdentityPattern.matches(it.id) && validName(it.name) })
                "unavailable" -> verify(participants == null)
                else -> throw ChirpException("INVALID_RESPONSE")
            }
        }
        return directory.copy(fresh = true)
    }

    suspend fun awaitSessionFailure(): String {
        fun remainingMillis() = login.expiresAt.coerceAtMost(Long.MAX_VALUE / 1000) * 1000 - System.currentTimeMillis()
        while (remainingMillis() > 0) {
            try {
                kotlinx.coroutines.withTimeoutOrNull(remainingMillis()) { validateLogin() } ?: break
            } catch (e: IOException) {
                if (e is ChirpException) e.sessionFailure?.let { return it }
            }
            delay(remainingMillis().coerceIn(0, 3_000))
        }
        return "SESSION_EXPIRED"
    }

    suspend fun validateLogin(): Long {
        val (_, state) = http.json(api("session").authorized().build(), timeout = 5_000, operation = LogEvent.validateSession)
        val sequence = state.long("join_sequence")
        verify(state.text("participant_identity") == login.identity && state.long("expires_at") == login.expiresAt &&
            sequence in 0 until Long.MAX_VALUE)
        return sequence
    }

    suspend fun join(room: RoomInfo, password: String): Admission {
        verify(roomIDPattern.matches(room.id) && password.encodeToByteArray().size <= 512, "ROOM_PASSWORD_INVALID")
        val account = accountIdentity
        account.local.validate()
        verify(login.device == account.local.device, "DEVICE_IDENTITY_REQUIRED")
        account.refresh(force = false)
        fun checkDevice() = verify(account.active(login.memberID, account.local.device), "AUTHORIZATION_STALE")
        checkDevice()
        val config = connection.group.path("rooms", room.id, "config")
        val policy = http.json(config.authorized().build(), timeout = 3_000, operation = LogEvent.groupConfig).second
        verify(policy.text("room_id") == room.id && policy.text("protocol") == GROUP_PROTOCOL &&
            policy.obj("identity_policy") == cn.youzifeile.chirp.media.MutualRoom(connection.passkeyOrigin.identityOrigin, room.id).wire,
            "IDENTITY_INVALID")
        // The profile response is bound to login.memberID before a previous room can be replaced.
        profile()
        val sequence = reserveJoinSequence(validateLogin())
        val preflightBody = buildJsonObject {
            put("join_sequence", sequence)
            if (password.isNotEmpty()) put("password", password)
        }
        verify(preflightBody.toString().encodeToByteArray().size <= 1024, "ROOM_PASSWORD_INVALID")
        val (_, preflight) = http.json(
            api("rooms", room.id, "preflight").authorized().jsonPost(preflightBody).build(), timeout = 7_000, operation = LogEvent.preflight)
        val proof = preflight.text("preflight_proof")
        val expires = preflight.long("expires_at")
        verify(preflight.text("room_id") == room.id && preflight.long("join_sequence") == sequence &&
            expires in (nowSeconds() + 1)..login.expiresAt && proof.length <= 2048 &&
            proof.matches(Regex("[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]{43}")))
        val body = buildJsonObject { put("join_sequence", sequence); put("preflight_proof", proof) }
        val request = api("rooms", room.id, "join").authorized().jsonPost(body).build()
        checkDevice()
        val admission = kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) {
            commitJoin(room, sequence, expires, request)
        }
        try {
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            return admission
        } catch (e: CancellationException) {
            kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) { runCatching { leave(admission) } }
            throw e
        }
    }

    private suspend fun commitJoin(room: RoomInfo, sequence: Long, expires: Long, request: Request): Admission {
        for (attempt in 0..1) {
            val joined = try {
                http.json(request, timeout = 7_000, operation = LogEvent.admit).second
            } catch (e: IOException) {
                if (e is ChirpException && (e.status in 400..499 && e.status != 408 || e.code == "MEDIA_SERVICE_UNAVAILABLE")) throw e
                if (attempt == 1 || nowSeconds() >= expires) throw ChirpException("ROOM_JOIN_OUTCOME_UNKNOWN")
                continue
            }
            val entry = joined.text("entry_id")
            val identity = joined.text("participant_identity")
            verify(joined.text("room_id") == room.id && joined.long("join_sequence") == sequence &&
                entryIDPattern.matches(entry) && identity == "${login.identity}.$entry")
            try {
                val deadline = joined.long("admission_expires_at")
                verify(deadline in (nowSeconds() + 1)..login.expiresAt && joined.text("key_protocol") == GROUP_PROTOCOL &&
                    joined.text("media_transport") == "udp" && joined.bool("e2ee_required"))
                return Admission(room, entry, identity, deadline, connection.signaling(joined.text("livekit_url")), mediaAccess(joined))
            } catch (e: Exception) {
                // The response already identified our committed entry, even if its media data is unusable.
                runCatching { releaseEntry(room.id, entry) }
                throw e
            }
        }
        throw ChirpException("ROOM_JOIN_OUTCOME_UNKNOWN")
    }

    suspend fun refreshMedia(admission: Admission): MediaAccess {
        val (_, value) = http.json(entryAction(admission, "media-token"), timeout = 7_000, operation = LogEvent.refreshMedia)
        verify(value.text("room_id") == admission.room.id && value.text("entry_id") == admission.entryID &&
            value.text("participant_identity") == admission.identity)
        return mediaAccess(value)
    }

    suspend fun leave(admission: Admission) {
        releaseEntry(admission.room.id, admission.entryID)
    }

    private suspend fun releaseEntry(roomID: String, entryID: String) {
        val body = buildJsonObject { put("entry_id", entryID) }
        http.json(api("rooms", roomID, "leave").authorized().jsonPost(body).build(), setOf(204), timeout = 5_000, operation = LogEvent.leaveRoom)
    }

    suspend fun logout() {
        http.json(api("logout").authorized().post(ByteArray(0).toRequestBody()).build(), setOf(204), timeout = 5_000, operation = LogEvent.endSession)
    }

    suspend fun profile(): Profile = parseProfile(http.json(api("me").authorized().build(), operation = LogEvent.getProfile).second)

    suspend fun rename(name: String): Profile = LogEvent.renameProfile.measure(started = true) {
        verify(validName(name), "INVALID_DISPLAY_NAME")
        val body = buildJsonObject { put("display_name", name) }
        return@measure parseProfile(http.json(api("me").authorized().patch(body.jsonBody()).build(), operation = LogEvent.updateProfile).second)
    }

    suspend fun avatar(profile: Profile): ByteArray? {
        val revision = profile.avatar ?: return null
        profile.validate()
        val request = api("members", profile.id, "avatar", revision).authorized().header("Accept", "image/png").build()
        val data = http.binary(request, 4_999_999, contentType = "image/png", operation = LogEvent.getAvatar)
        verify(sha256(data).toHexString() == revision, "AVATAR_INVALID")
        return data
    }

    suspend fun updateAvatar(jpeg: ByteArray?): Profile = (if (jpeg == null) LogEvent.removeAvatar else LogEvent.changeAvatar).measure(started = true) {
        val builder = api("me", "avatar").authorized()
        val mime = if (jpeg?.firstOrNull() == 0x89.toByte()) "image/png" else "image/jpeg"
        val request = if (jpeg == null) builder.delete() else builder.put(jpeg.toRequestBody(mime.toMediaType()))
        return@measure parseProfile(http.json(request.build(), operation = LogEvent.updateAvatar).second)
    }

    private fun parseProfile(value: kotlinx.serialization.json.JsonObject): Profile {
        val profile = wireJson.decodeFromJsonElement(Profile.serializer(), value)
        profile.validate()
        verify(profile.id == login.memberID)
        return profile
    }

    private fun entryAction(admission: Admission, action: String): Request =
        api("rooms", admission.room.id, action).authorized()
            .jsonPost(buildJsonObject { put("entry_id", admission.entryID) }).build()

    private fun mediaAccess(value: kotlinx.serialization.json.JsonObject): MediaAccess {
        val token = value.text("token")
        val deadline = try { Instant.parse(value.text("expires_at")).epochSecond }
        catch (_: Exception) { throw ChirpException("INVALID_RESPONSE") }
        verify(deadline > nowSeconds() && token.length <= 8192 &&
            token.matches(Regex("[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+")))
        return MediaAccess(token, deadline)
    }
}
