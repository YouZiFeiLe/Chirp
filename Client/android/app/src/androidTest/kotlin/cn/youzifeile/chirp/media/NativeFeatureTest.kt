package cn.youzifeile.chirp.media

import androidx.test.platform.app.InstrumentationRegistry
import cn.youzifeile.chirp.data.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class NativeFeatureTest {
    @Test fun importsTheSharedRecoveryFileWithItsOriginalUnicodePassword() {
        val sample = InstrumentationRegistry.getInstrumentation().context.assets.open("recovery-v1.json").use { parseObject(it.readBytes()) }
        MlsNative("recovery-vector").use { native ->
            val file = sample.text("file")
            val password = sample.text("password")
            assertEquals(sample.text("payload"),native.security("decrypt","file" to file,"password" to password).text("payload"))
            assertThrows(ChirpException::class.java) { native.security("decrypt","file" to file,"password" to password.trim()) }
        }
    }
    @Test fun shippedDenoiserStillSuppressesNoiseAndRespectsSafetyGates() {
        val checks = RNNoiseInstrumentation()
        for (rate in listOf(8000, 16000, 32000, 48000)) checks.verifyCapture(rate)
    }

    @Test fun stagedMlsKeysMatchAcrossTwoClientsAndRetainIdentity() {
        MlsNative("self").use { a -> MlsNative("other").use { b ->
            val ownPublic = a.publicKey
            val context = MutualRoom("https://fixture.example:443","friends")
            a.authorize(context); b.authorize(context)
            fun member(id: String, native: MlsNative): GroupMember {
                val seed = randomBytes(32)
                val device = DeviceIdentity.issue(randomBytes(32), publicKey(seed))
                val now = nowSeconds()
                val binding = EntryBinding(device,context.origin,context.room,context.trust,context.hash,id,native.publicKey,
                    base64(randomBytes(32)),now,now+300).let { it.copy(signature = sign(seed,it.message())) }
                seed.fill(0)
                return GroupMember(id,id,native.publicKey,native.keyPackage(),binding)
            }
            val initial = listOf(member("self",a), member("other",b))
            val position = GroupPosition("friends", "server", "session", 1UL)
            fun offers(members: List<GroupMember>, group: String, epoch: ULong): List<GroupMember> = members.zip(listOf(a,b)).map { (m,n) ->
                m.copy(offer = roundProof(false,group,epoch,context.hash,rosterHash(members),digest(m.keyPackage.base64Bytes(32,16384)),n::sign))
            }
            val peers = offers(initial,position.groupID,0UL)
            val empty = GroupSnapshot(GroupStatus(position, 1UL, "welcoming", false), "self", peers, "", "")
            assertThrows(ChirpException::class.java) { a.create(empty) }
            val authority = digest("fixture authority".encodeToByteArray())
            a.approve(position.groupID,peers,authority); b.approve(position.groupID,peers,authority)
            val created = a.create(empty)
            val group = empty.copy(welcome = created["welcome"]!!.let { (it as kotlinx.serialization.json.JsonPrimitive).content },
                confirmation = (created["confirmation"] as kotlinx.serialization.json.JsonPrimitive).content)
            assertEquals(group.confirmation, b.join(group))
            val old = a.key("self")
            assertTrue(a.keyLifetimeMillis() in 1..120_000)
            assertArrayEquals(old, b.key("self"))
            val groupId = "${position.groupID}/key/1"
            val nextPeers = offers(listOf(peers[0].copy(keyPackage = a.stagedKeyPackage()), peers[1].copy(keyPackage = b.stagedKeyPackage())),groupId,1UL)
            a.approve(groupId,nextPeers,authority); b.approve(groupId,nextPeers,authority)
            val fresh = a.createStaged("${position.groupID}/key/1", nextPeers)
            assertEquals((fresh["confirmation"] as kotlinx.serialization.json.JsonPrimitive).content,
                b.joinStaged("${position.groupID}/key/1", nextPeers, (fresh["welcome"] as kotlinx.serialization.json.JsonPrimitive).content))
            val next = a.key("self", true)
            assertTrue(a.keyLifetimeMillis(staged = true) in 1..120_000)
            assertFalse(old.contentEquals(next)); assertArrayEquals(next, b.key("self", true))
            assertArrayEquals(old, b.key("self"))
            a.activateStaged("${position.groupID}/key/1"); b.activateStaged("${position.groupID}/key/1")
            assertEquals(ownPublic, a.publicKey); assertArrayEquals(next, a.key("self")); assertArrayEquals(next, b.key("self"))
            old.fill(0); next.fill(0)
        } }
    }
}
