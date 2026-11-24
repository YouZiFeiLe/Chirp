package cn.youzifeile.chirp.data

import java.time.Instant
import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class ClientFailureTest {
    @Test fun parsesBothRetryHeadersOnlyWhenRetryIsAllowed() {
        val now = Instant.parse("2026-11-19T12:00:00.500Z")
        val deadline = "Thu, 19 Nov 2026 12:00:03 GMT"
        assertEquals(3L, retryDelay(503, deadline, now))
        assertEquals(6L, retryDelay(429, "6", now))
        for (invalid in listOf("0", "-1", "later", "Thu, 19 Nov 2026 11:59:59 GMT")) assertNull(retryDelay(503, invalid, now))
        assertNull(retryDelay(403, "60", now))
    }

    @Test fun readsValidPolicyAndDiscardsMalformedPolicyWithoutLosingTheServerError() = runBlocking {
        suspend fun request(code: String, build: Int): ChirpException {
            val http = ChirpHttp(OkHttpClient.Builder().addInterceptor { chain ->
                val payload = """{"error":{"code":"$code"},"client_policy":{"platform":"android","latest_version":"3.0.0","latest_build":$build,"minimum_version":"2.0.0","minimum_build":8}}"""
                Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(503).message("Unavailable")
                    .header("Retry-After", "2").body(payload.toResponseBody()).build()
            })
            val error = runCatching { http.json("https://example.test".toHttpUrl().request().build()) }.exceptionOrNull()
            return error as ChirpException
        }
        assertEquals(VersionPolicy(ClientVersion("3.0.0", 10), ClientVersion("2.0.0", 8)), request("CLIENT_UPDATE_REQUIRED", 10).policy)
        val unknown = request("X".repeat(80), 0).clientFailure()
        assertEquals("X".repeat(80), unknown.code)
        assertEquals(2L, unknown.retryAfterSeconds)
        assertNull(unknown.policy)
        assertEquals("CLIENT_HTTP_FAILURE", request("server prose", 10).code)
    }

    @Test fun recoveryPasswordUsesCodePointsAndUtf8Bytes() {
        assertFalse(validRecoveryPassword("🍊".repeat(15)))
        assertTrue(validRecoveryPassword("🍊".repeat(16)))
        assertTrue(validRecoveryPassword("🍊".repeat(256)))
        assertFalse(validRecoveryPassword("🍊".repeat(256) + " "))
    }
}
