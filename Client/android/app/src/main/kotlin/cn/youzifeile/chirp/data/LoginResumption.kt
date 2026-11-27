package cn.youzifeile.chirp.data

import java.util.Base64
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal class ActivatedLogin(val login: Login, val saved: SavedLogin?)

@Serializable
internal class SavedLogin(
    val token: String,
    val connection: ServerConnection,
    val account: String,
    val participant: String,
    val deviceDigest: String,
    val expiresAt: Long,
) {
    fun proofMessage(challenge: String): ByteArray {
        verify(isNonce(challenge), "RESUMPTION_PROOF_INVALID")
        return message("Chirp login resumption v1", connection.passkeyOrigin.identityOrigin, "android", participant,
            digest(token.encodeToByteArray()), challenge, deviceDigest)
    }

    fun checkDeadline(now: Long = nowSeconds()) = verify(now < expiresAt, "SESSION_EXPIRED")

    suspend fun restore(
        server: ServerRepository,
        http: ChirpHttp,
        activeDevice: suspend (String, String) -> LocalDevice?,
        requireReady: () -> Unit,
    ): Pair<SessionRepository, LocalDevice> {
        fun checkReady() {
            checkDeadline()
            requireReady()
        }
        checkReady()
        connection.validateSaved(connection.origin.toString())
        val current = server.refresh(connection)
        verify(current.api == connection.api && current.group == connection.group, "SERVER_CONFIGURATION_CHANGED")
        val origin = current.passkeyOrigin.identityOrigin
        val local = activeDevice(origin, account) ?: throw ChirpException("DEVICE_IDENTITY_REQUIRED")
        local.validate()
        verify(local.device.hash() == deviceDigest && expiresAt <= local.device.deadline, "CLIENT_INVALID_LOGIN_SESSION")

        suspend fun post(action: String, signature: String? = null): JsonObject {
            checkReady()
            val body = buildJsonObject {
                put("resume_token", token)
                if (signature != null) put("signature", signature)
            }
            val request = current.passkeyOrigin.path("api", "client", "resume", action).request().clientVersion()
                .header("Cache-Control", "no-store").post(OneShotJsonBody(body)).build()
            return http.json(request, operation = if (signature == null) LogEvent.resumeChallenge else LogEvent.resumeComplete).second
        }
        val challenge = post("challenge").text("challenge")
        checkReady()
        val response = post("complete", local.sign(proofMessage(challenge)))
        checkReady()
        val login = Login.fromResponse(response, account, local.device)
        verify(login.identity == participant && login.expiresAt == expiresAt &&
            activeDevice(origin, account)?.device == local.device, "CLIENT_INVALID_LOGIN_SESSION")
        checkReady()
        return SessionRepository(current, login, http) to local
    }

    companion object {
        private fun isNonce(value: String) = tokenPattern.matches(value) &&
            base64url(Base64.getUrlDecoder().decode(value)) == value

        fun fromActivation(response: JsonObject, login: Login, connection: ServerConnection): SavedLogin? {
            val token = (response["resume_token"] as? JsonPrimitive)?.takeIf {
                it.isString && it.content.startsWith("resume-v1_") && isNonce(it.content.removePrefix("resume-v1_"))
            }
                ?.content ?: return null
            val device = login.device ?: return null
            return SavedLogin(token, connection, login.memberID, login.identity, device.hash(), login.expiresAt)
        }
    }
}

internal fun ClientFailure.endsSavedLogin() = code in setOf(
    "SESSION_EXPIRED", "INVALID_AUTHORIZATION", "UNAUTHORIZED", "MEMBER_DISABLED", "IDENTITY_BLACKLISTED",
    "DEVICE_IDENTITY_REQUIRED", "IDENTITY_INVALID", "IDENTITY_EXPIRED", "CLIENT_INVALID_LOGIN_SESSION",
    "LOGIN_BIOMETRICS_CHANGED", "CLIENT_UPDATE_REQUIRED", "SERVER_CONFIGURATION_CHANGED",
)
