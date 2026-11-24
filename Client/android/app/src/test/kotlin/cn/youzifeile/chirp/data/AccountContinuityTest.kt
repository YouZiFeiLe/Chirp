package cn.youzifeile.chirp.data

import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class AccountContinuityTest {
    private fun session(expires: Long, status: () -> Pair<Int,String>): SessionRepository {
        val origin = "https://accounts.example".toHttpUrl()
        val connection = ServerConnection(origin, origin, origin, null, origin, origin, origin, origin, "friends", null)
        val http = ChirpHttp(OkHttpClient.Builder().addInterceptor { chain ->
            assertEquals("/v1/session", chain.request().url.encodedPath)
            val (code, error) = status()
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).message("fixture").code(code)
                .body("""{"error":{"code":"$error"}}""".toResponseBody()).build()
        })
        return SessionRepository(connection, Login("credential", "identity", "Alice", expires), http)
    }

    @Test fun idleSessionDetectsReplacementAfterTransientOfflineResponse() = runBlocking {
        val count = AtomicInteger()
        val repository = session(nowSeconds() + 60) {
            if (count.incrementAndGet() == 1) 503 to "SERVER_UNAVAILABLE" else 401 to "UNAUTHORIZED"
        }
        assertEquals("SESSION_EXPIRED", withTimeout(8000) { repository.awaitSessionFailure() })
        assertEquals(2, count.get())
    }

    @Test fun idleSessionStopsAtLocalExpiryOrWhenDisabled() = runBlocking {
        assertEquals("SESSION_EXPIRED", session(nowSeconds() - 1) { error("Expired credentials reached the server") }.awaitSessionFailure())
        assertEquals("MEMBER_DISABLED", session(nowSeconds() + 60) { 403 to "MEMBER_DISABLED" }.awaitSessionFailure())
    }

    @Test fun learnedBanTimestampsUpgradeOlderRecordsAndCannotBeRolledBack() {
        val prior = Ban(1, "account", "Alice", "Alice", "root", "Alice")
        val dated = prior.copy(createdAt = 100)
        assertTrue(dated.preserves(prior))
        assertFalse(prior.preserves(dated))
        assertFalse(dated.copy(username = "replacement").preserves(prior))
        assertTrue(dated.blocks("Alice", "other", "any-device"))
        assertTrue(dated.blocks("other", "root"))
        assertFalse(dated.blocks("other", "another-root"))
        val device = dated.copy(kind = "device", subject = "device")
        assertFalse(device.blocks("Alice", "root", "other-device"))
        assertTrue(device.blocks("Alice", "root", "device"))
    }
}
