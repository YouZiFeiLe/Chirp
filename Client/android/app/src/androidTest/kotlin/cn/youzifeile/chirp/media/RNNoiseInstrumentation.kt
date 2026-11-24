package cn.youzifeile.chirp.media

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import android.os.SystemClock
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.random.Random

/** Runs the shipped JNI library and full model on Android without recording audio. */
class RNNoiseInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val result = Bundle()
        try {
            for (rate in listOf(8000, 16000, 32000, 48000)) verifyCapture(rate)
            result.putString("stream", "RNNoise JNI: real model attenuation, bypass, mute, lease expiry, sample-rate reset and close passed\n")
            finish(Activity.RESULT_OK, result)
        } catch (failure: Throwable) {
            result.putString("stream", failure.stackTraceToString())
            finish(Activity.RESULT_CANCELED, result)
        }
    }

    internal fun verifyCapture(rate: Int) {
        val gate = MediaGate("test")
        fun grant() = gate.grant(MediaPermit("test", System.currentTimeMillis() + 3000, SystemClock.elapsedRealtime() + 3000))
        grant()
        gate.micAllowed = true
        val processor = RNNoiseProcessor(gate)
        processor.initializeAudioProcessing(48000, 1)
        processor.resetAudioProcessing(rate)
        val frames = rate / 100
        val buffer = ByteBuffer.allocateDirect(frames * 4).order(ByteOrder.nativeOrder())
        val samples = buffer.asFloatBuffer()
        val random = Random(1234)
        var inputEnergy = 0.0
        var outputEnergy = 0.0
        repeat(200) { frame ->
            grant()
            for (i in 0 until frames) {
                val value = random.nextFloat() * 6000 - 3000
                samples.put(i, value)
                if (frame > 100) inputEnergy += value * value
            }
            processor.processAudio(if (rate >= 32000) rate / 16000 else 1, frames, buffer)
            for (i in 0 until frames) {
                val value = samples.get(i)
                check(value.isFinite())
                if (frame > 100) outputEnergy += value * value
            }
        }
        check(inputEnergy > 0 && outputEnergy < inputEnergy * 0.25) { "RNNoise did not suppress synthetic noise at $rate Hz" }
        processor.enabled = false
        for (i in 0 until frames) samples.put(i, 1234f)
        processor.processAudio(1, frames, buffer)
        check((0 until frames).all { samples.get(it) == 1234f }) { "Disabled RNNoise changed the samples" }
        processor.enabled = true
        gate.systemMuted = true
        for (i in 0 until frames) samples.put(i, 2000f)
        processor.processAudio(1, frames, buffer)
        check((0 until frames).all { samples.get(it) == 0f }) { "Muted capture leaked filter history" }
        gate.systemMuted = false
        grant()
        samples.put(0, Float.NaN)
        processor.processAudio(1, frames, buffer)
        check((0 until frames).all { samples.get(it) == 0f }) { "Invalid audio was not silenced" }
        gate.revoke()
        for (i in 0 until frames) samples.put(i, 2000f)
        processor.processAudio(1, frames, buffer)
        check((0 until frames).all { samples.get(it) == 0f }) { "Revoked lease leaked audio" }
        processor.close()
        processor.close()
        for (i in 0 until frames) samples.put(i, 1234f)
        processor.processAudio(1, frames, buffer)
        check((0 until frames).all { samples.get(it) == 0f }) { "Closed processor leaked audio" }
    }
}
