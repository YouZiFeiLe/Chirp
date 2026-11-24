package cn.youzifeile.chirp.data

import java.io.IOException
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

internal const val GROUP_PROTOCOL = "chirp-mls-authenticated-v5"
internal val roomIDPattern = Regex("[A-Za-z0-9_-]{1,64}")
internal val entryIDPattern = Regex("entry_[A-Za-z0-9_-]{32}")
internal val memberIDPattern = Regex("member_[A-Za-z0-9_-]{16}")
internal val entryIdentityPattern = Regex("member_[A-Za-z0-9_-]{16}\\.login_[A-Za-z0-9_-]{16}\\.entry_[A-Za-z0-9_-]{32}")
internal val tokenPattern = Regex("[A-Za-z0-9_-]{43}")
internal val wireJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }
internal val random = SecureRandom()

internal val clientErrorCode = Regex("[A-Z0-9_]{1,80}")

internal data class ClientFailure(val code: String, val retryAfterSeconds: Long? = null, val policy: VersionPolicy? = null)

internal fun Exception.clientFailure(fallback: String = "CLIENT_UNEXPECTED"): ClientFailure = when (this) {
    is ChirpException -> ClientFailure(code, retryAfterSeconds, policy)
    is java.io.InterruptedIOException -> ClientFailure("CLIENT_NETWORK_TIMEOUT")
    is java.net.UnknownHostException, is java.net.NoRouteToHostException -> ClientFailure("CLIENT_NETWORK_UNAVAILABLE")
    is IOException -> ClientFailure("CLIENT_NETWORK_FAILURE")
    else -> ClientFailure(fallback)
}

internal class ChirpException(val code: String, val status: Int = 0, val retryAfterSeconds: Long? = null,
    val policy: VersionPolicy? = null, val diagnosticCode: String = code) : IOException(code) {
    val sessionFailure: String? get() = when {
        status == 403 && code == "MEMBER_DISABLED" -> code
        status == 401 -> "SESSION_EXPIRED"
        code == "IDENTITY_BLACKLISTED" -> code
        else -> null
    }
}

internal fun verify(valid: Boolean, code: String = "INVALID_RESPONSE") {
    if (!valid) throw ChirpException(code)
}

internal fun nowSeconds(): Long = System.currentTimeMillis() / 1000
internal fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
internal fun base64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
internal fun base64url(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
internal fun randomBytes(size: Int): ByteArray = ByteArray(size).also(random::nextBytes)
internal fun String.base64Bytes(min: Int, max: Int = min): ByteArray {
    verify(length <= ((max + 2) / 3) * 4)
    val value = try {
        Base64.getDecoder().decode(this)
    } catch (_: IllegalArgumentException) {
        throw ChirpException("INVALID_RESPONSE")
    }
    verify(value.size in min..max && base64(value) == this)
    return value
}

internal fun validName(value: String): Boolean =
    value.isNotBlank() && value.codePointCount(0, value.length) <= 80 && value.none(Char::isISOControl)

internal fun JsonObject.text(key: String): String =
    (get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw ChirpException("INVALID_RESPONSE")
internal fun JsonObject.long(key: String): Long =
    (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull ?: throw ChirpException("INVALID_RESPONSE")
internal fun JsonObject.int(key: String): Int =
    (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull ?: throw ChirpException("INVALID_RESPONSE")
internal fun JsonObject.bool(key: String): Boolean =
    (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull ?: throw ChirpException("INVALID_RESPONSE")
internal fun JsonObject.obj(key: String): JsonObject =
    get(key) as? JsonObject ?: throw ChirpException("INVALID_RESPONSE")

internal fun HttpUrl.sameOrigin(other: HttpUrl): Boolean =
    scheme == other.scheme && host == other.host && port == other.port

internal fun parseServerAddress(raw: String, debugLoopback: Boolean): HttpUrl {
    val address = raw.trim()
    // Before the first slash, a scheme ends in ':' and a host with a port ends in a digit.
    val hasScheme = address.substringBefore('/').endsWith(':')
    val url = if (hasScheme) address else "https://$address"
    return validatedHttpUrl(url, debugLoopback).directory()
}

internal fun validatedHttpUrl(text: String, debugLoopback: Boolean): HttpUrl {
    val parsed = text.toHttpUrlOrNull()
    val authority = text.substringAfter("://", "").substringBefore('/')
    verify(parsed != null && text.length <= 2048 && authority.isNotEmpty() && '@' !in authority &&
        (text.startsWith("https://", true) || text.startsWith("http://", true)) &&
        !unsafeUrlCharacters(text) && !ambiguousPath(text.substringAfter("://", "").substringAfter('/', "")) &&
        (parsed.isHttps || (debugLoopback && parsed.host in setOf("localhost", "127.0.0.1", "::1"))) &&
        !cloudHost(parsed.host), "INVALID_SERVER_ADDRESS")
    return requireNotNull(parsed)
}

private fun ambiguousPath(path: String): Boolean = path.split('/').any { segment ->
    val dots = segment.replace("%2e", ".", ignoreCase = true)
    dots == "." || dots == ".." || segment.contains("%2f", true) || segment.contains("%5c", true)
}

internal fun discoveryEndpoint(base: HttpUrl, raw: String, debug: Boolean, authenticationOrigin: HttpUrl? = null): HttpUrl {
    verify(raw.isNotEmpty() && !unsafeUrlCharacters(raw) && !raw.startsWith("//"), "INVALID_SERVER_ADDRESS")
    val absolute = raw.startsWith("https://", true) || raw.startsWith("http://", true)
    val result = if (absolute) validatedHttpUrl(raw, debug) else {
        verify(authenticationOrigin == null && ':' !in raw.substringBefore('/') && !ambiguousPath(raw), "INVALID_SERVER_ADDRESS")
        val resolved = base.resolve(raw) ?: throw ChirpException("INVALID_SERVER_ADDRESS")
        validatedHttpUrl(resolved.toString(), debug)
    }
    verify((!base.isHttps || result.isHttps) && (authenticationOrigin == null || result.sameOrigin(authenticationOrigin)),
        "INVALID_SERVER_ADDRESS")
    return result
}

internal fun unsafeUrlCharacters(value: String): Boolean =
    value.any { it.isWhitespace() || it.isISOControl() || it in "\\?#" }

private fun cloudHost(raw: String): Boolean {
    val host = raw.trimEnd('.')
    return '*' in host || listOf("livekit.cloud", "livekit.run", "livekit.io").any {
        host == it || host.endsWith(".$it")
    }
}

internal fun HttpUrl.path(vararg segments: String): HttpUrl =
    newBuilder().apply { segments.forEach(::addPathSegment) }.build()

internal fun HttpUrl.directory(): HttpUrl =
    if (encodedPath.endsWith('/')) this else newBuilder().addPathSegment("").build()

internal fun JsonObject.unsigned(key: String): ULong =
    (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.content?.toULongOrNull()
        ?: throw ChirpException("INVALID_RESPONSE")
