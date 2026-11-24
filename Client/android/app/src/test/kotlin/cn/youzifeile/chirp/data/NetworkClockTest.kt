package cn.youzifeile.chirp.data

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

class NetworkClockTest {
    @Test fun signedOffsetUsesElapsedTimeAndAcceptsBothTwoSecondBoundaries() = runTest {
        var elapsed = 3_000L
        val origin = 1_800_000_000_000L
        var offset = 0L
        val replies = CompletableDeferred<List<NetworkTimeSample>>()
        var attempts = 0
        val clock = NetworkClock({ origin + elapsed + offset }, { elapsed }) { attempts++; replies.await() }
        val first = launch(start = CoroutineStart.UNDISPATCHED) { clock.check(false) {} }
        clock.check(true) {}
        assertEquals(ClockStatus.Checking, clock.read().status)
        assertEquals(1, attempts)
        val early = NetworkTimeSample(origin + elapsed, elapsed, 40)
        elapsed += 3_000
        replies.complete(listOf(early, NetworkTimeSample(origin + elapsed, elapsed, 60),
            NetworkTimeSample(origin + elapsed - 60_000, elapsed, 10)))
        first.join()
        elapsed += 20_000
        for (sign in listOf(-1, 1)) {
            offset = sign * 2_000L
            assertTrue(clock.read().ready)
            offset += sign
            assertEquals(ClockReading(ClockStatus.OutOfSync, offset, canRetry = true), clock.read())
        }
        offset = 0
        assertTrue(clock.read().ready)
        assertEquals(1, attempts)
    }

    @Test fun failedRefreshKeepsOnlyAFreshReferenceAndOneReplyRestoresAccess() = runTest {
        var elapsed = 0L
        var offset = 0L
        var replies = listOf(NetworkTimeSample(25_000, 0, 500), NetworkTimeSample(0, 0, 25))
        var attempts = 0
        val clock = NetworkClock({ elapsed + offset }, { elapsed }) { attempts++; replies }
        clock.check(false) {}
        assertTrue(clock.read().ready) // Two sources select the shorter round trip.
        replies = emptyList()
        elapsed += 10 * 60_000
        clock.check(false) {}
        assertTrue(clock.read().ready)
        offset = -30_000
        assertEquals(ClockStatus.OutOfSync, clock.read().status)
        elapsed += 5 * 60_000
        assertEquals(ClockStatus.Unavailable, clock.read().status)
        clock.check(false) {}
        clock.check(true) {}
        assertEquals(3, attempts)
        assertFalse(clock.read().canRetry)
        elapsed += 16_000
        assertTrue(clock.read().canRetry)
        replies = listOf(NetworkTimeSample(elapsed, elapsed, 50))
        clock.check(true) {}
        assertEquals(ClockStatus.OutOfSync, clock.read().status)
        offset = 0
        assertTrue(clock.read().ready)
    }

    @Test fun startupOutageBlocksUntilTheAutomaticRetrySucceeds() = runTest {
        var elapsed = 0L
        var attempts = 0
        val clock = NetworkClock({ elapsed }, { elapsed }) {
            if (++attempts == 1) emptyList() else listOf(NetworkTimeSample(elapsed, elapsed, 10))
        }
        val published = mutableListOf<ClockStatus>()
        clock.check(false) { published.add(it.status) }
        assertEquals(listOf(ClockStatus.Checking, ClockStatus.Unavailable), published)
        elapsed = 59_999
        clock.check(false) {}
        assertEquals(1, attempts)
        elapsed++
        clock.check(false) {}
        assertTrue(clock.read().ready)
        assertEquals(2, attempts)
    }

    @Test fun aResolverExceptionLeavesTheGateClosedAndAllowsTheNextCheck() = runTest {
        var elapsed = 0L
        val clock = NetworkClock({ elapsed }, { elapsed }) {
            if (elapsed == 0L) throw IllegalArgumentException("Network handle is unavailable")
            listOf(NetworkTimeSample(elapsed, elapsed, 10))
        }
        clock.check(false) {}
        assertEquals(ClockStatus.Unavailable, clock.read().status)
        elapsed = 16_000
        clock.check(true) {}
        assertTrue(clock.read().ready)
    }

    private val nonce = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8)
    private val rolloverMillis = 2_085_978_496_000L

    private fun reply(): ByteBuffer = ByteBuffer.allocate(48).apply {
        put(0, 0x24)
        put(1, 2)
        nonce.copyInto(array(), 24)
        // Receive just before the 2036 rollover, transmit just after it.
        putLong(32, -0x40000000L)
        putLong(40, 0x40000000L)
    }

    @Test fun validatesNtpRepliesAndSubtractsServerProcessingAcrossTheEraRollover() {
        assertEquals(rolloverMillis + 500, NtpTime.estimateUtc(reply(), nonce, 1000))
        for ((index, value) in listOf(0 to 0xe4, 0 to 0x23, 0 to 0x0c, 1 to 0, 1 to 16, 24 to 0)) {
            assertNull(NtpTime.estimateUtc(reply().put(index, value.toByte()), nonce, 1000))
        }
        assertNull(NtpTime.estimateUtc(reply().apply { limit(47) }, nonce, 1000))
        assertNull(NtpTime.estimateUtc(reply().putLong(32, 0), nonce, 1000))
        assertNull(NtpTime.estimateUtc(reply().putLong(40, 0), nonce, 1000))
        assertNull(NtpTime.estimateUtc(reply().putLong(32, 0x80000000L), nonce, 1000))
        assertNull(NtpTime.estimateUtc(reply(), nonce, 499))
        assertNull(NtpTime.estimateUtc(reply(), nonce, 4001))
    }

    @Test fun sendsAClientDatagramAndMatchesTheEchoedOrigin() = runBlocking {
        val loopback = InetAddress.getLoopbackAddress()
        DatagramSocket(0, loopback).use { server ->
            server.soTimeout = 3_000
            val sample = async(Dispatchers.IO) {
                withTimeout(3_000) {
                    runInterruptible { NtpTime.exchange(InetSocketAddress(loopback, server.localPort)) { System.nanoTime() / 1_000_000 } }
                }
            }
            val request = DatagramPacket(ByteArray(512), 512)
            server.receive(request)
            assertEquals(48, request.length)
            assertEquals(0x23, request.data[0].toInt())
            val response = reply().apply { putLong(32, getLong(40)) }.array()
            request.data.copyInto(response, 24, 40, 48)
            server.send(DatagramPacket(response, response.size, request.socketAddress))
            val measured = requireNotNull(sample.await())
            assertEquals(rolloverMillis + 250 + measured.roundTripMillis / 2, measured.utcMillis)
        }
    }
}
