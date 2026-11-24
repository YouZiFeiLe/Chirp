package cn.youzifeile.chirp.media

import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.lifecycle.viewModelScope
import cn.youzifeile.chirp.ChirpApplication
import cn.youzifeile.chirp.ui.MainViewModel
import cn.youzifeile.chirp.ui.qrBitmap
import cn.youzifeile.chirp.ui.readPairingQrImage
import cn.youzifeile.chirp.ui.savePairingQrToGallery
import kotlinx.coroutines.flow.first
import cn.youzifeile.chirp.data.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

class GroupProtocolTest {
    private fun fixture(): JsonObject {
        val instrument = InstrumentationRegistry.getInstrumentation()
        val filename = InstrumentationRegistry.getArguments().getString("attachment_fixture")
        assumeTrue("Run scripts/test-android-protocol.py for the isolated Go fixture", filename != null)
        return parseObject(File(instrument.targetContext.getExternalFilesDir(null), filename!!).readBytes())
    }

    @Test fun firstLoginResumesBackupAndCompletesDeviceActivation() = runBlocking<Unit> {
        val fixture = fixture()
        val http = ChirpHttp()
        val server = ServerRepository(http)
        val connection = server.discover(fixture.text("url"))
        val vault = IdentityVault(InstrumentationRegistry.getInstrumentation().targetContext)
        val verifier = fixture.text("setup_verifier")
        val request = DeviceLogin(fixture.text("setup_request"), verifier, connection.deviceVerify, nowSeconds() + 60, 1)
        assertTrue(connection.nativeLogin)
        val native = NativeLogin.create(connection, taskId = 42)
        val authorization = native.authorizationURL(connection)
        val (_, callback) = http.json(connection.origin.path("test", "native-authorization").request().jsonPost(
            kotlinx.serialization.json.buildJsonObject {
                for (field in authorization.queryParameterNames) {
                    put(field, kotlinx.serialization.json.JsonPrimitive(requireNotNull(authorization.queryParameter(field))))
                }
            }).build())
        // A fresh activity model receives the browser return after the original process was lost.
        vault.savePendingLogin(native)
        val application = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as ChirpApplication
        val offset = AtomicLong(0)
        val firstReply = CompletableDeferred<Unit>()
        val networkClock = NetworkClock(wallMillis = { System.currentTimeMillis() + offset.get() }) {
            firstReply.await()
            listOf(NetworkTimeSample(System.currentTimeMillis(), SystemClock.elapsedRealtime(), 0))
        }
        val restored = withContext(Dispatchers.Main) { MainViewModel(application, restoreOnStart = false, taskId = 42, networkClock = networkClock) }
        val requireClock = { verify(networkClock.read().ready, "NETWORK_TIME_REQUIRED") }
        val setup = try {
            val uri = callback.text("callback")
            withContext(Dispatchers.Main) {
                restored.state.first { !it.checking }
                restored.loginCallback(uri.replace(native.state, "unrelated-state"))
                assertEquals(ClockStatus.Checking, restored.state.value.clock.status)
                assertNull(restored.state.value.error)
                firstReply.complete(Unit)
            }
            withTimeout(10_000) { restored.state.first { it.error?.code == "INVALID_LOGIN_CALLBACK" } }
            withContext(Dispatchers.Main) {
                offset.set(30_000)
                restored.loginCallback(uri)
                assertEquals(ClockStatus.OutOfSync, restored.state.value.clock.status)
            }
            assertEquals(native, vault.pendingLogin())
            offset.set(0)
            restored.loginCallback(uri)
            withTimeout(10_000) { restored.state.first { it.setupStep != null } }
            assertNull(vault.pendingLogin())
            requireNotNull(restored.setup)
        } finally { withContext(Dispatchers.Main) { restored.viewModelScope.cancel() } }
        val grant = setup.grant
        assertEquals(SetupStep.Create, setup.step)
        val password = " 设备恢复 interop password 🔑 "
        setup.create(password, password)
        assertEquals(SetupStep.Export, setup.step)
        val backup = setup.backupBytes()
        setup.exported()
        assertTrue(setup.filename.endsWith("_Android.chirpkey"))
        val originalCandidate = requireNotNull(setup.record.candidate)
        val scope = IdentitySetup.scope(grant.origin, grant.account)
        vault.write(scope, wireJson.encodeToString(setup.record.copy(candidate = null)))
        var clock = 0L
        val resumed = IdentitySetup(grant, native.verifier, connection, http, vault) { clock }
        resumed.load()
        assertEquals(SetupStep.Resume, resumed.step)
        assertTrue(runCatching { resumed.resume("wrong password") }.isFailure)
        assertEquals(SetupStep.Resume, resumed.step)
        resumed.resume(password)
        assertEquals(SetupStep.Saved, resumed.step)
        val rebuilt = requireNotNull(resumed.record.candidate)
        assertEquals(originalCandidate.device.accountKey, rebuilt.device.accountKey)
        assertNotEquals(originalCandidate.device.leaf, rebuilt.device.leaf)
        assertArrayEquals(backup, resumed.backupBytes())
        assertTrue(runCatching { resumed.verifyBackup(backup, "wrong password") }.isFailure)
        assertFalse(resumed.backupVerified)
        resumed.verifyBackup(backup, password)
        assertTrue(resumed.backupVerified)
        resumed.setConfirmationVisible(true)
        clock += 8_000
        assertEquals(5, resumed.confirmationSeconds())
        assertTrue(runCatching { resumed.confirmBackup() }.isFailure)
        resumed.showConfirmation()
        assertEquals(SetupStep.Confirm, resumed.step)
        resumed.setConfirmationVisible(true)
        clock += 4_000
        resumed.backToSave()
        resumed.showConfirmation()
        assertEquals(5, resumed.confirmationSeconds())
        resumed.setConfirmationVisible(true)
        clock += 2_000
        resumed.setConfirmationVisible(false)
        clock += 120_000
        assertEquals(3, resumed.confirmationSeconds())
        assertTrue(runCatching { resumed.confirmBackup() }.isFailure)
        resumed.setConfirmationVisible(true)
        clock += 3_000
        resumed.confirmBackup()
        val confirmed = IdentitySetup(grant, native.verifier, connection, http, vault)
        confirmed.load()
        assertEquals(SetupStep.Resume, confirmed.step)
        confirmed.resume(password)
        assertEquals(SetupStep.Activate, confirmed.step)
        val login = confirmed.finish(requireClock)
        assertEquals(rebuilt.device, login.device)
        val saved = vault.savedIdentities().single { it.scope == scope }
        assertEquals(rebuilt.device.accountKey, saved.root)
        assertEquals(grant.username, saved.name)
        val pairedGrant = requireNotNull(server.poll(connection, request.copy(requestID = fixture.text("pairing_request"))))
        val pairing = IdentitySetup(pairedGrant,verifier,connection,http,vault)
        val previous = requireNotNull(confirmed.record.active)
        fun account(login: Login, local: LocalDevice) =
            AccountIdentity(SessionRepository(connection, login, http), local, vault, fixture.text("authorization_key"))
        val primary = account(login, previous)
        primary.refresh()
        val secondary = DevicePairing.create(pairing,http,requireClock).use { candidate ->
            val resolver = application.contentResolver
            val qr = qrBitmap(candidate.request.code())
            val image = try { savePairingQrToGallery(resolver, qr) } finally { qr.recycle() }
            val imported = try { PairRequest.parse(readPairingQrImage(resolver, image)) }
                finally { resolver.delete(image, null, null) }
            DevicePairing.approve(imported,previous,connection,http,requireClock).use { approver ->
                approver.poll(); candidate.poll(); approver.poll()
                assertEquals(3, approver.decimals.size)
                assertEquals(approver.decimals, candidate.decimals)
                candidate.confirm(null,false)
                var unlocks = 0
                val mismatch = runCatching { approver.confirm("0000 0000 0000", false) { unlocks++; true } }
                assertEquals("PAIR_CODE_MISMATCH", (mismatch.exceptionOrNull() as? ChirpException)?.code)
                assertEquals(0, unlocks)
                val code = candidate.decimals.joinToString(" ")
                val cancelled = runCatching { approver.confirm(code, false) { unlocks++; false } }
                assertEquals("PAIR_UNLOCK_REQUIRED", (cancelled.exceptionOrNull() as? ChirpException)?.code)
                assertFalse(approver.confirmed)
                val drifted = runCatching { approver.confirm(code, false) { offset.set(-30_000); true } }
                assertEquals("NETWORK_TIME_REQUIRED", (drifted.exceptionOrNull() as? ChirpException)?.code)
                assertFalse(approver.confirmed)
                offset.set(0)
                approver.confirm(code, false) { unlocks++; true }
                assertEquals(2, unlocks)
                approver.poll(); candidate.poll()
                val child = requireNotNull(candidate.approval)
                assertFalse(child.certificates.last().canEnroll)
                pairing.paired(child)
                val childLogin = pairing.finish(requireClock)
                assertEquals(child, childLogin.device)
                val secondary = account(childLogin, requireNotNull(pairing.record.active))
                secondary.refresh()
                secondary.rename(child.leaf, "Android test device")
                assertNotNull(secondary.view.value.devices[child.leaf]?.lastLogin)
                secondary
            }
        }
        val recoveryGrant = requireNotNull(server.poll(connection, request.copy(requestID = fixture.text("recovery_request"))))
        val recovery = IdentitySetup(recoveryGrant, verifier, connection, http, vault)
        recovery.restore(backup, password)
        assertEquals(previous.device.accountKey, recovery.record.candidate?.device?.accountKey)
        assertNotEquals(previous.device.leaf, recovery.record.candidate?.device?.leaf)
        val recovered = account(recovery.finish(requireClock), requireNotNull(recovery.record.active))
        recovered.refresh()
        assertTrue(recovered.view.value.synced)
        assertTrue(previous.device.leaf in recovered.view.value.devices)
        val child = secondary.local.device
        assertEquals("Android test device", recovered.view.value.devices[child.leaf]?.name)
        recovered.revoke(child.leaf)
        assertTrue(child.leaf in recovered.view.value.revoked)
        assertFalse(recovered.active(login.memberID, child))
        assertTrue(recovered.blocked(login.memberID, child))
        assertFalse(recovered.blocked(login.memberID, previous.device))
        assertEquals("IDENTITY_BLACKLISTED", (runCatching { secondary.refresh() }.exceptionOrNull() as? ChirpException)?.code)
        val room = RoomInfo(connection.defaultRoom, "Fixture", false, false, GROUP_PROTOCOL, 0, "available", emptyList())
        val entry = Admission(room, "fixture-owner", recovered.session.login.identity, nowSeconds() + 30, "", MediaAccess("", 0))
        val policy = MutualRoom(connection.passkeyOrigin.identityOrigin, room.id)
        val peer = secondary.session.login.identity
        val binding = EntryBinding(child, policy.origin, room.id, policy.trust, policy.hash, peer,
            base64(randomBytes(32)), base64(randomBytes(32)), nowSeconds(), nowSeconds() + 30)
        val signed = binding.copy(signature = secondary.local.sign(binding.message()))
        RoomTrust(recovered, entry) {}.use { trust ->
            val member = GroupMember(peer, "Paired child", binding.mls, "", signed)
            signed.validate(policy, member, nowSeconds())
            val denied = runCatching { trust.update(listOf(member)) }.exceptionOrNull() as? ChirpException
            assertEquals("ROOM_IDENTITY_REVOKED", denied?.code)
        }

        recovered.session.accountIdentity = recovered
        verifyAdmissionOwnership(recovered.session, room)

        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as ChirpApplication
        withContext(Dispatchers.Main) {
            val model = MainViewModel(app, restoreOnStart = false)
            try {
                model.activateSession(recovered.session, recovered.local, fixture.text("authorization_key"))
                assertNull(model.state.value.directory)
                repeat(2) {
                    model.setDirectoryVisible(true)
                    withTimeout(10_000) { model.state.first { it.directory?.fresh == true && it.identity.synced } }
                    model.setDirectoryVisible(false)
                    assertEquals(false, model.state.value.directory?.fresh)
                }
                val startedLogout = CompletableDeferred<Unit>()
                val releaseLogout = CountDownLatch(1)
                val unavailable = ChirpHttp(OkHttpClient.Builder().addInterceptor { chain ->
                    if (chain.request().url.pathSegments.last() == "logout") {
                        startedLogout.complete(Unit)
                        check(releaseLogout.await(5, TimeUnit.SECONDS))
                        throw java.io.IOException("offline")
                    }
                    chain.proceed(chain.request())
                })
                val signingOut = SessionRepository(connection, recovered.session.login, unavailable)
                model.activateSession(signingOut, recovered.local, fixture.text("authorization_key"))
                try {
                    model.logout()
                    assertNull(model.state.value.account)
                    withTimeout(3_000) { startedLogout.await() }
                    assertNull(model.state.value.profileSession)
                } finally { releaseLogout.countDown() }
                withTimeout(3_000) { model.state.first { it.error?.code == "LOGOUT_OFFLINE" } }
                val disabledHttp = ChirpHttp(OkHttpClient.Builder().addInterceptor { chain ->
                    Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                        .code(403).message("fixture").body("""{"error":{"code":"MEMBER_DISABLED"}}""".toResponseBody()).build()
                })
                val background = SessionRepository(connection, recovered.session.login, disabledHttp)
                model.activateSession(background, recovered.local, fixture.text("authorization_key"))
                val disabled = runCatching { background.profile() }.exceptionOrNull() as? ChirpException
                assertEquals("MEMBER_DISABLED", disabled?.code)
                withTimeout(2_000) { model.state.first { it.account == null && it.error?.code == "MEMBER_DISABLED" } }
            } finally {
                model.setDirectoryVisible(false)
                model.viewModelScope.cancel()
            }
        }
    }

    private suspend fun verifyAdmissionOwnership(session: SessionRepository, room: RoomInfo) = coroutineScope {
        val active = session.join(room, "")
        try {
            val sequence = session.validateLogin()
            val mismatchedProfile = ChirpHttp(OkHttpClient.Builder().addInterceptor { chain ->
                if (chain.request().url.pathSegments.last() != "me") chain.proceed(chain.request())
                else Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("fixture")
                    .body(Profile("member_0123456789abcdef", "Another account", 1).toWire().toString().toResponseBody()).build()
            })
            val wrongAccount = SessionRepository(session.connection, session.login, mismatchedProfile).also {
                it.accountIdentity = session.accountIdentity
            }
            val rejected = runCatching { wrongAccount.join(room, "") }.exceptionOrNull() as? ChirpException
            assertEquals("INVALID_RESPONSE", rejected?.code)
            assertEquals(sequence, session.validateLogin())
            assertTrue(session.refreshMedia(active).deadline > nowSeconds())
            val otherPolicy = session.connection.copy(passkeyOrigin = "https://other-authority.example/".toHttpUrl())
            val mismatch = SessionRepository(otherPolicy, session.login, session.http).also { it.accountIdentity = session.accountIdentity }
            val error = runCatching { mismatch.join(room, "") }.exceptionOrNull() as? ChirpException
            assertEquals("IDENTITY_INVALID", error?.code)
            assertEquals(sequence, session.validateLogin())
            assertTrue(session.refreshMedia(active).token.isNotEmpty())
        } finally { session.leave(active) }

        // Stop the caller after the real Go server has committed, before OkHttp delivers the response.
        val committed = CompletableDeferred<Admission>()
        val deliver = CountDownLatch(1)
        val http = ChirpHttp(OkHttpClient.Builder().addInterceptor { chain ->
            val response = chain.proceed(chain.request())
            if (response.isSuccessful && chain.request().url.pathSegments.last() == "join") {
                val joined = parseObject(response.peekBody(65_536).bytes())
                committed.complete(active.copy(entryID = joined.text("entry_id"), identity = joined.text("participant_identity")))
                check(deliver.await(6, TimeUnit.SECONDS))
            }
            response
        })
        val delayed = SessionRepository(session.connection, session.login, http).also { it.accountIdentity = session.accountIdentity }
        val joining = launch { delayed.join(room, "") }
        val entry = try {
            withTimeout(5_000) { committed.await() }.also { joining.cancel() }
        } finally { deliver.countDown() }
        joining.join()
        assertTrue(joining.isCancelled)
        val released = runCatching { session.refreshMedia(entry) }.exceptionOrNull() as? ChirpException
        assertEquals("ADMISSION_CHANGED", released?.code)
    }

    private suspend fun groupSession(fixture: JsonObject, connection: ServerConnection, client: JsonObject, http: ChirpHttp): SessionRepository {
        val local = LocalDevice(client.text("seed"), client.obj("device").decode())
        val credential = client.text("credential")
        val sessionState = http.json(connection.api.path("v1","session").request(credential).build()).second
        val login = Login(credential, client.text("identity").substringBeforeLast('.'), "Fixture", sessionState.long("expires_at"), local.device)
        val session = SessionRepository(connection, login, http)
        session.accountIdentity = AccountIdentity(session, local, IdentityVault(InstrumentationRegistry.getInstrumentation().targetContext),
            fixture.text("authorization_key"))
        session.accountIdentity.refresh()
        return session
    }

    private suspend fun verifyThreeMembers(trusts: List<RoomTrust>, views: Array<RoomTrustView>,
        sessions: List<SessionRepository>, entries: List<Admission>) {
        val (a, b) = listOf(0, 1).sortedBy { entries[it].identity }
        val c = 2
        suspend fun start(from: Int, to: Int, previous: String? = null): String {
            trusts[from].act("start", entries[to].identity, previous)
            return requireNotNull(views[from].verification).id
        }
        suspend fun poll(vararg participants: Int) {
            for (index in participants) trusts[index].pollSignals()
        }
        fun expectBusy(from: Int, to: Int, tx: String) {
            assertNull(views[from].verification)
            assertEquals(VerificationNotice(tx, entries[to].identity, VerificationPhase.PeerBusy), views[from].notice)
            assertNull(views[from].failure)
        }
        suspend fun sendPacket(from: Int, to: Int, tx: String, packet: String) {
            val session = sessions[from]
            val account = session.accountIdentity
            val envelope = buildJsonObject { put("transaction", tx); put("message", packet) }
            val signal = IdentitySignal(base64(randomBytes(32)), account.origin, entries[from].room.id,
                session.login.memberID, sessions[to].login.memberID, entries[from].identity, entries[to].identity,
                "sas", envelope.toString(), nowSeconds() + 120, account.local.device)
            val body = signal.copy(signature = account.local.sign(signal.message())).toWire()
            session.http.json(session.api("identity", "signals").request(session.login.credential).jsonPost(body).build(), setOf(204, 200))
        }
        suspend fun compare(from: Int, to: Int, tx: String): List<Int> {
            assertEquals(tx, views[to].verification?.id)
            assertNotNull(views[to].verification?.commitment)
            trusts[to].act("accept", entries[from].identity, tx)
            poll(from, to)
            val codes = requireNotNull(views[from].verification).numbers
            assertEquals(3, codes.size)
            assertEquals(codes, views[to].verification?.numbers)
            return codes
        }
        suspend fun finish(from: Int, to: Int, tx: String) {
            if (views[from].verification?.confirmed != true) trusts[from].act("confirm", entries[to].identity, tx)
            trusts[to].act("confirm", entries[from].identity, tx)
            poll(from, to)
            for (index in listOf(from, to)) assertEquals(VerificationPhase.Verified, views[index].notice?.phase)
            assertTrue(entries[to].identity in views[from].trusted && entries[from].identity in views[to].trusted)
        }

        // Two requests are already in B's inbox when it first polls.
        val first = start(a, b)
        val queued = start(c, b)
        poll(b, c)
        assertEquals(first, views[b].verification?.id)
        expectBusy(c, b, queued)
        val request = buildJsonObject { put("kind", "Request"); put("commitment", requireNotNull(views[b].verification?.commitment)) }.toString()
        trusts[b].act("cancel", entries[a].identity, first)
        poll(a)
        assertEquals(VerificationPhase.PeerCancelled, views[a].notice?.phase)
        sendPacket(a, b, first, request)
        poll(b)
        assertEquals(VerificationPhase.Cancelled, views[b].notice?.phase)
        assertNull(views[b].verification)

        val ab = start(a, b)
        val crossed = start(b, a)
        poll(b, a)
        assertEquals(ab, views[a].verification?.id)
        assertEquals(ab, views[b].verification?.id)
        assertTrue(requireNotNull(views[a].verification).awaitingAcceptance)
        trusts[b].act("cancel", entries[a].identity, crossed)
        trusts[a].act("start", entries[c].identity)
        val ca = start(c, a)
        val busy = """{"kind":"Busy"}"""
        sendPacket(b, c, ca, busy)
        poll(c)
        assertEquals(ca, views[c].verification?.id)
        poll(a, c)
        expectBusy(c, a, ca)
        val codes = compare(a, b, ab)
        trusts[a].act("confirm", entries[b].identity, ab)
        sendPacket(a, b, base64(randomBytes(32)), request)
        val cb = start(c, b)
        poll(b, c)
        expectBusy(c, b, cb)
        assertEquals(true, views[a].verification?.confirmed)
        assertEquals(codes, views[a].verification?.numbers)
        assertEquals(codes, views[b].verification?.numbers)
        assertTrue(views.all { it.trusted.isEmpty() && it.pending })
        finish(a, b, ab)

        val retry = start(c, b, cb)
        assertNotEquals(cb, retry)
        sendPacket(b, c, cb, busy)
        poll(c, b)
        assertEquals(retry, views[c].verification?.id)
        compare(c, b, retry)
        sendPacket(b, c, retry, busy)
        poll(c)
        assertEquals(3, views[c].verification?.numbers?.size)
        finish(c, b, retry)
        val last = start(c, a)
        poll(a)
        compare(c, a, last)
        finish(c, a, last)
    }

    @Test fun threeMembersVerifyBusyPeersAndKeepTheRoomUsableAfterOneLeaves() = runBlocking(Dispatchers.Main) {
        val fixture = fixture()
        val clients = (fixture["departure_clients"] as JsonArray).map { it as JsonObject }
        val connection = ServerRepository(ChirpHttp()).discover(fixture.text("url"))
        val room = RoomInfo(clients.first().text("room_id"), "Departure", false, false, GROUP_PROTOCOL, 0, "available", emptyList())
        val departing = clients.last().text("identity")
        val holdBroadcast = AtomicBoolean()
        val started = CompletableDeferred<Unit>()
        val release = CountDownLatch(1)
        val response = CompletableDeferred<Int>()
        val residentHttp = ChirpHttp(OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            if (holdBroadcast.get() && request.method == "POST" && request.url.pathSegments.last() == "signals") {
                val signal = parseObject(Buffer().apply { request.body!!.writeTo(this) }.readByteArray())
                if (signal.text("recipient_entry") == departing && holdBroadcast.compareAndSet(true, false)) {
                    started.complete(Unit)
                    check(release.await(7, TimeUnit.SECONDS))
                    return@addInterceptor chain.proceed(request).also { response.complete(it.code) }
                }
            }
            chain.proceed(request)
        })
        val sessions = clients.mapIndexed { index, client ->
            groupSession(fixture, connection, client, if (index == 0) residentHttp else ChirpHttp())
        }
        val entries = clients.mapIndexed { index, client ->
            Admission(room, client.text("entry_id"), client.text("identity"), sessions[index].login.expiresAt, "", MediaAccess("", 0))
        }
        val media = arrayOfNulls<ProtocolMedia>(clients.size)
        val views = Array(clients.size) { RoomTrustView() }
        val reportedErrors = mutableSetOf<String>()
        val trusts = sessions.mapIndexed { index, session ->
            RoomTrust(session.accountIdentity, entries[index]) { view ->
                views[index] = view
                if (index == 0) view.failure?.let(reportedErrors::add)
            }
        }
        val resumePolling = CompletableDeferred<Unit>()
        val workers = sessions.mapIndexed { index, session -> launch {
            trusts[index].use { trust ->
                val follow = launch { resumePolling.await(); trust.follow() }
                try {
                    SecureGroup(session, entries[index], { state, keys ->
                        ProtocolMedia(state.position.groupID, keys).also { media[index] = it }
                    }, { media[index]?.pause() }, makeTransport = { s, a, n -> GroupTransport(s, a, n, trust) }).run()
                } finally { follow.cancelAndJoin() }
            }
        } }
        suspend fun awaitSecureRoom(current: List<Admission>) = withTimeout(30_000) {
            val identities = current.map { it.identity }.toSet()
            while (!current.indices.all { index ->
                val transport = media[index]
                val peers = views[index].peers.map { it.identity }.toSet()
                !views[index].pending && peers == identities - current[index].identity &&
                    transport != null && transport.gate.remaining() > 0 && transport.activeHashes.keys == identities &&
                    transport.activeHashes == media.first()?.activeHashes
            }) delay(25)
        }
        try {
            withTimeout(20_000) { while (!views.all { it.peers.size == 2 && it.pending }) delay(25) }
            verifyThreeMembers(trusts, views, sessions, entries)
            resumePolling.complete(Unit)
            awaitSecureRoom(entries)
            reportedErrors.clear()
            holdBroadcast.set(true)
            withTimeout(15_000) { started.await() }
            workers.last().cancelAndJoin()
            sessions.last().leave(entries.last())
            release.countDown()
            assertEquals(403, withTimeout(5_000) { response.await() })
            awaitSecureRoom(entries.dropLast(1))
            assertTrue("Departed recipient produced room errors: $reportedErrors", reportedErrors.isEmpty())
        } finally {
            release.countDown()
            workers.forEach { it.cancel() }
            workers.joinAll()
        }
    }

    @Test fun realHttpCoordinatorAndNativeMlsRotateRepeatedlyWithoutReplacingMedia() {
        val fixture = fixture()
        val origin = fixture.text("url").toHttpUrl()
        val clients = (fixture["clients"] as JsonArray).take(2).map { it as JsonObject }
        val connection = ServerConnection(origin, origin, origin.newBuilder().addPathSegments("v1/group/").build(),
            null, origin, origin, origin, origin, clients[0].text("room_id"), null)
        val room = RoomInfo(clients[0].text("room_id"), "Fixture", false, true, GROUP_PROTOCOL, 0, "available", emptyList())
        runBlocking(Dispatchers.Main) {
            val jobs = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val media = arrayOf<ProtocolMedia?>(null, null)
            val trusts = arrayOfNulls<RoomTrust>(2)
            val views = Array(2) { RoomTrustView() }
            val installs = intArrayOf(0, 0)
            val lastPulseFailure = arrayOfNulls<String>(2)
            val residentHasSoloRoster = CompletableDeferred<Unit>()
            val releaseNewRoster = CompletableDeferred<Unit>()
            val failures = mutableListOf<Throwable>()
            val failSignalReads = AtomicInteger()
            val successfulSignalReads = AtomicInteger()
            val reportedErrors = mutableSetOf<String>()
            val sessions = clients.mapIndexed { index, client ->
                val http = if (index != 0) ChirpHttp() else ChirpHttp(OkHttpClient.Builder().addInterceptor { chain ->
                    val request = chain.request()
                    if (request.method != "GET" || "signals" !in request.url.pathSegments) return@addInterceptor chain.proceed(request)
                    if (failSignalReads.getAndUpdate { (it - 1).coerceAtLeast(0) } > 0) throw java.io.IOException("interrupted identity poll")
                    chain.proceed(request).also { if (it.isSuccessful) successfulSignalReads.incrementAndGet() }
                })
                groupSession(fixture, connection, client, http)
            }
            // A discovery entry that cannot be authorized must not replace the current admission.
            val existingSequence = sessions.first().validateLogin()
            val failure = runCatching { sessions.first().join(room.copy(id = "missing-parity-room"), "") }.exceptionOrNull()
            assertEquals(404, (failure as? ChirpException)?.status)
            assertEquals(existingSequence, sessions.first().validateLogin())
            val workers = clients.mapIndexed { index, client -> jobs.launch {
                val identity = client.text("identity")
                val session = sessions[index]
                val admission = Admission(room, client.text("entry_id"), identity, session.login.expiresAt,
                    "wss://unused.example", MediaAccess("unused",session.login.expiresAt))
                val trust = RoomTrust(session.accountIdentity, admission) {
                    views[index] = it
                    if (index == 0) it.failure?.let(reportedErrors::add)
                }
                trusts[index] = trust
                val signals = launch {
                    if (index == 1) releaseNewRoster.await()
                    trust.follow()
                }
                try {
                    SecureGroup(session, admission, { state, keys ->
                        installs[index]++
                        ProtocolMedia(state.position.groupID, keys).also { media[index] = it }
                    }, { media[index]?.pause() }, makeTransport = { s, a, n ->
                        val coordinator = GroupTransport(s, a, n, trust)
                        object : GroupServing by coordinator {
                            override suspend fun approve(state: GroupSnapshot, rotation: GroupRotation?): Boolean {
                                if (index == 1 && state.members.size == 2 && !releaseNewRoster.isCompleted) {
                                    trust.update(state.members.filter { it.identity == identity })
                                    residentHasSoloRoster.complete(Unit)
                                    releaseNewRoster.await()
                                }
                                return coordinator.approve(state, rotation)
                            }
                            override suspend fun pulse(state: GroupSnapshot, action: String, epoch: ULong): GroupPulse {
                                try { return coordinator.pulse(state, action, epoch) }
                                catch (failure: java.io.IOException) {
                                    val cause = (failure as? ChirpException)?.let { "${it.status}/${it.code}" } ?: failure.javaClass.simpleName
                                    lastPulseFailure[index] = "$action epoch=$epoch error=$cause"
                                    throw failure
                                }
                            }
                        }
                    }).run()
                } catch (e: CancellationException) { throw e }
                catch (e: Throwable) { failures += e }
                finally { signals.cancelAndJoin(); trust.close() }
            } }
            try {
                suspend fun awaitCondition(stage: String, check: () -> Boolean) {
                    val reached = withTimeoutOrNull(20000) {
                        while (!check()) { failures.firstOrNull()?.let { throw it }; delay(25) }
                        true
                    }
                    assertTrue("$stage: " + views.map { "peers=${it.peers.size}, pending=${it.pending}, error=${it.failure}" }, reached == true)
                }
                awaitCondition("sender sees the entrant") { views[0].peers.size == 1 && views[0].pending && residentHasSoloRoster.isCompleted }
                trusts[0]!!.act("start", views[0].peers.single().identity)
                trusts[1]!!.pollSignals()
                assertNull("An invitation from outside the current roster cannot be shown", views[1].verification)
                assertFalse("Media requires mutual trust", media[0]?.ready == true)
                releaseNewRoster.complete(Unit)
                awaitCondition("SAS request") { views[1].verification?.commitment != null }
                trusts[1]!!.act("cancel")
                awaitCondition("invitation cancelled") {
                    views[1].notice?.phase == VerificationPhase.Cancelled && views[0].notice?.phase == VerificationPhase.PeerCancelled
                }
                assertTrue(views.all { it.trusted.isEmpty() && it.pending })
                trusts[0]!!.act("start", views[0].peers.single().identity)
                awaitCondition("new SAS request") { views[1].verification?.commitment != null }
                trusts[1]!!.act("accept")
                awaitCondition("SAS codes") { views.all { it.verification?.numbers?.size == 3 } }
                assertEquals(views[0].verification!!.numbers, views[1].verification!!.numbers)
                trusts[0]!!.act("confirm"); trusts[1]!!.act("confirm")
                withTimeout(20000) {
                    while (media.any { it?.ready != true || (it?.gate?.remaining() ?: 0) <= 0 } || media[0]?.gate?.groupID != media[1]?.gate?.groupID) {
                        if (failures.isNotEmpty()) throw failures.first()
                        delay(25)
                    }
                }
                val baseline = installs.copyOf()
                withTimeout(35000) {
                    while (media.any { (it?.switches ?: 0) < 3 }) {
                        if (failures.isNotEmpty()) throw failures.first()
                        for (i in media.indices) {
                            val current = media[i]
                            assertTrue("peer $i: ${current?.leaseStatus()} installs=${installs[i]} trustPending=${views[i].pending} lastFailure=${lastPulseFailure[i]}",
                                (current?.gate?.remaining() ?: 0) > 0)
                        }
                        delay(25)
                    }
                }
                assertArrayEquals(baseline, installs)
                assertEquals(media[0]!!.activeHashes, media[1]!!.activeHashes)
                assertTrue(media.all { it!!.retired.isNotEmpty() })
                assertTrue(views.all { it.notice?.phase == VerificationPhase.Verified && it.friends.size == 1 })
                trusts[0]!!.act("dismiss")
                reportedErrors.clear()
                val lastRead = successfulSignalReads.get()
                failSignalReads.set(1)
                awaitCondition("a successful poll follows the interrupted poll") {
                    failSignalReads.get() == 0 && successfulSignalReads.get() > lastRead + 1
                }
                assertTrue("A transient identity poll appeared as a room error: $reportedErrors", reportedErrors.isEmpty())
                failSignalReads.set(3)
                awaitCondition("persistent identity sync outage is reported") { views[0].failure == "ROOM_TRUST_SYNC_UNAVAILABLE" }
                assertTrue(media.all { (it?.gate?.remaining() ?: 0L) > 0L })
                awaitCondition("identity sync warning clears on recovery") { views[0].failure == null }
                trusts[0]!!.act("start", "absent-peer")
                val recoveredRead = successfulSignalReads.get()
                awaitCondition("background polling continues after a rejected action") { successfulSignalReads.get() > recoveredRead + 1 }
                assertEquals("IDENTITY_INVALID", views[0].failure)
                trusts[0]!!.act("dismiss")
                val peer = views[0].peers.single()
                val device = peer.requireBinding().device
                sessions[0].accountIdentity.change(SocialChange("untrust", peer.identity.substringBefore('.'),
                    device.accountKey, device.leaf, peer.name))
                awaitCondition("withdrawn trust stops both leases") {
                    views.all { it.pending } && media.all { (it?.gate?.remaining() ?: 0) == 0L }
                }
            } finally {
                workers.forEach { it.cancel() }; workers.forEach { it.join() }; jobs.cancel()
            }
        }
    }

    private class ProtocolMedia(groupID: String, keys: Map<String, ByteArray>) : GroupMedia {
        override val gate = MediaGate(groupID)
        var ready = false
        var switches = 0
        val retired = mutableListOf<Int>()
        var activeHashes = hashes(keys)
        private var stagedHashes: Map<String, String>? = null
        private var lastGrant = 0L
        private var lastDuration = 0L
        private var lastSlot = 0
        fun leaseStatus() = "ready=$ready switches=$switches slot=$lastSlot leaseMs=$lastDuration elapsedSinceGrantMs=${android.os.SystemClock.elapsedRealtime() - lastGrant}"
        override fun granted(index: Int) {
            ready = true
            lastGrant = android.os.SystemClock.elapsedRealtime()
            lastDuration = gate.remaining()
            lastSlot = index
        }
        override fun pause() { ready = false; gate.revoke() }
        override suspend fun prepareKeys(keys: Map<String, ByteArray>, index: Int) { stagedHashes = hashes(keys) }
        override suspend fun switchKeys(index: Int) { activeHashes = requireNotNull(stagedHashes); switches++ }
        override fun retireKeys(index: Int) { retired += index }
        private fun hashes(keys: Map<String, ByteArray>) = keys.mapValues { sha256(it.value).toHexString() }
    }
}
