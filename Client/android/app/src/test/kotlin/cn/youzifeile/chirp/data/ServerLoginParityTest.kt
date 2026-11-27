package cn.youzifeile.chirp.data

import cn.youzifeile.chirp.BuildConfig
import java.io.IOException
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.SocketEffect
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import okio.Buffer

class ServerLoginParityTest {
    private val discovery = "https://discovery.example/chirp"
    private val auth = "https://keys.example:8443"
    private val healthy = """{"status":"ok","service":"chirp"}"""
    private val body = buildJsonObject {
        put("service", "chirp")
        put("protocol_version", 5)
        put("passkey_origin", auth)
        put("default_room_id", "main")
        putJsonObject("client_policy") {
            put("platform", "android")
            put("minimum_version", "0.0.1")
            put("minimum_build", 1)
            put("latest_version", BuildConfig.VERSION_NAME)
            put("latest_build", BuildConfig.CLIENT_BUILD)
        }
        putJsonObject("capabilities") {
            put("dynamic_rooms", true)
            put("state_events", true)
            put("registration", true)
            put("attachment_protocol", 3)
            put("device_login", false)
            put("max_members", 0)
            put("max_room_participants", 0)
        }
        putJsonObject("endpoints") {
            put("api_base_url", "api/")
            put("health_url", "status/api")
            put("group_base_url", "https://groups.example/coord/")
            put("authorization_url", auth + "/account/login")
            put("registration_url", auth + "/account/register")
            put("token_url", auth + "/account/token")
        }
    }

    private fun repository(config: JsonObject): ServerRepository {
        val builder = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            val result = when (request.url.toString()) {
                discovery + "/v1/client-config" -> {
                    assertEquals(BuildConfig.VERSION_NAME, request.header("X-Chirp-Version"))
                    assertEquals(BuildConfig.CLIENT_BUILD.toString(), request.header("X-Chirp-Build"))
                    config.toString()
                }
                discovery + "/status/api" -> healthy
                else -> error("Unexpected request to " + request.url)
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).message("OK")
                .code(200).body(result.toResponseBody()).build()
        }
        return ServerRepository(ChirpHttp(builder))
    }

    private fun localRepository(server: MockWebServer): ServerRepository {
        val builder = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            chain.proceed(request.newBuilder().url(server.url(request.url.encodedPath)).build())
        }
        return ServerRepository(ChirpHttp(builder))
    }

    private fun MockWebServer.enqueueDiscovery() {
        enqueue(MockResponse(body = body.toString()))
        enqueue(MockResponse(body = healthy))
    }

    @Test fun resumptionPinsTheServiceAccountDeviceAndOriginalExpiry() = runTest {
        val server = repository(body)
        val connection = server.discover(discovery)
        val seed = randomBytes(32)
        val local = LocalDevice(base64(seed), DeviceIdentity.issue(randomBytes(32), publicKey(seed)))
        val account = "member_" + "a".repeat(16)
        val login = Login("chirp_" + "a".repeat(43), account + ".login_" + "b".repeat(16), "Test", nowSeconds() + 300, local.device)
        val token = "resume-v1_" + base64url(randomBytes(32))
        assertNull(SavedLogin.fromActivation(buildJsonObject {}, login, connection))
        assertNull(SavedLogin.fromActivation(buildJsonObject { put("resume_token", login.credential) }, login, connection))
        val saved = requireNotNull(SavedLogin.fromActivation(buildJsonObject { put("resume_token", token) }, login, connection))
        assertFalse(wireJson.encodeToString(saved).contains(login.credential))
        val challenge = base64url(randomBytes(32))
        val rotated = "chirp_" + "c".repeat(43)
        val valid = buildJsonObject {
            put("credential", rotated); put("expires_at", login.expiresAt); put("participant_identity", login.identity)
            putJsonObject("member") { put("id", account); put("enabled", true); put("display_name", "Renamed") }
            put("device_identity", local.device.toWire())
        }
        val beyondCertificate = JsonObject(valid + ("expires_at" to JsonPrimitive(local.device.deadline + 1)))
        assertEquals("CLIENT_INVALID_LOGIN_SESSION",
            assertThrows(ChirpException::class.java) { Login.fromResponse(beyondCertificate, account, local.device) }.code)
        var reply = valid
        var proofExpired = true
        val actions = mutableListOf<String>()
        val http = ChirpHttp(OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            assertEquals(auth, request.url.toString().substringBefore("/api/client/resume/"))
            assertEquals("android", request.header("X-Chirp-Platform"))
            assertEquals(BuildConfig.VERSION_NAME, request.header("X-Chirp-Version"))
            assertEquals(BuildConfig.CLIENT_BUILD.toString(), request.header("X-Chirp-Build"))
            assertEquals("no-store", request.header("Cache-Control"))
            assertTrue(request.body!!.isOneShot())
            assertNull(request.header("Authorization"))
            val json = parseObject(Buffer().also { request.body!!.writeTo(it) }.readByteArray())
            assertEquals(token, json.text("resume_token"))
            val action = request.url.pathSegments.last()
            actions += action
            var status = 200
            val payload = when (action) {
                "challenge" -> buildJsonObject { put("challenge", challenge) }
                "complete" -> {
                    verifySignature(local.device.leaf, json.text("signature"), saved.proofMessage(challenge))
                    if (proofExpired) {
                        status = 409
                        buildJsonObject { putJsonObject("error") { put("code", "RESUMPTION_PROOF_INVALID") } }
                    } else reply
                }
                else -> error("Unexpected resumption request")
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).message("Test")
                .code(status).body(payload.toString().toResponseBody()).build()
        })
        val lookup: suspend (String, String) -> LocalDevice = { origin, id ->
            assertEquals(connection.passkeyOrigin.identityOrigin, origin); assertEquals(account, id); local
        }
        suspend fun restore() = saved.restore(server, http, lookup) {}.first.login
        val expiredProof = runCatching { restore() }.exceptionOrNull() as ChirpException
        assertEquals("RESUMPTION_PROOF_INVALID", expiredProof.code)
        assertFalse(expiredProof.clientFailure().endsSavedLogin())
        proofExpired = false
        assertEquals(login.copy(credential = rotated, name = "Renamed"), restore())
        assertEquals(listOf("challenge", "complete", "challenge", "complete"), actions)
        val wrongDevice = local.device.copy(certificates = local.device.certificates.map { it.copy(canEnroll = false) })
        for (change in listOf(
            "expires_at" to JsonPrimitive(login.expiresAt + 1),
            "participant_identity" to JsonPrimitive(account + ".login_" + "c".repeat(16)),
            "member" to buildJsonObject { put("id", "member_" + "d".repeat(16)); put("enabled", true); put("display_name", "Test") },
            "device_identity" to wrongDevice.toWire(),
        )) {
            reply = JsonObject(valid + change)
            assertEquals("CLIENT_INVALID_LOGIN_SESSION", (runCatching { restore() }.exceptionOrNull() as ChirpException).code)
        }
        actions.clear()
        val changedEndpoints = JsonObject(body.obj("endpoints") + ("api_base_url" to JsonPrimitive("/other/")))
        val changed = repository(JsonObject(body + ("endpoints" to changedEndpoints)))
        val failure = runCatching { saved.restore(changed, http, lookup) {} }.exceptionOrNull() as ChirpException
        assertEquals("SERVER_CONFIGURATION_CHANGED", failure.code)
        assertTrue(actions.isEmpty())
    }

    @Test fun permanentDenialsRemoveSavedLoginWhileARetryCanUseTheOriginalRecord() {
        for (code in listOf("INVALID_AUTHORIZATION", "MEMBER_DISABLED", "IDENTITY_BLACKLISTED", "CLIENT_UPDATE_REQUIRED",
            "LOGIN_BIOMETRICS_CHANGED", "DEVICE_IDENTITY_REQUIRED", "SESSION_EXPIRED")) {
            assertTrue(code, ClientFailure(code).endsSavedLogin())
        }
        for (code in listOf("CLIENT_NETWORK_FAILURE", "SERVER_UNAVAILABLE", "NETWORK_TIME_REQUIRED",
            "RESUMPTION_PROOF_INVALID", "CLIENT_LOCAL_UNLOCK_FAILED")) {
            assertFalse(code, ClientFailure(code).endsSavedLogin())
        }
    }

    @Test fun firstPasskeyRefreshAfterRegistrationRecoversFromAClosedPooledConnection() = runTest {
        MockWebServer().use { server ->
            server.start()
            val repository = localRepository(server)
            server.enqueueDiscovery()
            val registration = repository.discover(discovery)
            assertNotNull(registration.register)

            // Drop the reused connection after receiving the next GET, before sending its headers.
            server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build())
            server.enqueueDiscovery()
            val refreshed = repository.refresh(registration)
            assertEquals("/account/login", NativeLogin.create(refreshed).authorizationURL(refreshed).encodedPath)

            assertEquals(5, server.requestCount)
            val requests = List(5) { server.takeRequest() }
            val configPath = "/chirp/v1/client-config"
            assertEquals(listOf(configPath, "/chirp/status/api", configPath, configPath, "/chirp/status/api"),
                requests.map { it.url.encodedPath })
            assertEquals(requests[1].connectionIndex, requests[2].connectionIndex)
            assertNotEquals(requests[2].connectionIndex, requests[3].connectionIndex)
        }
    }

    @Test fun eachLoginCodeUsesANewConnectionWithoutDiscardingTheDiscoveryConnection() = runTest {
        MockWebServer().use { server ->
            server.start()
            val repository = localRepository(server)
            server.enqueueDiscovery()
            val connection = repository.discover(discovery)
            val grant = IdentityGrant("setup_" + "t".repeat(43), "member_" + "m".repeat(16), "Test",
                connection.passkeyOrigin.identityOrigin, "", nowSeconds() + 180)
            val codes = listOf("a".repeat(43), "b".repeat(43))
            for (code in codes) {
                server.enqueue(MockResponse(body = wireJson.encodeToString(grant)))
                assertEquals(grant, repository.exchange(connection, NativeLogin.create(connection), code))
            }
            server.enqueueDiscovery()
            repository.refresh(connection)

            assertEquals(6, server.requestCount)
            val requests = List(6) { server.takeRequest() }
            val exchanges = requests.subList(2, 4)
            assertEquals(codes, exchanges.map { parseObject(requireNotNull(it.body).toByteArray()).text("code") })
            val discoverySocket = requests.first().connectionIndex
            assertTrue(exchanges.all { it.connectionIndex != discoverySocket })
            assertNotEquals(exchanges[0].connectionIndex, exchanges[1].connectionIndex)
            assertEquals(discoverySocket, requests[4].connectionIndex)
        }
    }

    @Test fun loginCodeIsNotReplayedWhenTheServiceAsksForAnImmediateRetry() = runTest {
        MockWebServer().use { server ->
            server.start()
            val repository = localRepository(server)
            server.enqueueDiscovery()
            val connection = repository.discover(discovery)
            server.enqueue(MockResponse.Builder().code(503).addHeader("Retry-After", "0").build())
            server.enqueue(MockResponse(code = 400))

            val failure = runCatching { repository.exchange(connection, NativeLogin.create(connection), "x".repeat(43)) }.exceptionOrNull()
            assertEquals(503, (failure as? ChirpException)?.status)
            assertEquals(3, server.requestCount)
        }
    }

    @Test fun lostExchangeResponseDoesNotResubmitTheSingleUseLoginCode() = runTest {
        MockWebServer().use { server ->
            server.start()
            val repository = localRepository(server)
            server.enqueueDiscovery()
            val connection = repository.discover(discovery)
            server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build())
            server.enqueue(MockResponse(code = 400))

            val login = NativeLogin.create(connection)
            val failure = runCatching { repository.exchange(connection, login, "x".repeat(43)) }.exceptionOrNull()
            assertTrue(failure is IOException && failure !is ChirpException)
            assertEquals(3, server.requestCount)
            val exchange = List(3) { server.takeRequest() }.last()
            assertEquals("POST", exchange.method)
            assertEquals("/account/token", exchange.url.encodedPath)
        }
    }

    @Test fun discoveryRequiresThePublishedBuildWithinTheCurrentVersion() = runTest {
        val nextBuild = BuildConfig.CLIENT_BUILD + 1
        val policy = buildJsonObject {
            put("platform", "android")
            put("minimum_version", BuildConfig.VERSION_NAME)
            put("minimum_build", nextBuild)
            put("latest_version", BuildConfig.VERSION_NAME)
            put("latest_build", nextBuild)
        }
        val config = JsonObject(body + ("client_policy" to policy))
        val failure = runCatching { repository(config).discover(discovery) }.exceptionOrNull()
        assertEquals("CLIENT_UPDATE_REQUIRED", (failure as? ChirpException)?.code)
    }

    @Test fun discoveryCannotReplaceBundledSnapshotTrustOrChooseItsPath() = runTest {
        val advertised = JsonObject(body + mapOf(
            "public_key" to JsonPrimitive(base64(ByteArray(32))),
            "authorization_base_url" to JsonPrimitive("https://unused.example/other"),
        ))
        val connection = repository(advertised).discover(discovery)
        assertEquals("$auth/authorization/v5/snapshot", connection.authorizationBase.path("snapshot").toString())
        assertEquals("$auth/authorization/v5/append", connection.authorizationBase.path("append").toString())
        val restored = wireJson.decodeFromString<ServerConnection>(wireJson.encodeToString(connection))
        restored.validateSaved(connection.origin.toString())
        assertEquals(connection, restored)
        assertThrows(ChirpException::class.java) { restored.validateSaved("https://different.example/") }
    }

    @Test fun resolvesPrefixAndSplitHostsAndUsesNativeOnlyWhenDeviceFlowIsDisabled() = runTest {
        val connection = repository(body).discover(discovery.removePrefix("https://") + "/")
        assertEquals(discovery + "/", connection.origin.toString())
        assertEquals(discovery + "/api/", connection.api.toString())
        assertEquals("https://groups.example/coord/", connection.group.toString())
        assertEquals(auth + "/account/login", connection.authorize.toString())
        assertEquals(auth + "/account/token", connection.exchange.toString())
        assertTrue(connection.nativeLogin)
        assertFalse(connection.deviceLogin)
        assertEquals("wss://media.example:8444/rtc", connection.signaling("wss://media.example:8444/rtc"))
        for (url in listOf("ws://media.example/rtc", "wss://media.example/../signal", "wss://user@media.example/")) {
            assertThrows(ChirpException::class.java) { connection.signaling(url) }
        }
    }

    @Test fun retainsPollingForExistingServersAndPinsAuthenticationEndpoints() = runTest {
        val endpoints = body.obj("endpoints").toMutableMap()
        for (field in listOf("device_start_url", "device_poll_url", "device_cancel_url", "device_verification_url")) {
            endpoints[field] = JsonPrimitive(auth + "/" + field)
        }
        val old = JsonObject(body + ("capabilities" to JsonObject(body.obj("capabilities") + ("device_login" to JsonPrimitive(true)))) +
            ("endpoints" to JsonObject(endpoints)))
        val connection = repository(old).discover(discovery)
        assertTrue(connection.deviceLogin)
        assertFalse(connection.nativeLogin)
        endpoints["token_url"] = JsonPrimitive("https://other.example/token")
        val invalid = JsonObject(old + ("endpoints" to JsonObject(endpoints)))
        assertEquals("INVALID_SERVER_ADDRESS", (runCatching { repository(invalid).discover(discovery) }.exceptionOrNull() as ChirpException).code)
    }

    @Test fun localCallbackRequiresTheExactStateRedirectCodeAndOriginalTransaction() = runTest {
        val connection = repository(body).discover(discovery)
        val native = NativeLogin.create(connection)
        val url = native.authorizationURL(connection)
        assertEquals(NativeLogin.CLIENT_ID, url.queryParameter("client_id"))
        assertEquals(NativeLogin.REDIRECT, url.queryParameter("redirect_uri"))
        assertEquals("S256", url.queryParameter("code_challenge_method"))
        assertEquals(base64url(sha256(native.verifier.encodeToByteArray())), url.queryParameter("code_challenge"))
        assertNull(url.queryParameter("code_verifier"))
        val code = "x".repeat(43)
        val callback = NativeLogin.REDIRECT + "?code=" + code + "&state=" + native.state
        assertEquals(code, native.code(callback))
        listOf(callback.replace("android", "windows"), callback.replace(native.state, "incorrect"),
            callback.replace(code, "short"), callback + "&code=" + code, callback + "#fragment").forEach { invalid ->
            assertThrows(ChirpException::class.java) { native.code(invalid) }
        }
        assertThrows(ChirpException::class.java) { native.copy(expires = nowSeconds() - 1).code(callback) }
        assertFalse(native.matches(connection.copy(exchange = connection.authorize)))
        assertFalse(native.matches(connection.copy(group = connection.api)))
    }
}
