package cn.youzifeile.chirp.data

import android.accessibilityservice.AccessibilityService
import android.os.ParcelFileDescriptor
import android.view.View
import androidx.lifecycle.viewModelScope
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import cn.youzifeile.chirp.ChirpApplication
import cn.youzifeile.chirp.MainActivity
import cn.youzifeile.chirp.ui.MainViewModel
import cn.youzifeile.chirp.ui.authenticateLogin
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Opt in on an isolated device with a strong biometric enrolled. */
class BiometricLoginTest {
    private val app get() = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as ChirpApplication

    private fun fixture(): SavedLogin {
        assumeTrue(InstrumentationRegistry.getArguments().getString("biometric_login") == "true")
        assumeTrue(app.savedLogin.available())
        val url = "https://keys.example.test/".toHttpUrl()
        val connection = ServerConnection(url, url, url, null, url, url, url, url, "main", null)
        val account = "member_" + "a".repeat(16)
        return SavedLogin("resume-v1_" + base64url(randomBytes(32)), connection, account,
            account + ".login_" + "b".repeat(16), digest(randomBytes(32)), nowSeconds() + 120)
    }

    @Test fun taskRemovalKeepsTheRecordAndOnlyTheFirstForegroundPrompts() = runBlocking<Unit> {
        val saved = fixture()
        val vault = app.savedLogin
        vault.replace(saved)
        val model = withContext(Dispatchers.Main) { MainViewModel(app, networkClock = synchronizedTestClock()) }
        val prompts = AtomicInteger()
        try {
            withTimeout(10_000) { model.state.first { it.lockedUntil == saved.expiresAt } }
            val cancelled = CompletableDeferred<Unit>()
            withContext(Dispatchers.Main) {
                model.enterForeground { prompts.incrementAndGet(); cancelled.complete(Unit); null }
            }
            withTimeout(10_000) { cancelled.await(); model.state.first { !it.unlocking } }
            assertNull(model.state.value.account)
            val retry = CompletableDeferred<Unit>()
            withContext(Dispatchers.Main) {
                model.leaveForeground()
                model.enterForeground { prompts.incrementAndGet(); retry.complete(Unit); awaitCancellation() }
                assertFalse(model.state.value.unlocking)
                model.unlock()
            }
            withTimeout(10_000) { retry.await() }
            withContext(Dispatchers.Main) { model.endTaskSession(); model.viewModelScope.cancel() }
            assertEquals(2, prompts.get())
            assertEquals(saved.expiresAt, vault.expiration())

            val reopened = withContext(Dispatchers.Main) { MainViewModel(app, networkClock = synchronizedTestClock()) }
            try {
                withTimeout(10_000) { reopened.state.first { it.lockedUntil != null } }
                withContext(Dispatchers.Main) {
                    reopened.enterForeground { awaitCancellation() }
                    reopened.logout()
                }
                assertNull(reopened.state.value.account)
                assertNull(reopened.state.value.lockedUntil)
                assertNull(vault.expiration())
            } finally { withContext(Dispatchers.Main) { reopened.viewModelScope.cancel() } }
        } finally {
            withContext(Dispatchers.Main) { model.viewModelScope.cancel(); vault.clear() }
            vault.awaitPendingWrites()
        }
    }

    @Test fun onlyTheCipherApprovedByTheSystemCanReadTheRecord() = runBlocking<Unit> {
        val saved = fixture()
        val vault = app.savedLogin
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var activity: MainActivity
            scenario.onActivity { activity = it }
            withTimeout(15_000) { activity.model.state.first { !it.checking } }
            vault.replace(saved)
            try {
                suspend fun silentRead() = runCatching { vault.open(saved.expiresAt) { it } }
                assertTrue(silentRead().isFailure)
                // Present the enrolled finger on the emulator or dedicated device when prompted.
                val opened = withTimeout(45_000) {
                    withContext(Dispatchers.Main) { vault.open(saved.expiresAt) { authenticateLogin(activity, it) } }
                }
                assertTrue(wireJson.encodeToString(saved) == wireJson.encodeToString(requireNotNull(opened)))
                assertTrue(silentRead().isFailure)
            } finally {
                withContext(Dispatchers.Main) { vault.clear() }
                vault.awaitPendingWrites()
            }
        }
    }

    @Test fun recentsHidesTheLiveWindowAndReturningShowsItAgain() = runBlocking<Unit> {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var activity: MainActivity
            scenario.onActivity { activity = it }
            val content = activity.findViewById<View>(android.R.id.content)
            suspend fun assertVisibility(expected: Int) {
                val reached = withTimeoutOrNull(8_000) {
                    while (!withContext(Dispatchers.Main) { content.visibility == expected }) delay(50)
                    true
                }
                assertTrue("Expected task content visibility $expected", reached == true)
            }
            assertVisibility(View.VISIBLE)
            val automation = instrumentation.uiAutomation
            assertTrue(automation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_RECENTS))
            try { assertVisibility(View.INVISIBLE) }
            finally {
                automation.waitForIdle(500, 5_000)
                assertTrue(automation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME))
                automation.waitForIdle(500, 5_000)
                val launch = "am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n " +
                    "${app.packageName}/${MainActivity::class.java.name}"
                ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand(launch)).use { it.readBytes() }
            }
            assertVisibility(View.VISIBLE)
        }
    }
}
