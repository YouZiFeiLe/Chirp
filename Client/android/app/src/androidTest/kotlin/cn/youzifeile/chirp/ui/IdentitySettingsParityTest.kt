package cn.youzifeile.chirp.ui

import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import cn.youzifeile.chirp.ChirpApplication
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.*
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class IdentitySettingsParityTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun signedOutSettingsOfferDeviceAuthorizationAndSavedIdentities() {
        val activity = compose.activity
        val saved = SavedIdentity("https://example.test:443","member_" + "a".repeat(16),"Alice",
            base64(ByteArray(32) { 7 }),"https://example.test/")
        var localOffset = 30_000L
        val clock = NetworkClock({ localOffset }, { 0 }) { listOf(NetworkTimeSample(0, 0, 10)) }
        val model = compose.runOnUiThread { MainViewModel(activity.application as ChirpApplication, restoreOnStart = false, networkClock = clock) }
        compose.setContent {
            val live by model.state.collectAsStateWithLifecycle()
            val state = live.copy(savedIdentities = listOf(saved), selectedIdentity = saved)
            ChirpTheme { ChirpApp(activity, state, cn.youzifeile.chirp.media.CallState(), model) }
        }
        val authorize = compose.onNodeWithText(activity.getString(R.string.pair_device))
        authorize.assertDoesNotExist()
        compose.onNodeWithContentDescription(activity.getString(R.string.security_settings)).performClick()
        authorize.performScrollTo().assertIsNotEnabled()
        compose.onNodeWithText(activity.getString(R.string.clock_settings)).assertExists()
        compose.runOnUiThread { localOffset = 0; model.checkClock() }
        authorize.assertIsEnabled()
        val identities = compose.onNodeWithText(activity.getString(R.string.parity_saved_identities))
        val fingerprint = compose.onNodeWithText(sha256(saved.root.base64Bytes(32)).toHexString())
        identities.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, activity.getString(R.string.settings_collapsed)))
        fingerprint.assertDoesNotExist()
        identities.performScrollTo().performClick()
        identities.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, activity.getString(R.string.settings_expanded)))
        fingerprint.performScrollTo().assertIsDisplayed()
        identities.performScrollTo().performClick()
        fingerprint.assertDoesNotExist()
        authorize.performScrollTo().performClick()
        compose.onNodeWithText(activity.getString(R.string.pair_scan)).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(activity.getString(R.string.pair_choose_image)).performScrollTo().assertIsDisplayed()
    }

    @Test fun signedInAccountShowsNetworkPermissionInPreferencesAndFingerprintInLocalIdentity() {
        val activity = compose.activity
        val local = DeviceIdentity.issue(randomBytes(32), publicKey(randomBytes(32)))
        val account = Profile("member_" + "b".repeat(16), "Bob", 1)
        val state = MainState(checking = false, account = account, accountDevice = local)
        compose.setContent {
            val model = remember { MainViewModel(activity.application as ChirpApplication, restoreOnStart = false) }
            ChirpTheme { ChirpApp(activity, state, cn.youzifeile.chirp.media.CallState(), model) }
        }
        compose.onNodeWithText(activity.getString(R.string.account)).performClick()
        if (Build.VERSION.SDK_INT >= 37) {
            val granted = activity.checkSelfPermission(ChirpPermission.LocalNetwork.value) == PackageManager.PERMISSION_GRANTED
            val label = if (granted) R.string.local_network_allowed else R.string.local_network
            val network = compose.onNodeWithText(activity.getString(label)).performScrollTo().assertIsDisplayed()
            if (granted) network.assertHasNoClickAction() else network.assertHasClickAction()
        } else {
            compose.onNodeWithText(activity.getString(R.string.local_network)).assertDoesNotExist()
            compose.onNodeWithText(activity.getString(R.string.local_network_allowed)).assertDoesNotExist()
        }
        compose.onNodeWithText(activity.getString(R.string.local_identity_data)).performScrollTo().performClick()
        val fingerprint = compose.onNodeWithText(sha256(local.accountKey.base64Bytes(32)).toHexString())
        fingerprint.assertDoesNotExist()
        compose.onNodeWithText(activity.getString(R.string.parity_account_fingerprint)).performScrollTo().performClick()
        fingerprint.performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(activity.getString(R.string.pair_device)).assertDoesNotExist()
        compose.onNodeWithText(activity.getString(R.string.pair_other_devices)).assertDoesNotExist()
        compose.onNodeWithText(activity.getString(R.string.reset_local)).performScrollTo().assertIsEnabled()
    }

    @Test fun signedInAccountOffersAuthorizationDirectlyBelowMyDevices() {
        val activity = compose.activity
        val account = Profile("member_" + "c".repeat(16), "Carol", 1)
        val local = DeviceIdentity.issue(randomBytes(32), publicKey(randomBytes(32)))
        var state by mutableStateOf(MainState(checking = false, account = account, accountDevice = local))
        compose.setContent {
            val model = remember { MainViewModel(activity.application as ChirpApplication, restoreOnStart = false, networkClock = synchronizedTestClock()) }
            ChirpTheme { ChirpApp(activity, state, cn.youzifeile.chirp.media.CallState(), model) }
        }
        fun node(label: Int) = compose.onNodeWithText(activity.getString(label))
        node(R.string.account).performClick()
        val devices = node(R.string.devices)
        val authorize = node(R.string.pair_other_devices)
        authorize.performScrollTo().assertIsNotEnabled()
        compose.runOnIdle { state = state.copy(clock = ClockReading(ClockStatus.Ready)) }
        authorize.performScrollTo().assertIsDisplayed().assertTextContains(activity.getString(R.string.pair_other_devices_detail))
        assertEquals(devices.getUnclippedBoundsInRoot().bottom.value, authorize.getUnclippedBoundsInRoot().top.value, 1.5f)
        authorize.assertIsEnabled().performClick()
        node(R.string.pair_scan).performScrollTo().assertIsDisplayed()
        node(R.string.pair_choose_image).performScrollTo().assertIsDisplayed()
        compose.runOnIdle { state = state.copy(clock = ClockReading(ClockStatus.Unavailable, canRetry = true)) }
        node(R.string.pair_scan).assertDoesNotExist()
        authorize.performScrollTo().assertIsNotEnabled()
        node(R.string.clock_retry).assertIsEnabled()
        compose.runOnIdle { state = state.copy(clock = ClockReading(ClockStatus.Ready)) }
        authorize.assertIsEnabled()

        devices.performScrollTo().performClick()
        node(R.string.devices_title).assertIsDisplayed()
        node(R.string.pair_device).assertDoesNotExist()
        authorize.assertDoesNotExist()
        compose.runOnUiThread { activity.onBackPressedDispatcher.onBackPressed() }

        compose.runOnIdle { state = state.copy(identity = state.identity.copy(revoked = setOf(local.leaf))) }
        authorize.performScrollTo().assertIsNotEnabled()
        node(R.string.pair_enrollment_unavailable).assertIsDisplayed()
    }

    @Test fun deviceDetailsStayWithTheSelectedDeviceWhenTheListChanges() {
        val activity = compose.activity
        fun label(name: String, number: Byte) = DeviceLabel(base64(ByteArray(32) { number }), name, "Android", 1)
        val local = label("Phone", 1)
        val remote = label("Tablet", 2)
        var identity by mutableStateOf(AccountView(devices = mapOf(local.key to local, remote.key to remote),
            currentKey = local.key, enrollingDevices = setOf(local.key), synced = true))
        compose.setContent {
            val model = remember { MainViewModel(activity.application as ChirpApplication, restoreOnStart = false) }
            ChirpTheme { DevicesScreen(MainState(checking = false, identity = identity), model, back = {}) }
        }
        fun fingerprint(device: DeviceLabel) = compose.onNodeWithText(sha256(device.key.base64Bytes(32)).toHexString())
        fun node(id: Int) = compose.onNodeWithText(activity.getString(id))
        val phone = compose.onNodeWithText(local.name)
        val tablet = compose.onNodeWithText(remote.name)
        phone.assertTextContains(activity.getString(R.string.device_current), substring = true)
        tablet.assertTextContains(activity.getString(R.string.device_authorized), substring = true)
        fingerprint(local).assertDoesNotExist()
        fingerprint(remote).assertDoesNotExist()
        tablet.performScrollTo().performClick()
        fingerprint(remote).performScrollTo().assertIsDisplayed()
        node(R.string.revoke_device).performScrollTo().assertIsEnabled()
        compose.runOnIdle { identity = identity.copy(currentKey = remote.key, revoked = setOf(local.key)) }
        fingerprint(remote).assertExists()
        fingerprint(local).assertDoesNotExist()
        node(R.string.revoke_device).assertDoesNotExist()
        phone.assertTextContains(activity.getString(R.string.device_revoked), substring = true)
        tablet.performScrollTo().performClick()
        phone.performScrollTo().performClick()
        fingerprint(local).performScrollTo().assertIsDisplayed()
        node(R.string.device_rename).assertDoesNotExist()
    }

    @Test fun revokedFriendDeviceIsIdentifiableBeforeOpeningItsFingerprintOnBothPages() {
        val activity = compose.activity
        val device = base64(ByteArray(32) { 3 })
        val friend = Friend("river", base64(ByteArray(32) { 2 }), "River", setOf(device))
        val ban = Ban(1, "device", device, friend.id, friend.root, friend.name)
        val state = MainState(checking = false, account = Profile("local", "Local", 1),
            identity = AccountView(friends = listOf(friend), bans = listOf(ban), synced = true))
        compose.setContent {
            val model = remember { MainViewModel(activity.application as ChirpApplication, restoreOnStart = false) }
            ChirpTheme { ChirpApp(activity, state, cn.youzifeile.chirp.media.CallState(), model) }
        }
        fun node(id: Int) = compose.onNodeWithText(activity.getString(id))
        val fingerprint = compose.onNodeWithText(sha256(device.base64Bytes(32)).toHexString())
        node(R.string.friends).performClick()
        compose.onNodeWithText(friend.name).performClick()
        fingerprint.assertDoesNotExist()
        node(R.string.device_revoked).performScrollTo().performClick()
        fingerprint.performScrollTo().assertIsDisplayed()
        node(R.string.untrust_device).performScrollTo().performClick()
        node(R.string.friend_sync_warning).assertIsDisplayed()
        node(R.string.cancel).performClick()
        compose.runOnUiThread { activity.onBackPressedDispatcher.onBackPressed() }
        node(R.string.account).performClick()
        node(R.string.blocked_identities).performScrollTo().performClick()
        val record = compose.onNodeWithText(friend.name)
        record.performScrollTo().assertTextContains(activity.getString(R.string.banned_device))
        fingerprint.assertDoesNotExist()
        record.performClick()
        fingerprint.performScrollTo().assertIsDisplayed()
    }

    @Test fun opensResetWarningFromSignedOutSettings() {
        val activity = compose.activity
        compose.setContent {
            val model = remember { MainViewModel(activity.application as ChirpApplication, restoreOnStart = false) }
            val call by model.calls.state.collectAsStateWithLifecycle()
            ChirpTheme { ChirpApp(activity, MainState(checking = false), call, model) }
        }
        val reset = compose.onNodeWithText(activity.getString(R.string.reset_local))
        reset.assertDoesNotExist()
        compose.onNodeWithContentDescription(activity.getString(R.string.security_settings)).performClick()
        reset.performScrollTo().performClick()
        compose.onNodeWithText(activity.getString(R.string.reset_local_warning)).assertIsDisplayed()
        compose.onNodeWithText(activity.getString(R.string.cancel)).performClick()
        compose.onNodeWithText(activity.getString(R.string.reset_local_warning)).assertDoesNotExist()
    }

    @Test fun switchingSavedAccountsDisplaysEachAccountFingerprint() {
        fun item(name: String, seed: Int) = SavedIdentity("https://example.test:443", "member_" + name,
            name, base64(ByteArray(32) { seed.toByte() }), "https://example.test/")
        val first = item("Account A", 1)
        val second = item("Account B", 2)
        compose.setContent {
            var selected by remember { mutableStateOf<SavedIdentity?>(first) }
            val state = MainState(savedIdentities = listOf(first, second), selectedIdentity = selected)
            ChirpTheme {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    SavedIdentitySettings(state, onSelect = { selected = it }, onFind = { _, _ -> })
                }
            }
        }
        fun fingerprint(item: SavedIdentity) = sha256(item.root.base64Bytes(32)).toHexString()
        compose.onNodeWithText(compose.activity.getString(R.string.parity_saved_identities)).performClick()
        compose.onNodeWithText(fingerprint(first)).assertExists()
        compose.onNodeWithText(second.name).performScrollTo().performClick()
        compose.onNodeWithText(fingerprint(first)).assertDoesNotExist()
        compose.onNodeWithText(fingerprint(second)).assertExists()
    }
}
