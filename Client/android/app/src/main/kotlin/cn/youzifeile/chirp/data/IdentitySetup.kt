package cn.youzifeile.chirp.data

import android.os.Build
import cn.youzifeile.chirp.media.MlsNative
import java.time.Instant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

private const val SETUP_LIFETIME_SECONDS = 300L

@Serializable
internal data class IdentityGrant(
    @SerialName("setup_token") val token: String,
    @SerialName("account_id") val account: String,
    val username: String,
    @SerialName("service_origin") val origin: String,
    @SerialName("account_key") val root: String,
    @SerialName("expires_at") val expires: Long,
) {
    fun receivedAt(now: Long): IdentityGrant {
        // The server grants five minutes. A small clock difference must never extend local use.
        verify(expires in (now + 1)..(now + SETUP_LIFETIME_SECONDS + 5), "IDENTITY_INVALID")
        return copy(expires = minOf(expires, now + SETUP_LIFETIME_SECONDS))
    }
    fun validate(connection: ServerConnection) {
        verify(origin == connection.passkeyOrigin.identityOrigin && memberIDPattern.matches(account) && validName(username) &&
            token.startsWith("setup_") && tokenPattern.matches(token.removePrefix("setup_")) &&
            expires in (nowSeconds() + 1)..(nowSeconds() + SETUP_LIFETIME_SECONDS), "IDENTITY_INVALID")
        if (root.isNotEmpty()) root.base64Bytes(32)
    }
}

@Serializable
internal data class LocalDevice(val seed: String, val device: DeviceIdentity) {
    fun sign(data: ByteArray): String {
        val key = seed.base64Bytes(32)
        return try { sign(key, data) } finally { key.fill(0) }
    }
    fun validate() {
        device.validate()
        val key = seed.base64Bytes(32)
        try { verify(publicKey(key) == device.leaf, "IDENTITY_INVALID") } finally { key.fill(0) }
    }
}

@Serializable
internal data class SetupRecord(
    val active: LocalDevice? = null,
    val candidate: LocalDevice? = null,
    val backup: String? = null,
    val exported: Boolean = false,
    val confirmed: Boolean = false,
    val pairingSeed: String? = null,
    val backupRoot: String? = null,
    val confirmedDigest: String? = null,
)

internal enum class SetupStep { Create, Restore, Resume, Export, Saved, Confirm, Activate }

internal class IdentitySetup(
    val grant: IdentityGrant,
    private val verifier: String,
    val connection: ServerConnection,
    private val http: ChirpHttp,
    private val vault: IdentityVault,
    private val monotonic: () -> Long = android.os.SystemClock::elapsedRealtime,
) {
    var record = SetupRecord()
        private set
    private val scope = scope(grant.origin, grant.account)
    private var locked = false
    private var confirmingBackup = false
    private var visibleSince: Long? = null
    private var visibleMillis = 0L
    var backupVerified = false
        private set
    val filename get() = grant.username.map { if (it.isLetterOrDigit() || it in "_-") it else '_' }
        .joinToString("").take(64) + "_${java.time.LocalDate.now()}_Android.chirpkey"
    val step: SetupStep get() = when {
        locked -> SetupStep.Resume
        record.candidate != null && (grant.root.isEmpty() || record.candidate?.device?.accountKey == grant.root) ->
            if (record.backup != null && !record.confirmed) {
                when {
                    !record.exported -> SetupStep.Export
                    confirmingBackup -> SetupStep.Confirm
                    else -> SetupStep.Saved
                }
            } else SetupStep.Activate
        grant.root.isEmpty() -> SetupStep.Create
        record.active?.device?.accountKey == grant.root -> SetupStep.Activate
        else -> SetupStep.Restore
    }

    suspend fun load() {
        record = loadRecord(vault, scope)
        val root = record.backupRoot ?: record.candidate?.device?.accountKey
        locked = record.backup != null && (grant.root.isEmpty() || root == null || grant.root == root)
        record.active?.let { rememberIdentity(it) }
    }

    private suspend fun rememberIdentity(local: LocalDevice) {
        vault.rememberIdentity(SavedIdentity(grant.origin, grant.account, grant.username, local.device.accountKey, connection.origin.toString()))
    }
    private suspend fun save(value: SetupRecord) {
        try { vault.write(scope, wireJson.encodeToString(value)) }
        catch (e: kotlinx.coroutines.CancellationException) { throw e }
        catch (_: java.io.IOException) { throw ChirpException("RECOVERY_STATE_WRITE_FAILED") }
        catch (_: java.security.GeneralSecurityException) { throw ChirpException("RECOVERY_STATE_WRITE_FAILED") }
        record = value
    }
    suspend fun create(password: String, confirmation: String) = LogEvent.createIdentity.measure(started = true) {
        grant.validate(connection)
        verify(step == SetupStep.Create && grant.root.isEmpty(), "IDENTITY_INVALID")
        verify(password == confirmation && validRecoveryPassword(password), "RECOVERY_PASSWORD_INVALID")
        val next = withContext(Dispatchers.Default) {
            val root = randomBytes(32)
            val deviceSeed = randomBytes(32)
            try {
                val device = DeviceIdentity.issue(root, publicKey(deviceSeed))
                val payload = buildJsonObject {
                    put("payload_version", 1); put("identity_protocol", GROUP_PROTOCOL); put("root_algorithm", "Ed25519")
                    put("root_seed", base64(root)); put("root_public_key", device.accountKey)
                    put("service_origin", grant.origin); put("account_id", grant.account); put("username", grant.username)
                    put("created_at", Instant.now().toString()); put("source_platform", "Android")
                }
                val backup = MlsNative("recovery-file").use {
                    LogEvent.recoveryEncrypt.measure { it.security("encrypt", "password" to password, "payload" to payload.toString()).text("file") }
                }
                record.copy(candidate = LocalDevice(base64(deviceSeed), device), backupRoot = device.accountKey,
                    backup = backup, exported = false, confirmed = false, confirmedDigest = null)
            } finally { root.fill(0); deviceSeed.fill(0) }
        }
        save(next)
    }
    fun backupBytes() = requireNotNull(record.backup).base64Bytes(71, 65606)
    suspend fun exported() {
        verify(step == SetupStep.Export || step == SetupStep.Saved)
        save(record.copy(exported = true, confirmed = false, confirmedDigest = null))
        backupVerified = false
        backToSave()
    }

    fun showConfirmation() {
        verify(step == SetupStep.Saved, "RECOVERY_INVALID")
        confirmingBackup = true
        visibleMillis = 0
        visibleSince = null
    }

    fun backToSave() {
        confirmingBackup = false
        visibleMillis = 0
        visibleSince = null
    }

    fun setConfirmationVisible(visible: Boolean) {
        val now = monotonic()
        visibleSince?.let { visibleMillis += (now - it).coerceAtLeast(0) }
        visibleSince = if (visible && step == SetupStep.Confirm) now else null
    }

    fun confirmationSeconds(): Int {
        val elapsed = visibleMillis + (visibleSince?.let { monotonic() - it } ?: 0)
        return ((5_000 - elapsed).coerceAtLeast(0) + 999).toInt() / 1000
    }

    suspend fun confirmBackup() = LogEvent.confirmBackup.measure(started = true) {
        verify(step == SetupStep.Confirm && record.exported && confirmationSeconds() == 0)
        save(record.copy(confirmed = true, confirmedDigest = digest(backupBytes())))
    }

    private suspend fun <T> unlock(file: ByteArray, password: String, expectedRoot: String?, use: (ByteArray) -> T): T =
        withContext(Dispatchers.Default) {
            grant.validate(connection)
            verify(file.size <= 65606, "RECOVERY_TOO_LARGE")
            verify(file.size >= 71, "RECOVERY_INVALID")
            val payload = try {
                MlsNative("recovery-file").use {
                    LogEvent.recoveryDecrypt.measure { it.security("decrypt", "password" to password, "file" to base64(file)).text("payload") }
                }.let { parseObject(it.encodeToByteArray()) }
            } catch (e: ChirpException) {
                if (e.code == "MLS_FAILED") throw ChirpException("RECOVERY_INVALID")
                throw e
            }
            val rootKey = payload.text("root_public_key")
            verify(payload.text("service_origin") == grant.origin && payload.text("account_id") == grant.account &&
                (expectedRoot == null || rootKey == expectedRoot), "RECOVERY_ACCOUNT_MISMATCH")
            verify(payload.int("payload_version") == 1 && payload.text("identity_protocol") == GROUP_PROTOCOL &&
                payload.text("root_algorithm") == "Ed25519" && payload.text("source_platform") in setOf("Android", "iOS", "macOS", "Windows"),
                "RECOVERY_INVALID")
            Instant.parse(payload.text("created_at"))
            val root = payload.text("root_seed").base64Bytes(32)
            try { verify(publicKey(root) == rootKey, "RECOVERY_INVALID"); use(root) } finally { root.fill(0) }
        }

    private fun newCandidate(root: ByteArray): LocalDevice {
        val seed = randomBytes(32)
        return try { LocalDevice(base64(seed), DeviceIdentity.issue(root, publicKey(seed))) } finally { seed.fill(0) }
    }

    suspend fun resume(password: String) = LogEvent.resumeSetup.measure(started = true) {
        verify(step == SetupStep.Resume, "RECOVERY_INVALID")
        val file = backupBytes()
        val expected = record.backupRoot ?: record.candidate?.device?.accountKey ?: grant.root.ifEmpty { null }
        val candidate = unlock(file, password, expected) { root ->
            record.candidate?.takeIf { it.device.accountKey == publicKey(root) && runCatching { it.validate() }.isSuccess }
                ?: newCandidate(root)
        }
        save(record.copy(candidate = candidate, backupRoot = candidate.device.accountKey,
            confirmed = record.exported && record.confirmedDigest == digest(file)))
        locked = false
    }

    fun clearBackupVerification() { backupVerified = false }

    suspend fun verifyBackup(file: ByteArray, password: String) = LogEvent.verifyBackup.measure(started = true) {
        backupVerified = false
        verify(step == SetupStep.Saved, "RECOVERY_INVALID")
        val root = record.backupRoot ?: requireNotNull(record.candidate).device.accountKey
        unlock(file, password, root) {}
        backupVerified = true
    }

    suspend fun restore(file: ByteArray, password: String) = LogEvent.restoreIdentity.measure(started = true) {
        verify(grant.root.isNotEmpty(), "RECOVERY_INVALID")
        val candidate = unlock(file, password, grant.root, ::newCandidate)
        save(record.copy(candidate = candidate, backup = null, backupRoot = null, confirmedDigest = null, exported = false, confirmed = false))
    }

    suspend fun pairingKey(): String {
        verify(grant.root.isNotEmpty(), "IDENTITY_INVALID")
        record.pairingSeed?.let { return it }
        val seed = base64(randomBytes(32))
        save(record.copy(pairingSeed = seed))
        return seed
    }

    suspend fun paired(device: DeviceIdentity) {
        val next = LocalDevice(requireNotNull(record.pairingSeed), device)
        next.validate()
        verify(device.accountKey == grant.root, "IDENTITY_INVALID")
        save(record.copy(candidate = next, backup = null, exported = false, confirmed = false))
    }

    suspend fun finish(requireClock: () -> Unit): Login {
        requireClock()
        grant.validate(connection)
        verify(step == SetupStep.Activate, "IDENTITY_INVALID")
        val local = record.candidate?.takeIf { grant.root.isEmpty() || it.device.accountKey == grant.root }
            ?: requireNotNull(record.active)
        local.validate()
        verify(grant.root.isNotEmpty() || (record.confirmed && record.exported && record.backup != null &&
            record.confirmedDigest == digest(backupBytes())), "RECOVERY_SAVE_REQUIRED")
        val body = buildJsonObject {
            put("setup_token", grant.token); put("code_verifier", verifier); put("device", local.device.toWire())
        }
        suspend fun post(action: String, value: JsonObject) = http.json(
            connection.passkeyOrigin.path("api", "client", "identity", action).request().clientVersion().jsonPost(value).build(), operation = if (action == "challenge") LogEvent.identityChallenge else LogEvent.identityComplete).second
        val challenge = post("challenge", body).text("challenge")
        requireClock()
        val proof = message("Chirp identity activation v1", grant.origin, grant.account, "chirp-android",
            digest(grant.token.encodeToByteArray()), digest(verifier.encodeToByteArray()), challenge,
            local.device.accountKey, local.device.hash())
        val response = post("complete", buildJsonObject {
            body.forEach { (k,v) -> put(k,v) }; put("signature", local.sign(proof)); put("device_name", Build.MODEL.take(64))
        })
        val member = response.obj("member")
        val login = Login(response.text("credential"), response.text("participant_identity"), member.text("display_name"),
            response.long("expires_at"), response.obj("device_identity").decode<DeviceIdentity>())
        login.validate()
        verify(login.device == local.device && member.bool("enabled") && member.text("id") == grant.account &&
            login.memberID == grant.account, "IDENTITY_INVALID")
        rememberIdentity(local)
        save(SetupRecord(active = local))
        return login
    }
    suspend fun pairingStart(request: JsonObject): JsonObject = http.json(connection.passkeyOrigin.path("api","client","identity","pairing","start")
        .request().clientVersion().jsonPost(buildJsonObject {
            put("setup_token", grant.token); put("code_verifier", verifier); put("request", request)
        }).build(), operation = LogEvent.pairingStart).second

    companion object {
        fun scope(origin: String, account: String) = "device|$origin|$account"
        suspend fun loadRecord(vault: IdentityVault, scope: String): SetupRecord =
            vault.read(scope)?.let { wireJson.decodeFromString<SetupRecord>(it) } ?: SetupRecord()
    }
}

internal fun validRecoveryPassword(password: String) = password.codePointCount(0, password.length) >= 16 &&
    password.length <= 1024 && password.toByteArray(Charsets.UTF_8).size <= 1024
