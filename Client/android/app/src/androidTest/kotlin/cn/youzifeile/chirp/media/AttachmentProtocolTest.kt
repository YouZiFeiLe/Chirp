package cn.youzifeile.chirp.media

import android.content.Context
import android.content.ContextWrapper
import androidx.core.content.FileProvider
import androidx.test.platform.app.InstrumentationRegistry
import cn.youzifeile.chirp.data.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.UUID

class AttachmentProtocolTest {
    @Test fun uploadResumeDownloadPauseAndVerifiedPrefixWorkAgainstTheRealServer() {
        val instrument = InstrumentationRegistry.getInstrumentation()
        val filename = InstrumentationRegistry.getArguments().getString("attachment_fixture")
        assumeTrue("Run scripts/test-android-protocol.py for the isolated Go fixture", filename != null)
        val context = instrument.targetContext
        val fixture = parseObject(File(context.getExternalFilesDir(null), filename!!).readBytes())
        val origin = fixture.text("url").toHttpUrl()
        val clients = (fixture["clients"] as JsonArray).map { it as JsonObject }
        val http = ChirpHttp()
        val connection = ServerConnection(origin, origin, origin, null, origin, origin, origin, origin, "public", null)
        val room = RoomInfo(clients[0].text("room_id"), "Fixture", false, true, GROUP_PROTOCOL, 0, "available", emptyList())
        fun admission(client: JsonObject) = Admission(room, client.text("entry_id"), client.text("identity"), Long.MAX_VALUE / 1000,
            "wss://unused.example", MediaAccess("unused", Long.MAX_VALUE / 1000))
        fun session(client: JsonObject) = SessionRepository(connection,
            Login(client.text("credential"), client.text("identity").substringBeforeLast('.'), "Fixture", Long.MAX_VALUE / 1000), http)
        val recipient = clients.last()
        val first = admission(clients[0]); val second = admission(recipient)
        val root = File(context.cacheDir, "android-protocol/${UUID.randomUUID()}").apply { mkdirs() }
        val source = File(root, "source.bin").apply { outputStream().use { out -> repeat(3) { out.write(ByteArray(NETWORK_CHUNK) { (it % 251).toByte() }) } } }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.test-files", source)
        runBlocking(Dispatchers.Main) {
            val jobs = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val senderAccess = FakeAccess(first, listOf(second.identity))
            val receiverAccess = FakeAccess(second, listOf(first.identity))
            val lease = jobs.launch { while (isActive) { senderAccess.grant(); receiverAccess.grant(); delay(500) } }
            var sent = emptyMap<String, TransferState>(); var received = emptyMap<String, TransferState>()
            val sender = RoomAttachments.open(CacheContext(context, File(root, "sender")), session(clients[0]), first, jobs) { sent = it }
            val receiver = RoomAttachments.open(CacheContext(context, File(root, "receiver")), session(recipient), second, jobs) { received = it }
            try {
                sender.setMedia(senderAccess); receiver.setMedia(receiverAccess)
                receiver.bandwidth.policy = AttachmentPolicy.Constrained
                delay(500)
                var descriptor: AttachmentDescriptor? = null
                try {
                    sender.send(uri, senderAccess) { value ->
                        descriptor = value
                        assertTrue(receiver.accept(value))
                        val fault = buildJsonObject {
                            put("method", "PUT"); put("path", "/v1/rooms/${room.id}/attachments/${value.info.id}/chunks/1")
                            put("kind", "unavailable"); put("remaining", 4)
                        }
                        http.json(Request.Builder().url(origin.newBuilder().addPathSegments("test/fault").build()).jsonPost(fault).build(), setOf(204))
                    }
                    fail("The injected outage should interrupt upload")
                } catch (_: java.io.IOException) { }
                val info = requireNotNull(descriptor).info
                assertEquals(TransferPhase.Retryable, sent[info.id]?.phase)
                // Explicit download while the sender is paused must retain the key and wait for completion.
                receiver.retry(info.id)
                withTimeout(6000) { while (received[info.id]?.phase != TransferPhase.AwaitingUpload) delay(25) }
                receiver.pauseDownload(info.id)
                withTimeout(3000) { while (received[info.id]?.phase != TransferPhase.Paused) delay(25) }
                delay(100)
                receiver.retry(info.id)
                withTimeout(6000) { while (received[info.id]?.phase != TransferPhase.AwaitingUpload) delay(25) }
                sender.retry(info.id)
                withTimeout(12000) { while (sent[info.id]?.phase != TransferPhase.Available) delay(25) }
                withTimeout(8000) { while (received[info.id]?.phase != TransferPhase.Receiving || (received[info.id]?.progress ?: 0) == 0) delay(25) }
                receiver.pauseDownload(info.id)
                delay(300)
                assertEquals(TransferPhase.Paused, received[info.id]?.phase)
                receiver.retry(info.id)
                withTimeout(20000) { while (received[info.id]?.phase != TransferPhase.Available) delay(25) }
                val destination = File(root, "export.bin").apply { createNewFile() }
                receiver.export(info.id, FileProvider.getUriForFile(context, "${context.packageName}.test-files", destination))
                assertArrayEquals(source.readBytes(), destination.readBytes())
                val (_, requestCounts) = http.json(Request.Builder().url(origin.newBuilder().addPathSegments("test/requests").build()).build())
                val base = "/v1/rooms/${room.id}/attachments/${info.id}/chunks/0"
                assertEquals(1, (requestCounts["PUT $base"] as JsonArray).size)
                assertEquals(1, (requestCounts["GET $base"] as JsonArray).size)

                // Cancel during a paced upload, confirm the real server result,
                // and make sure retry cannot resurrect a cancelled file.
                sender.bandwidth.policy = AttachmentPolicy.Constrained
                var cancelled: AttachmentInfo? = null
                val upload = jobs.launch {
                    try { sender.send(uri, senderAccess) { value -> cancelled = value.info; receiver.accept(value) } }
                    catch (_: java.io.IOException) { }
                }
                withTimeout(6000) { while (cancelled == null || (sent[cancelled?.id]?.progress ?: 0) == 0) delay(25) }
                val cancelledInfo = requireNotNull(cancelled)
                sender.cancelUpload(cancelledInfo.id)
                withTimeout(6000) { while (sent[cancelledInfo.id]?.phase != TransferPhase.Cancelled) delay(25) }
                upload.join()
                sender.retry(cancelledInfo.id)
                assertEquals(TransferPhase.Cancelled, sent[cancelledInfo.id]?.phase)

                // A failure before publication keeps a sealed, unpublished file
                // retryable without re-reading or re-encrypting the source.
                sender.bandwidth.policy = AttachmentPolicy.Normal
                receiver.bandwidth.policy = AttachmentPolicy.Normal
                val reserveFault = buildJsonObject {
                    put("method", "POST"); put("path", "/v1/rooms/${room.id}/attachments")
                    put("kind", "unavailable"); put("remaining", 4)
                }
                http.json(Request.Builder().url(origin.newBuilder().addPathSegments("test/fault").build()).jsonPost(reserveFault).build(), setOf(204))
                var publishedAfterRetry: AttachmentInfo? = null
                try {
                    sender.send(uri, senderAccess) { value -> publishedAfterRetry = value.info; assertTrue(receiver.accept(value)) }
                    fail("The injected reservation outage should interrupt publication")
                } catch (_: java.io.IOException) { }
                assertNull(publishedAfterRetry)
                val unpublished = sender.unpublished.single()
                assertEquals(TransferPhase.Retryable, sent[unpublished.id]?.phase)
                sender.retry(unpublished.id)
                withTimeout(12000) { while (sent[unpublished.id]?.phase != TransferPhase.Available || received[unpublished.id]?.phase != TransferPhase.Available) delay(25) }
                assertEquals(unpublished.id, publishedAfterRetry?.id)
                assertTrue(sender.unpublished.isEmpty())
                withTimeout(8000) { while (received[info.id]?.remote != "delivered") delay(25) }
                assertEquals(TransferPhase.Available, received[info.id]?.phase)
                http.json(Request.Builder().url(origin.newBuilder().addPathSegments("test/fault").build()).jsonPost(reserveFault).build(), setOf(204))
                var changedPublications = 0
                try { sender.send(uri, senderAccess) { changedPublications++ }; fail("Expected interrupted reservation") }
                catch (_: java.io.IOException) { }
                val oldID = sender.unpublished.single().id
                val otherAudience = FakeAccess(first, emptyList()).apply { grant() }
                sender.setMedia(otherAudience)
                sender.retry(oldID)
                withTimeout(6000) { while (sent[oldID]?.phase != TransferPhase.Cancelled) delay(25) }
                assertEquals(0, changedPublications)
                sender.setMedia(senderAccess)

                sender.bandwidth.policy = AttachmentPolicy.Paused
                val pendingID = CompletableDeferred<AttachmentInfo>()
                val uploading = jobs.async {
                    sender.send(uri, senderAccess) { value -> pendingID.complete(value.info) }
                }
                val remoteInfo = withTimeout(5000) { pendingID.await() }
                sender.revoke()
                sender.close()
                val stopped = runCatching { uploading.await() }.exceptionOrNull()
                assertTrue("The revoked upload must stop before another chunk is sent",
                    stopped is CancellationException || (stopped as? ChirpException)?.code in setOf("GROUP_LEASE_LOST", "ATTACHMENT_INVALID"))
                val cancelledRemote = AttachmentTransport(session(clients[0]), first).status(remoteInfo) {}
                assertEquals("cancelled", cancelledRemote.state)

                session(recipient).leave(second)
                withTimeout(6000) { while (!receiver.authorizationEnded || received.isNotEmpty()) delay(25) }
                val expired = runCatching {
                    receiver.export(info.id, FileProvider.getUriForFile(context, "${context.packageName}.test-files", destination))
                }.exceptionOrNull()
                assertTrue(expired is ChirpException)
                assertFalse(receiver.accept(requireNotNull(descriptor)))
                receiver.close()
                assertTrue(File(root, "receiver/chirp-attachments").listFiles().isNullOrEmpty())
                assertArrayEquals(source.readBytes(), destination.readBytes())
            } finally {
                sender.close(); receiver.close(); lease.cancelAndJoin(); jobs.cancel(); root.deleteRecursively()
            }
        }
    }

    private class CacheContext(base: Context, private val directory: File) : ContextWrapper(base) {
        override fun getCacheDir(): File = directory.apply { mkdirs() }
    }
    private class FakeAccess(entry: Admission, override val recipients: List<String>) : AttachmentAccess {
        override val gate = MediaGate("${entry.room.id}/fixture/session/1")
        fun grant() { gate.grant(MediaPermit(gate.groupID, System.currentTimeMillis() + 3000, android.os.SystemClock.elapsedRealtime() + 3000)) }
    }
}
