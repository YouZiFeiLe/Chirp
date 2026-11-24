package cn.youzifeile.chirp.ui

import android.os.Bundle
import android.os.SystemClock
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import cn.youzifeile.chirp.MainActivity
import cn.youzifeile.chirp.data.RoomInfo
import cn.youzifeile.chirp.data.obj
import cn.youzifeile.chirp.data.text
import cn.youzifeile.chirp.media.CallPhase
import cn.youzifeile.chirp.media.CallState
import java.io.BufferedReader
import java.io.PrintWriter
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain

/** The timing socket carries test milestones only. Both clients use production admission, SAS, MLS and media. */
class RoomStartupLatencyTest {
    private val args get() = InstrumentationRegistry.getArguments()
    private val role get() = requireNotNull(args.getString("peer_role"))
    private val sender get() = role == "sender"
    private val login = ProductionLoginFixture {
        assumeTrue("Requires the paired latency runner", args.containsKey("timing_port"))
        it.obj(if (sender) "production_flow" else "production_peer")
    }
    private val activity = createAndroidComposeRule<MainActivity>()
    @get:Rule val rules: RuleChain = RuleChain.outerRule(login).around(activity)
    private val calls get() = login.app.calls
    private lateinit var model: MainViewModel

    private fun await(stage: String, match: (CallState) -> Boolean): CallState = try {
        runBlocking { withTimeout(50_000) { calls.state.first(match) } }
    } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
        val s = calls.state.value
        throw AssertionError("$role $stage phase=${s.phase} error=${s.error} trust=${s.trust.notice?.phase} " +
            "members=${s.members.size} tracks=${s.diagnostics.map { listOf(it.subscribed, it.received, it.decryptionFailure) }}", e)
    }

    private fun room(): RoomInfo = runBlocking {
        withTimeout(45_000) {
            model.state.first { it.account?.id == login.login.memberID && it.identity.synced && it.directory?.fresh == true }
                .directory!!.rooms.single { it.name == login.data.text("room_name") }
        }
    }

    private fun join(room: RoomInfo): Long = activity.runOnUiThread {
        SystemClock.elapsedRealtime().also { model.join(room, "") }
    }

    private fun verify(peer: String): Long {
        if (!sender) await("invitation") { it.trust.verification?.let { v -> v.peer == peer && !v.accepted && v.commitment != null } == true }
        activity.runOnUiThread { calls.identityAction(if (sender) "start" else "accept", peer) }
        val sas = requireNotNull(await("safety numbers") { it.trust.verification?.let { v ->
            v.peer == peer && v.accepted && !v.confirmed && v.numbers.size == 3
        } == true }.trust.verification)
        login.comparePeerNumbers(role, sas)
        return activity.runOnUiThread { SystemClock.elapsedRealtime().also { calls.identityAction("confirm", peer) } }
    }

    private fun ready(peer: String) = await("secure two-member room") {
        it.phase == CallPhase.Connected && it.chatVisible && !it.trust.pending && peer in it.trust.trusted &&
            it.members.size == 2 && it.members.any { m -> m.identity == peer }
    }

    private fun peer() = await("peer admission") { it.trust.peers.size == 1 }.trust.peers.single().identity

    private fun listen(port: Int, repeats: Int) {
        join(room())
        ServerSocket(port, 1, InetAddress.getByName("127.0.0.1")).use { server ->
            server.soTimeout = 90_000
            server.accept().use { socket ->
                exchange(socket) { input, output ->
                    output.println("hello")
                    repeat(repeats + 1) { round ->
                        repeat(5) {
                            check(input.readLine() == "clock")
                            output.println(SystemClock.elapsedRealtime())
                        }
                        await("resident alone") { it.phase == CallPhase.Connected && it.members.size == 1 && it.trust.peers.isEmpty() }
                        output.println("solo")
                        val peer = peer()
                        val confirm = if (round == 0) verify(peer) else 0L
                        ready(peer)
                        output.println("$confirm ${SystemClock.elapsedRealtime()}")
                        // The stats callback may run a second later. Use the decryptor's original timestamp.
                        val frame = await("remote microphone decryption") { state -> state.diagnostics.any {
                            it.identity == peer && it.subscribed && it.encrypted && it.firstDecryptedAt != null
                        } }.diagnostics.first { it.identity == peer && it.firstDecryptedAt != null }
                        output.println(frame.firstDecryptedAt)
                    }
                    check(input.readLine() == "done")
                }
            }
        }
    }

    private fun exchange(socket: Socket, body: (BufferedReader, PrintWriter) -> Unit) {
        socket.tcpNoDelay = true
        socket.soTimeout = 90_000
        body(socket.getInputStream().bufferedReader(), PrintWriter(socket.getOutputStream(), true))
    }

    private fun talk(port: Int, repeats: Int) {
        val deadline = SystemClock.elapsedRealtime() + 60_000
        // An ADB forward may accept before the other instrument has opened its server socket.
        var socket: Socket
        while (true) {
            socket = Socket("127.0.0.1", port)
            socket.soTimeout = 3_000
            try {
                if (socket.getInputStream().bufferedReader().readLine() == "hello") break
            } catch (_: java.io.IOException) { }
            socket.close()
            check(SystemClock.elapsedRealtime() < deadline) { "Resident did not start" }
            Thread.sleep(150)
        }
        socket.use {
            exchange(it) { input, output ->
                repeat(repeats + 1) { round ->
                    val target = room()
                    // Align monotonic clocks using the lowest-RTT exchange.
                    val (rtt, offset) = List(5) {
                        val sent = SystemClock.elapsedRealtime()
                        output.println("clock")
                        val remote = input.readLine().toLong()
                        val received = SystemClock.elapsedRealtime()
                        (received - sent) to ((sent + received) / 2 - remote)
                    }.minBy { sample -> sample.first }
                    check(input.readLine() == "solo")
                    val start = join(target)
                    await("admission") { s -> s.entryID != null }
                    val admitted = SystemClock.elapsedRealtime()
                    val peer = peer()
                    val confirm = if (round == 0) verify(peer) else 0L
                    check(!ready(peer).micOn)
                    val guestReady = SystemClock.elapsedRealtime()
                    val (otherConfirm, otherReady) = input.readLine().split(" ").map(String::toLong)
                    val both = maxOf(guestReady, otherReady + offset)
                    val mic = activity.runOnUiThread { SystemClock.elapsedRealtime().also { calls.setMic(true) } }
                    await("microphone publication") { s -> s.micOn }
                    val published = SystemClock.elapsedRealtime()
                    val frame = input.readLine().toLong() + offset
                    check(frame + rtt + 1 >= mic)
                    val sas = if (round == 0) maxOf(confirm, otherConfirm + offset) - start else 0
                    val sample = "ROOM_STARTUP round=$round admitted_ms=${admitted - start} confirm_ms=$sas " +
                        "ready_ms=${both - start} mic_ms=${mic - start} published_ms=${published - start} " +
                        "first_ms=${frame - start} sync_rtt_ms=$rtt"
                    InstrumentationRegistry.getInstrumentation().sendStatus(2, Bundle().apply { putString("stream", "$sample\n") })
                    activity.runOnUiThread { calls.leave() }
                    await("left") { s -> s.phase == CallPhase.Idle }
                }
                output.println("done")
            }
        }
    }

    @Test fun joinOccupiedRoomAndSendVoice() {
        model = activity.activity.model
        login.signIn(model)
        val port = requireNotNull(args.getString("timing_port")).toInt()
        val repeats = requireNotNull(args.getString("startup_repeats")).toInt()
        if (sender) talk(port, repeats) else listen(port, repeats)
    }
}
