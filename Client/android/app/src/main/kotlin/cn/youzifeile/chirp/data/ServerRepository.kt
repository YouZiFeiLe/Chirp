@file:kotlinx.serialization.UseSerializers(StoredHttpUrl::class)

package cn.youzifeile.chirp.data

import cn.youzifeile.chirp.BuildConfig
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl
import okhttp3.Request

internal object StoredHttpUrl : kotlinx.serialization.KSerializer<HttpUrl> {
    override val descriptor = kotlinx.serialization.descriptors.PrimitiveSerialDescriptor("HttpUrl", kotlinx.serialization.descriptors.PrimitiveKind.STRING)
    override fun serialize(encoder: kotlinx.serialization.encoding.Encoder, value: HttpUrl) = encoder.encodeString(value.toString())
    override fun deserialize(decoder: kotlinx.serialization.encoding.Decoder): HttpUrl = validatedHttpUrl(decoder.decodeString(), BuildConfig.DEBUG)
}

@Serializable
internal data class ServerConnection(
    val origin: HttpUrl,
    val api: HttpUrl,
    val group: HttpUrl,
    val register: HttpUrl?,
    val deviceStart: HttpUrl,
    val devicePoll: HttpUrl,
    val deviceCancel: HttpUrl,
    val deviceVerify: HttpUrl,
    val defaultRoom: String,
    val availableUpdate: String?,
    val passkeyOrigin: HttpUrl = origin,
    val authorize: HttpUrl = passkeyOrigin.path("client", "login"),
    val exchange: HttpUrl = passkeyOrigin.path("api", "client", "exchange"),
    val deviceLogin: Boolean = true,
    val nativeLogin: Boolean = false,
    val updatePolicy: VersionPolicy? = null,
) {
    val authorizationBase: HttpUrl get() {
        val service = validatedHttpUrl(passkeyOrigin.toString(), BuildConfig.DEBUG)
        verify(service.encodedPath == "/", "INVALID_SERVER_ADDRESS")
        return service.path("authorization", "v5", "")
    }

    fun validateSaved(discovery: String) {
        verify(origin == parseServerAddress(discovery, BuildConfig.DEBUG) &&
            roomIDPattern.matches(defaultRoom) && passkeyOrigin.encodedPath == "/" &&
            (!origin.isHttps || (api.isHttps && group.isHttps && passkeyOrigin.isHttps)) &&
            listOfNotNull(authorize, exchange, deviceStart, devicePoll, deviceCancel, deviceVerify, register).all { it.sameOrigin(passkeyOrigin) })
    }

    fun signaling(raw: String): String {
        val secure = raw.startsWith("wss://", true)
        verify(secure || raw.startsWith("ws://", true))
        val httpScheme = if (secure) "https:" else "http:"
        val url = validatedHttpUrl(httpScheme + raw.substringAfter(':'), cn.youzifeile.chirp.BuildConfig.DEBUG)
        verify(!origin.isHttps || secure)
        val wsScheme = if (secure) "wss:" else "ws:"
        return wsScheme + url.toString().substringAfter(':').trimEnd('/')
    }
}

internal data class Login(
    val credential: String,
    val identity: String,
    val name: String,
    val expiresAt: Long,
    val device: DeviceIdentity? = null,
) {
    val memberID: String get() = identity.substringBefore('.')

    fun validate(now: Long = nowSeconds()) {
        verify(credential.startsWith("chirp_") && tokenPattern.matches(credential.removePrefix("chirp_")) &&
            identity.matches(Regex("member_[A-Za-z0-9_-]{16}\\.login_[A-Za-z0-9_-]{16}")) &&
            validName(name) && expiresAt > now && expiresAt <= now + 20 * 3600 + 60)
    }

    companion object {
        fun fromResponse(response: JsonObject, account: String, device: DeviceIdentity): Login {
            val member = response.obj("member")
            val login = Login(response.text("credential"), response.text("participant_identity"), member.text("display_name"),
                response.long("expires_at"), response.obj("device_identity").decode<DeviceIdentity>())
            verify(member.bool("enabled"), "MEMBER_DISABLED")
            verify(member.text("id") == account && login.memberID == account && login.device == device &&
                login.expiresAt <= device.deadline, "CLIENT_INVALID_LOGIN_SESSION")
            login.validate()
            return login
        }
    }
}

internal data class DeviceLogin(
    val requestID: String,
    val verifier: String,
    val browserURL: HttpUrl,
    val expiresAt: Long,
    val interval: Long,
) {
    fun proof() = buildJsonObject {
        put("request_id", requestID)
        put("code_verifier", verifier)
    }
}

@Serializable
internal data class NativeLogin(
    val discovery: String, val passkeyOrigin: String, val exchange: String, val state: String, val verifier: String,
    val expires: Long, val apiOrigin: String, val groupOrigin: String,
    val taskId: Int? = null,
) {
    fun matches(connection: ServerConnection) = connection.nativeLogin && expires > nowSeconds() &&
        discovery == connection.origin.toString() && passkeyOrigin == connection.passkeyOrigin.toString() &&
        exchange == connection.exchange.toString() && apiOrigin == connection.api.identityOrigin && groupOrigin == connection.group.identityOrigin

    fun authorizationURL(connection: ServerConnection): HttpUrl {
        verify(matches(connection), "INVALID_LOGIN_CALLBACK")
        return connection.authorize.newBuilder()
            .addQueryParameter("client_id", CLIENT_ID).addQueryParameter("redirect_uri", REDIRECT)
            .addQueryParameter("state", state).addQueryParameter("code_challenge", base64url(sha256(verifier.encodeToByteArray())))
            .addQueryParameter("code_challenge_method", "S256").build()
    }

    fun code(callback: String): String {
        verify(expires > nowSeconds() && callback.length <= 512 && callback.startsWith(REDIRECT + "?"), "INVALID_LOGIN_CALLBACK")
        val pairs = callback.substringAfter('?').split('&')
        verify(pairs.size == 2 && "state=$state" in pairs, "INVALID_LOGIN_CALLBACK")
        return pairs.singleOrNull { it.startsWith("code=") }?.removePrefix("code=")?.takeIf(tokenPattern::matches)
            ?: throw ChirpException("INVALID_LOGIN_CALLBACK")
    }

    companion object {
        const val CLIENT_ID = "chirp-android"
        const val REDIRECT = "cn.youzifeile.chirp.android://auth/callback"
        const val PENDING = "pending-native-login-v1"
        fun create(connection: ServerConnection, taskId: Int? = null) = NativeLogin(connection.origin.toString(), connection.passkeyOrigin.toString(),
            connection.exchange.toString(), base64url(randomBytes(32)), base64url(randomBytes(32)), nowSeconds() + 300,
            connection.api.identityOrigin, connection.group.identityOrigin, taskId)
    }
}

internal class ServerRepository(private val http: ChirpHttp) {
    suspend fun discover(address: String): ServerConnection {
        val origin = parseServerAddress(address, BuildConfig.DEBUG)
        val (_, config) = http.json(origin.path("v1", "client-config").request().clientVersion().build(), operation = LogEvent.clientConfig)
        verify(config.text("service") == "chirp" && config.int("protocol_version") == 5)
        val policy = VersionPolicy.parse(config.obj("client_policy"))
        val current = ClientVersion(BuildConfig.VERSION_NAME, BuildConfig.CLIENT_BUILD)
        if (current < policy.minimum) throw ChirpException("CLIENT_UPDATE_REQUIRED", policy = policy)
        val passkeyOrigin = validatedHttpUrl(config.text("passkey_origin"), BuildConfig.DEBUG)
        verify(passkeyOrigin.encodedPath == "/" && (!origin.isHttps || passkeyOrigin.isHttps))
        val defaultRoom = config.text("default_room_id")
        verify(roomIDPattern.matches(defaultRoom))
        val caps = config.obj("capabilities")
        val deviceLogin = caps.bool("device_login")
        verify(caps.bool("dynamic_rooms") && caps.bool("state_events") &&
            caps.int("attachment_protocol") == 3 && caps.int("max_members") == 0 && caps.int("max_room_participants") == 0)
        val endpoints = config.obj("endpoints")
        fun endpoint(key: String, auth: Boolean = false) =
            discoveryEndpoint(origin, endpoints.text(key), BuildConfig.DEBUG, passkeyOrigin.takeIf { auth })

        fun deviceEndpoint(key: String): HttpUrl =
            if (deviceLogin || key in endpoints) endpoint(key, true) else passkeyOrigin

        val registration = caps.bool("registration")
        val register = if (registration || "registration_url" in endpoints) endpoint("registration_url", true) else null
        val connection = ServerConnection(
            origin, endpoint("api_base_url").directory(), endpoint("group_base_url").directory(),
            register.takeIf { registration },
            deviceEndpoint("device_start_url"), deviceEndpoint("device_poll_url"),
            deviceEndpoint("device_cancel_url"), deviceEndpoint("device_verification_url"),
            defaultRoom, policy.latest.version.takeIf { current < policy.latest }, passkeyOrigin,
            endpoint("authorization_url", true), endpoint("token_url", true), deviceLogin,
            !deviceLogin || (caps.containsKey("android_native_login") && caps.bool("android_native_login")),
            updatePolicy = policy.takeIf { current < it.latest },
        )
        val (_, health) = http.json(endpoint("health_url").request().build(), operation = LogEvent.health)
        verify(health.text("service") == "chirp" && health.text("status") == "ok")
        return connection
    }

    suspend fun refresh(connection: ServerConnection): ServerConnection {
        val refreshed = discover(connection.origin.toString())
        verify(refreshed.passkeyOrigin == connection.passkeyOrigin && refreshed.api.sameOrigin(connection.api) &&
            refreshed.group.sameOrigin(connection.group), "SERVER_CONFIGURATION_CHANGED")
        return refreshed
    }

    suspend fun exchange(connection: ServerConnection, login: NativeLogin, code: String): IdentityGrant {
        verify(login.matches(connection) && tokenPattern.matches(code), "INVALID_LOGIN_CALLBACK")
        val body = buildJsonObject {
            put("code", code); put("code_verifier", login.verifier)
            put("client_id", NativeLogin.CLIENT_ID); put("redirect_uri", NativeLogin.REDIRECT)
        }
        val request = connection.exchange.request().clientVersion().post(LoginCodeBody(body)).build()
        return http.json(request, operation = LogEvent.exchangeLogin).second
            .decode<IdentityGrant>().receivedAt(nowSeconds()).also { it.validate(connection) }
    }

    suspend fun beginLogin(connection: ServerConnection): DeviceLogin {
        verify(connection.deviceLogin, "INVALID_RESPONSE")
        val verifier = base64url(randomBytes(32))
        val body = buildJsonObject {
            put("client_id", "chirp-android")
            put("code_challenge", base64url(sha256(verifier.encodeToByteArray())))
            put("code_challenge_method", "S256")
        }
        val (_, response) = http.json(connection.deviceStart.request().clientVersion().jsonPost(body).build(), setOf(201), operation = LogEvent.deviceLoginStart)
        val request = response.text("request_id")
        val deadline = response.long("expires_at")
        val interval = response.long("interval")
        val expected = connection.deviceVerify.newBuilder().addQueryParameter("request", request).build()
        verify(tokenPattern.matches(request) && response.text("verification_uri") == expected.toString() &&
            deadline in (nowSeconds() + 1)..(nowSeconds() + 240) && interval in 1..30)
        return DeviceLogin(request, verifier, expected, deadline, interval)
    }

    suspend fun poll(connection: ServerConnection, device: DeviceLogin): IdentityGrant? {
        verify(connection.deviceLogin)
        val (status, response) = http.json(connection.devicePoll.request().clientVersion().jsonPost(device.proof()).build(),
            setOf(200, 202), operation = LogEvent.deviceLoginPoll)
        if (status == 202) {
            verify(response.text("status") == "pending")
            return null
        }
        return response.decode<IdentityGrant>().receivedAt(nowSeconds()).also { it.validate(connection) }
    }

    suspend fun cancel(connection: ServerConnection, device: DeviceLogin) {
        verify(connection.deviceLogin)
        http.json(connection.deviceCancel.request().clientVersion().jsonPost(device.proof()).build(), setOf(204), operation = LogEvent.deviceLoginCancel)
    }

}

internal fun Request.Builder.clientVersion(): Request.Builder =
    header("X-Chirp-Platform", "android").header("X-Chirp-Version", BuildConfig.VERSION_NAME)
        .header("X-Chirp-Build", BuildConfig.CLIENT_BUILD.toString())

@Serializable
internal data class VersionPolicy(val latest: ClientVersion, val minimum: ClientVersion) {
    companion object {
        fun parse(json: kotlinx.serialization.json.JsonObject): VersionPolicy {
            verify(json.text("platform") == "android")
            val latest = ClientVersion(json.text("latest_version"), json.int("latest_build"))
            val minimum = ClientVersion(json.text("minimum_version"), json.int("minimum_build"))
            verify(minimum <= latest)
            return VersionPolicy(latest, minimum)
        }
    }
}

@Serializable
internal data class ClientVersion(val version: String, val build: Int) : Comparable<ClientVersion> {
    private val numbers: List<Int>
        get() = version.split('.').map(String::toInt)

    init {
        verify(version.matches(Regex("(0|[1-9][0-9]{0,5})(\\.(0|[1-9][0-9]{0,5})){2}")) && build > 0)
    }

    override fun compareTo(other: ClientVersion): Int {
        val left = numbers
        val right = other.numbers
        for (i in left.indices) {
            if (left[i] != right[i]) return left[i].compareTo(right[i])
        }
        return build.compareTo(other.build)
    }
}
