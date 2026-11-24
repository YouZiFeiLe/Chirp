package cn.youzifeile.chirp.ui

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import cn.youzifeile.chirp.ChirpApplication
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.media.AudioPreset
import cn.youzifeile.chirp.media.MicrophoneTestPhase
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout

class AudioSettingsTest {
    @get:Rule val compose = createAndroidComposeRule<FeaturePreviewActivity>()

    @Test fun actualStopAndListenButtonStopsCaptureAndPlaysEachPresetsProcessedSample() {
        val instrument = InstrumentationRegistry.getInstrumentation()
        instrument.uiAutomation.executeShellCommand("pm grant ${instrument.targetContext.packageName} android.permission.RECORD_AUDIO").close()
        val audio = (compose.activity.application as ChirpApplication).calls.audio
        for (preset in AudioPreset.entries) {
            compose.runOnUiThread { audio.configure(preset, false, -45f) }
            compose.onNodeWithText(compose.activity.getString(R.string.microphone_test_start)).performScrollTo().performClick()
            compose.waitUntil(6000) { audio.state.value.test == MicrophoneTestPhase.Measuring || audio.state.value.error != null }
            assertEquals(audio.state.value.toString(), MicrophoneTestPhase.Measuring, audio.state.value.test)
            Thread.sleep(1200)
            compose.onNodeWithText(compose.activity.getString(R.string.microphone_test_listen)).performScrollTo().performClick()
            compose.waitUntil(3000) { audio.state.value.test == MicrophoneTestPhase.Playing || audio.state.value.error != null }
            assertEquals(audio.state.value.toString(), MicrophoneTestPhase.Playing, audio.state.value.test)
            compose.waitUntil(5000) { audio.state.value.test == MicrophoneTestPhase.Idle }
            assertNull(audio.state.value.error)
        }
    }

    @Test fun stopOnlyAndActivityRecreationDoNotKeepCapturing() {
        val instrument = InstrumentationRegistry.getInstrumentation()
        instrument.uiAutomation.executeShellCommand("pm grant ${instrument.targetContext.packageName} android.permission.RECORD_AUDIO").close()
        val audio = (compose.activity.application as ChirpApplication).calls.audio
        compose.onNodeWithText(compose.activity.getString(R.string.microphone_test_start)).performScrollTo().performClick()
        compose.waitUntil(6000) { audio.state.value.test == MicrophoneTestPhase.Measuring || audio.state.value.error != null }
        assertEquals(MicrophoneTestPhase.Measuring, audio.state.value.test)
        compose.onNodeWithText(compose.activity.getString(R.string.microphone_test_stop)).performScrollTo().performClick()
        compose.waitUntil(3000) { audio.state.value.test == MicrophoneTestPhase.Idle }
        compose.activityRule.scenario.recreate()
        compose.waitForIdle()
        assertEquals(MicrophoneTestPhase.Idle, audio.state.value.test)
        assertFalse(audio.state.value.reading.processing)
    }

    @Test fun audioChoicesSaveFromTheRealControlsAndSurviveRecreation() {
        val app = compose.activity.application as ChirpApplication
        val original = runBlocking { app.settings.audioSettings() }
        try {
            val label = compose.activity.getString(R.string.preset_webrtc)
            compose.onNodeWithText(label, substring = true).performScrollTo().performClick()
            compose.onNodeWithText(compose.activity.getString(R.string.voice_activation_enable)).performScrollTo().performClick()
            compose.waitUntil(3000) { app.calls.audio.state.value.preset == AudioPreset.WebRTC && app.calls.audio.state.value.activation }
            val saved = runBlocking {
                withTimeout(3000) {
                    var saved = app.settings.audioSettings()
                    while (saved.first != AudioPreset.WebRTC || !saved.second) {
                        delay(25)
                        saved = app.settings.audioSettings()
                    }
                    saved
                }
            }
            assertEquals(AudioPreset.WebRTC, saved.first); assertTrue(saved.second)
            compose.activityRule.scenario.recreate()
            compose.waitForIdle()
            assertEquals(AudioPreset.WebRTC, app.calls.audio.state.value.preset)
            assertTrue(app.calls.audio.state.value.activation)
        } finally {
            runBlocking { app.settings.saveAudioSettings(original.first, original.second, original.third) }
            compose.runOnUiThread { app.calls.audio.configure(original.first, original.second, original.third) }
        }
    }

}
