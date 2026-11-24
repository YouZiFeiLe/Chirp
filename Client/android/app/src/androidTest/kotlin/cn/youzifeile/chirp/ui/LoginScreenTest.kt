package cn.youzifeile.chirp.ui

import androidx.activity.ComponentActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.height
import androidx.compose.ui.unit.width
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.ClockReading
import cn.youzifeile.chirp.data.ClockStatus
import cn.youzifeile.chirp.data.ServerConnection
import cn.youzifeile.chirp.data.path
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.io.File

class LoginScreenTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun serverFieldShowsAnExampleAndKeepsTheEnteredAddressAfterConfirmation() {
        val entered = "chirp.example.com:8443/"
        val origin = "https://chirp.example.com:8443/".toHttpUrl()
        val connection = ServerConnection(origin, origin, origin, null, origin, origin, origin, origin, "main", null)
        var state by mutableStateOf(MainState(checking = false))
        compose.setContent {
            ChirpTheme {
                LoginScreen(state, onAddressChange = { state = state.copy(address = it, connection = null) },
                    onConfirm = { address ->
                        assertEquals(entered, address)
                        state = state.copy(connection = connection)
                    }, onLogin = {}, onCancel = {}, onRegister = {}, onLocalPermission = {}, onSettings = {}, onRetryClock = {})
            }
        }

        val field = compose.onNode(hasSetTextAction())
        val example = compose.onNodeWithText("chirp.example.com", useUnmergedTree = true)
        example.performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(compose.activity.getString(R.string.server_confirm)).assertIsNotEnabled()
        field.performTextInput(entered)
        example.assertDoesNotExist()
        field.performImeAction()
        field.assertTextContains(entered)
        compose.onNodeWithText(compose.activity.getString(R.string.server_verified)).assertExists()
    }

    @Test fun registrationButtonFollowsTheConfirmedServerWithoutBrowserInstructions() {
        val origin = "https://example.test/".toHttpUrl()
        var connection by mutableStateOf(ServerConnection(origin, origin, origin, origin.path("register"),
            origin, origin, origin, origin, "main", null))
        var registerClicks = 0
        val logins = mutableListOf<Boolean>()
        var openingRegistration by mutableStateOf(false)
        var clock by mutableStateOf(ClockReading())
        compose.setContent {
            ChirpTheme {
                LoginScreen(MainState(address = origin.toString(), connection = connection,
                    checking = openingRegistration, openingRegistration = openingRegistration, clock = clock),
                    onAddressChange = {}, onConfirm = {}, onLogin = { logins.add(it) }, onCancel = {},
                    onRegister = { registerClicks++ }, onLocalPermission = {}, onSettings = {}, onRetryClock = {})
            }
        }
        fun node(id: Int) = compose.onNodeWithText(compose.activity.getString(id))
        val scan = node(R.string.phone_login)
        val register = node(R.string.register)
        val login = node(R.string.passkey)
        login.assertIsNotEnabled()
        scan.assertIsNotEnabled()
        register.assertIsEnabled()
        node(R.string.clock_checking).assertExists()
        compose.runOnIdle { clock = ClockReading(ClockStatus.OutOfSync, -12_000, canRetry = true) }
        login.assertIsNotEnabled()
        scan.assertIsNotEnabled()
        node(R.string.clock_settings).assertExists()
        compose.runOnIdle { clock = ClockReading(ClockStatus.Ready) }
        node(R.string.clock_settings).assertDoesNotExist()
        val hint = compose.onNode(hasText("请在浏览器完成注册", substring = true) or
            hasText("Complete registration in your browser", substring = true))
        node(R.string.login_security).assertDoesNotExist()
        node(R.string.pair_device).assertDoesNotExist()
        node(R.string.reset_local).assertDoesNotExist()
        scan.performScrollTo().assertIsDisplayed()
        register.performScrollTo().assertIsDisplayed()
        val loginBounds = login.getUnclippedBoundsInRoot()
        val scanBounds = scan.getUnclippedBoundsInRoot()
        val registerBounds = register.getUnclippedBoundsInRoot()
        assertTrue(loginBounds.bottom <= scanBounds.top)
        assertEquals(scanBounds.top, registerBounds.top)
        assertTrue(scanBounds.right < registerBounds.left)
        assertTrue(loginBounds.width > scanBounds.width && loginBounds.width > registerBounds.width)
        assertTrue(scanBounds.height >= 48.dp && registerBounds.height >= 48.dp)
        val directory = File(compose.activity.getExternalFilesDir(null), "ui-checks").apply { mkdirs() }
        File(directory, "login-actions.png").outputStream().use { output ->
            compose.onRoot().captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output)
        }
        hint.assertDoesNotExist()
        login.performClick()
        scan.performClick()
        compose.runOnIdle {
            assertEquals(listOf(false, true), logins)
            openingRegistration = true
        }
        login.assertIsNotEnabled()
        scan.assertIsNotEnabled()
        node(R.string.opening_registration).assertIsNotEnabled()

        fun assertCentered(action: SemanticsNodeInteraction) {
            val bounds = action.getUnclippedBoundsInRoot()
            val primary = login.getUnclippedBoundsInRoot()
            assertEquals((primary.left.value + primary.right.value) / 2f, (bounds.left.value + bounds.right.value) / 2f, 1f)
        }
        compose.runOnIdle {
            openingRegistration = false
            connection = connection.copy(deviceLogin = false)
        }
        scan.assertDoesNotExist()
        assertCentered(register)
        register.performScrollTo().performClick()
        compose.runOnIdle {
            assertEquals(1, registerClicks)
            connection = connection.copy(deviceLogin = true, register = null)
        }
        scan.performScrollTo().assertIsDisplayed()
        assertCentered(scan)
        register.assertDoesNotExist()
        hint.assertDoesNotExist()
        node(R.string.registration_paused).assertDoesNotExist()
        compose.runOnIdle { connection = connection.copy(deviceLogin = false) }
        scan.assertDoesNotExist()
        register.assertDoesNotExist()
        login.assertIsEnabled()
    }
}
