package cn.youzifeile.chirp.data

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.asResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Pipe
import okio.buffer
import org.junit.Assert.*
import org.junit.Test

class DirectoryStreamParityTest {
    @Test fun roomDescriptionsAreOptionalAndVerbatimOnTheWire() {
        val legacy = wireJson.parseToJsonElement("""{
            "room_id":"main","display_name":"Main room","password_required":false,"is_default":true,
            "key_protocol":"$GROUP_PROTOCOL","max_participants":0,"media_status":"available","participants":[]
        }""").jsonObject
        fun decode(fields: JsonObject) = wireJson.decodeFromJsonElement(RoomInfo.serializer(), fields).description

        assertNull(decode(legacy))
        assertNull(decode(JsonObject(legacy + ("description" to JsonNull))))
        for (value in listOf("", " \n ", "一个房间，几个朋友，随时聊聊。", " 🎵\n<朋友> %@ **歌单** ")) {
            assertEquals(value, decode(JsonObject(legacy + ("description" to JsonPrimitive(value)))))
        }
    }

    @Test fun directoryLoadsOnConnectRefreshesOnStateEventsAndKeepsTheLastGoodRevisionWhileStale() = runBlocking {
        val requests = AtomicInteger()
        val eventConnections = AtomicInteger()
        val listening = CountDownLatch(1)
        val firstStream = Pipe(4096)
        val events = firstStream.sink.buffer()
        val room = RoomInfo("main", "Main room", false, true, GROUP_PROTOCOL, 0, "available", emptyList())
        val garden = room.copy(id = "garden", name = "Garden", isDefault = false, description = "Meet in the garden.")
        val updatedDescription = "周五听歌 🎵\n欢迎带上朋友。"
        val serverID = "a".repeat(48)
        val http = ChirpHttp(OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            val body = when (request.url.encodedPath) {
                "/v1/events" -> {
                    listening.countDown()
                    if (eventConnections.incrementAndGet() == 1)
                        firstStream.source.buffer().asResponseBody("text/event-stream".toMediaType())
                    else "".toResponseBody("text/event-stream".toMediaType())
                }
                "/v1/state" -> {
                    if (!listening.await(3, TimeUnit.SECONDS)) throw java.io.IOException("SSE was never opened")
                    val revision = when (requests.incrementAndGet()) { 1 -> 7UL; 2 -> 8UL; 3 -> 4UL; else -> 9UL }
                    val main = when (revision) {
                        8UL -> room.copy(description = updatedDescription)
                        9UL -> room.copy(description = "一个房间，几个朋友，随时聊聊。")
                        else -> room
                    }
                    wireJson.encodeToString(Directory(serverID, revision, listOf(main, garden), emptyList())).toResponseBody("application/json".toMediaType())
                }
                else -> throw java.io.IOException("Unexpected " + request.url)
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).message("OK").code(200).body(body).build()
        })
        val origin = "https://example.test/".toHttpUrl()
        val session = SessionRepository(ServerConnection(origin, origin, origin, null, origin, origin, origin, origin, room.id, null),
            Login("credential", "identity", "Fixture", nowSeconds() + 600), http)
        val output = Channel<Directory>(Channel.UNLIMITED)
        val reader = launch { session.followDirectory().filterNotNull().collect { output.send(it) } }
        try {
            val initial = withTimeout(4000) { output.receive() }
            assertTrue(initial.fresh)
            assertEquals(7UL, initial.revision)
            assertEquals(listOf(room, garden), initial.rooms)
            assertEquals(1, eventConnections.get())
            events.writeUtf8("event: state\ndata: {\"server_id\":\"$serverID\",\"revision\":8}\n\n").flush()
            val refreshed = withTimeout(4000) { output.receive() }
            assertTrue(refreshed.fresh)
            assertEquals(8UL, refreshed.revision)
            assertEquals(listOf(room.copy(description = updatedDescription), garden), refreshed.rooms)
            assertEquals(1, eventConnections.get())
            events.writeUtf8("event: unexpected\ndata: {}\n\n").close()
            withTimeout(6000) {
                var staleCount = 0
                while (true) {
                    val next = output.receive()
                    if (next.fresh) {
                        assertEquals(9UL, next.revision)
                        assertEquals(listOf(room.copy(description = "一个房间，几个朋友，随时聊聊。"), garden), next.rooms)
                        assertTrue(staleCount >= 2)
                        break
                    }
                    assertEquals(refreshed.copy(fresh = false), next)
                    staleCount++
                }
            }
            assertTrue(requests.get() >= 4)
        } finally {
            events.close()
            reader.cancelAndJoin()
        }
    }
}
