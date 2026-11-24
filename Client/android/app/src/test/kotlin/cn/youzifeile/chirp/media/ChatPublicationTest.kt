package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.ChirpException
import io.livekit.android.e2ee.ChirpDataKeyNotReady
import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

class ChatPublicationTest {
    @Test fun waitsForAnAuthorizedKeyAndRetriesOnlyARefusalBeforeDispatch() = runBlocking {
        var checks = 0
        var submissions = 0
        withTimeout(1_000) {
            publishChatBatches(listOf("peer"), { when (++checks) { 1 -> null; 2 -> 1L; else -> 2L } }) {
                if (++submissions == 1) throw ChirpDataKeyNotReady()
            }
        }
        assertEquals(3, checks)
        assertEquals(2, submissions)
    }

    @Test fun anUncertainPublicationIsNeverReplayed() = runBlocking {
        var submissions = 0
        val failure = runCatching {
            publishChatBatches(listOf("peer"), { 1L }) { submissions++; throw IOException("unknown outcome") }
        }.exceptionOrNull()
        assertTrue(failure is IOException)
        assertEquals(1, submissions)
    }

    @Test fun losingTheAdmissionWhileWaitingStopsPublication() = runBlocking {
        var checks = 0
        var submissions = 0
        val failure = runCatching {
            publishChatBatches(listOf("peer"), { if (++checks > 1) throw ChirpException("GROUP_LEASE_LOST"); null }) { submissions++ }
        }.exceptionOrNull()
        assertEquals("GROUP_LEASE_LOST", (failure as? ChirpException)?.code)
        assertEquals(0, submissions)
    }

    @Test fun aRekeyAfterTheFirstBatchDoesNotReplayOrContinueAPartialBroadcast() = runBlocking {
        val peers = (1..12).map { "peer-$it" }
        val submitted = mutableListOf<List<String>>()
        var epoch = 20L
        val failure = runCatching {
            publishChatBatches(peers, { epoch }) { batch -> submitted.add(batch); epoch++ }
        }.exceptionOrNull()
        assertEquals("GROUP_CHANGED", (failure as? ChirpException)?.code)
        assertEquals(listOf(peers.take(8)), submitted)
    }
}
