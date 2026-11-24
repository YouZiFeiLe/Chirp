package cn.youzifeile.chirp.data

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.transform
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

internal fun ChirpException.temporaryAttachmentError() = status == 408 || status == 429 || status in 500..599

internal data class RemoteAttachment(
    val id: String,
    val size: Long,
    val digest: String,
    val state: String,
    val chunks: Int,
    val hashes: List<String>,
    val revision: ULong,
    val completedAt: Long,
    val expiresAt: Long,
) {
    fun verifyInfo(info: AttachmentInfo) {
        verify(id == info.id && size == info.cipherSize && digest == info.digest, "ATTACHMENT_INTEGRITY")
        verify(state in setOf("expired", "delivered", "cancelled") || expiresAt > System.currentTimeMillis() / 1000,
            "ATTACHMENT_EXPIRED")
    }

    fun requireActive() {
        if (state == "cancelled") throw ChirpException("ATTACHMENT_CANCELLED")
        if (state == "expired") throw ChirpException("ATTACHMENT_EXPIRED")
    }

    fun supersedes(previous: RemoteAttachment?): Boolean {
        if (previous == null) return true
        if (revision < previous.revision) return false
        return when (previous.state) {
            "cancelled", "expired", "delivered" -> state == previous.state
            "completed" -> state in setOf("completed", "expired", "delivered")
            else -> true
        }
    }
}

internal data class AttachmentRevision(val server: String, val revision: ULong)
internal data class AttachmentCatalog(val version: AttachmentRevision, val files: Map<String, RemoteAttachment>)

internal class AttachmentTransport(private val session: SessionRepository, private val entry: Admission,
    private val bandwidth: AttachmentBandwidth = AttachmentBandwidth()) {
    private val base = session.api("rooms", entry.room.id, "attachments")
    private val http = session.http

    fun watch(): Flow<AttachmentRevision> = http.events(request("events").header("Accept", "text/event-stream").build(), operation = LogEvent.attachmentEvents).transform { event ->
        when (event.name) {
            "revoked" -> throw ChirpException("ADMISSION_EXPIRED")
            "unavailable" -> throw ChirpException("ATTACHMENT_UNAVAILABLE")
            "state" -> {
                val hint = parseObject(event.data.encodeToByteArray())
                emit(version(hint))
            }
            else -> throw ChirpException("ATTACHMENT_UNAVAILABLE")
        }
    }

    private fun version(value: JsonObject): AttachmentRevision {
        val server = value.text("server_id")
        val revision = value.unsigned("revision")
        verify(value.text("room_id") == entry.room.id && server.isNotBlank() && server.encodeToByteArray().size <= 128 && revision > 0UL)
        return AttachmentRevision(server, revision)
    }

    suspend fun catalog(): AttachmentCatalog {
        val (_, value) = http.json(request().build(), limit = NETWORK_CHUNK.toLong(), operation = LogEvent.attachmentCatalog)
        val version = version(value)
        val entries = (value["attachments"] as? JsonArray)?.map(::remote) ?: throw ChirpException("INVALID_RESPONSE")
        val map = entries.associateBy(RemoteAttachment::id)
        verify(map.size == entries.size && entries.size <= 4096)
        return AttachmentCatalog(version, map)
    }

    suspend fun reserve(info: AttachmentInfo, recipients: List<String>, check: () -> Unit): RemoteAttachment {
        verify(info.sender == entry.identity && recipients.size <= 256 && recipients.all(entryIdentityPattern::matches),
            "ATTACHMENT_INVALID")
        val body = buildJsonObject {
            put("id", info.id)
            put("entry_id", entry.entryID)
            put("ciphertext_size", info.cipherSize)
            put("ciphertext_sha256", info.digest)
            put("recipients", JsonArray(recipients.map(::JsonPrimitive)))
        }
        val response = retry(check) { http.json(request().jsonPost(body).build(), setOf(201), operation = LogEvent.attachmentReserve).second }
        return remote(response).also { it.verifyInfo(info) }
    }

    suspend fun status(info: AttachmentInfo, check: () -> Unit): RemoteAttachment {
        val response = retry(check) { http.json(request(info.id).build(), operation = LogEvent.attachmentStatus).second }
        return remote(response).also {
            it.verifyInfo(info)
            verify(it.hashes.size == it.chunks)
        }
    }

    suspend fun uploadChunk(info: AttachmentInfo, index: Int, bytes: ByteArray, check: () -> Unit) {
        val body = bytes.toRequestBody("application/octet-stream".toMediaType())
        retry(check) {
            bandwidth.acquire(bytes.size, upload = true)
            check()
            http.json(request(info.id, "chunks", index.toString()).put(body).build(), setOf(204), timeout = 30_000, operation = LogEvent.uploadChunk)
        }
    }

    suspend fun downloadChunk(info: AttachmentInfo, index: Int, length: Int, check: () -> Unit): ByteArray =
        retry(check) {
            bandwidth.acquire(length, upload = false)
            check()
            http.binary(request(info.id, "chunks", index.toString()).build(), length.toLong(), timeout = 30_000, operation = LogEvent.downloadChunk)
                .also { verify(it.size == length, "ATTACHMENT_INTEGRITY") }
        }

    suspend fun complete(info: AttachmentInfo, check: () -> Unit): RemoteAttachment {
        val state = action(info, "complete", check)
        verify(state.state in setOf("completed", "delivered"))
        return state
    }

    suspend fun cancel(info: AttachmentInfo): RemoteAttachment {
        val result = http.json(request(info.id, "cancel").post(ByteArray(0).toRequestBody()).build(), timeout = 3_000, operation = LogEvent.attachmentCancel).second
        return remote(result).also { it.verifyInfo(info) }
    }

    suspend fun pause(info: AttachmentInfo) {
        http.json(request(info.id, "pause").post(ByteArray(0).toRequestBody()).build(), timeout = 3_000, operation = LogEvent.attachmentPause)
    }

    suspend fun received(info: AttachmentInfo, check: () -> Unit) =
        action(info, "received", check, buildJsonObject { put("ciphertext_sha256", info.digest) })

    private suspend fun action(info: AttachmentInfo, operation: String, check: () -> Unit,
        body: JsonObject? = null): RemoteAttachment {
        val payload = body?.jsonBody() ?: ByteArray(0).toRequestBody()
        val response = retry(check) {
            http.json(request(info.id, operation).post(payload).build(), timeout = 30_000, operation = if (operation == "complete") LogEvent.attachmentComplete else LogEvent.attachmentReceived).second
        }
        return remote(response).also { it.verifyInfo(info) }
    }

    private fun request(vararg suffix: String): Request.Builder =
        base.path(*suffix).request(session.login.credential).header("X-Chirp-Entry", entry.entryID)

    private fun remote(element: kotlinx.serialization.json.JsonElement): RemoteAttachment {
        val value = element as? JsonObject ?: throw ChirpException("INVALID_RESPONSE")
        val id = value.text("id")
        val digest = value.text("ciphertext_sha256")
        val size = value.long("ciphertext_size")
        val chunks = value.int("uploaded_chunks")
        val state = value.text("state")
        val revision = value.unsigned("revision")
        val completedAt = value.long("completed_at")
        val hashes = (value["chunk_sha256"] as? JsonArray)?.map {
            (it as? JsonPrimitive)?.takeIf { primitive -> primitive.isString }?.content
                ?: throw ChirpException("INVALID_RESPONSE")
        }.orEmpty()
        verify(value.text("room_id") == entry.room.id && value.int("protocol_version") == 3 &&
            value.int("chunk_bytes") == NETWORK_CHUNK && revision > 0UL && completedAt >= 0 &&
            attachmentIDPattern.matches(id) && digestPattern.matches(digest) &&
            size in 16..(MAX_ATTACHMENT + 8192) && chunks in 0..((size + NETWORK_CHUNK - 1) / NETWORK_CHUNK).toInt() &&
            hashes.size <= chunks && hashes.all(digestPattern::matches) &&
            state in setOf("reserved", "uploading", "paused", "completed", "delivered", "cancelled", "expired"))
        val uploaded = state == "completed" || state == "delivered"
        val expiresAt = value.long("expires_at")
        verify(value.long("updated_at") > 0 && expiresAt > 0 &&
            (state != "reserved" || chunks == 0) &&
            (!uploaded || (chunks == ((size + NETWORK_CHUNK - 1) / NETWORK_CHUNK).toInt() && completedAt > 0)) &&
            (completedAt == 0L || uploaded || state == "expired"))
        return RemoteAttachment(id, size, digest, state, chunks, hashes, revision, completedAt, expiresAt)
    }

    private suspend fun <T> retry(check: () -> Unit, operation: suspend () -> T): T {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
        repeat(4) { attempt ->
            check()
            try {
                val result = operation()
                check()
                return result
            } catch (e: IOException) {
                if (attempt == 3 || e is ChirpException && !e.temporaryAttachmentError()) throw e
                val retryAfter = (e as? ChirpException)?.retryAfterSeconds ?: 0
                val wait = maxOf(250L shl attempt, TimeUnit.SECONDS.toMillis(retryAfter))
                if (wait >= TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())) throw e
                delay(wait)
            }
        }
        error("Unreachable")
    }
}
