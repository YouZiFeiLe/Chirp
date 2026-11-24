package cn.youzifeile.chirp.media

import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.core.app.ActivityScenario
import cn.youzifeile.chirp.ChirpApplication
import cn.youzifeile.chirp.ui.FeaturePreviewActivity
import cn.youzifeile.chirp.data.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class CallParityTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val room = RoomInfo("friends", "Friends", false, true, GROUP_PROTOCOL, 0, "available", emptyList())
    private val entry = Admission(room, "entry", "self.login.entry", 1000, "wss://example.test", MediaAccess("unused", 1000))

    private fun session(reply: (String) -> Pair<Int, String>): SessionRepository {
        val http = ChirpHttp(OkHttpClient.Builder().addInterceptor { chain ->
            val (status, body) = reply(chain.request().url.encodedPath)
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(status).message("fixture").body(body.toResponseBody()).build()
        })
        val url = "https://example.test/".toHttpUrl()
        val connection = ServerConnection(url, url, url, null, url, url, url, url, room.id, null)
        return SessionRepository(connection, Login("fixture", "self.login", "Self", nowSeconds() + 900), http)
    }

    @Test fun telecomActivatesTheRealServiceThenReleasesItsAdmissionAfterCoordinatorRejection() {
        val configured = AtomicInteger()
        val leaves = AtomicInteger()
        val session = session { path -> when {
            path.endsWith("/leave") -> { leaves.incrementAndGet(); 204 to "" }
            path.endsWith("/config") -> { configured.incrementAndGet(); 404 to """{"error":{"code":"ROOM_NOT_FOUND"}}""" }
            else -> 503 to """{"error":{"code":"UNAVAILABLE"}}"""
        } }
        val app = context.applicationContext as ChirpApplication
        val seed = randomBytes(32)
        val local = LocalDevice(base64(seed), DeviceIdentity.issue(randomBytes(32), publicKey(seed)))
        session.accountIdentity = AccountIdentity(session, local, app.identities, app.authorityKey)
        ActivityScenario.launch(FeaturePreviewActivity::class.java).use {
            runBlocking(Dispatchers.Main) {
                val joining = entry.copy(entryID = "entry_actual_service", deadline = nowSeconds() + 30)
                app.calls.audio.prepareForCall()
                assertTrue(app.calls.join(session, joining))
                try {
                    val final = withTimeout(15_000) { app.calls.state.first { it.phase == CallPhase.Idle } }
                    assertEquals("ROOM_NOT_FOUND", final.error)
                    assertEquals(1, configured.get())
                    assertEquals(1, leaves.get())
                } finally { app.calls.leaveAndWait() }
            }
        }
    }

    @Test fun disabledSessionTerminatesDirectoryWithoutRetry() = runBlocking {
        val calls = AtomicInteger()
        val session = session { calls.incrementAndGet(); 403 to """{"error":{"code":"MEMBER_DISABLED"}}""" }
        val failure = runCatching { withTimeout(2000) { session.followDirectory().first() } }.exceptionOrNull()
        assertEquals("MEMBER_DISABLED", (failure as? ChirpException)?.sessionFailure)
        assertTrue(calls.get() in 1..2)
    }

    @Test fun preServiceCancellationAndStartupFailureBothReleaseExactlyOnce() = runBlocking(Dispatchers.Main) {
        for (fail in listOf(false, true)) {
            val leaves = AtomicInteger()
            val session = session { path ->
                assertTrue(path.endsWith("/leave"))
                leaves.incrementAndGet()
                204 to ""
            }
            val controller = CallController(context) { if (fail) error("Telecom unavailable") }
            assertTrue(controller.join(session, entry))
            if (!fail) { controller.leave(); controller.leave() }
            withTimeout(3000) { controller.state.first { it.phase == CallPhase.Idle } }
            assertEquals(1, leaves.get())
            assertEquals(if (fail) "CALL_SERVICE_UNAVAILABLE" else null, controller.state.value.error)
        }
    }

    @Test fun retiredServiceIntentsCannotClaimOrHangUpTheNextCall() = runBlocking(Dispatchers.Main) {
        val leaves = AtomicInteger()
        val session = session { leaves.incrementAndGet(); 204 to "" }
        val controller = CallController(context) {}
        controller.join(session, entry)
        val service = CallService()
        assertNull(controller.claim(service, "previous-entry"))
        controller.leaveEntry("previous-entry")
        assertEquals(CallPhase.Joining, controller.state.value.phase)
        val claim = requireNotNull(controller.claim(service, entry.entryID))
        // Core-Telecom rejected the call before starting the media coroutine.
        controller.finish(claim, cn.youzifeile.chirp.data.ClientFailure("CALL_SERVICE_UNAVAILABLE"))
        controller.finish(claim, null)
        withTimeout(3000) { controller.state.first { it.phase == CallPhase.Idle } }
        assertEquals(1, leaves.get())
        assertEquals("CALL_SERVICE_UNAVAILABLE", controller.state.value.error)
    }

    @Test fun freshRoomDirectoryRenamesThenEndsTheCorrectCall() = runBlocking(Dispatchers.Main) {
        val session = session { 204 to "" }
        val controller = CallController(context) {}
        controller.join(session, entry)
        val renamed = room.copy(name = "After rename")
        val snapshot = Directory("server", 2UL, listOf(renamed), emptyList())
        controller.updateDirectory(session, snapshot)
        assertEquals("After rename", controller.state.value.room?.name)
        controller.updateDirectory(session, snapshot.copy(fresh = false, rooms = emptyList()))
        assertEquals(room.id, controller.state.value.room?.id)
        controller.updateDirectory(session, snapshot.copy(rooms = emptyList()))
        withTimeout(3000) { controller.state.first { it.phase == CallPhase.Idle } }
        assertNull(controller.state.value.room)
    }

    @Test fun revokedAttachmentStreamClosesLocalAccessAndPublishesEmptyState() = runBlocking(Dispatchers.Main) {
        val session = session { 403 to """{"error":{"code":"MEMBER_DISABLED"}}""" }
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val retired = CompletableDeferred<Unit>()
        val files = RoomAttachments.open(context, session, entry, owner) { if (it.isEmpty()) retired.complete(Unit) }
        try {
            withTimeout(3000) { retired.await() }
            assertTrue(files.authorizationEnded)
            assertTrue(files.unpublished.isEmpty())
            assertTrue(runCatching { files.preview("old") }.exceptionOrNull() is ChirpException)
        } finally { files.close(); owner.cancel() }
    }
}
