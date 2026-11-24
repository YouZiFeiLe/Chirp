package cn.youzifeile.chirp.data

import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class AttachmentRateLimitTest {
    @Test fun reserveHonorsRetryAfterAndStopsWhenTheDelayExceedsItsRequestBudget() = runBlocking {
        val times = java.util.concurrent.CopyOnWriteArrayList<Long>()
        val http = ChirpHttp(OkHttpClient.Builder().addInterceptor { chain ->
            times.add(System.nanoTime())
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(429)
                .message("Too Many Requests").header("Retry-After", if (times.size == 1) "1" else "1000")
                .body("""{"error":{"code":"ATTACHMENT_BUSY"}}""".toResponseBody()).build()
        })
        val origin = "https://fixture.example".toHttpUrl()
        val session = SessionRepository(ServerConnection(origin, origin, origin, null, origin, origin, origin, origin, "room", null),
            Login("credential", "identity", "test", 10000), http)
        val room = RoomInfo("room", "Room", false, false, GROUP_PROTOCOL, 0, "available", emptyList())
        val admission = Admission(room, "entry", "self", 10000, "wss://fixture.example", MediaAccess("", 10000))
        val info = AttachmentInfo(id = "a".repeat(32), roomID = room.id, sender = admission.identity, name = "test",
            mimeType = "application/octet-stream", size = 4, digest = "0".repeat(64))
        val result = runCatching { AttachmentTransport(session, admission).reserve(info, emptyList()) {} }.exceptionOrNull()
        assertTrue(result is ChirpException && result.status == 429 && result.retryAfterSeconds == 1000L)
        assertEquals(2, times.size)
        assertTrue((times.last() - times.first()) / 1_000_000 >= 990)
    }
}
