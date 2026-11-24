package cn.youzifeile.chirp.media

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

class CaptureSettingsTest {
    private val buffer = ByteBuffer.allocateDirect(480 * 4).order(ByteOrder.nativeOrder())
    private fun frame(amplitude: Float) { repeat(480) { buffer.putFloat(it * 4, amplitude) } }
    @Test fun gateHasHysteresisHoldAndResetAndDoesNotChangeBypassedAudio() {
        val gate = VoiceGate()
        frame(3276.8f)
        assertTrue(gate.process(buffer, 480, 48000, true, -30f)); assertTrue(gate.open)
        assertEquals(-20f, gate.db, 0.01f)
        frame(32768f * 0.025f) // about -32 dBFS: inside the 5 dB hysteresis.
        gate.process(buffer, 480, 48000, true, -30f); assertTrue(gate.open)
        repeat(24) { frame(0f); gate.process(buffer, 480, 48000, true, -30f) }
        assertTrue(gate.open)
        frame(0f); gate.process(buffer, 480, 48000, true, -30f); assertFalse(gate.open)
        gate.reset(); frame(10f); gate.process(buffer, 480, 48000, true, -30f)
        assertTrue((0 until 480).all { buffer.getFloat(it * 4) == 0f })
        frame(1234f); gate.process(buffer, 480, 48000, false, -30f)
        assertTrue((0 until 480).all { buffer.getFloat(it * 4) == 1234f })
        buffer.putFloat(0, Float.NaN); assertFalse(gate.process(buffer, 480, 48000, true, -30f))
    }
    @Test fun sampleRetainsOnlyTheMostRecentThreeSecondsAndClears() {
        val sample = MicrophoneSample(48000)
        repeat(400) { index -> frame(index.toFloat()); sample.append(buffer, 480) }
        val pcm = sample.copy()
        assertEquals(144000, pcm.size); assertEquals(100.toShort(), pcm.first()); assertEquals(399.toShort(), pcm.last())
        sample.clear(); assertEquals(0, sample.copy().size)
    }
}
