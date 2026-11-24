package cn.youzifeile.chirp.data

import cn.youzifeile.chirp.media.EntryBinding
import cn.youzifeile.chirp.media.GroupMember
import cn.youzifeile.chirp.media.rosterHash
import org.junit.Assert.*
import org.junit.Test

class IdentityVectorTest {
    private fun vector(name: String) = javaClass.getResourceAsStream("/$name")!!.use { parseObject(it.readBytes()) }

    @Test fun serverClockSkewDoesNotExtendDeviceActivation() {
        val now = 10_000L
        val grant = IdentityGrant("token", "account", "name", "origin", "", now + 302)
        assertEquals(now + 300, grant.receivedAt(now).expires)
        assertEquals(now + 290, grant.copy(expires = now + 290).receivedAt(now).expires)
        assertThrows(ChirpException::class.java) { grant.copy(expires = now + 306).receivedAt(now) }
        assertThrows(ChirpException::class.java) { grant.copy(expires = now).receivedAt(now) }
    }

    @Test fun certificateBindingAndRosterMatchSharedV5Vector() {
        val sample = vector("v5.json")
        val identity = sample.obj("device").decode<DeviceIdentity>()
        identity.validate(sample.long("now"))
        val hashes = sample.obj("hashes")
        assertEquals(hashes.text("certificate"), identity.certificates.last().hash())
        assertEquals(hashes.text("device"), identity.hash())
        val binding = sample.obj("binding").decode<EntryBinding>()
        verifySignature(identity.leaf, binding.signature, binding.message())
        assertEquals(hashes.text("binding"), binding.hash())
        assertEquals(hashes.text("roster"), rosterHash(listOf(GroupMember(binding.identity,"",binding.mls,"",binding))))
        assertThrows(ChirpException::class.java) { verifySignature(identity.leaf,binding.signature,binding.copy(room = "other").message()) }
    }

    @Test fun pairingTranscriptMatchesSharedVector() {
        val sample = vector("device-pairing-v1.json")
        val request = sample.obj("request").decode<PairRequest>()
        verifySignature(request.key,request.signature,request.message())
        assertEquals(sample.text("context"),request.context())
        assertEquals(sample.text("request_digest"),request.hash())
        assertThrows(ChirpException::class.java) { verifySignature(request.key,request.signature,request.copy(origin = "https://other.test:443").message()) }
    }
}
