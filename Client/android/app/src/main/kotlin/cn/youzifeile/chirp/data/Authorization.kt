package cn.youzifeile.chirp.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

internal fun bundledAuthorizationKey(bytes: ByteArray): String {
    try {
        val trust = parseObject(bytes)
        verify(trust.keys == setOf("public_key"))
        return trust.text("public_key").also { it.base64Bytes(32) }
    } catch (_: ChirpException) {
        throw ChirpException("AUTHORIZATION_TRUST_INVALID")
    }
}

@Serializable internal data class Checkpoint(val version: Long = 0, val hash: String = "")
@Serializable internal data class Friend(val id: String, val root: String, val name: String, val devices: Set<String> = emptySet())
@Serializable internal data class SocialChange(val operation: String, val id: String, val root: String, val key: String, val name: String) {
    fun applyTo(list: MutableList<Friend>) {
        val index = list.indexOfFirst { it.id == id && it.root == root }
        val current = list.getOrNull(index) ?: Friend(id, root, name)
        val next = when (operation) {
            "friend" -> current.copy(name = name)
            "trust" -> current.copy(devices = current.devices + key)
            "untrust" -> if (index >= 0) current.copy(devices = current.devices - key) else return
            "remove_friend" -> { if (index >= 0) list.removeAt(index); return }
            else -> throw ChirpException("IDENTITY_INVALID")
        }
        if (index < 0) list.add(next) else list[index] = next
    }
}

internal fun socialMessage(e: JsonObject, signer: DeviceIdentity) = message("Chirp account social event v5",
    e.text("origin"), e.text("account_id"), e.long("version").toString(), e.text("previous_hash"), e.text("operation"),
    e.text("friend_id"), e.text("friend_key"), e.text("device_key"), e.text("name"), signer.hash())
private fun socialDigest(e: JsonObject, signer: DeviceIdentity) =
    signedDigest("Chirp account social event digest v5", socialMessage(e, signer), e.text("signature"))

internal fun authorizationMessage(e: JsonObject, signer: DeviceIdentity): ByteArray {
    val body = (e["social"] as? JsonObject)?.let { socialDigest(it, signer) } ?: e["social_hash"]?.jsonPrimitive?.content.orEmpty()
    return message("Chirp authorization event v5", e.text("origin"), e.long("version").toString(),
        e.text("previous_hash"), e.text("operation"), signer.hash(), e.text("target_key"), body)
}

internal class VerifiedAccount(val root: String, private val issued: Long) {
    var checkpoint = Checkpoint()
        private set
    val devices = mutableMapOf<String, DeviceIdentity>()
    val revoked = mutableSetOf<String>()
    val friends = mutableListOf<Friend>()
    val socialHashes = mutableListOf<String>()
    var complete = true
        private set
    fun active(device: DeviceIdentity, now: Long = maxOf(issued, nowSeconds())) =
        devices[device.leaf] == device && device.leaf !in revoked && now < device.deadline &&
            device.certificates.all { it.notBefore <= now + 60 }

    companion object {
        fun replay(account: JsonObject, origin: String, issued: Long, known: Checkpoint?, ownId: String?): VerifiedAccount {
            val root = account.text("root")
            root.base64Bytes(32)
            val records = account.getValue("records").jsonArray
            verify(records.size <= 8192)
            verify((known?.version ?: 0) <= records.size, "IDENTITY_HISTORY_CHANGED")
            val state = VerifiedAccount(root, issued)
            var lastTime = 0L
            for (record in records) {
                val v = record.jsonObject
                val at = v.long("accepted_at")
                val e = v.obj("event")
                val version = e.long("version")
                val signer = e.obj("signer").decode<DeviceIdentity>()
                verify(at > 0 && at in lastTime..issued && e.text("origin") == origin && signer.accountKey == root &&
                    version == state.checkpoint.version + 1 && e.text("previous_hash") == state.checkpoint.hash, "IDENTITY_HISTORY_CHANGED")
                signer.validate(at)
                val msg = authorizationMessage(e, signer)
                verifySignature(signer.leaf, e.text("signature"), msg)
                val target = e.text("target_key")
                val operation = e.text("operation")
                verify(operation == "revoke" || version <= 4096)
                if (operation != "social") verify("social" !in e && "social_hash" !in e)
                when (operation) {
                    "enroll" -> {
                        verify(target.isEmpty() && state.devices.size < 128 && signer.leaf !in state.devices && signer.leaf !in state.revoked)
                        if (signer.certificates.size > 1) {
                            val parent = signer.copy(certificates = signer.certificates.dropLast(1))
                            verify(state.active(parent, at) && parent.certificates.last().canEnroll)
                        }
                        state.devices[signer.leaf] = signer
                    }
                    "revoke" -> {
                        verify(state.active(signer, at) && signer.certificates.last().canEnroll &&
                            target in state.devices && state.revoked.add(target))
                    }
                    "social" -> {
                        verify(target.isEmpty() && state.active(signer, at))
                        val social = e["social"] as? JsonObject
                        if (social == null) {
                            verify(ownId == null)
                            val hash = e.text("social_hash")
                            hash.base64Bytes(32); state.socialHashes.add(hash); state.complete = false
                        } else {
                            verify("social_hash" !in e && social.obj("signer").decode<DeviceIdentity>() == signer &&
                                social.text("origin") == origin && social.long("version") == state.socialHashes.size + 1L &&
                                social.text("previous_hash") == state.socialHashes.lastOrNull().orEmpty())
                            val accountId = social.text("account_id")
                            val change = SocialChange(social.text("operation"), social.text("friend_id"), social.text("friend_key"),
                                social.text("device_key"), social.text("name"))
                            verify((ownId == null || ownId == accountId) && accountId.encodeToByteArray().size in 1..128 &&
                                change.id.encodeToByteArray().size in 1..128 && change.name.encodeToByteArray().size <= 320)
                            change.root.base64Bytes(32)
                            if (change.operation in setOf("trust","untrust")) change.key.base64Bytes(32) else verify(change.key.isEmpty())
                            verifySignature(signer.leaf, social.text("signature"), socialMessage(social, signer))
                            change.applyTo(state.friends)
                            state.socialHashes.add(socialDigest(social, signer))
                        }
                    }
                    else -> throw ChirpException("IDENTITY_INVALID")
                }
                state.checkpoint = Checkpoint(version, signedDigest("Chirp authorization event digest v5", msg, e.text("signature")))
                if (known?.version == version) verify(state.checkpoint == known, "IDENTITY_HISTORY_CHANGED")
                lastTime = at
            }
            return state
        }
    }
}

internal fun verifySnapshot(envelope: JsonObject, publicKey: String, origin: String, nonce: String,
    roots: List<String>, known: Map<String, Checkpoint>, self: Pair<String, String>): Map<String, VerifiedAccount> = try {
    val bytes = envelope.text("payload").base64Bytes(1, 6 * 1024 * 1024)
    verifySignature(publicKey, envelope.text("signature"), message("Chirp authorization snapshot v5", origin, nonce, digest(bytes)))
    val snapshot = parseObject(bytes)
    val accounts = snapshot.getValue("accounts").jsonArray
    val issued = snapshot.long("issued_at")
    verify(snapshot.int("protocol") == 5 && snapshot.text("origin") == origin && snapshot.text("nonce") == nonce &&
        issued > 0 && accounts.size == roots.size && accounts.map { it.jsonObject.text("root") }.toSet() == roots.toSet())
    accounts.associate {
        val root = it.jsonObject.text("root")
        root to VerifiedAccount.replay(it.jsonObject, origin, issued, known[root], self.second.takeIf { root == self.first })
    }
} catch (_: RuntimeException) {
    // A malformed signed response must invalidate a cached authorization just like an invalid signature.
    throw ChirpException("INVALID_RESPONSE")
}
