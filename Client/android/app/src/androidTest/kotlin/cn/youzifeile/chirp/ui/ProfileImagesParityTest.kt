package cn.youzifeile.chirp.ui

import android.graphics.Bitmap
import android.graphics.Color
import cn.youzifeile.chirp.data.*
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class ProfileImagesParityTest {
    private fun bytes(color: Int, size: Int = 512, format: Bitmap.CompressFormat = Bitmap.CompressFormat.PNG): ByteArray {
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        return try {
            bitmap.eraseColor(color)
            ByteArrayOutputStream().use { out ->
                check(bitmap.compress(format, 95, out))
                out.toByteArray()
            }
        } finally { bitmap.recycle() }
    }

    @Test fun concurrentRevisionLookupsShareRetriesAndNewRevisionsCannotUseStaleOrInvalidImages() = runBlocking(Dispatchers.Main) {
        val old = bytes(Color.RED)
        val updated = bytes(Color.BLUE)
        val wrongSize = bytes(Color.GREEN, size = 8)
        val wrongFormat = bytes(Color.GREEN, format = Bitmap.CompressFormat.JPEG)
        val wrongMime = bytes(Color.YELLOW)
        fun revision(data: ByteArray) = sha256(data).toHexString()
        val red = revision(old)
        val blue = revision(updated)
        val digestMismatch = "e".repeat(64)
        val memberID = "member_" + "A".repeat(16)
        val payload = listOf(old, updated, wrongSize, wrongFormat, wrongMime).associateBy(::revision) + (digestMismatch to old)
        val counts = ConcurrentHashMap<String, AtomicInteger>()
        val http = ChirpHttp(OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            val hash = request.url.pathSegments.last()
            check(request.url.encodedPath == "/v1/members/" + memberID + "/avatar/" + hash)
            check(request.header("Accept") == "image/png")
            val count = counts.computeIfAbsent(hash) { AtomicInteger() }.incrementAndGet()
            val retry = hash == red && count == 1
            val mime = if (hash == revision(wrongMime)) "image/jpeg" else "image/png"
            val body = if (retry) """{"error":{"code":"SERVICE_UNAVAILABLE"}}""".toResponseBody()
                else requireNotNull(payload[hash]).toResponseBody(mime.toMediaType())
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).message("Fixture")
                .code(if (retry) 503 else 200).body(body).build()
        })
        val origin = "https://example.test/".toHttpUrl()
        val session = SessionRepository(ServerConnection(origin, origin, origin, null, origin, origin, origin, origin, "main", null),
            Login("credential", "identity", "Fixture", nowSeconds() + 600), http)
        val images = ProfileImages(this, session)
        val first = Profile(memberID, "Riley", 1, red)
        try {
            val copies = withTimeout(5000) {
                listOf(async { images.get(first) }, async { images.get(first) }, async { images.get(first) }).awaitAll()
            }
            assertEquals(2, counts[red]?.get())
            assertEquals(Color.RED, requireNotNull(copies.first()).getPixel(0, 0))
            assertTrue(copies.all { it === copies.first() })
            assertSame(copies.first(), images.get(first))
            val next = first.copy(revision = 2, avatar = blue)
            images.retain(listOf(next))
            withTimeout(5000) { while (counts[blue]?.get() != 1) delay(10) }
            val changed = requireNotNull(images.get(next))
            assertEquals(Color.BLUE, changed.getPixel(0, 0))
            assertNotSame(copies.first(), changed)
            assertEquals(1, counts[blue]?.get())
            assertEquals("AVATAR_INVALID", (runCatching { session.avatar(first.copy(avatar = digestMismatch)) }
                .exceptionOrNull() as? ChirpException)?.code)
            assertEquals("INVALID_RESPONSE", (runCatching { session.avatar(first.copy(avatar = revision(wrongMime))) }
                .exceptionOrNull() as? ChirpException)?.code)
            assertNull(images.get(first.copy(avatar = revision(wrongSize))))
            assertNull(images.get(first.copy(avatar = revision(wrongFormat))))
            assertNull(images.get(next.copy(avatar = null)))
        } finally { images.close() }
    }
}
