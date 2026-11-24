package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.ClientLog
import cn.youzifeile.chirp.data.LogDetails
import cn.youzifeile.chirp.data.LogEvent
import androidx.annotation.Keep
import java.nio.ByteBuffer
import java.security.GeneralSecurityException
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import livekit.org.webrtc.RtpReceiver
import livekit.org.webrtc.FrameDecryptor
import livekit.org.webrtc.FrameEncryptor
import livekit.org.webrtc.RtpSender

/** One authenticated nonce set per sender and actual key, shared across RTP subscriptions. */
internal class VoiceKeys(private val permitted: () -> Boolean, private val clock: () -> Long,
    private val log: ClientLog? = ClientLog.current, private val receiveAllowed: (Int) -> Boolean = { true }) {
    private data class Nonce(val high: Long, val low: Int)
    private class Epoch(val key: SecretKeySpec) {
        val seen = HashSet<Nonce>()
        val sent = HashSet<Nonce>()
    }
    private class Slot(val epoch: Epoch, var active: Boolean = false, var until: Long = Long.MAX_VALUE)
    private val senders = mutableMapOf<String, MutableMap<Int, Slot>>()
    private val retiredIndices = mutableSetOf<Int>()
    private val failures = mutableMapOf<String, Pair<VoiceFailure, Long>>()
    @Synchronized fun failure(track: String): VoiceFailure? =
        failures[track]?.takeIf { clock() - it.second <= 2_000 }?.first
    @Synchronized private fun failed(track: String, reason: VoiceFailure): ByteArray? {
        if (permitted()) failures[track] = reason to clock()
        return null
    }
    private class DecryptTimes(val first: Long, var last: Long = first)
    private var sampleGeneration = 0L
    private var frames = 0L
    private var totalNS = 0L
    private var maxNS = 0L

    @Synchronized fun flushTiming() {
        if (frames > 0) log?.record(LogEvent.voiceDecrypt,
            details = LogDetails.Voice(frames, totalNS, maxNS), expected = sampleGeneration)
        frames = 0; totalNS = 0; maxNS = 0
    }
    private val decryptedAt = mutableMapOf<String, DecryptTimes>()

    @Synchronized fun install(identity: String, index: Int, material: ByteArray) {
        require(material.size == 32)
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec("LKFrameEncryptionKey".encodeToByteArray(), mac.algorithm))
        val extracted = mac.doFinal(material)
        mac.init(SecretKeySpec(extracted, mac.algorithm))
        extracted.fill(0)
        val block = mac.doFinal(ByteArray(129).apply { this[lastIndex] = 1 })
        val key = SecretKeySpec(block, 0, 16, "AES")
        block.fill(0)
        retiredIndices.remove(index)
        val slots = senders.getOrPut(identity) { mutableMapOf() }
        if (slots[index]?.epoch?.key == key) return
        val epoch = slots.values.firstOrNull { it.epoch.key == key }?.epoch ?: Epoch(key)
        slots[index] = Slot(epoch)
    }
    @Synchronized fun activate(index: Int) { senders.values.forEach { it[index]?.active = true } }
    @Synchronized fun expire(index: Int, remaining: Long) {
        val until = clock() + minOf(1000, remaining)
        senders.values.forEach { it[index]?.until = until }
    }
    @Synchronized fun retire(index: Int) { retiredIndices.add(index); senders.values.forEach { it.remove(index) } }
    @Synchronized fun clear() { flushTiming(); senders.clear(); decryptedAt.clear(); failures.clear(); retiredIndices.clear() }
    @Synchronized fun lastDecryption(track: String) = decryptedAt[track]?.last
    @Synchronized fun firstDecryption(track: String) = decryptedAt[track]?.first
    private fun active(identity: String, index: Int) =
        senders[identity]?.get(index)?.takeIf { it.active && clock() < it.until }?.epoch

    private fun validFrame(frame: ByteArray) = frame.size in 31..65535 && frame[frame.size - 2].toInt() == 12
    private fun nonce(frame: ByteArray) = ByteBuffer.wrap(frame, frame.size - 14, 12).let { Nonce(it.long, it.int) }

    private fun decrypt(epoch: Epoch, frame: ByteArray): ByteArray? {
        val offset = frame.size - 14
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, epoch.key, GCMParameterSpec(128, frame, offset, 12))
            cipher.updateAAD(frame, 0, 1)
            cipher.doFinal(frame, 1, offset - 1)
        } catch (_: GeneralSecurityException) { null }
    }

    // WebRTC invokes the mandatory FrameEncryptor after its optional LiveKit transformer.
    // Only release the original ciphertext to RTP after authenticating it under this sender's current key.
    fun authenticatesOutgoing(identity: String, ssrc: Int, frame: ByteArray, maySend: (Int) -> Boolean): Boolean {
        if (!validFrame(frame)) return false
        val index = frame.last().toInt()
        if (!maySend(index) || ByteBuffer.wrap(frame, frame.size - 14, 4).int != ssrc) return false
        val epoch = synchronized(this) { active(identity, index) } ?: return false
        val plain = decrypt(epoch, frame) ?: return false
        plain.fill(0)
        return synchronized(this) {
            active(identity, index) === epoch && maySend(index) && epoch.sent.size < 65536 && epoch.sent.add(nonce(frame))
        }
    }

    fun open(identity: String, frame: ByteArray, track: String = identity): ByteArray? {
        if (!permitted()) return null
        if (!validFrame(frame)) return failed(track, VoiceFailure.DecryptionFailed)
        val index = frame.last().toInt()
        if (!receiveAllowed(index)) return null
        val epoch = synchronized(this) {
            val slot = senders[identity]?.get(index)
            if (index in retiredIndices || (slot != null && (!slot.active || clock() >= slot.until))) return null
            slot?.epoch
        } ?: return failed(track, VoiceFailure.MissingKey)
        val generation = log?.generation ?: 0L
        val start = if (generation != 0L) System.nanoTime() else 0L
        val plain = decrypt(epoch, frame) ?: return failed(track, VoiceFailure.DecryptionFailed)
        val elapsed = if (generation != 0L) System.nanoTime() - start else 0L
        try {
            return synchronized(this) {
                if (!permitted() || !receiveAllowed(index) || active(identity, index) !== epoch || epoch.seen.size >= 65536) return null
                if (!epoch.seen.add(nonce(frame))) return null
                failures.remove(track)
                val now = clock()
                decryptedAt.getOrPut(track) { DecryptTimes(now) }.last = now
                if (generation != 0L && generation == log?.generation) {
                    if (sampleGeneration != generation) {
                        frames = 0; totalNS = 0; maxNS = 0
                        sampleGeneration = generation
                    }
                    frames++
                    totalNS += elapsed
                    maxNS = maxOf(maxNS, elapsed)
                }
                ByteArray(plain.size + 1).also { it[0] = frame[0]; plain.copyInto(it, 1) }
            }
        } finally { plain.fill(0) }
    }
}

@Keep
internal class VoiceSender(private val keys: VoiceKeys, private val identity: String, private val maySend: (Int) -> Boolean) {
    fun accepts(ssrc: Int, frame: ByteArray) = keys.authenticatesOutgoing(identity, ssrc, frame, maySend)
    private external fun create(): Long
    private external fun release(handle: Long)
    fun install(sender: RtpSender) {
        val handle = create()
        check(handle != 0L)
        try { sender.setFrameEncryptor(FrameEncryptor { handle }) } finally { release(handle) }
    }
    companion object { init { System.loadLibrary("chirp_voice") } }
}

@Keep
internal class VoiceReceiver(private val keys: VoiceKeys, private val identity: String) {
    private var track = identity
    fun open(frame: ByteArray): ByteArray? = keys.open(identity, frame, track)
    private external fun create(): Long
    private external fun release(handle: Long)
    fun install(receiver: RtpReceiver) {
        track = receiver.track()?.id() ?: identity
        val handle = create()
        check(handle != 0L)
        try { receiver.setFrameDecryptor(FrameDecryptor { handle }) } finally { release(handle) }
    }
    companion object { init { System.loadLibrary("chirp_voice") } }
}
