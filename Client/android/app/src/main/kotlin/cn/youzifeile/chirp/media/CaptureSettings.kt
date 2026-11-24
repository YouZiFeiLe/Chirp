package cn.youzifeile.chirp.media

import java.nio.ByteBuffer
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min

internal enum class AudioPreset(val rnnoise: Boolean, val webRtcNoise: Boolean) {
    RNNoise(true, false), WebRTC(false, true), EchoOnly(false, false)
}

internal class CaptureSettings {
    @Volatile var preset = AudioPreset.RNNoise
    @Volatile var activation = false
    @Volatile var threshold = -45f
}

internal data class CaptureReading(val db: Float = -96f, val open: Boolean = false, val processing: Boolean = false,
    val failed: Boolean = false, val preset: AudioPreset? = null) {
    val level get() = ((db + 80f) / 80f).coerceIn(0f, 1f)
}

/** Serialized with capture. Uses Float-S16 and the same gate before calls and local playback. */
internal class VoiceGate {
    var db = -96f; private set
    var open = false; private set
    private var quiet = 0
    private var gain = 0f
    private var enabledBefore = false
    fun reset() { open = false; quiet = 0; gain = 0f; enabledBefore = false; db = -96f }
    fun process(buffer: ByteBuffer, frames: Int, rate: Int, enabled: Boolean, threshold: Float): Boolean {
        if (frames <= 0 || rate <= 0 || !threshold.isFinite()) return false
        var energy = 0.0
        for (i in 0 until frames) {
            val value = buffer.getFloat(i * 4)
            if (!value.isFinite()) return false
            val normalized = value / 32768.0
            energy += normalized * normalized
        }
        db = (10 * log10(max(energy / frames, 1e-12))).toFloat().coerceIn(-96f, 0f)
        if (!enabled) { open = false; quiet = 0; gain = 0f; enabledBefore = false; return true }
        if (!enabledBefore) { open = false; quiet = 0; gain = 0f; enabledBefore = true }
        val limit = threshold.coerceIn(-80f, -10f)
        if (db >= limit || open && db >= limit - 5) { open = true; quiet = 0 }
        else if (open) { quiet += frames; if (quiet >= rate / 4) { open = false; quiet = 0 } }
        val target = if (open) 1f else 0f
        val step = 1f / max(1, rate / 200)
        for (i in 0 until frames) {
            gain = if (target > gain) min(target, gain + step) else max(target, gain - step)
            buffer.putFloat(i * 4, buffer.getFloat(i * 4) * gain)
        }
        return true
    }
}

/** Bounded three-second mono PCM ring. Never writes a recording to disk. */
internal class MicrophoneSample(val rate: Int) {
    private val samples = ShortArray(rate * 3)
    private var position = 0
    private var count = 0
    fun append(buffer: ByteBuffer, frames: Int) {
        for (i in 0 until frames) {
            samples[position] = buffer.getFloat(i * 4).coerceIn(-32768f, 32767f).toInt().toShort()
            position = (position + 1) % samples.size
            count = min(samples.size, count + 1)
        }
    }
    fun copy(): ShortArray = ShortArray(count) { samples[(position - count + it + samples.size) % samples.size] }
    fun clear() { samples.fill(0); count = 0; position = 0 }
}
