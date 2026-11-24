package cn.youzifeile.chirp.media

import android.content.ContextWrapper
import android.graphics.Bitmap
import androidx.test.platform.app.InstrumentationRegistry
import cn.youzifeile.chirp.data.*
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class AttachmentCatalogTest {
    private val sender = "member_" + "m".repeat(16) + ".login_" + "l".repeat(16) + ".entry_" + "a".repeat(32)
    private val room = RoomInfo("friends", "Friends", false, true, GROUP_PROTOCOL, 0, "available", emptyList())

    private class Image(val descriptor: AttachmentDescriptor, val encrypted: ByteArray) {
        val info = descriptor.info

        fun remote(revision: Int, state: String, completed: Boolean = state == "completed") = buildJsonObject {
            put("protocol_version", 3)
            put("room_id", info.roomID)
            put("id", info.id)
            put("ciphertext_size", info.cipherSize)
            put("ciphertext_sha256", info.digest)
            put("chunk_bytes", NETWORK_CHUNK)
            put("uploaded_chunks", if (completed) 1 else 0)
            if (completed) put("chunk_sha256", JsonArray(listOf(JsonPrimitive(info.digest))))
            put("state", state)
            put("revision", revision)
            put("updated_at", 1100)
            put("expires_at", System.currentTimeMillis() / 1000 + 900)
            put("completed_at", if (completed) 1000 else 0)
        }
    }

    private fun image(id: Char): Image {
        val bitmap = Bitmap.createBitmap(3, 3, Bitmap.Config.ARGB_8888)
        val png = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        bitmap.recycle()
        val meta = AttachmentInfo(id = id.toString().repeat(32), roomID = room.id, sender = sender,
            name = "test.png", mimeType = "image/png", size = png.size.toLong(), digest = "0".repeat(64), hasThumbnail = true)
        val key = randomBytes(32)
        val encrypted = ByteArrayOutputStream()
        val info = AttachmentCrypto.encrypt(meta, key, png.inputStream(), encrypted) {}
        val thumb = AttachmentCrypto.thumbnail(info, key, png, true)
        return Image(AttachmentDescriptor(info, base64(key), base64(thumb)), encrypted.toByteArray())
    }

    private fun catalog(revision: Int, vararg files: JsonObject) = buildJsonObject {
        put("room_id", room.id)
        put("server_id", "fixture")
        put("revision", revision)
        put("attachments", JsonArray(files.toList()))
    }

    @Test fun aLateOpenAndCloseFromAnotherAdmissionCannotRemoveTheActiveRoomCache() = runBlocking(Dispatchers.Main) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val sandbox = File(context.cacheDir, "android-protocol/" + UUID.randomUUID()).apply { mkdirs() }
        val cache = object : ContextWrapper(context) { override fun getCacheDir() = sandbox }
        val root = File(sandbox, "chirp-attachments")
        val origin = "https://fixture.example".toHttpUrl()
        val connection = ServerConnection(origin, origin, origin, null, origin, origin, origin, origin, room.id, null)
        val http = ChirpHttp(OkHttpClient.Builder().addInterceptor { chain ->
            val body = if (chain.request().url.pathSegments.last() == "events") "".toResponseBody("text/event-stream".toMediaType())
                else catalog(1).toString().toResponseBody("application/json".toMediaType())
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body).build()
        })
        val session = SessionRepository(connection, Login("test", "receiver", "Receiver", 10000), http)
        val entry = Admission(room, "entry_" + "1".repeat(32), sender, 10000, "wss://fixture.example", MediaAccess("test", 10000))
        val jobs = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val managers = mutableListOf<RoomAttachments>()
        suspend fun open(admission: Admission): File {
            val before = root.listFiles().orEmpty().toSet()
            managers += RoomAttachments.open(cache, session, admission, jobs) {}
            return root.listFiles()!!.single { it !in before }
        }
        try {
            val active = open(entry)
            val cached = File(active, "file").apply { writeBytes(byteArrayOf(1, 2, 3)) }
            val unrelated = File(sandbox, "outside").apply { mkdirs() }
            val retained = File(unrelated, "retained").apply { writeText("retained") }
            java.nio.file.Files.createSymbolicLink(File(root, "unused").toPath(), unrelated.toPath())
            assertEquals(3L, RoomAttachments.cacheSize(cache))
            val delayed = open(entry.copy(entryID = "entry_" + "2".repeat(32)))
            assertTrue(cached.exists())
            managers.last().close()
            assertFalse(delayed.exists())
            RoomAttachments.clearIfIdle(cache) { true }
            assertArrayEquals(byteArrayOf(1, 2, 3), cached.readBytes())
            assertTrue(retained.exists())
            managers.first().close()
            assertEquals(0L, RoomAttachments.cacheSize(cache))
        } finally {
            for (manager in managers) manager.close()
            jobs.cancel()
            sandbox.deleteRecursively()
        }
    }

    @Test fun catalogOrdersSnapshotsReclaimsMissingTransfersAndPreservesVerifiedCachedImages() = runBlocking(Dispatchers.Main) {
        val removed = image('a')
        val waiting = image('b')
        val cached = image('c')
        val complete = cached.remote(4, "completed")
        val snapshot = AtomicReference(catalog(5, removed.remote(3, "reserved"), waiting.remote(10, "reserved"), complete))
        val catalogReads = AtomicInteger()
        val admissionGone = java.util.concurrent.atomic.AtomicBoolean(false)
        val returnReceipt = CountDownLatch(1)
        val http = ChirpHttp(OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            val json = "application/json".toMediaType()
            if (admissionGone.get() && request.url.pathSegments.last() == "attachments") {
                return@addInterceptor Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(404)
                    .message("Not Found").body("""{"error":{"code":"ATTACHMENT_UNAVAILABLE"}}""".toResponseBody(json)).build()
            }
            val body = when (request.url.pathSegments.last()) {
                "attachments" -> snapshot.get().toString().toResponseBody(json).also { catalogReads.incrementAndGet() }
                "events" -> ("event: state\ndata: " + JsonObject(snapshot.get().filterKeys { it != "attachments" }) +
                    "\n\n").toResponseBody("text/event-stream".toMediaType())
                "received" -> {
                    if (!returnReceipt.await(9, TimeUnit.SECONDS)) throw java.io.IOException("Receipt fixture timed out")
                    complete.toString().toResponseBody(json)
                }
                cached.info.id -> complete.toString().toResponseBody(json)
                "0" -> cached.encrypted.toResponseBody("application/octet-stream".toMediaType())
                else -> throw java.io.IOException("Unexpected path " + request.url.encodedPath)
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body).build()
        })
        suspend fun replaceCatalog(next: JsonObject) {
            val prior = catalogReads.get()
            snapshot.set(next)
            // A second request means the previous snapshot was parsed and applied.
            withTimeout(6000) { while (catalogReads.get() < prior + 2) delay(20) }
        }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "android-protocol/" + UUID.randomUUID()).apply { mkdirs() }
        val cache = object : ContextWrapper(context) { override fun getCacheDir() = root }
        val origin = "https://fixture.example".toHttpUrl()
        val connection = ServerConnection(origin, origin, origin, null, origin, origin, origin, origin, "public", null)
        val session = SessionRepository(connection, Login("credential", "receiver", "Receiver", 10000), http)
        val entry = Admission(room, "b".repeat(32), sender.dropLast(32) + "b".repeat(32), 10000,
            "wss://fixture.example", MediaAccess("media", 10000))
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        var states = emptyMap<String, TransferState>()
        val files = RoomAttachments.open(cache, session, entry, scope) { states = it }
        try {
            files.setMedia(object : AttachmentAccess {
                override val gate = MediaGate("fixture", { 0L }, { 0L }).apply { grant(MediaPermit(groupID, 10000, 10000)) }
                override val recipients = listOf(sender)
            })
            listOf(removed, waiting, cached).forEach { assertTrue(files.accept(it.descriptor)) }
            withTimeout(6000) { while (states[cached.info.id]?.phase != TransferPhase.Available) delay(20) }
            assertNotNull(files.thumbnail(removed.info.id))
            assertEquals(3, files.preview(cached.info.id).width)
            val directory = File(root, "chirp-attachments").listFiles()!!.single()
            val partial = File(directory, removed.info.id + ".part").apply { writeBytes(byteArrayOf(1)) }

            replaceCatalog(catalog(4))
            assertEquals(TransferPhase.Waiting, states[removed.info.id]?.phase)
            assertTrue(partial.exists())
            replaceCatalog(catalog(6, waiting.remote(9, "cancelled")))
            assertEquals(TransferPhase.Expired, states[removed.info.id]?.phase)
            assertEquals("reserved", states[waiting.info.id]?.remote)
            assertEquals("removed", states[cached.info.id]?.remote)
            assertEquals(3, files.preview(cached.info.id).width)
            assertTrue(runCatching { files.thumbnail(removed.info.id) }.exceptionOrNull() is ChirpException)
            withTimeout(3000) { while (partial.exists()) delay(20) }
            returnReceipt.countDown()
            replaceCatalog(catalog(5))
            assertEquals("removed", states[cached.info.id]?.remote)

            replaceCatalog(catalog(7, removed.remote(7, "reserved"), waiting.remote(11, "expired"),
                cached.remote(8, "expired", completed = true)))
            assertEquals(TransferPhase.Expired, states[removed.info.id]?.phase)
            assertEquals(TransferPhase.Expired, states[waiting.info.id]?.phase)
            assertEquals(TransferPhase.Available, states[cached.info.id]?.phase)
            assertEquals("expired", states[cached.info.id]?.remote)
            assertEquals(3, files.preview(cached.info.id).width)
            replaceCatalog(catalog(8, waiting.remote(12, "reserved"), complete))
            assertEquals(TransferPhase.Expired, states[waiting.info.id]?.phase)
            assertEquals("expired", states[cached.info.id]?.remote)

            replaceCatalog(catalog(9, cached.remote(9, "expired", completed = false)))
            assertEquals(TransferPhase.Expired, states[cached.info.id]?.phase)
            assertTrue(runCatching { files.preview(cached.info.id) }.exceptionOrNull() is ChirpException)
            withTimeout(3000) { while (File(directory, cached.info.id).exists()) delay(20) }
            val outstanding = image('d')
            assertTrue(files.accept(outstanding.descriptor))
            assertNotNull(files.thumbnail(outstanding.info.id))
            // The Go catalog returns 404 if the entry was revoked while the event stream was offline.
            admissionGone.set(true)
            withTimeout(6000) { while (!files.authorizationEnded) delay(20) }
            assertTrue(states.isEmpty())
            assertTrue(runCatching { files.thumbnail(outstanding.info.id) }.exceptionOrNull() is ChirpException)
        } finally {
            returnReceipt.countDown()
            files.close()
            scope.cancel()
            root.deleteRecursively()
        }
        Unit
    }
}
