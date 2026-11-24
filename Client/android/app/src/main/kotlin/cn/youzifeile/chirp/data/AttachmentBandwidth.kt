package cn.youzifeile.chirp.data

import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal enum class AttachmentPolicy { Normal, Constrained, Paused }

/** Shared per-direction budgets include retried network chunks. No burst credit. */
internal class AttachmentBandwidth(private val clock: () -> Long = { System.nanoTime() / 1_000_000 },
    private val sleep: suspend (Long) -> Unit = { delay(it) }) {
    @Volatile var policy = AttachmentPolicy.Normal
    private val locks = arrayOf(Mutex(), Mutex())
    private val next = longArrayOf(0, 0)
    suspend fun acquire(bytes: Int, upload: Boolean) {
        require(bytes in 1..NETWORK_CHUNK)
        val direction = if (upload) 0 else 1
        locks[direction].withLock {
            while (policy == AttachmentPolicy.Paused || clock() < next[direction]) sleep(25)
            val rate = if (policy == AttachmentPolicy.Constrained) 512 * 1024 else 8 * 1024 * 1024
            next[direction] = clock() + (bytes * 1000L / rate).coerceAtLeast(1)
        }
    }
}
