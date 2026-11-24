package cn.youzifeile.chirp.data

import android.os.SystemClock
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable internal data class DeviceLabel(
    @SerialName("device_key") val key: String, val name: String, val platform: String,
    @SerialName("created_at") val created: Long, @SerialName("last_login_at") val lastLogin: Long? = null)
@Serializable internal data class Ban(val sequence: Long, val kind: String, val subject: String,
    @SerialName("account_id") val account: String, @SerialName("account_key") val root: String, val username: String,
    @SerialName("created_at") val createdAt: Long = 0) {
    fun blocks(id: String, accountKey: String, deviceKey: String = "") = when (kind) {
        "account" -> subject == id || root == accountKey
        "device" -> subject == deviceKey
        else -> false
    }

    fun preserves(prior: Ban) = this == prior || prior.createdAt == 0L && copy(createdAt = 0) == prior
}
@Serializable private data class OriginHistory(val checkpoints: Map<String, Checkpoint> = emptyMap(), val bans: List<Ban> = emptyList())
@Serializable private data class SocialState(val pending: SocialChange? = null, val submitted: String = "",
    val revoke: String? = null, val friends: List<Friend> = emptyList())
internal data class AccountView(val friends: List<Friend> = emptyList(), val devices: Map<String, DeviceLabel?> = emptyMap(),
    val revoked: Set<String> = emptySet(), val bans: List<Ban> = emptyList(), val currentKey: String = "",
    val synced: Boolean = false, val pending: Boolean = false, val enrollingDevices: Set<String> = emptySet(), val pendingRevoke: String? = null,
    val refreshing: Boolean = false)

internal class AccountIdentity(val session: SessionRepository, val local: LocalDevice,
    private val vault: IdentityVault, private val publicKey: String) {
    val origin = session.connection.passkeyOrigin.identityOrigin
    private val storage = "social|$origin|${local.device.accountKey}"
    private val historyKey = "history|$origin"
    private var history = OriginHistory()
    private val lock = Mutex()
    private var stored = SocialState()
    private val mutable = MutableStateFlow(AccountView(currentKey = local.device.leaf))
    val view = mutable.asStateFlow()
    private var verified: Map<String, VerifiedAccount> = emptyMap()
    var deadline = 0L
        private set
    private var observed = emptySet<String>()
    val version get() = verified[local.device.accountKey]?.socialHashes?.size ?: 0
    val trustWritePending get() = stored.pending?.operation == "trust"
    private var loaded = false
    private val base = session.connection.authorizationBase
    init { publicKey.base64Bytes(32) }

    private suspend fun load() {
        if (loaded) return
        stored = vault.read(storage)?.let { wireJson.decodeFromString<SocialState>(it) } ?: SocialState()
        loaded = true
        publish()
    }
    private suspend fun save(next: SocialState) {
        vault.write(storage, wireJson.encodeToString(next))
        stored = next
        publish()
    }
    private fun publish(labels: List<DeviceLabel> = mutable.value.devices.values.filterNotNull()) {
        val own = verified[local.device.accountKey]
        val friends = stored.friends.toMutableList()
        stored.pending?.takeIf { it.operation in setOf("untrust", "remove_friend") }?.applyTo(friends)
        mutable.value = AccountView(friends, own?.devices?.keys.orEmpty().associateWith { k -> labels.find { it.key == k } },
            own?.revoked.orEmpty() + listOfNotNull(stored.revoke), history.bans, local.device.leaf,
            own != null && deadline > SystemClock.elapsedRealtime(), stored.pending != null || stored.revoke != null,
            own?.devices.orEmpty().filterValues { it.certificates.last().canEnroll }.keys, stored.revoke, mutable.value.refreshing)
    }

    suspend fun refresh(roots: Set<String>? = null, force: Boolean = true) = historyLock.withLock {
        lock.withLock {
            mutable.value = mutable.value.copy(refreshing = true)
            try { refreshLocked(roots, force) }
            catch (e: Exception) {
                if (e is ChirpException && (e.status in setOf(401,403) || e.code in setOf(
                        "IDENTITY_BLACKLISTED","IDENTITY_INVALID","IDENTITY_HISTORY_CHANGED","INVALID_RESPONSE"))) deadline = 0
                publish()
                throw e
            } finally { mutable.value = mutable.value.copy(refreshing = false) }
        }
    }
    private suspend fun rememberHistory(value: OriginHistory) {
        if (history == value) return
        vault.write(historyKey, wireJson.encodeToString(value))
        history = value
    }
    private suspend fun refreshLocked(roots: Set<String>?, force: Boolean) {
        load()
        if (roots != null) observed = roots
        val requested = (observed + local.device.accountKey + listOfNotNull(stored.pending?.root)).sorted()
        if (!force && verified.keys.containsAll(requested) && deadline - SystemClock.elapsedRealtime() > 40_000) return
        history = vault.read(historyKey)?.let { wireJson.decodeFromString<OriginHistory>(it) } ?: OriginHistory()
        repeat(4) {
            val result = mutableMapOf<String, VerifiedAccount>()
            val until = SystemClock.elapsedRealtime() + 60_000
            for (batch in requested.chunked(2)) {
                val nonce = base64(randomBytes(32))
                val time = nowSeconds().toString()
                val signature = local.sign(message("Chirp authorization read v5", origin, nonce, local.device.hash(), time, *batch.toTypedArray()))
                val body = buildJsonObject {
                    put("origin",origin); put("nonce",nonce); put("roots",JsonArray(batch.map(::JsonPrimitive)))
                    put("signed_at",time.toLong()); put("device",local.device.toWire()); put("signature",signature)
                }
                val envelope = session.http.json(base.path("snapshot").request().jsonPost(body).build(), limit = 9L * 1024 * 1024, operation = LogEvent.identitySnapshot).second
                result += withContext(Dispatchers.Default) {
                    verifySnapshot(envelope, publicKey, origin, nonce, batch, history.checkpoints, local.device.accountKey to session.login.memberID)
                }
            }
            verify(until > SystemClock.elapsedRealtime(), "AUTHORIZATION_STALE")
            val own = result.getValue(local.device.accountKey)
            val checkpoints = history.checkpoints + result.mapValues { it.value.checkpoint }
            if (!own.active(local.device)) {
                deadline = 0
                verified = result
                rememberHistory(history.copy(checkpoints = checkpoints))
                publish()
                verify(local.device.leaf !in own.devices && local.device.leaf !in own.revoked, "IDENTITY_BLACKLISTED")
                append(own, "enroll")
                return@repeat
            }
            verify(own.complete)
            val committed = stored.submitted.isNotEmpty() && stored.submitted in own.socialHashes
            rememberHistory(history.copy(checkpoints = checkpoints))
            save(stored.copy(friends = own.friends,
                pending = stored.pending.takeUnless { committed }, submitted = if (committed) "" else stored.submitted))
            verified = result
            publish()
            stored.revoke?.let { target ->
                if (target !in own.revoked) { append(own, "revoke", target); return@repeat }
                val url = session.api("identity","devices",base64url(target.base64Bytes(32)))
                session.http.json(url.request(session.login.credential).delete().build(), setOf(204, 200), operation = LogEvent.deleteDevice)
                save(stored.copy(revoke = null))
            }
            stored.pending?.let { change ->
                val social = buildJsonObject {
                    put("origin", origin); put("account_id",session.login.memberID); put("version",own.socialHashes.size + 1)
                    put("previous_hash",own.socialHashes.lastOrNull().orEmpty()); put("operation",change.operation)
                    put("friend_id",change.id); put("friend_key",change.root); put("device_key",change.key)
                    put("name",change.name); put("signer",local.device.toWire())
                }
                val msg = socialMessage(social, local.device)
                val signature = local.sign(msg)
                save(stored.copy(submitted = signedDigest("Chirp account social event digest v5", msg, signature)))
                append(own, "social", social = JsonObject(social + ("signature" to JsonPrimitive(signature))))
                return@repeat
            }
            val bans = session.list<Ban>("identity","blacklist")
            for (ban in bans) {
                verify(ban.sequence > 0 && ban.kind in setOf("account","device") && memberIDPattern.matches(ban.account))
                if (ban.root.isNotEmpty()) ban.root.base64Bytes(32)
                if (ban.kind == "device") ban.subject.base64Bytes(32) else verify(ban.subject == ban.account)
            }
            val bySequence = bans.associateBy(Ban::sequence)
            verify(bySequence.size == bans.size && history.bans.all { bySequence[it.sequence]?.preserves(it) == true },
                "IDENTITY_HISTORY_CHANGED")
            rememberHistory(history.copy(bans = bans))
            verify(until > SystemClock.elapsedRealtime(), "AUTHORIZATION_STALE")
            deadline = until
            publish(session.list<DeviceLabel>("identity","devices"))
            return
        }
        throw ChirpException("IDENTITY_HISTORY_CHANGED")
    }

    private suspend fun append(own: VerifiedAccount, op: String, target: String = "", social: JsonObject? = null) {
        val event = buildJsonObject {
            put("origin",origin); put("version",own.checkpoint.version + 1); put("previous_hash",own.checkpoint.hash)
            put("operation",op); put("signer",local.device.toWire()); put("target_key",target)
            social?.let { put("social",it) }
        }
        val signed = JsonObject(event + ("signature" to JsonPrimitive(local.sign(authorizationMessage(event,local.device)))))
        session.http.json(base.path("append").request().jsonPost(signed).build(), setOf(204), operation = LogEvent.identityAppend)
    }
    fun blocked(id: String, device: DeviceIdentity): Boolean =
        verified[device.accountKey]?.revoked?.contains(device.leaf) == true ||
            (device.accountKey == local.device.accountKey && stored.revoke == device.leaf) ||
            history.bans.any { it.blocks(id, device.accountKey, device.leaf) }

    fun active(id: String, device: DeviceIdentity): Boolean = SystemClock.elapsedRealtime() < deadline &&
        verified[device.accountKey]?.active(device) == true && !blocked(id, device)
    fun trusted(id: String, device: DeviceIdentity) = active(id,device) && view.value.friends.any {
        it.id == id && it.root == device.accountKey && device.leaf in it.devices
    }
    fun authorizationHash(roots: List<String>): String = digest(message("Chirp approved authorization v5",
        *roots.distinct().sorted().flatMap { root -> verified.getValue(root).checkpoint.let { listOf(root,it.version.toString(),it.hash) } }.toTypedArray()))
    suspend fun change(change: SocialChange) = socialLogEvent(change.operation).measure(started = true) {
        lock.withLock {
            load()
            if (change.operation == "trust" || change.operation == "friend") {
                verify(history.bans.none { it.blocks(change.id, change.root, change.key) } &&
                    change.key !in verified[change.root]?.revoked.orEmpty(), "PEER_IDENTITY_REVOKED")
            }
            verify(stored.pending == null || stored.pending == change, "IDENTITY_CHANGE_PENDING")
            save(stored.copy(pending = change))
        }
        refresh()
    }
    suspend fun rename(key: String, name: String) = LogEvent.renameDevice.measure(started = true) {
        val url = session.api("identity","devices",base64url(key.base64Bytes(32)))
        val body = buildJsonObject { put("name",name) }
        session.http.json(url.request(session.login.credential).patch(body.jsonBody()).build(), setOf(200,204), operation = LogEvent.updateDevice)
        refresh()
    }
    suspend fun revoke(key: String) = LogEvent.revokeDevice.measure(started = true) {
        lock.withLock {
            load()
            verify(key != local.device.leaf && key in view.value.devices && local.device.certificates.last().canEnroll &&
                (stored.revoke == null || stored.revoke == key), "IDENTITY_INVALID")
            save(stored.copy(revoke = key))
        }
        refresh()
    }

    private companion object {
        // Accounts on the same installation share monotonic authority checkpoints and administrator bans.
        val historyLock = Mutex()
    }
}

internal suspend inline fun <reified T> SessionRepository.list(vararg parts: String): List<T> =
    wireJson.decodeFromString(http.binary(api(*parts).request(login.credential).build(), 4L * 1024 * 1024, operation = when (parts.getOrNull(1)) {
        "devices" -> LogEvent.listDevices
        "blacklist" -> LogEvent.listBlacklist
        else -> LogEvent.identitySignals
    }).decodeToString())

private fun socialLogEvent(operation: String) = when (operation) {
    "trust" -> LogEvent.trustDevice
    "untrust" -> LogEvent.untrustDevice
    "friend" -> LogEvent.addFriend
    "remove_friend" -> LogEvent.removeFriend
    else -> LogEvent.identityChange
}
