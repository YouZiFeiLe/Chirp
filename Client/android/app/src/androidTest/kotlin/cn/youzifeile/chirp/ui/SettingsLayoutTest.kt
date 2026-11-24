package cn.youzifeile.chirp.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.media.AudioState
import cn.youzifeile.chirp.media.CallState
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import java.io.File

/** Device screenshots plus scroll/accessibility assertions. No golden files are overwritten. */
@OptIn(ExperimentalTestApi::class)
@RunWith(Parameterized::class)
class SettingsLayoutTest(private val width: Int, private val height: Int, private val dark: Boolean, private val font: Float) {
    @get:Rule val compose = createComposeRule()
    @Test fun allAudioToolsRemainReachableAcrossWindowSizesAndFontScales() {
        compose.setContent {
            DeviceConfigurationOverride(DeviceConfigurationOverride.ForcedSize(DpSize(width.dp, height.dp)) then DeviceConfigurationOverride.FontScale(font)) {
                ChirpTheme(darkTheme = dark) { Box(Modifier.fillMaxSize()) { AudioSettingsForm(AudioState(), CallState(), {}) } }
            }
        }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        compose.onNodeWithText(context.getString(R.string.audio_presets)).performScrollTo().assertIsDisplayed()
        val folder = File(context.getExternalFilesDir(null), "ui-checks").apply { mkdirs() }
        val name = "audio-${width}x${height}-${if (dark) "dark" else "light"}-$font"
        File(folder, "$name-top.png").outputStream().use { compose.onRoot().captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        compose.onNodeWithText(context.getString(R.string.microphone_test_start)).performScrollTo().assertIsDisplayed()
        File(folder, "$name-bottom.png").outputStream().use { compose.onRoot().captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
    }
    companion object {
        @JvmStatic @Parameterized.Parameters(name = "{0}x{1} dark={2} font={3}")
        fun sizes(): List<Array<Any>> = buildList {
            for (w in listOf(400, 610, 900)) for (h in listOf(400, 500, 1000)) add(arrayOf(w, h, false, 1f))
            add(arrayOf(400, 500, true, 1f)); add(arrayOf(400, 500, false, 1.5f)); add(arrayOf(900, 500, true, 1.5f))
        }
    }
}
