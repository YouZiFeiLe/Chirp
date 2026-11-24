package cn.youzifeile.chirp.ui

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.content.FileProvider
import androidx.test.platform.app.InstrumentationRegistry
import cn.youzifeile.chirp.MainActivity
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.*
import cn.youzifeile.chirp.media.*
import java.io.File
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain

/** The disposable fixture compares keyed commitments before either device confirms. It never receives the digits. */
internal fun ProductionLoginFixture.comparePeerNumbers(role: String, sas: Verification) {
    val key = fixture.text("peer_comparison_key").base64Bytes(32)
    val digest = try {
        val hmac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }
        hmac.doFinal((sas.id + "/" + sas.numbers.joinToString(",")).encodeToByteArray()).toHexString()
    } finally { key.fill(0) }
    val request = connection.origin.path("test", "peer-sas").request(login.credential)
        .jsonPost(buildJsonObject { put("role", role); put("commitment", digest) }).build()
    runBlocking(Dispatchers.IO) {
        withTimeout(35_000) {
            while (true) {
                when (app.http.client.newCall(request).execute().use { it.code }) {
                    202 -> delay(200)
                    204 -> return@withTimeout
                    409 -> throw AssertionError("The two devices derived different verification numbers")
                    else -> throw AssertionError("The out-of-band verifier rejected the device")
                }
            }
        }
    }
}

/** Run concurrently on two devices with separate accounts against the same real Go and LiveKit servers. */
class PeerFlowTest {
    private val role get() = InstrumentationRegistry.getArguments().getString("peer_role")
    private val sender get() = role == "sender"
    private val login = ProductionLoginFixture { shared ->
        assumeTrue("Requires the two-device runner", role != null)
        require(role in setOf("sender", "receiver"))
        shared.obj(if (sender) "production_flow" else "production_peer")
    }
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val activityRule: RuleChain = RuleChain.outerRule(login).around(compose)
    private val calls get() = login.app.calls
    private var previousRecording: Boolean? = null
    private var logStart = 0L

    @org.junit.After fun restoreRecording() { previousRecording?.let(login.app.logs::setEnabled) }

    private fun verifyCallLog(directory: File, peer: String, fileName: String) = runBlocking {
        val logs = login.app.logs
        val name = requireNotNull(logs.prepareExport())
        val file = File(directory, "call.chirplog")
        logs.finishExport(name) { file.outputStream() }
        android.database.sqlite.SQLiteDatabase.openDatabase(file.path, null,
            android.database.sqlite.SQLiteDatabase.OPEN_READONLY).use { db ->
            fun count(sql: String) = android.database.DatabaseUtils.longForQuery(db, sql, null)
            assertTrue(count("SELECT sum(json_extract(details,'$.frames')) FROM crypto WHERE time_ms >= $logStart AND event='voiceDecrypt'") > 0)
            assertTrue(count("SELECT min(json_extract(details,'$.max_ns')) FROM crypto WHERE time_ms >= $logStart AND event='voiceDecrypt'") > 0)
            for (stage in listOf("authorizationStarted", "activated", "firstRemoteDecryption")) {
                assertTrue(stage, count("SELECT count(*) FROM call WHERE time_ms >= $logStart AND event='lifecycle' AND json_extract(details,'$.event')='$stage'") > 0)
            }
            assertTrue(count("SELECT count(*) FROM call,json_each(details,'$.tracks') t WHERE time_ms >= $logStart AND event='trackSample' " +
                "AND json_extract(t.value,'$.encryption')='verified' AND json_extract(t.value,'$.packetsReceived') > 0") > 0)
            assertTrue(count("SELECT count(*) FROM network WHERE time_ms >= $logStart AND event='mediaLease' AND http_status=200 AND duration_us>0") > 0)
            assertTrue(count("SELECT count(*) FROM chat WHERE time_ms >= $logStart AND event='sendMessage' AND outcome='succeeded'") > 0)
        }
        val bytes = file.readBytes().decodeToString()
        for (privateValue in listOf(peer, fileName, login.login.credential, "Hello from the sender", login.fixture.text("url"))) {
            assertFalse("Private fixture value in .chirplog", bytes.contains(privateValue))
        }
    }
    private fun text(id: Int) = compose.activity.getString(id)

    private fun awaitCall(stage: String, timeout: Long = 45_000, predicate: (CallState) -> Boolean): CallState =
        try {
            runBlocking { withTimeout(timeout) { calls.state.first(predicate) } }
        } catch (failure: TimeoutCancellationException) {
            val state = calls.state.value
            val audio = state.diagnostics.map { listOf(it.subscribed, it.encrypted, it.received, it.lastDecryptionMS, it.decryptionFailure) }
            throw AssertionError(listOf(role, stage, state.phase, state.error, state.trust.failure,
                state.trust.notice?.phase, "peers=" + state.trust.peers.size, "tracks=" + audio,
                "messages=" + state.messages.size, "files=" + state.attachments.values.map { it.phase },
                "chatVisible=" + state.chatVisible, "draftBytes=" + state.draft.encodeToByteArray().size,
                "sending=" + state.sending, "held=" + state.held, "trustPending=" + state.trust.pending).joinToString(" "), failure)
        }

    private fun click(matcher: SemanticsMatcher) {
        val action = matcher and hasClickAction() and isEnabled()
        compose.waitUntil(12_000) { compose.onAllNodes(action).fetchSemanticsNodes().isNotEmpty() }
        compose.onNode(action).performClick()
    }

    private fun joinThroughActivity() {
        val activity = compose.activity
        val model = activity.model
        login.signIn(model)
        try {
            runBlocking { withTimeout(45_000) {
                model.state.first { it.account?.id == login.login.memberID && it.identity.synced && it.directory?.fresh == true }
            } }
        } catch (e: TimeoutCancellationException) {
            val state = model.state.value
            val interactive = activity.getSystemService(android.os.PowerManager::class.java).isInteractive
            val locked = activity.getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked
            throw AssertionError("Saved login readiness: account=${state.account?.id == login.login.memberID}, " +
                "identity=${state.identity.synced}, directory=${state.directory?.fresh}, error=${state.error?.code}, " +
                "checking=${state.checking}, interactive=$interactive, locked=$locked", e)
        }
        val roomName = login.data.text("room_name")
        val room = hasText(roomName) and hasClickAction()
        if (compose.onAllNodes(room).fetchSemanticsNodes().isEmpty()) {
            compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsActions.ScrollToIndex)).onFirst()
                .performScrollToNode(hasText(roomName))
        }
        compose.onAllNodes(room).onFirst().performClick()
        click(hasText(text(R.string.join_room)))
    }

    private fun verifyPeer(peer: String) {
        if (sender) {
            val name = calls.state.value.trust.peers.single { it.identity == peer }.name
            click(hasText(compose.activity.getString(R.string.trust_target, name)))
            click(hasText(text(R.string.sas_start)) and hasAnyAncestor(isDialog()))
        } else {
            awaitCall("incoming verification") { state ->
                state.trust.verification?.let { it.peer == peer && !it.accepted && it.commitment != null } == true
            }
            click(hasText(text(R.string.verify_accept)) and hasAnyAncestor(isDialog()))
        }
        val state = awaitCall("SAS exchange") { state -> state.trust.verification?.let {
            it.peer == peer && it.accepted && !it.confirmed && it.numbers.size == 3
        } == true }
        val sas = requireNotNull(state.trust.verification)
        assertTrue("SAS must contain three valid decimal groups", sas.numbers.all { it in 1000..9191 })
        // Check the rendered transaction without including the comparison numbers in assertion or log output.
        for ((index, digits) in sas.numbers.withIndex()) {
            val label = compose.activity.getString(R.string.sas_group_accessible, index + 1) + ", " + digits.toString().toList().joinToString(" ")
            val group = androidx.compose.ui.test.hasContentDescription(label) and hasAnyAncestor(isDialog())
            compose.waitUntil(5_000) { compose.onAllNodes(group).fetchSemanticsNodes().size == 1 }
        }
        login.comparePeerNumbers(requireNotNull(role), sas)
        click(hasText(text(R.string.verify_match)) and hasAnyAncestor(isDialog()))
        awaitCall("verified device") { it.trust.verification == null && peer in it.trust.trusted &&
            it.trust.notice?.let { n -> n.peer == peer && n.phase == VerificationPhase.Verified } == true }
        click(hasText(text(R.string.sas_finish_room)) and hasAnyAncestor(isDialog()))
        awaitCall("both devices admitted to the encrypted call", 70_000) {
            it.phase == CallPhase.Connected && it.chatVisible && !it.trust.pending && peer in it.trust.trusted &&
                it.members.any { member -> member.identity == peer }
        }
    }

    private fun openChat() {
        click(hasText(text(R.string.chat)) or hasText(compose.activity.getString(R.string.chat_unread, 1)))
    }

    private fun sendChat(message: String) {
        val editor = hasContentDescription(text(R.string.chat_hint)) and hasSetTextAction()
        compose.onNode(editor).performTextReplacement(message)
        val entry = awaitCall("text field delivered the complete draft", 8_000) { it.draft == message }.entryID
        val label = hasContentDescription(text(R.string.send))
        val control = (label or hasAnyDescendant(label)) and hasClickAction()
        val enabled = control and isEnabled()
        // Match Material's clickable button even when its Icon owns the accessible label.
        try {
            compose.waitUntil(12_000) { compose.onAllNodes(enabled, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }
        } catch (failure: Throwable) {
            val state = calls.state.value
            fun count(matcher: SemanticsMatcher, unmerged: Boolean) =
                compose.onAllNodes(matcher, useUnmergedTree = unmerged).fetchSemanticsNodes().size
            throw AssertionError("Chat send UI " + listOf(state.phase, state.error, "visible=" + state.chatVisible,
                "sameEntry=" + (state.entryID == entry), "draftValid=" + validChatText(state.draft),
                "draftBytes=" + state.draft.encodeToByteArray().size,
                "ownDelivery=" + state.messages.firstOrNull { it.own && it.text == message }?.delivery,
                "sending=" + state.sending, "held=" + state.held,
                "editors=" + count(editor, false), "mergedLabels=" + count(label, false),
                "labels=" + count(label, true), "buttons=" + count(control, true), "enabled=" + count(enabled, true)).joinToString(" "), failure)
        }
        compose.onNode(enabled, useUnmergedTree = true).performClick()
        val state = awaitCall("outgoing chat delivery") { !it.sending && it.messages.any { m ->
            m.own && m.text == message && m.delivery in setOf(Delivery.Sent, Delivery.Failed)
        } }
        assertEquals("Chat submission: phase=${state.phase}, held=${state.held}, error=${state.error}",
            Delivery.Sent, state.messages.single { it.own && it.text == message }.delivery)
    }

    private fun receiveChat(peer: String, message: String) {
        val state = awaitCall("peer chat delivery", 60_000) { it.messages.any { m ->
            !m.own && m.id.substringBefore(':') == peer && m.text == message && m.delivery == Delivery.Received
        } }
        assertEquals(1, state.messages.count { !it.own && it.text == message && it.id.substringBefore(':') == peer })
    }

    private fun track(state: CallState, peer: String) = state.diagnostics.firstOrNull {
        it.identity == peer && it.subscribed && !it.muted && it.encrypted && it.decryptionFailure == null &&
            (it.lastDecryptionMS ?: Long.MAX_VALUE) <= 10_000 && (it.received ?: 0) > 0
    }

    private fun verifyPlaybackSwitches(peer: String) {
        fun awaitPlayback(enabled: Boolean) = awaitCall("peer playback = $enabled") { state ->
            state.members.any { it.identity == peer && it.listening == enabled }
        }
        fun switch(enabled: Boolean) = compose.runOnUiThread { calls.setListening(enabled) }
        if (sender) {
            awaitPlayback(false)
            switch(false)
            awaitPlayback(true)
            switch(true)
        } else {
            val initial = awaitPlayback(true)
            assertEquals(false, initial.members.single { it.identity == peer }.microphoneEnabled)
            switch(false)
            awaitPlayback(false)
            switch(true)
            awaitPlayback(true)
        }
    }

    private fun verifySystemMicrophoneMute(peer: String) {
        // The receiver acknowledges each observed microphone change with its own playback switch.
        for (muted in listOf(true, false)) {
            if (sender) {
                compose.runOnUiThread { calls.setSystemMute(muted) }
                awaitCall("receiver acknowledged system mute = $muted") { state ->
                    state.members.any { it.identity == peer && it.listening == !muted }
                }
            } else {
                awaitCall("peer system mute = $muted") { state ->
                    state.members.any { it.identity == peer && it.microphoneEnabled == !muted }
                }
                compose.runOnUiThread { calls.setListening(!muted) }
            }
        }
    }

    private fun verifyIncomingMicrophone(peer: String) {
        val first = requireNotNull(track(awaitCall("encrypted inbound microphone", 65_000) { state ->
            state.members.any { it.identity == peer && it.microphoneEnabled == true } && track(state, peer) != null
        }, peer))
        awaitCall("continued RTP reception and frame decryption", 35_000) { state ->
            track(state, peer)?.let { next ->
                next.trackID == first.trackID && requireNotNull(next.received) > requireNotNull(first.received) &&
                    requireNotNull(next.lastDecryptedAt) > requireNotNull(first.lastDecryptedAt) &&
                    next.averageJitterBufferMS != null
            } == true
        }
    }

    private fun uri(file: File) = FileProvider.getUriForFile(login.app, login.app.packageName + ".test-files", file)

    @Test fun twoRegisteredDevicesVerifyEachOtherReceiveLiveAudioAndExchangeChatAndAttachmentBytes() {
        val other = login.fixture.obj(if (sender) "production_peer" else "production_flow")
        val memberID = other.text("account_id")
        val peerDevice = other.obj("device").decode<DeviceIdentity>()
        assertTrue("Fixture needs a different account and device per emulator", memberID != login.login.memberID &&
            peerDevice.leaf != login.login.device?.leaf)
        logStart = System.currentTimeMillis()
        previousRecording = login.app.logs.enabled.value
        login.app.logs.setEnabled(true)
        joinThroughActivity()
        val roomID = login.data.text("room_id")
        assertEquals(roomID, other.text("room_id"))
        val entered = awaitCall("other registered device in untrusted roster", 75_000) { state ->
            state.room?.id == roomID && state.entryID != null && state.trust.peers.any {
                it.identity.substringBefore('.') == memberID && it.binding?.device == peerDevice
            }
        }
        val peer = entered.trust.peers.single { it.identity.substringBefore('.') == memberID }.identity
        assertFalse("Devices must enter without a prior trust record", peer in entered.trust.trusted)
        verifyPeer(peer)
        verifyPlaybackSwitches(peer)

        val directory = File(login.app.cacheDir, "android-protocol/" + UUID.randomUUID()).apply { check(mkdirs()) }
        val fileName = "peer-fixture.bin"
        val bytes = ByteArray(8193) { (it * 19 % 251).toByte() }
        try {
            if (!sender) verifyIncomingMicrophone(peer)
            click(hasText(text(R.string.enable_mic)))
            awaitCall("publish the microphone") { it.phase == CallPhase.Connected && it.micOn }
            runBlocking { withTimeout(10_000) { calls.audio.state.first { it.applied } } }
            if (sender) verifyIncomingMicrophone(peer)
            openChat()
            if (sender) {
                receiveChat(peer, "Your microphone arrived")
                sendChat("Hello from the sender")
                receiveChat(peer, "Hello from the receiver")
                val source = File(directory, fileName).apply { writeBytes(bytes) }
                compose.runOnUiThread {
                    val active = calls.state.value
                    calls.sendFile(uri(source), active.entryID, active.cacheRevision)
                }
                awaitCall("outgoing attachment completed") { state -> state.messages.any { message ->
                    message.own && message.delivery == Delivery.Sent && message.attachment?.let { info ->
                        info.name == fileName && state.attachments[info.id]?.phase == TransferPhase.Available
                    } == true
                } }
                receiveChat(peer, "The exported bytes match")
                verifySystemMicrophoneMute(peer)
                compose.runOnUiThread {
                    calls.setListening(false)
                    calls.setMic(false)
                }
                sendChat("Transfer receipt received")
                val reunited = awaitCall("trusted receiver rejoined") { state ->
                    state.phase == CallPhase.Connected && state.members.any { member ->
                        member.identity != peer && member.identity.substringBefore('.') == memberID &&
                            member.identity in state.trust.trusted
                    }
                }
                // A membership change can mute the publisher while it renews its media permit.
                if (!reunited.micOn) compose.runOnUiThread { calls.setMic(true) }
                awaitCall("receiver finished checking audio and left", 75_000) { it.trust.peers.isEmpty() }
            } else {
                sendChat("Your microphone arrived")
                receiveChat(peer, "Hello from the sender")
                sendChat("Hello from the receiver")
                val withFile = awaitCall("incoming attachment completed", 60_000) { state -> state.messages.any { message ->
                    !message.own && message.id.substringBefore(':') == peer && message.attachment?.let { info ->
                        info.name == fileName && state.attachments[info.id]?.phase == TransferPhase.Available
                    } == true
                } }
                val received = requireNotNull(withFile.messages.single { !it.own && it.attachment?.name == fileName }.attachment)
                assertEquals(bytes.size.toLong(), received.size)
                val target = File(directory, "exported.bin").apply { check(createNewFile()) }
                compose.runOnUiThread { calls.export(received.id, uri(target), withFile.entryID, withFile.cacheRevision) }
                compose.waitUntil(10_000) { target.length() == bytes.size.toLong() }
                assertArrayEquals(bytes, target.readBytes())
                sendChat("The exported bytes match")
                verifySystemMicrophoneMute(peer)
                receiveChat(peer, "Transfer receipt received")
                awaitCall("peer muted and paused playback") { state ->
                    state.members.any { it.identity == peer && it.microphoneEnabled == false && it.listening == false }
                }
                compose.runOnUiThread { calls.leave() }
                awaitCall("left before trusted rejoin") { it.phase == CallPhase.Idle }
                compose.runOnUiThread {
                    compose.activity.model.join(requireNotNull(entered.room), "")
                }
                awaitCall("rejoined without verification") { state ->
                    state.phase == CallPhase.Connected && state.entryID != entered.entryID && peer in state.trust.trusted &&
                        state.members.any { it.identity == peer && it.listening == false }
                }
                verifyIncomingMicrophone(peer)
            }
            verifyCallLog(directory, peer, fileName)
        } finally { directory.deleteRecursively() }
    }
}
