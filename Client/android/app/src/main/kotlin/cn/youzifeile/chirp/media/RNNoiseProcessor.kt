package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.LogDetails
import cn.youzifeile.chirp.data.ClientLog
import cn.youzifeile.chirp.data.LogEvent
import cn.youzifeile.chirp.data.LogOutcome
import androidx.annotation.Keep
import io.livekit.android.audio.AudioProcessorInterface
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Per-room capture post processor: after WebRTC AEC, before encoding/encryption. */
@Keep
internal class RNNoiseProcessor(private val gate: MediaGate, private val settings: CaptureSettings? = null) : AudioProcessorInterface, AutoCloseable {
    companion object { init { System.loadLibrary("chirp_audio") } }

    @Volatile var enabled = true
    private var handle = 0L
    private var channels = 1
    private var rate = 0
    private var closed = false
    private val voice = VoiceGate()
    private var sample: MicrophoneSample? = null
    @Volatile var testing = false
    @Volatile private var frameAt = 0L
    @Volatile private var failed = false
    @Volatile private var inputDB = -96f
    @Volatile private var activated = false
    @Volatile private var processedPreset: AudioPreset? = null
    val reading get() = CaptureReading(inputDB, activated, System.nanoTime() - frameAt < 500_000_000 && frameAt != 0L, failed, processedPreset)

    override fun isEnabled() = true // The final microphone gate also applies when RNNoise is off.
    override fun getName() = "RNNoise 0.2"

    @Synchronized
    override fun initializeAudioProcessing(sampleRateHz: Int, numChannels: Int) {
        destroy(handle)
        handle = 0
        rate = sampleRateHz
        channels = numChannels
        voice.reset(); sample?.clear(); sample = if (testing) MicrophoneSample(sampleRateHz) else null
        frameAt = 0; failed = false
        if (!closed) {
            handle = create(rate, channels)
            val log = ClientLog.current
            val generation = log?.generation ?: 0L
            if (generation != 0L) log?.record(LogEvent.captureInitialized,
                details = LogDetails.Capture(rate, channels, settings?.preset?.rnnoise ?: enabled), expected = generation)
        }
    }

    @Synchronized
    override fun resetAudioProcessing(newRate: Int) = initializeAudioProcessing(newRate, channels)

    @Synchronized
    fun resetCapture() {
        voice.reset(); frameAt = 0
        if (rate > 0 && !closed) initializeAudioProcessing(rate, channels)
    }

    @Synchronized
    override fun processAudio(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        val valid = !closed && numBands in 1..3 && numFrames == rate / 100 && channels == 1 &&
            buffer.isDirect && buffer.capacity() >= numFrames * Float.SIZE_BYTES
        buffer.order(ByteOrder.nativeOrder())
        val preset = settings?.preset
        val usesNoise = preset?.rnnoise ?: enabled
        val processed = valid && (!usesNoise || process(handle, buffer, numFrames)) &&
            voice.process(buffer, numFrames, rate, settings?.activation == true, settings?.threshold ?: -45f)
        if (processed) {
            processedPreset = preset
            inputDB = voice.db; activated = voice.open
            frameAt = if (testing || gate.micAllowed && !gate.systemMuted && gate.remaining() > 0) System.nanoTime() else 0
            if (testing) sample?.append(buffer, numFrames)
        } else if (!failed) {
            failed = true
            LogEvent.captureFailed.record(LogOutcome.failed, "MICROPHONE_UNAVAILABLE")
        }
        // RNNoise keeps a frame of history. Gate after processing as well so a
        // muted or expired capture cannot release that history into an encoder.
        if (!processed || !testing && (!gate.micAllowed || gate.systemMuted || gate.remaining() == 0L)) {
            for (i in 0 until buffer.limit()) buffer.put(i, 0)
        }
    }

    @Synchronized fun sampleCopy(): Pair<Int, ShortArray> = rate to (sample?.copy() ?: shortArrayOf())

    @Synchronized
    override fun close() {
        closed = true
        sample?.clear(); sample = null; frameAt = 0
        destroy(handle)
        handle = 0
    }

    private external fun create(rate: Int, channels: Int): Long
    private external fun process(handle: Long, buffer: ByteBuffer, frames: Int): Boolean
    private external fun destroy(handle: Long)
}
