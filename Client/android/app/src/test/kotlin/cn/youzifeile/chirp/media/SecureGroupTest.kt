package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SecureGroupTest {
    private val room = RoomInfo("friends", "Friends", false, false, GROUP_PROTOCOL, 0, "available", emptyList())
    private val entry = Admission(room, "entry", "self", 3600, "wss://example.test", MediaAccess("test", 3600))
    private val position = GroupPosition("friends", "server", "session", 1UL)
    private fun session(): SessionRepository {
        val url = "https://example.test/".toHttpUrl()
        val connection = ServerConnection(url, url, url, null, url, url, url, url, "friends", null)
        return SessionRepository(connection, Login("test", "self", "Self", 3600), ChirpHttp())
    }

    @Test fun delayedActivationKeepsRenewingTheAcknowledgedEpochWithoutReinstallingMedia() = delayedActivation(true)
    @Test fun anUnacknowledgedCutoverCannotRenewOrResurrectAnExpiredLease() = delayedActivation(false)

    private fun delayedActivation(confirmedBeforeExpiry: Boolean) = runTest {
        val native = FakeNative()
        val service = FakeService(position)
        val dispatcher = StandardTestDispatcher(testScheduler)
        var installations = 0
        var paused = 0
        var switched = 0
        val retired = mutableListOf<Int>()
        val gate = MediaGate(position.groupID, { testScheduler.currentTime }, { testScheduler.currentTime })
        val media = object : GroupMedia {
            override val gate = gate
            override fun granted(index: Int) {}
            override fun pause() { paused++; gate.revoke() }
            override suspend fun prepareKeys(keys: Map<String, ByteArray>, index: Int) { assertEquals(1, index); assertEquals(setOf("self"), keys.keys) }
            override suspend fun switchKeys(index: Int) { switched++; assertEquals(1, index) }
            override fun retireKeys(index: Int) { retired += index }
        }
        val worker = backgroundScope.launch(dispatcher) {
            SecureGroup(session(), entry, { _, _ -> installations++; media }, {}, { native }, { _, _, _ -> service },
                { testScheduler.currentTime }, { testScheduler.currentTime }, dispatcher).run()
        }
        runCurrent()
        assertTrue(gate.remaining() > 0)
        service.rotate()
        advanceTimeBy(1600); runCurrent()
        assertEquals(0, switched)
        assertFalse(gate.maySend(1))
        assertTrue(service.leases.size >= 2)
        assertTrue(service.leases.all { it == 0UL })
        assertTrue(gate.remaining() > 0)
        // Go has applied this member's new epoch. Its activation response is still in flight.
        service.rejectOldLease = true
        advanceTimeBy(500); runCurrent()
        assertEquals(1, service.rejectedLeases)
        assertTrue(gate.remaining() > 0)
        if (!confirmedBeforeExpiry) {
            advanceTimeBy(1_950); runCurrent()
            assertEquals(0L, gate.remaining())
            assertTrue(paused > 0)
            service.activation.complete(Unit)
            runCurrent()
            assertEquals(0L, gate.remaining())
            assertFalse(service.leases.contains(1UL))
            worker.cancelAndJoin()
            return@runTest
        }
        service.nextLease = CompletableDeferred()
        service.activation.complete(Unit)
        runCurrent()
        assertEquals(1UL, service.leases.last())
        assertEquals(0, switched)
        assertTrue(gate.maySend(0))
        assertNull(gate.receiveEpoch(1))
        service.nextLease!!.complete(Unit)
        runCurrent()
        assertEquals(1, switched)
        assertTrue(gate.maySend(1))
        assertFalse(gate.maySend(0))
        advanceTimeBy(1600); runCurrent()
        assertTrue(service.leases.contains(1UL)); assertEquals(listOf(0), retired)
        assertEquals(1, installations); assertEquals(0, paused)
        assertEquals(1, native.activations)
        worker.cancelAndJoin()
        assertEquals(0, gate.remaining())
    }

    @Test fun aMediaLeaseCannotOutlastTheNativeMlsKeyEvenWhenTheServerGrantsLonger() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val service = FakeService(position)
        val media = TestMedia(MediaGate(position.groupID, { testScheduler.currentTime }, { testScheduler.currentTime }))
        val worker = backgroundScope.launch(dispatcher) {
            SecureGroup(session(), entry, { _, _ -> media }, {}, { FakeNative(650) }, { _, _, _ -> service },
                { testScheduler.currentTime }, { testScheduler.currentTime }, dispatcher).run()
        }
        runCurrent()
        assertTrue(media.gate.remaining() in 1..650)
        advanceTimeBy(400); runCurrent()
        assertTrue(media.gate.remaining() in 1..250)
        advanceTimeBy(251); runCurrent()
        assertEquals(0L, media.gate.remaining())
        worker.cancelAndJoin()
    }

    @Test fun trustAndRevisionHintsWakeSetupButOnlyVerifiedReadyStateCanGrantMedia() = runTest {
        val service = FakeService(position)
        service.trustReady.value = false
        service.state = service.state.copy(status = service.state.status.copy(phase = "collecting"))
        val dispatcher = StandardTestDispatcher(testScheduler)
        val gate = MediaGate(position.groupID, { testScheduler.currentTime }, { testScheduler.currentTime })
        val worker = backgroundScope.launch(dispatcher) {
            SecureGroup(session(), entry, { _, _ -> TestMedia(gate) }, {}, { FakeNative() }, { _, _, _ -> service },
                { testScheduler.currentTime }, { testScheduler.currentTime }, dispatcher).run()
        }
        runCurrent()
        advanceTimeBy(10)
        service.trustReady.value = true
        runCurrent()
        assertTrue(service.verifiedSnapshots > 0)
        assertTrue(service.leases.isEmpty())
        advanceTimeBy(10)
        service.state = service.state.copy(status = service.state.status.copy(revision = 2UL, phase = "ready"))
        service.hints.value = 2UL to 0UL
        runCurrent()
        assertTrue(gate.remaining() > 0)
        worker.cancelAndJoin()
    }

    @Test fun anAuthorityRevisionRevokesMediaBeforeRecoveryCanInstallAnything() = runTest {
        val service = FakeService(position)
        val dispatcher = StandardTestDispatcher(testScheduler)
        val media = TestMedia(MediaGate(position.groupID, { testScheduler.currentTime }, { testScheduler.currentTime }))
        var installations = 0
        val worker = backgroundScope.launch(dispatcher) {
            SecureGroup(session(), entry, { _, _ -> installations++; media }, {}, { FakeNative() }, { _, _, _ -> service },
                { testScheduler.currentTime }, { testScheduler.currentTime }, dispatcher).run()
        }
        runCurrent(); assertTrue(media.gate.remaining() > 0)
        service.state = service.state.copy(status = service.state.status.copy(revision = 2UL))
        service.hints.value = 2UL to 0UL
        runCurrent()
        assertEquals(0L, media.gate.remaining()); assertTrue(media.paused > 0); assertEquals(1, installations)
        worker.cancelAndJoin()
    }

    @Test fun legacyCoordinationKeepsTheOriginalLeaseAndDoesNotStageKeys() = runTest {
        val service = FakeService(position, smoothRotation = false)
        val native = FakeNative()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val media = TestMedia(MediaGate(position.groupID, { testScheduler.currentTime }, { testScheduler.currentTime }))
        val worker = backgroundScope.launch(dispatcher) {
            SecureGroup(session(), entry, { _, _ -> media }, {}, { native }, { _, _, _ -> service },
                { testScheduler.currentTime }, { testScheduler.currentTime }, dispatcher).run()
        }
        advanceTimeBy(4200); runCurrent()
        assertTrue(media.gate.remaining() > 0); assertEquals(0, native.activations); assertEquals(0, media.paused)
        assertTrue(service.leases.isNotEmpty()); assertTrue(service.leases.all { it == 0UL })
        worker.cancelAndJoin()
    }

    @Test fun holdingRetainsMembershipWithoutLeasesAndResumesWithFreshMedia() = runTest {
        val service = FakeService(position, smoothRotation = false)
        val held = MutableStateFlow(false)
        val installed = mutableListOf<TestMedia>()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val worker = backgroundScope.launch(dispatcher) {
            SecureGroup(session(), entry.copy(deadline = 2), { _, _ ->
                TestMedia(MediaGate(position.groupID, { testScheduler.currentTime }, { testScheduler.currentTime }))
                    .also(installed::add)
            }, {}, { FakeNative() }, { _, _, _ -> service },
                { testScheduler.currentTime }, { testScheduler.currentTime }, dispatcher).run(held)
        }
        runCurrent()
        val first = installed.single()
        assertTrue(first.gate.remaining() > 0)
        held.value = true
        runCurrent()
        val leasesBeforeHold = service.leases.size
        advanceTimeBy(31_000); runCurrent()
        assertEquals(0L, first.gate.remaining())
        assertTrue(service.heartbeats > 12)
        assertEquals(leasesBeforeHold, service.leases.size)
        held.value = false
        runCurrent()
        assertEquals(2, installed.size)
        assertTrue(installed.last().gate.remaining() > 0)
        assertTrue(service.refreshes > 0)
        worker.cancelAndJoin()
    }

    private class TestMedia(override val gate: MediaGate) : GroupMedia {
        var paused = 0
        override fun granted(index: Int) {}
        override fun pause() { paused++; gate.revoke() }
        override suspend fun prepareKeys(keys: Map<String, ByteArray>, index: Int) { fail("Unexpected staged keys") }
        override suspend fun switchKeys(index: Int) { fail("Unexpected key switch") }
        override fun retireKeys(index: Int) { fail("Unexpected retirement") }
    }

    private class FakeNative(private val lifetime: Long = 120_000) : MlsClient {
        override fun keyLifetimeMillis(staged: Boolean) = lifetime
        override fun authorize(room: MutualRoom) = Unit
        override fun approve(group: String, members: List<GroupMember>, authority: String) = Unit
        var activations = 0
        override val publicKey = "public"
        override fun sign(bytes: ByteArray) = "signature"
        override fun keyPackage() = "package"
        override fun clear() {}
        override fun stagedKeyPackage() = "candidate"
        override fun activateStaged(groupID: String) { activations++ }
        override fun createStaged(groupID: String, members: List<GroupMember>) = buildJsonObject { put("welcome", "welcome"); put("confirmation", "confirmation") }
        override fun joinStaged(groupID: String, members: List<GroupMember>, welcome: String) = "confirmation"
        override fun create(group: GroupSnapshot) = createStaged("", group.members)
        override fun join(group: GroupSnapshot) = "confirmation"
        override fun key(identity: String, staged: Boolean) = ByteArray(32) { if (staged) 2 else 1 }
        override fun close() {}
    }

    private class FakeService(val position: GroupPosition, override val smoothRotation: Boolean = true) : GroupServing {
        override val trustReady = MutableStateFlow(true)
        var verifiedSnapshots = 0
        override suspend fun approve(state: GroupSnapshot, rotation: GroupRotation?): Boolean {
            if (trustReady.value) verifiedSnapshots++
            return trustReady.value
        }
        override fun contentMillis(members: List<GroupMember>) = 60_000L
        val peer = GroupMember("self", "Self", "public", "package")
        var state = GroupSnapshot(GroupStatus(position, 1UL, "ready", false), "self", listOf(peer), "welcome", "confirmation")
        val hints = MutableStateFlow(1UL to 0UL)
        val leases = mutableListOf<ULong>()
        val activation = CompletableDeferred<Unit>()
        var nextLease: CompletableDeferred<Unit>? = null
        var rejectOldLease = false
        var rejectedLeases = 0
        var heartbeats = 0
        var refreshes = 0
        override suspend fun config() = position
        override fun watch(position: GroupPosition): Flow<Pair<ULong, ULong>> = hints
        fun rotate() {
            state = state.copy(status = state.status.copy(rotationRevision = 1UL), rotation = GroupRotation(1UL, "collecting", listOf(peer), "", ""))
            hints.value = 1UL to 1UL
        }
        override suspend fun snapshot(position: GroupPosition, action: String, fields: JsonObject): GroupSnapshot {
            if (action == "refresh") refreshes++
            val phase = when (action) {
                "rotation_package" -> "welcoming"
                "rotation_publish" -> "confirming"
                "rotation_ack" -> "switching"
                else -> null
            }
            if (phase != null) state = state.copy(rotation = state.rotation!!.copy(phase = phase, welcome = "welcome", confirmation = "confirmation"))
            if (action == "rotation_activate") {
                activation.await()
                state = state.copy(status = state.status.copy(keyEpoch = 1UL, rotationRevision = 2UL), rotation = null)
                hints.value = 1UL to 2UL
            }
            return state
        }
        override suspend fun pulse(state: GroupSnapshot, action: String, epoch: ULong): GroupPulse {
            if (action == "heartbeat") heartbeats++
            if (action == "lease") {
                leases += epoch
                if (rejectOldLease && epoch == 0UL) {
                    rejectedLeases++
                    throw ChirpException("GROUP_CHANGED", 409)
                }
                assertEquals(this.state.status.keyEpoch, epoch)
                if (epoch == 1UL) nextLease?.await()
            }
            return GroupPulse(this.state.status, if (action == "lease") 3000 else 0)
        }
    }
}
