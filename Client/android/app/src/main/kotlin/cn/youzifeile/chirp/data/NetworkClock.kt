package cn.youzifeile.chirp.data

import android.content.Context
import android.net.ConnectivityManager
import android.net.DnsResolver
import android.net.Network
import android.os.Build
import android.os.CancellationSignal
import android.os.SystemClock
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.channels.DatagramChannel
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

internal enum class ClockStatus { Checking, Ready, OutOfSync, Unavailable }

internal data class ClockReading(
    val status: ClockStatus = ClockStatus.Checking,
    val offsetMillis: Long = 0,
    val canRetry: Boolean = false,
) {
    val ready get() = status == ClockStatus.Ready
}

internal data class NetworkTimeSample(val utcMillis: Long, val elapsedMillis: Long, val roundTripMillis: Long) {
    fun utcAt(elapsed: Long) = utcMillis + (elapsed - elapsedMillis)
}

// The task's main dispatcher owns the reference. Only elapsed time advances it, including during sleep.
internal class NetworkClock(
    private val wallMillis: () -> Long = System::currentTimeMillis,
    private val elapsedMillis: () -> Long = SystemClock::elapsedRealtime,
    private val query: suspend () -> List<NetworkTimeSample>,
) {
    private var reference: NetworkTimeSample? = null
    private var lastAttempt: Long? = null
    private var measuring = false
    private var lastAttemptSucceeded = false

    fun read(): ClockReading {
        val now = elapsedMillis()
        val canRetry = !measuring && due(now, MANUAL_RETRY_MS)
        reference?.let { sample ->
            if (now - sample.elapsedMillis < REFERENCE_LIFETIME_MS) {
                val offset = wallMillis() - sample.utcAt(now)
                return if (offset in -TOLERANCE_MS..TOLERANCE_MS) ClockReading(ClockStatus.Ready)
                else ClockReading(ClockStatus.OutOfSync, offset, canRetry)
            }
        }
        return if (measuring || lastAttempt == null) ClockReading()
        else ClockReading(ClockStatus.Unavailable, canRetry = canRetry)
    }

    private fun due(now: Long, interval: Long) = lastAttempt?.let { now - it >= interval } ?: true

    suspend fun check(manual: Boolean, publish: (ClockReading) -> Unit) {
        val now = elapsedMillis()
        val interval = if (manual) MANUAL_RETRY_MS else if (lastAttemptSucceeded) REFRESH_MS else RETRY_MS
        if (!measuring && due(now, interval)) {
            measuring = true
            lastAttempt = now
            try {
                publish(read())
                val samples = try { query() }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { emptyList() }
                val end = elapsedMillis()
                val selected = when (samples.size) {
                    0 -> null
                    2 -> samples.minBy { it.roundTripMillis }
                    else -> samples.sortedBy { it.utcAt(end) }[samples.size / 2]
                }
                lastAttemptSucceeded = selected != null
                if (selected != null) reference = selected
            } finally {
                measuring = false
            }
        }
        publish(read())
    }

    private companion object {
        // A fresh device pairing code uses 297 seconds of a 300-second acceptance window.
        const val TOLERANCE_MS = 2_000L
        const val REFRESH_MS = 10 * 60_000L
        const val REFERENCE_LIFETIME_MS = 15 * 60_000L
        const val RETRY_MS = 60_000L
        const val MANUAL_RETRY_MS = 16_000L
    }
}

internal object NtpTime {
    private val servers = listOf("time.windows.com", "ntp.aliyun.com", "time.cloudflare.com")
    private const val TIMEOUT_MS = 4_000L

    suspend fun query(context: Context): List<NetworkTimeSample> = withContext(Dispatchers.IO) {
        val network = context.getSystemService(ConnectivityManager::class.java).activeNetwork
            ?: return@withContext emptyList()
        @Suppress("DEPRECATION")
        val resolver = if (Build.VERSION.SDK_INT >= 37) DnsResolver(context, null) else DnsResolver.getInstance()
        servers.map { host ->
            async {
                try {
                    withTimeoutOrNull(TIMEOUT_MS) {
                        val address = resolver.resolve(network, host) ?: return@withTimeoutOrNull null
                        runInterruptible { exchange(InetSocketAddress(address, 123), network, SystemClock::elapsedRealtime) }
                    }
                } catch (_: IOException) { null }
                catch (_: SecurityException) { null }
                catch (_: IllegalArgumentException) { null } // Android can invalidate a network handle during DNS.
            }
        }.awaitAll().filterNotNull()
    }

    private suspend fun DnsResolver.resolve(network: Network, host: String): InetAddress? = suspendCancellableCoroutine { result ->
        val signal = CancellationSignal()
        result.invokeOnCancellation { signal.cancel() }
        query(network, host, DnsResolver.FLAG_EMPTY, Dispatchers.IO.asExecutor(), signal,
            object : DnsResolver.Callback<List<InetAddress>> {
                override fun onAnswer(answer: List<InetAddress>, rcode: Int) =
                    result.resume(if (rcode == 0) answer.firstOrNull() else null)
                override fun onError(error: DnsResolver.DnsException) = result.resume(null)
            })
    }

    internal fun exchange(address: InetSocketAddress, network: Network? = null, elapsedMillis: () -> Long): NetworkTimeSample? =
        DatagramChannel.open().use { socket ->
            network?.bindSocket(socket.socket())
            socket.connect(address)
            val nonce = randomBytes(8)
            val request = ByteArray(48)
            request[0] = 0x23 // NTPv4 client mode. The server echoes the transmit nonce as its origin.
            nonce.copyInto(request, 40)
            val response = ByteBuffer.allocate(512)
            val start = elapsedMillis()
            socket.write(ByteBuffer.wrap(request))
            socket.read(response)
            val end = elapsedMillis()
            val roundTrip = end - start
            response.flip()
            estimateUtc(response, nonce, roundTrip)?.let { NetworkTimeSample(it, end, roundTrip) }
        }

    internal fun estimateUtc(reply: ByteBuffer, nonce: ByteArray, roundTrip: Long): Long? {
        if (reply.limit() < 48 || nonce.size != 8 || roundTrip !in 0..TIMEOUT_MS) return null
        val header = reply.get(0).toInt() and 0xff
        if ((header and 7) != 4 || ((header ushr 3) and 7) !in 3..4 || header ushr 6 == 3 ||
            reply.get(1).toInt() !in 1..15 || nonce.indices.any { reply.get(24 + it) != nonce[it] }) return null
        val received = timestamp(reply, 32) ?: return null
        val sent = timestamp(reply, 40) ?: return null
        val processing = sent - received
        if (processing !in 0..roundTrip) return null
        return sent + (roundTrip - processing) / 2
    }

    private fun timestamp(reply: ByteBuffer, offset: Int): Long? {
        if (reply.getLong(offset) == 0L) return null
        // Unfold the 2036 era rollover into 1970–2106 without consulting the clock being checked.
        val seconds = (reply.getInt(offset).toLong() - 2_208_988_800L) and 0xffff_ffffL
        val fraction = reply.getInt(offset + 4).toLong() and 0xffff_ffffL
        return seconds * 1_000 + ((fraction * 1_000) ushr 32)
    }
}
