package cn.youzifeile.chirp.data

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test

class AuthorizationTrustTest {
    private val signer = ByteArray(32) { 7 }
    private val pin = publicKey(signer)
    private val nonce = base64(ByteArray(32) { 4 })
    private val root = publicKey(ByteArray(32) { 9 })

    private fun envelope(origin: String): JsonObject {
        val payload = buildJsonObject {
            put("protocol", 5)
            put("origin", origin)
            put("nonce", nonce)
            put("issued_at", nowSeconds())
            put("accounts", JsonArray(listOf(buildJsonObject {
                put("root", root)
                put("records", JsonArray(emptyList()))
            })))
        }.toString().encodeToByteArray()
        return buildJsonObject {
            put("payload", base64(payload))
            put("signature", sign(signer, message("Chirp authorization snapshot v5", origin, nonce, digest(payload))))
        }
    }

    @Test fun consumesOnlyCanonicalEd25519PublicKeyFromTrustFile() {
        fun read(value: String) = bundledAuthorizationKey(value.encodeToByteArray())
        assertEquals(pin, read("""{"public_key":"$pin"}"""))
        for (invalid in listOf("{}", "[]", "{invalid", """{"public_key":false}""",
            """{"public_key":"${pin.trimEnd('=')}"}""", """{"public_key":"$pin","origin":"https://domain.test"}""")) {
            assertEquals("AUTHORIZATION_TRUST_INVALID", assertThrows(ChirpException::class.java) { read(invalid) }.code)
        }
    }

    @Test fun authorityUrlsComeOnlyFromValidatedIdentityOrigin() {
        val discovery = "https://discovery.test/service/".toHttpUrl()
        fun connection(service: String) = ServerConnection(discovery, discovery, discovery, null, discovery,
            discovery, discovery, discovery, "room", null, passkeyOrigin = service.toHttpUrl())
        for (host in listOf("first.test", "second.test", "second.test:8443")) {
            for (slash in listOf("", "/")) {
                val c = connection("https://$host$slash")
                assertEquals("https://$host/authorization/v5/snapshot", c.authorizationBase.path("snapshot").toString())
                assertEquals("https://$host/authorization/v5/append", c.authorizationBase.path("append").toString())
            }
        }
        for (invalid in listOf("https://server.test/path", "https://user@server.test", "https://server.test/?q=1",
            "https://server.test/#fragment", "http://server.test/")) {
            assertThrows(ChirpException::class.java) { connection(invalid).authorizationBase }
        }
    }

    @Test fun snapshotBindsPinnedKeyOriginNonceRequestedAccountsAndCheckpoint() {
        val origin = "https://first.test:443"
        val response = envelope(origin)
        fun check(key: String = pin, service: String = origin, challenge: String = nonce, roots: List<String> = listOf(root),
            known: Map<String, Checkpoint> = emptyMap()) = verifySnapshot(response, key, service, challenge, roots, known, root to "me")
        assertEquals(Checkpoint(), check().getValue(root).checkpoint)
        assertThrows(ChirpException::class.java) { check(key = publicKey(ByteArray(32) { 8 })) }
        assertThrows(ChirpException::class.java) { check(service = "https://second.test:443") }
        assertThrows(ChirpException::class.java) { check(challenge = base64(randomBytes(32))) }
        assertThrows(ChirpException::class.java) { check(roots = emptyList()) }
        assertEquals("IDENTITY_HISTORY_CHANGED", assertThrows(ChirpException::class.java) {
            check(known = mapOf(root to Checkpoint(1, base64(ByteArray(32)))))
        }.code)
    }
}
