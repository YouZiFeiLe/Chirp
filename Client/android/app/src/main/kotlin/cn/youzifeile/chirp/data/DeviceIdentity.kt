package cn.youzifeile.chirp.data

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import okhttp3.HttpUrl
import org.bouncycastle.math.ec.rfc8032.Ed25519

internal val HttpUrl.identityOrigin: String
    get() = "$scheme://${if (':' in host) "[$host]" else host}:$port"

internal fun record(domain: String, vararg fields: ByteArray): ByteArray {
    val bytes = ByteArrayOutputStream()
    DataOutputStream(bytes).use { out ->
        for (field in listOf(domain.encodeToByteArray()) + fields) {
            out.writeInt(field.size)
            out.write(field)
        }
    }
    return bytes.toByteArray()
}

internal fun message(domain: String, vararg fields: String) =
    record(domain, *fields.map(String::encodeToByteArray).toTypedArray())

internal fun digest(bytes: ByteArray) = base64(sha256(bytes))
internal fun signedDigest(domain: String, message: ByteArray, signature: String) =
    digest(record(domain, message, signature.encodeToByteArray()))

internal fun publicKey(seed: ByteArray): String {
    require(seed.size == 32)
    return base64(ByteArray(32).also { Ed25519.generatePublicKey(seed, 0, it, 0) })
}
internal fun sign(seed: ByteArray, data: ByteArray): String {
    require(seed.size == 32)
    return base64(ByteArray(64).also { Ed25519.sign(seed, 0, data, 0, data.size, it, 0) })
}
internal fun verifySignature(key: String, signature: String, data: ByteArray) {
    verify(Ed25519.verify(signature.base64Bytes(64), 0, key.base64Bytes(32), 0, data, 0, data.size), "IDENTITY_INVALID")
}
internal inline fun <reified T> T.toWire(): JsonObject = wireJson.encodeToJsonElement(this).jsonObject
internal inline fun <reified T> JsonObject.decode(): T = wireJson.decodeFromJsonElement(kotlinx.serialization.serializer<T>(), this)

@Serializable
internal data class DeviceCertificate(
    @SerialName("account_key") val accountKey: String,
    @SerialName("device_key") val deviceKey: String,
    @SerialName("issuer_key") val issuerKey: String,
    @SerialName("parent_hash") val parentHash: String,
    val serial: String,
    @SerialName("can_enroll") val canEnroll: Boolean,
    @SerialName("not_before") val notBefore: Long,
    @SerialName("not_after") val notAfter: Long,
    val signature: String = "",
) {
    fun message() = message("Chirp device certificate v5", accountKey, deviceKey, issuerKey, parentHash,
        serial, if (canEnroll) "1" else "0", notBefore.toString(), notAfter.toString())
    fun hash() = signedDigest("Chirp device certificate digest v5", message(), signature)
}

@Serializable
internal data class DeviceIdentity(@SerialName("account_key") val accountKey: String, val certificates: List<DeviceCertificate>) {
    val leaf get() = certificates.last().deviceKey
    val deadline get() = certificates.minOf { it.notAfter }
    fun hash() = digest(message("Chirp device identity digest v5", accountKey, certificates.size.toString(),
        *certificates.map { it.hash() }.toTypedArray()))

    fun validate(now: Long = nowSeconds()) {
        accountKey.base64Bytes(32)
        verify(certificates.size in 1..8, "IDENTITY_INVALID")
        val seen = mutableSetOf(accountKey)
        var issuer = accountKey
        var parent = ""
        var deadline = Long.MAX_VALUE
        certificates.forEachIndexed { index, cert ->
            cert.deviceKey.base64Bytes(32)
            cert.serial.base64Bytes(16)
            verify(cert.accountKey == accountKey && cert.issuerKey == issuer && cert.parentHash == parent &&
                seen.add(cert.deviceKey) && (cert.canEnroll || index == certificates.lastIndex) &&
                cert.notBefore > 0 && cert.notBefore <= now + 60 && cert.notAfter > maxOf(cert.notBefore, now) &&
                cert.notAfter <= deadline && cert.notAfter - cert.notBefore <= DEVICE_LIFETIME, "IDENTITY_INVALID")
            verifySignature(issuer, cert.signature, cert.message())
            issuer = cert.deviceKey
            parent = cert.hash()
            deadline = cert.notAfter
        }
    }

    companion object {
        const val DEVICE_LIFETIME = 5L * 365 * 24 * 3600
        fun issue(issuerSeed: ByteArray, newKey: String, issuer: DeviceIdentity? = null, canEnroll: Boolean = true): DeviceIdentity {
            val key = publicKey(issuerSeed)
            val root = issuer?.accountKey ?: key
            val start = nowSeconds()
            if (issuer != null) {
                issuer.validate()
                verify(issuer.leaf == key && issuer.certificates.last().canEnroll, "IDENTITY_INVALID")
            }
            val cert = DeviceCertificate(root, newKey, key, issuer?.certificates?.last()?.hash().orEmpty(),
                base64(randomBytes(16)), canEnroll, start, minOf(start + DEVICE_LIFETIME, issuer?.deadline ?: Long.MAX_VALUE))
            return DeviceIdentity(root, issuer?.certificates.orEmpty() + cert.copy(signature = sign(issuerSeed, cert.message())))
                .also { it.validate() }
        }
    }
}
