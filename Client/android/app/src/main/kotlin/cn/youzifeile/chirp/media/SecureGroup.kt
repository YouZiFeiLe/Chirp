package cn.youzifeile.chirp.media

import android.os.SystemClock
import cn.youzifeile.chirp.data.Admission
import cn.youzifeile.chirp.data.ChirpException
import cn.youzifeile.chirp.data.SessionRepository
import cn.youzifeile.chirp.data.text
import cn.youzifeile.chirp.data.verify
import java.io.IOException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.async
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal interface GroupMedia {
    val gate: MediaGate
    fun granted(index: Int)
    fun pause()
    suspend fun prepareKeys(keys: Map<String, ByteArray>, index: Int)
    suspend fun switchKeys(index: Int)
    fun retireKeys(index: Int)
}

internal class SecureGroup(
    private val session: SessionRepository,
    private val admission: Admission,
    private val install: suspend (GroupSnapshot, Map<String, ByteArray>) -> GroupMedia,
    private val closeMedia: suspend () -> Unit,
    private val makeNative: (String) -> MlsClient = ::MlsNative,
    private val makeTransport: (SessionRepository, Admission, MlsClient) -> GroupServing,
    private val wall: () -> Long = System::currentTimeMillis,
    private val monotonic: () -> Long = { SystemClock.elapsedRealtime() },
    private val cryptoDispatcher: kotlinx.coroutines.CoroutineDispatcher = Dispatchers.Default,
) {
    suspend fun run(held: StateFlow<Boolean> = MutableStateFlow(false)): Nothing = makeNative(admission.identity).use { native ->
        val transport = makeTransport(session, admission, native)
        var retired: GroupPosition? = null
        held.collectLatest { paused ->
            var failures = 0
            while (true) {
                try {
                    try {
                        val config = transport.config()
                        var next = transport.snapshot(config, "join")
                        if (paused) {
                            retired = next.position
                            // Keep only membership heartbeats. No MLS media leases are requested on hold.
                            while (transport.pulse(next, "heartbeat").status.position == next.position) {
                                delay(2_000)
                            }
                        } else {
                            if (next.position == retired) next = transport.snapshot(next.position, "refresh")
                            round(transport, native, next, retire = { retired = it }, onReady = { failures = 0 })
                        }
                    } finally {
                        withContext(NonCancellable) { native.clear(); closeMedia() }
                    }
                } catch (e: IOException) {
                    if (e is ChirpException && (e.status in setOf(401, 403, 404) ||
                            e.code in setOf("ADMISSION_EXPIRED", "IDENTITY_KEY_CHANGED", "ROOM_IDENTITY_REVOKED",
                                "IDENTITY_BLACKLISTED"))) throw e
                    if (++failures >= 8) throw e
                    delay((200L shl (failures - 1)).coerceAtMost(2000))
                }
            }
        }
        error("Group hold flow completed")
    }

    private suspend fun round(
        transport: GroupServing,
        native: MlsClient,
        initial: GroupSnapshot,
        retire: (GroupPosition) -> Unit,
        onReady: () -> Unit,
    ): Unit = coroutineScope {
        var state = initial
        var watching = false
        var newest = 0UL
        var newestRotation = 0UL
        var media: GroupMedia? = null
        var authorized = false
        var authorizedRevision = 0UL
        // Keep one notification if a new snapshot or mutual-trust decision arrives during a request.
        val progress = Channel<Unit>(Channel.CONFLATED)

        fun observe(revision: ULong) {
            if (revision > newest) {
                newest = revision
                progress.trySend(Unit)
            }
            if (authorized && newest > authorizedRevision) {
                media?.gate?.revoke()
                throw ChirpException("GROUP_CHANGED")
            }
        }

        val watcher = launch(start = CoroutineStart.UNDISPATCHED) {
            transport.watch(initial.position).collect {
                if (!watching) progress.trySend(Unit)
                watching = true
                observe(it.first)
                newestRotation = maxOf(newestRotation, it.second)
            }
            throw ChirpException("GROUP_EVENTS_CLOSED")
        }
        val trustWatcher = launch(start = CoroutineStart.UNDISPATCHED) {
            transport.trustReady.collect { if (it) progress.trySend(Unit) }
        }
        val heartbeat = launch {
            while (true) {
                delay(2_000)
                val reply = transport.pulse(state, "heartbeat")
                if (reply.status.suspended || reply.status.position.session != state.position.session ||
                    (authorized && reply.status.position != state.position)) {
                    media?.gate?.revoke()
                    throw ChirpException("GROUP_CHANGED")
                }
                observe(reply.status.revision)
                newestRotation = maxOf(newestRotation, reply.status.rotationRevision)
            }
        }

        try {
            var working: GroupPosition? = null
            var pkg = ""
            var confirmation = ""
            var sentAck = false
            var deadline = monotonic() + 25_000
            var keyStarted = 0L
            var keyDeadline = 0L
            while (monotonic() < deadline) {
                if (state.status.suspended) throw ChirpException("GROUP_SUSPENDED")
                if (state.position != working) {
                    media?.pause()
                    closeMedia()
                    media = null
                    native.clear()
                    working = state.position
                    retire(state.position)
                    pkg = ""
                    confirmation = ""
                    sentAck = false
                }
                try {
                    if (!transport.approve(state)) {
                        verify(media == null && confirmation.isEmpty(), "GROUP_CHANGED")
                        deadline = monotonic() + 25_000
                        if (newest <= state.status.revision) withTimeoutOrNull(500) { progress.receive() }
                        state = transport.snapshot(state.position, "snapshot")
                        continue
                    }
                    when (state.status.phase) {
                        "collecting" -> {
                            val own = state.members.single { it.identity == admission.identity }
                            if (pkg.isEmpty()) pkg = withContext(cryptoDispatcher) { native.keyPackage() }
                            verify(own.keyPackage.isEmpty() || own.keyPackage == pkg, "MLS_PACKAGE_CHANGED")
                            if (own.keyPackage.isEmpty()) {
                                state = transport.snapshot(state.position, "package", buildJsonObject { put("key_package", pkg) })
                                continue
                            }
                        }
                        "welcoming" -> if (state.leader == admission.identity) {
                            keyStarted = monotonic()
                            val created = withContext(cryptoDispatcher) { native.create(state) }
                            confirmation = created.text("confirmation")
                            state = transport.snapshot(state.position, "publish", buildJsonObject {
                                put("welcome", created.text("welcome"))
                                put("confirmation", confirmation)
                            })
                            continue
                        }
                        "confirming", "ready" -> {
                            if (confirmation.isEmpty()) {
                                keyStarted = monotonic()
                                confirmation = withContext(cryptoDispatcher) { native.join(state) }
                            }
                            verify(confirmation == state.confirmation, "MLS_CONFIRMATION_MISMATCH")
                            if (media == null) {
                                val keys = LinkedHashMap<String, ByteArray>()
                                try {
                                    withContext(cryptoDispatcher) {
                                        keyDeadline = monotonic() + native.keyLifetimeMillis()
                                        for (member in state.members) keys[member.identity] = native.key(member.identity)
                                    }
                                    media = withTimeout(8_000) { install(state, keys) }
                                } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
                                    throw ChirpException("MEDIA_CONNECT_TIMEOUT")
                                } finally {
                                    keys.values.forEach { it.fill(0) }
                                }
                            }
                            if (!sentAck) {
                                state = transport.snapshot(state.position, "ack", buildJsonObject { put("confirmation", confirmation) })
                                sentAck = true
                                continue
                            }
                            if (state.status.phase == "ready" && watching && newest <= state.status.revision) break
                        }
                    }
                } catch (e: ChirpException) {
                    if (e.code != "GROUP_CONFLICT") throw e
                }
                if (newest <= state.status.revision) withTimeoutOrNull(350) { progress.receive() }
                state = transport.snapshot(state.position, "snapshot")
            }

            val connected = media ?: throw ChirpException("GROUP_TRANSITION_TIMEOUT")
            verify(sentAck && watching && state.status.phase == "ready" && newest <= state.status.revision &&
                connected.gate.groupID == state.position.groupID, "GROUP_TRANSITION_TIMEOUT")
            val epochs = MutableStateFlow(0UL)
            var leaseRequest: Deferred<GroupPulse>? = null
            var activationReply: CompletableDeferred<Unit>? = null
            var retirement: Job? = null
            val leasing = launch {
                var sendingEpoch = 0UL
                while (isActive) {
                    val expectedEpoch = epochs.value
                    val wallStarted = wall()
                    val mono = monotonic()
                    val remaining = if (authorized) connected.gate.remaining() else 2500L
                    verify(remaining > 0, "GROUP_LEASE_LOST")
                    try {
                        val reply = supervisorScope {
                            val request = async { withTimeout(remaining) { transport.pulse(state, "lease", expectedEpoch) } }
                            leaseRequest = request
                            try { request.await() } finally { leaseRequest = null }
                        }
                        if (expectedEpoch != epochs.value) continue
                        observe(reply.status.revision)
                        newestRotation = maxOf(newestRotation, reply.status.rotationRevision)
                        verify(reply.status.position == state.position && reply.status.revision == state.status.revision &&
                            !reply.status.suspended && reply.status.phase == "ready" && reply.status.keyEpoch == expectedEpoch &&
                            newest <= reply.status.revision && reply.leaseMillis > 0 &&
                            (!authorized || connected.gate.remaining() > 0), "GROUP_LEASE_LOST")
                        // Each lease checks the live admission. Heartbeats renew the original 30-second entry.
                        val duration = minOf(reply.leaseMillis.toLong(), session.login.expiresAt * 1000 - wallStarted,
                            keyDeadline - mono,
                            transport.contentMillis(state.members))
                        val permit = MediaPermit(state.position.groupID, wallStarted + duration, mono + duration, expectedEpoch)
                        verify(permit.remaining(wall(), monotonic()) > 0, "GROUP_LEASE_LOST")
                        connected.gate.grant(permit)
                        val index = (expectedEpoch % 2UL).toInt()
                        if (expectedEpoch != sendingEpoch) {
                            connected.switchKeys(index)
                            sendingEpoch = expectedEpoch
                            retirement?.cancel()
                            retirement = launch { delay(1000); connected.retireKeys(1 - index) }
                        }
                        connected.granted(index)
                        if (!authorized) { authorizedRevision = state.status.revision; authorized = true; onReady() }
                        val renewAfter = minOf(1_000, (permit.remaining(wall(), monotonic()) / 3).coerceAtLeast(1))
                        withTimeoutOrNull(renewAfter) { epochs.first { it != expectedEpoch } }
                    } catch (e: ChirpException) {
                        if (e.status != 409 || e.code != "GROUP_CHANGED") throw e
                        if (expectedEpoch == epochs.value) {
                            // The coordinator can reject an old lease after applying our activation but before its HTTP reply.
                            val pending = activationReply ?: throw e
                            val left = connected.gate.remaining()
                            verify(left > 0 && withTimeoutOrNull(left) { pending.await(); true } == true &&
                                expectedEpoch != epochs.value, "GROUP_LEASE_LOST")
                        }
                    } catch (e: CancellationException) {
                        if (!isActive) throw e
                        if (expectedEpoch == epochs.value) throw ChirpException("GROUP_LEASE_LOST")
                    }
                }
            }
            var candidate: ULong? = null
            var candidateConfirmation = ""
            var installed = false
            var confirmed = false
            var activated = false
            var candidateStarted = 0L
            var candidateKeyStarted = 0L
            var candidateDeadline = 0L
            suspend fun act(operation: String, rotation: GroupRotation, extra: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit = {}) {
                val next = transport.snapshot(state.position, operation, buildJsonObject {
                    put("key_epoch", kotlinx.serialization.json.JsonPrimitive(rotation.epoch)); extra()
                })
                observe(next.status.revision)
                verify(next.position == state.position && !next.status.suspended, "GROUP_CHANGED")
                state = next
            }
            try {
                while (isActive) {
                    if (!authorized) { delay(25); continue }
                    val epoch = epochs.value
                    verify(connected.gate.remaining() > 0, "GROUP_LEASE_LOST")
                    verify(transport.contentMillis(state.members) > 0, "GROUP_CHANGED")
                    verify(monotonic() - keyStarted < 90_000, "GROUP_REKEY_REQUIRED")
                    if (candidate != null) verify(monotonic() - candidateStarted < 15_000, "GROUP_REKEY_REQUIRED")
                    val rotation = state.rotation
                    if (rotation == null) {
                        verify(state.status.keyEpoch == epoch, "MLS_CONFIRMATION_MISMATCH")
                        if (activated) {
                            candidate = null; activated = false; installed = false; confirmed = false
                            candidateConfirmation = ""
                        }
                    } else {
                        verify(transport.approve(state, rotation), "GROUP_CHANGED")
                        verify(rotation.epoch == epoch || epoch < ULong.MAX_VALUE && rotation.epoch == epoch + 1UL,
                            "MLS_CONFIRMATION_MISMATCH")
                        if (candidate != rotation.epoch) {
                            verify(rotation.epoch == epoch + 1UL && rotation.phase == "collecting", "MLS_CONFIRMATION_MISMATCH")
                            retirement?.cancel()
                            candidateStarted = monotonic()
                            val packageValue = withContext(cryptoDispatcher) { native.stagedKeyPackage() }
                            candidate = rotation.epoch; candidateConfirmation = ""; installed = false; confirmed = false; activated = false
                            act("rotation_package", rotation) { put("key_package", packageValue) }
                            continue
                        }
                        if (rotation.phase == "welcoming" && state.leader == admission.identity && candidateConfirmation.isEmpty()) {
                            candidateKeyStarted = monotonic()
                            val created = withContext(cryptoDispatcher) {
                                native.createStaged("${state.position.groupID}/key/${rotation.epoch}", rotation.members)
                            }
                            candidateConfirmation = created.text("confirmation")
                            act("rotation_publish", rotation) {
                                put("welcome", created.text("welcome")); put("confirmation", candidateConfirmation)
                            }
                            continue
                        }
                        if (rotation.phase in setOf("confirming", "ready", "switching") && !confirmed) {
                            if (candidateConfirmation.isEmpty()) {
                                candidateKeyStarted = monotonic()
                                candidateConfirmation = withContext(cryptoDispatcher) {
                                    native.joinStaged("${state.position.groupID}/key/${rotation.epoch}", rotation.members, rotation.welcome)
                                }
                            }
                            verify(candidateConfirmation == rotation.confirmation, "MLS_CONFIRMATION_MISMATCH")
                            if (!installed) {
                                val keys = LinkedHashMap<String, ByteArray>()
                                try {
                                    withContext(cryptoDispatcher) {
                                        candidateDeadline = monotonic() + native.keyLifetimeMillis(staged = true)
                                        rotation.members.forEach { keys[it.identity] = native.key(it.identity, staged = true) }
                                    }
                                    verify(connected.gate.remaining() > 0, "GROUP_LEASE_LOST")
                                    connected.prepareKeys(keys, rotation.index); installed = true
                                } finally { keys.values.forEach { it.fill(0) } }
                            }
                            act("rotation_ack", rotation) { put("confirmation", candidateConfirmation) }
                            confirmed = true
                            continue
                        }
                        if (rotation.phase == "switching" && !activated) {
                            verify(installed && confirmed && candidateConfirmation == rotation.confirmation, "MLS_CONFIRMATION_MISMATCH")
                            verify(candidateDeadline > monotonic(), "MEDIA_KEY_REJECTED")
                            withContext(cryptoDispatcher) { native.activateStaged("${state.position.groupID}/key/${rotation.epoch}") }
                            val pending = CompletableDeferred<Unit>()
                            activationReply = pending
                            try {
                                act("rotation_activate", rotation) { put("confirmation", candidateConfirmation) }
                                val previousLease = leaseRequest
                                keyStarted = candidateKeyStarted; keyDeadline = candidateDeadline
                                activated = true; epochs.value = rotation.epoch
                                previousLease?.cancel()
                            } finally {
                                activationReply = null
                                pending.complete(Unit)
                            }
                            continue
                        }
                    }
                    if (state.rotation == null && newestRotation <= state.status.rotationRevision) { delay(100); continue }
                    delay(if (newestRotation > state.status.rotationRevision) 10 else 250)
                    val next = transport.snapshot(state.position, "snapshot")
                    observe(next.status.revision)
                    verify(next.position == state.position && !next.status.suspended, "GROUP_CHANGED")
                    state = next
                }
            } finally { leasing.cancel(); retirement?.cancel() }
        } finally {
            media?.gate?.revoke()
            media?.pause()
            watcher.cancel()
            trustWatcher.cancel()
            heartbeat.cancel()
        }
    }
}
