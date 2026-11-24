package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.LogEvent
import android.os.SystemClock
import cn.youzifeile.chirp.data.*
import java.io.Closeable
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

private const val TRUST_SYNC_UNAVAILABLE = "ROOM_TRUST_SYNC_UNAVAILABLE"

@Serializable internal data class IdentitySignal(val id: String, val origin: String, @SerialName("room_id") val room: String,
    val sender: String, val recipient: String, @SerialName("sender_entry") val from: String,
    @SerialName("recipient_entry") val to: String, val kind: String, val payload: String,
    @SerialName("expires_at") val expires: Long, val device: DeviceIdentity, val signature: String = "") {
    fun message() = message("Chirp identity signal v5",id,origin,room,sender,recipient,from,to,kind,payload,expires.toString(),device.hash())
}
@Serializable private data class RoutedSignal(val sequence: Long, val signal: IdentitySignal)
@Serializable private data class TrustStatement(val roster: String, val version: Long, val trustedKeys: Set<String>)
internal data class Verification(val id: String, val peer: String, val commitment: String? = null,
    val accepted: Boolean = false, val numbers: List<Int> = emptyList(), val confirmed: Boolean = false) {
    val awaitingAcceptance get() = commitment == null && numbers.isEmpty()
    fun notice(phase: VerificationPhase) = VerificationNotice(id, peer, phase)
}
internal enum class VerificationPhase { Saving, SyncPending, Verified, Mismatch, Cancelled, PeerCancelled, PeerBusy, RoomChanged, Expired, Failed }
internal data class VerificationNotice(val id: String, val peer: String, val phase: VerificationPhase)
internal data class RoomTrustView(val peers: List<GroupMember> = emptyList(), val trusted: Set<String> = emptySet(),
    val verification: Verification? = null, val pending: Boolean = false, val failure: String? = null,
    val expires: Long = 0, val notice: VerificationNotice? = null, val friends: Set<String> = emptySet(),
    val localMember: GroupMember? = null)

internal class RoomTrust(private val account: AccountIdentity, private val entry: Admission,
    private val changed: (RoomTrustView) -> Unit) : Closeable {
    private val sas = MlsNative("sas-" + entry.entryID)
    private val mutex = Mutex()
    private var roster = emptyList<GroupMember>()
    private var rosterId = ""
    private var statements = mutableMapOf<String, Pair<TrustStatement, Long>>()
    private var verification: Verification? = null
    private var notice: VerificationNotice? = null
    private var expires = 0L
    private var closed = false
    private var broadcastAt = 0L
    private val pollNow = Channel<Unit>(Channel.CONFLATED)
    private var quickPollUntil = 0L
    private val mutualTrust = MutableStateFlow(false)
    val ready = mutualTrust.asStateFlow()
    private var roots = emptySet<String>()
    private var actionFailure: String? = null
    private var syncFailure: String? = null
    private var cursor = 0L
    private val seen = mutableMapOf<String, Long>()
    private val awaitingRoster = linkedMapOf<String, IdentitySignal>()
    private fun peer(id: String) = roster.singleOrNull { it.identity == id }
    private fun matchesInvitation(peer: String, transaction: String) =
        transaction == (verification?.id ?: notice?.id) && peer == (verification?.peer ?: notice?.peer)
    private fun id(peer: GroupMember) = peer.identity.substringBefore('.')
    private fun trusted(peer: GroupMember) = peer.identity == entry.identity ||
        account.trusted(id(peer),peer.requireBinding().device)
    private fun isFriend(peer: GroupMember) = account.view.value.friends.any {
        it.id == id(peer) && it.root == peer.requireBinding().device.accountKey
    }
    private fun publish() {
        if (closed) return
        val peers = roster.filter { it.identity != entry.identity }
        mutualTrust.value = remaining(roster) > 0
        changed(RoomTrustView(peers, peers.filter(::trusted).map { it.identity }.toSet(), verification,
            roster.isNotEmpty() && !ready.value, actionFailure ?: syncFailure, expires, notice, peers.filter(::isFriend).map { it.identity }.toSet(),
            localMember = roster.find { it.identity == entry.identity }))
    }

    // Identity signals use an inbox. Poll briefly after an exchange, then return to the normal cadence.
    private fun expectSignal() {
        quickPollUntil = SystemClock.elapsedRealtime() + 2_000
        pollNow.trySend(Unit)
    }

    private fun trustPayload() = wireJson.encodeToString(TrustStatement(rosterId, account.version.toLong(),
        roster.filter(::trusted).map { it.requireBinding().device.leaf }.toSet()))
    suspend fun update(next: List<GroupMember>) {
        val digest = digest(message("Chirp mutual trust roster v5", *next.map { it.requireBinding().hash() }.sorted().toTypedArray()))
        val wanted = next.map { it.requireBinding().device.accountKey }.toSet()
        requireEligible(next)
        if (rosterId == digest && roots == wanted) return
        mutex.withLock {
            if (rosterId != digest) {
                cancelLocal(VerificationPhase.RoomChanged); statements.clear(); roster = next; rosterId = digest; broadcastAt = 0
                syncFailure = null
            }
            if (wanted != roots) { account.refresh(wanted, force = false); roots = wanted }
            requireEligible(next)
            publish()
            if (next.size > 1) expectSignal()
        }
    }
    private fun requireEligible(members: List<GroupMember>) {
        verify(members.none { account.blocked(id(it), it.requireBinding().device) }, "ROOM_IDENTITY_REVOKED")
    }

    fun remaining(members: List<GroupMember>): Long {
        if (closed || members.isEmpty() || members.size != roster.size) return 0
        val now = System.currentTimeMillis()
        var ms = account.deadline - SystemClock.elapsedRealtime()
        val keys = roster.map { it.requireBinding().device.leaf }.toSet()
        for (m in members) {
            val b = m.requireBinding()
            if (peer(m.identity)?.binding != b || !account.active(id(m),b.device) || !trusted(m)) return 0
            ms = minOf(ms, minOf(b.end,b.device.deadline) * 1000 - now)
            if (m.identity != entry.identity) {
                val (statement,until) = statements[m.identity] ?: return 0
                if (statement.roster != rosterId || !statement.trustedKeys.containsAll(keys)) return 0
                ms = minOf(ms, until - SystemClock.elapsedRealtime())
            }
        }
        return ms.coerceAtLeast(0)
    }
    suspend fun follow() {
        var retryingRoster: String? = null
        while (!closed) {
            var nextPoll = 1000L
            val attemptedRoster = rosterId
            try {
                mutex.withLock {
                    if (verification != null && SystemClock.elapsedRealtime() >= expires) {
                        cancelLocal(VerificationPhase.Expired)
                        publish()
                    }
                    notice?.takeIf { it.phase == VerificationPhase.SyncPending && peer(it.peer)?.let(::trusted) == true }?.let {
                        notice = it.copy(phase = VerificationPhase.Verified)
                        actionFailure = null
                        broadcastAt = 0
                        publish()
                    }
                }
                if (roster.isNotEmpty()) {
                    // An active call continues checking its authority when there is no visible directory.
                    account.refresh(force = false)
                    requireEligible(roster)
                    pollSignals()
                    mutex.withLock {
                        if (SystemClock.elapsedRealtime() >= broadcastAt) {
                            val payload = trustPayload()
                            for (m in roster.filter { it.identity != entry.identity }) send(m, "trust", payload)
                            broadcastAt = SystemClock.elapsedRealtime() + 8000
                        }
                        retryingRoster = null
                        syncFailure = null
                        publish()
                        if (!ready.value && SystemClock.elapsedRealtime() < quickPollUntil) nextPoll = 150
                    }
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                if (e is ChirpException && (e.sessionFailure != null || e.code == "ROOM_IDENTITY_REVOKED")) throw e
                val code = when (e) {
                    is ChirpException -> if (e.status == 408 || e.status in 500..599) TRUST_SYNC_UNAVAILABLE else e.code
                    is IOException -> TRUST_SYNC_UNAVAILABLE
                    else -> "INVALID_RESPONSE"
                }
                mutex.withLock {
                    if (rosterId == attemptedRoster) {
                        // Retry a transient failure once for this roster before showing a sync warning.
                        val retryable = code == TRUST_SYNC_UNAVAILABLE
                        syncFailure = code.takeIf { !retryable || retryingRoster == attemptedRoster }
                        retryingRoster = if (retryable) attemptedRoster else null
                        publish()
                    }
                }
            }
            withTimeoutOrNull(nextPoll) { pollNow.receive() }
        }
    }
    suspend fun pollSignals() {
        mutex.withLock {
            val now = nowSeconds()
            awaitingRoster.values.removeAll { it.expires <= now }
            for (signal in awaitingRoster.values.toList()) {
                if (peer(signal.from) != null) {
                    awaitingRoster.remove(signal.id)
                    receive(signal)
                }
            }
        }
        val received = account.session.list<RoutedSignal>("identity","signals",cursor.toString())
        for ((sequence, signal) in received) {
            if (sequence <= cursor) continue
            cursor = sequence
            mutex.withLock { receive(signal) }
        }
    }

    suspend fun act(action: String, entryId: String = "", transaction: String? = null) = mutex.withLock {
        if (transaction != null && !matchesInvitation(entryId, transaction)) return@withLock
        if (action == "start" && (verification != null || account.trustWritePending)) return@withLock
        actionFailure = null
        val operation = when (action) {
            "accept" -> LogEvent.acceptVerification
            "confirm" -> LogEvent.verificationMatches
            "cancel" -> LogEvent.cancelVerification
            "mismatch" -> LogEvent.verificationMismatch
            "sync" -> LogEvent.syncIdentity
            "friend" -> LogEvent.addFriend
            else -> LogEvent.verification
        }
        try {
            operation.measure(started = true) {
                if (action == "dismiss") {
                    notice = null
                } else if (action == "sync") {
                    if (notice?.phase == VerificationPhase.SyncPending) account.refresh()
                } else if (action == "friend") {
                    val m = requireNotNull(peer(entryId))
                    if (!isFriend(m)) account.change(SocialChange("friend",id(m),m.requireBinding().device.accountKey,"",m.name))
                } else if (action == "start") {
                    val m = requireNotNull(peer(entryId))
                    verify(m.identity != entry.identity && account.active(id(m),m.requireBinding().device))
                    val v = Verification(base64(randomBytes(32)),m.identity,accepted = true)
                    verification = v; notice = null; expires = SystemClock.elapsedRealtime() + 120_000
                    result(v,sas.security("sas_start","id" to v.id,"context" to context(v.id,entry.identity,m.identity)))
                } else {
                    val v = verification ?: return@withLock
                    when (action) {
                        "accept" -> {
                            if (v.accepted || v.commitment == null) return@withLock
                            verification = v.copy(accepted = true)
                            result(v,sas.security("sas_accept","id" to v.id,"context" to context(v.id,v.peer,entry.identity),
                                "commitment" to v.commitment))
                        }
                        "confirm" -> {
                            if (!v.accepted || v.confirmed || v.numbers.size != 3) return@withLock
                            verification = v.copy(confirmed = true)
                            result(v,sas.security("sas_confirm","id" to v.id))
                        }
                        "cancel", "mismatch" -> {
                            val packet = sas.security("sas_cancel","id" to v.id)
                            verification = null
                            notice = v.notice(if (action == "mismatch") VerificationPhase.Mismatch else VerificationPhase.Cancelled)
                            publish()
                            sendSas(requireNotNull(peer(v.peer)), v.id, packet.text("message"))
                        }
                    }
                }
            }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { cancelLocal(VerificationPhase.Failed); actionFailure = (e as? ChirpException)?.code ?: "IDENTITY_INVALID" }
        publish()
    }
    private fun context(id: String, from: String, to: String): String {
        val a = requireNotNull(peer(from)).requireBinding().device
        val b = requireNotNull(peer(to)).requireBinding().device
        return base64(message("Chirp SAS session v5",id,account.origin,entry.room.id,from,a.accountKey,a.leaf,to,b.accountKey,b.leaf))
    }
    private suspend fun send(m: GroupMember, kind: String, payload: String) {
        verify(!closed)
        val s = IdentitySignal(base64(randomBytes(32)),account.origin,entry.room.id,account.session.login.memberID,id(m),
            entry.identity,m.identity,kind,payload,nowSeconds()+120,account.local.device)
        val body = s.copy(signature = account.local.sign(s.message())).toWire()
        try {
            account.session.http.json(account.session.api("identity","signals").request(account.session.login.credential).jsonPost(body).build(),setOf(204,200), operation = LogEvent.sendSignal)
        } catch (e: ChirpException) {
            // The server can remove the recipient's admission before our signed roster changes.
            if (kind == "trust" && e.status == 403 && e.code == "DEVICE_IDENTITY_REQUIRED")
                throw ChirpException(TRUST_SYNC_UNAVAILABLE, e.status)
            throw e
        }
    }
    private suspend fun sendSas(recipient: GroupMember, transaction: String, packet: String) {
        send(recipient, "sas", buildJsonObject { put("transaction",transaction); put("message",packet) }.toString())
        expectSignal()
    }
    private suspend fun receive(s: IdentitySignal) {
        val now = nowSeconds()
        if (s.room != entry.room.id || s.to != entry.identity || s.origin != account.origin ||
            s.recipient != account.session.login.memberID || s.sender != s.from.substringBefore('.') ||
            s.expires !in (now+1)..(now+600)) return
        val m = peer(s.from)
        if (m == null) {
            // The inbox can advance before MLS delivers the entrant's signed roster.
            // Retry only inside this admission, through the same signature and eligibility checks.
            if ((s.kind == "trust" || s.kind == "sas") && s.id !in seen && awaitingRoster.size < 128) {
                awaitingRoster.putIfAbsent(s.id, s)
            }
            return
        }
        if (s.device != m.requireBinding().device || !account.active(id(m), s.device)) return
        seen.entries.removeAll { it.value <= now }
        if (s.id in seen || seen.size >= 8192) return
        verifySignature(s.device.leaf,s.signature,s.message())
        seen[s.id] = s.expires
        if (s.kind == "trust") {
            val t = wireJson.decodeFromString<TrustStatement>(s.payload)
            val previous = statements[s.from]
            if (t.roster == rosterId && t.version >= (previous?.first?.version ?: 0L)) {
                statements[s.from] = t to (SystemClock.elapsedRealtime() + (s.expires - now)*1000)
                // The peer may have read our first declaration before installing this roster.
                if (previous == null && trusted(m) && broadcastAt != 0L) {
                    try { send(m, "trust", trustPayload()) }
                    catch (e: Exception) { broadcastAt = 0; throw e }
                }
            }
        } else if (s.kind == "sas") {
            val envelope = parseObject(s.payload.encodeToByteArray())
            val tx = envelope.text("transaction")
            val packet = envelope.text("message")
            val value = parseObject(packet.encodeToByteArray())
            val kind = value.text("kind")
            if (kind == "Request") {
                tx.base64Bytes(32)
                val commitment = value.text("commitment")
                commitment.base64Bytes(32)
                val prior = verification
                if (matchesInvitation(s.from, tx)) return
                if (account.trustWritePending || (prior != null && (prior.peer != s.from || !prior.awaitingAcceptance))) {
                    // Answer this invitation without touching the active SAS exchange.
                    try { sendSas(m, tx, """{"kind":"Busy"}""") }
                    catch (e: IOException) {
                        // The requester may already have left while our own peer is still available.
                        if (e is ChirpException && (e.sessionFailure != null || e.code == "ROOM_IDENTITY_REVOKED")) throw e
                    }
                    return
                }
                // Crossed invitations between the same two peers keep the lower identity's transaction.
                if (prior != null && s.from >= entry.identity) return
                cancelLocal()
                verification = Verification(tx, s.from, commitment); notice = null
                expires = SystemClock.elapsedRealtime()+120_000
            } else {
                val v = verification ?: return
                if (v.id != tx || v.peer != s.from) return
                if (expires <= SystemClock.elapsedRealtime()) cancelLocal(VerificationPhase.Expired)
                else if (kind == "Busy") {
                    if (!v.awaitingAcceptance) return
                    cancelLocal(VerificationPhase.PeerBusy)
                } else if (kind == "Cancel") cancelLocal(VerificationPhase.PeerCancelled)
                else try { result(v,sas.security("sas_receive","id" to tx,"message" to packet)) }
                catch (e: CancellationException) { throw e }
                catch (e: Exception) {
                    cancelLocal(VerificationPhase.Failed)
                    actionFailure = e.clientFailure("IDENTITY_INVALID").code
                    throw e
                }
            }
        }
        publish()
    }
    private suspend fun result(v: Verification, result: JsonObject) {
        result["message"]?.let { sendSas(requireNotNull(peer(v.peer)), v.id, it.jsonPrimitive.content) }
        val numbers = (result["decimals"] as? JsonArray)?.map { it.jsonPrimitive.int }
        if (numbers != null) {
            verify(numbers.size == 3 && numbers.all { it in 1000..9191 })
            verification = verification?.copy(numbers = numbers)
        }
        if (result["complete"] == JsonPrimitive(true)) {
            val m = requireNotNull(peer(v.peer)); val d = m.requireBinding().device
            verify(verification?.confirmed == true && expires > SystemClock.elapsedRealtime())
            verification = null
            notice = v.notice(VerificationPhase.Saving)
            publish()
            try {
                account.change(SocialChange("trust",id(m),d.accountKey,d.leaf,m.name))
                verify(trusted(m), "IDENTITY_INVALID")
                notice = v.notice(VerificationPhase.Verified)
                broadcastAt = 0
                expectSignal()
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                val phase = if (account.trustWritePending) VerificationPhase.SyncPending else VerificationPhase.Failed
                notice = v.notice(phase)
                actionFailure = (e as? ChirpException)?.code ?: "SERVER_UNAVAILABLE"
            }
        }
    }
    private fun cancelLocal(reason: VerificationPhase = VerificationPhase.Cancelled) {
        verification?.let { notice = it.notice(reason); runCatching { sas.security("sas_cancel","id" to it.id) } }
        verification = null
    }
    override fun close() { closed = true; sas.close(); verification = null; statements.clear(); awaitingRoster.clear() }
}
