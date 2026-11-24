package cn.youzifeile.chirp.data

import android.os.SystemClock
import cn.youzifeile.chirp.media.MlsNative
import java.io.Closeable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

internal fun String.pairingInputDigits(): String? {
    if (any { it !in '0'..'9' && it !in " -\t\r\n" }) return null
    return filter { it in '0'..'9' }
}

internal fun String.pairingCodeDigits(): String? = pairingInputDigits()?.takeIf { it.length == 12 }

@Serializable internal data class PairRequest(val version: Int = 1, val origin: String,
    @SerialName("account_id") val account: String, @SerialName("account_key") val root: String,
    @SerialName("device_key") val key: String, val nonce: String, @SerialName("expires_at") val expires: Long,
    val commitment: String = "", val signature: String = "") {
    fun context() = digest(message("Chirp device pairing context v1",version.toString(),origin,account,root,key,nonce,expires.toString()))
    fun message() = message("Chirp device pairing request v1",context(),commitment)
    fun hash() = signedDigest("Chirp device pairing digest v1",message(),signature)
    fun code() = PREFIX + base64(toWire().toString().encodeToByteArray())
    fun validate() {
        val server = validatedHttpUrl(origin, cn.youzifeile.chirp.BuildConfig.DEBUG)
        verify(expires > nowSeconds(), "DEVICE_PAIRING_EXPIRED")
        verify(version == 1 && server.identityOrigin == origin && account.isNotBlank() &&
            account.none { it.isISOControl() } && account.encodeToByteArray().size <= 128 && root != key &&
            expires <= nowSeconds()+300, "DEVICE_PAIRING_INVALID")
        listOf(root,key,nonce,commitment).forEach { it.base64Bytes(32) }
        verifySignature(key,signature,message())
    }
    companion object {
        const val PREFIX = "chirp-device-pair-v1:"
        fun parse(code: String): PairRequest {
            verify(code.startsWith(PREFIX) && code.length <= 4096, "PAIR_INVALID_QR")
            return try {
                parseObject(code.removePrefix(PREFIX).base64Bytes(1,3072)).decode<PairRequest>().also { it.validate() }
            } catch (e: Exception) {
                if (e is ChirpException && e.code == "DEVICE_PAIRING_EXPIRED") throw e
                throw ChirpException("PAIR_INVALID_QR")
            }
        }
    }
}

@Serializable private data class PairAction(@SerialName("request_id") val requestId: String,val action: String,
    val issuer: DeviceIdentity,val payload: String,val nonce: String,@SerialName("created_at") val created: Long,val signature: String = "") {
    fun message() = message("Chirp device pairing action v1",requestId,action,issuer.hash(),digest(payload.encodeToByteArray()),nonce,created.toString())
    fun validate(request: PairRequest, expected: String) {
        verify(action == expected && requestId == request.hash() && payload.encodeToByteArray().size <= 16384 &&
            created <= nowSeconds()+60 && created in (request.expires-360)..request.expires, "DEVICE_PAIRING_INVALID")
        nonce.base64Bytes(32)
        val key = if (action in setOf("reveal","new-confirm")) request.key else {
            issuer.validate()
            verify(issuer.accountKey == request.root && issuer.leaf != request.key && issuer.certificates.size < 8 &&
                issuer.certificates.last().canEnroll, "DEVICE_PAIRING_INVALID")
            issuer.leaf
        }
        verifySignature(key,signature,message())
    }
}

internal class DevicePairing private constructor(val request: PairRequest, val approving: Boolean, private val seed: ByteArray,
    private var issuer: DeviceIdentity, private val native: MlsNative, val connection: ServerConnection, private val http: ChirpHttp,
    private val requireClock: () -> Unit, private val scopeIsCurrent: () -> Boolean) : Closeable {
    private val lock = Mutex()
    private val deadline = SystemClock.elapsedRealtime() + (request.expires - nowSeconds()).coerceIn(0,300)*1000
    private val queued = ArrayDeque<PairAction>()
    private val transcript = mutableMapOf<String,PairAction>()
    private var complete = false
    private var grantEnrollment = false
    private var mismatches = 0
    private var closed = false
    var decimals = emptyList<Int>()
        private set
    var confirmed = false
        private set
    var approval: DeviceIdentity? = null
        private set
    fun remainingSeconds(): Long = minOf(request.expires - nowSeconds(),
        (deadline - SystemClock.elapsedRealtime() + 999) / 1000).coerceAtLeast(0)

    private fun checkActive() {
        requireClock()
        verify(scopeIsCurrent(), "PAIR_IDENTITY_CHANGED")
        verify(!closed && remainingSeconds() > 0,"DEVICE_PAIRING_EXPIRED")
        request.validate()
    }
    private fun action(op: String, payload: String = ""): PairAction {
        val a = PairAction(request.hash(),op,issuer,payload,base64(randomBytes(32)),nowSeconds())
        return a.copy(signature = sign(seed,a.message()))
    }
    private fun actionRequest(a: PairAction) = connection.passkeyOrigin.path("api","client","identity","pairing","action")
        .request().clientVersion().jsonPost(a.toWire()).build()
    private suspend fun post(a: PairAction): JsonObject = http.json(actionRequest(a), operation = LogEvent.pairingAction).second
    suspend fun poll() = lock.withLock {
        checkActive()
        if (queued.isEmpty()) receive(post(action(if (approving) "poll-old" else "poll-new")))
        flush()
    }
    private suspend fun flush() {
        while (queued.isNotEmpty()) {
            checkActive()
            val reply = post(queued.first())
            checkActive(); queued.removeFirst(); receive(reply)
        }
    }
    suspend fun confirm(code: String?, canEnroll: Boolean, unlock: (suspend () -> Boolean)? = null) = lock.withLock {
        LogEvent.confirmNewDevice.measure(started = true) {
            checkActive()
            verify(!confirmed && decimals.size == 3,"DEVICE_PAIRING_INVALID")
            if (code != null && code.pairingCodeDigits() != decimals.joinToString("")) {
                if (++mismatches >= 3) close()
                throw ChirpException("PAIR_CODE_MISMATCH")
            }
            if (approving) {
                verify(unlock?.invoke() == true, "PAIR_UNLOCK_REQUIRED")
                checkActive()
            }
            val result = native.security("sas_confirm","id" to request.nonce)
            grantEnrollment = approving && canEnroll
            confirmed = true; accept(result)
            queued.add(action(if (approving) "old-confirm" else "new-confirm",result.text("message")))
            flush()
        }
    }
    private fun accept(result: JsonObject) {
        (result["decimals"] as? JsonArray)?.let { list ->
            val next = list.map { it.jsonPrimitive.int }
            verify(next.size == 3 && next.all { it in 1000..9191 } && (decimals.isEmpty() || decimals == next))
            decimals = next
        }
        if (result["complete"] == JsonPrimitive(true)) complete = true
    }
    private fun receive(state: JsonObject) {
        checkActive()
        verify(state.obj("request").decode<PairRequest>() == request, "DEVICE_PAIRING_INVALID")
        verify(state["cancelled"] != JsonPrimitive(true), "DEVICE_PAIRING_CANCELLED")
        val fields = listOf("offer" to "offer","reveal" to "reveal","new_confirmation" to "new-confirm",
            "old_confirmation" to "old-confirm","approval" to "approve")
        for ((field,op) in fields) {
            val a = (state[field] as? JsonObject)?.decode<PairAction>() ?: continue
            a.validate(request,op)
            if (op == "offer" && issuer.certificates.isEmpty()) issuer = a.issuer
            verify(issuer == a.issuer && (op == "offer" || "offer" in transcript))
            val old = transcript.putIfAbsent(op,a)
            if (old != null) { verify(old == a); continue }
            when {
                op == "offer" && !approving -> {
                    val result = native.security("sas_receive","id" to request.nonce,"message" to a.payload)
                    accept(result); queued.add(action("reveal",result.text("message")))
                }
                op == "reveal" && approving || op == (if (approving) "new-confirm" else "old-confirm") ->
                    accept(native.security("sas_receive","id" to request.nonce,"message" to a.payload))
                op == "approve" -> {
                    verify(complete && confirmed && "new-confirm" in transcript && "old-confirm" in transcript)
                    val device = parseObject(a.payload.encodeToByteArray()).obj("device").decode<DeviceIdentity>()
                    device.validate()
                    verify(device.accountKey == request.root && device.leaf == request.key &&
                        device.certificates.dropLast(1) == issuer.certificates)
                    approval = device
                }
            }
        }
        if (approving && complete && confirmed && "new-confirm" in transcript && "old-confirm" in transcript &&
            "approve" !in transcript && queued.none { it.action == "approve" }) {
            val device = DeviceIdentity.issue(seed, request.key, issuer, grantEnrollment)
            queued.add(action("approve",buildJsonObject { put("device",device.toWire()) }.toString()))
        }
    }
    private fun stop(): PairAction? {
        if (closed) return null
        val cancellation = if (approval == null && scopeIsCurrent() && request.expires > nowSeconds()) {
            runCatching { action(if (approving) "cancel-old" else "cancel-new") }.getOrNull()
        } else null
        closed = true
        seed.fill(0)
        native.close()
        queued.clear()
        decimals = emptyList()
        return cancellation
    }
    suspend fun cancel() { stop()?.let { LogEvent.stopPairing.measure { post(it) } } }
    override fun close() {
        val cancellation = stop() ?: return
        LogEvent.stopPairing.record()
        // A dismissed screen loses its coroutine scope before the server can acknowledge cancellation.
        val span = LogEvent.pairingAction.begin()
        http.client.newCall(actionRequest(cancellation)).enqueue(object : okhttp3.Callback {
            override fun onFailure(call: okhttp3.Call, e: java.io.IOException) { span?.finish(e) }
            override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) { response.use { span?.finish(status = it.code) } }
        })
    }

    companion object {
        suspend fun create(setup: IdentitySetup,http: ChirpHttp, requireClock: () -> Unit,
            scopeIsCurrent: () -> Boolean = { true }): DevicePairing = LogEvent.newDevicePairing.measure(started = true) {
            requireClock()
            val native = MlsNative("device-pairing")
            val seed = setup.pairingKey().base64Bytes(32)
            try {
                val grant = setup.grant
                val r = PairRequest(origin = grant.origin,account = grant.account,root = grant.root,key = publicKey(seed),
                    nonce = base64(randomBytes(32)),expires = minOf(grant.expires-3,nowSeconds()+297))
                val start = native.security("sas_start","id" to r.nonce,"context" to r.context())
                val committed = r.copy(commitment = parseObject(start.text("message").encodeToByteArray()).text("commitment"))
                val req = committed.copy(signature = sign(seed,committed.message()))
                val session = DevicePairing(req, false, seed, DeviceIdentity("", emptyList()), native,
                    setup.connection, http, requireClock, scopeIsCurrent)
                session.checkActive()
                session.receive(setup.pairingStart(req.toWire()))
                session
            } catch (e: Throwable) { seed.fill(0); native.close(); throw e }
        }
        suspend fun approve(req: PairRequest,local: LocalDevice,connection: ServerConnection,http: ChirpHttp, requireClock: () -> Unit,
            scopeIsCurrent: () -> Boolean = { true }): DevicePairing {
            requireClock()
            req.validate(); local.validate()
            verify(req.origin == connection.passkeyOrigin.identityOrigin && req.root == local.device.accountKey &&
                req.key != local.device.leaf && local.device.certificates.last().canEnroll && local.device.certificates.size < 8)
            val native = MlsNative("device-pairing")
            val seed = local.seed.base64Bytes(32)
            try {
                val session = DevicePairing(req, true, seed, local.device, native, connection, http, requireClock, scopeIsCurrent)
                session.checkActive()
                val result = native.security("sas_accept","id" to req.nonce,"context" to req.context(),"commitment" to req.commitment)
                session.queued.add(session.action("offer",result.text("message")))
                return session
            } catch (e: Throwable) { seed.fill(0); native.close(); throw e }
        }
    }
}
