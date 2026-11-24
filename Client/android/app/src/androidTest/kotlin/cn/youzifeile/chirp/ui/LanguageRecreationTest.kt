package cn.youzifeile.chirp.ui

import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Test

class LanguageRecreationTest {
    private fun visibleTitle(node: AccessibilityNodeInfo?, title: String): Boolean {
        if (node == null) return false
        if (node.isVisibleToUser && (node.text?.toString() == title || node.contentDescription?.toString() == title)) return true
        return (0 until node.childCount).any { visibleTitle(node.getChild(it), title) }
    }

    @Test fun switchingTheApplicationLanguageRecreatesTheVisibleAudioSettings() {
        val instrument = InstrumentationRegistry.getInstrumentation()
        val original = AppLanguage.selected(instrument.targetContext)
        ActivityScenario.launch(FeaturePreviewActivity::class.java).use { scenario ->
            fun choose(tag: String) = scenario.onActivity { AppLanguage.choose(it, tag) }
            fun expectScreen(language: String, title: String) {
                val end = SystemClock.elapsedRealtime() + 10_000
                while (SystemClock.elapsedRealtime() < end) {
                    var translated = false
                    scenario.onActivity { translated = it.resources.configuration.locales[0].language == language }
                    val root = instrument.uiAutomation.rootInActiveWindow
                    if (translated && visibleTitle(root, title)) return
                    SystemClock.sleep(80)
                }
                throw AssertionError("The visible audio settings did not switch to $language")
            }
            try {
                choose("en")
                expectScreen("en", "Audio settings")
                choose("zh-CN")
                expectScreen("zh", "声音设置")
            } finally {
                choose(original)
                assertEquals(original, AppLanguage.selected(instrument.targetContext))
            }
        }
    }
}
