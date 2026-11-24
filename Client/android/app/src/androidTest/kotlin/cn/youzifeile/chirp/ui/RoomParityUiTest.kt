package cn.youzifeile.chirp.ui

import android.Manifest
import android.graphics.Bitmap
import android.graphics.Rect
import android.hardware.camera2.CameraManager
import android.os.SystemClock
import android.view.View
import android.view.inspector.WindowInspector
import androidx.activity.ComponentActivity
import androidx.camera.view.PreviewView
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.height
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.test.platform.app.InstrumentationRegistry
import cn.youzifeile.chirp.ChirpApplication
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.*
import cn.youzifeile.chirp.media.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

class RoomParityUiTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val app get() = compose.activity.application as ChirpApplication
    private fun text(id: Int, vararg args: Any) = compose.activity.getString(id, *args)
    private fun inDialog(value: String) = compose.onNode(hasText(value) and hasAnyAncestor(isDialog()))

    private fun snapshot(name: String) {
        val directory = File(compose.activity.getExternalFilesDir(null), "ui-checks").apply { mkdirs() }
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        automation.waitForIdle(500, 5_000)
        val image = requireNotNull(automation.takeScreenshot())
        try {
            File(directory, name).outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        } finally { image.recycle() }
    }

    @Test fun embeddedScannerReportsUnavailableOrStreamsAgainAfterDismissal() {
        val activity = compose.activity
        InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(activity.packageName, Manifest.permission.CAMERA)
        var showing by mutableStateOf(true)
        compose.setContent { ChirpTheme { if (showing) PairingScanner(activity, close = { showing = false }, chooseImage = {}) {} } }
        if (activity.getSystemService(CameraManager::class.java).cameraIdList.isEmpty()) {
            val unavailable = text(R.string.scan_camera_unavailable)
            compose.waitUntil(15_000) { compose.onAllNodesWithText(unavailable).fetchSemanticsNodes().isNotEmpty() }
            inDialog(text(R.string.cancel)).performClick()
            compose.runOnIdle { assertFalse(showing) }
            return
        }
        val previewLabel = text(R.string.scan_camera_preview)
        fun streamingPreview(): PreviewView? = compose.runOnUiThread {
            val previews = arrayListOf<View>()
            for (window in WindowInspector.getGlobalWindowViews()) {
                window.findViewsWithText(previews, previewLabel, View.FIND_VIEWS_WITH_CONTENT_DESCRIPTION)
            }
            previews.filterIsInstance<PreviewView>().firstOrNull { it.previewStreamState.value == PreviewView.StreamState.STREAMING }
        }
        compose.waitUntil(20_000) { streamingPreview() != null }
        inDialog(text(R.string.scan_camera_hint)).performScrollTo().assertIsDisplayed()
        val preview = requireNotNull(streamingPreview())
        val frame = compose.runOnUiThread {
            val position = IntArray(2)
            preview.getLocationOnScreen(position)
            Rect(position[0], position[1], position[0] + preview.width, position[1] + preview.height)
        }
        // The 8 dp gap between the live picture and its caption should match the dialog's side padding.
        val gap = (4 * activity.resources.displayMetrics.density).toInt().coerceAtLeast(1)
        val screenshot = requireNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        val pixels = screenshot.copy(Bitmap.Config.ARGB_8888, false)
        try {
            val y = frame.bottom + gap
            val background = pixels.getPixel(frame.left - gap, y)
            for (quarter in 1..3) {
                val x = frame.left + frame.width() * quarter / 4
                assertEquals("Camera preview drew outside its frame at ($x, $y)", background, pixels.getPixel(x, y))
            }
        } finally {
            pixels.recycle()
            screenshot.recycle()
        }
        inDialog(text(R.string.cancel)).performClick()
        compose.runOnIdle { assertFalse(showing); showing = true }
        compose.waitUntil(20_000) { streamingPreview() != null }
    }

    @Test fun prejoinTitleAndMenuOpenRulesAndLiveDetailsNeverShowStaleProgress() {
        val room = RoomInfo("garden", "声音工作室", true, false, GROUP_PROTOCOL, 6, "available", emptyList())
        val directory = Directory("example", 1UL, listOf(room), emptyList())
        val state = MainState(directory = directory)
        var call by mutableStateOf(CallState())
        val activity = compose.activity
        val application = app
        compose.setContent {
            val model = viewModel { MainViewModel(application, restoreOnStart = false) }
            ChirpTheme { RoomScreen(activity, room, state, call, model, {}, {}) }
        }

        compose.onNodeWithText(room.name).performClick()
        inDialog(text(R.string.room_information)).assertIsDisplayed()
        inDialog(text(R.string.info_prejoin)).assertIsDisplayed()
        inDialog(text(R.string.info_access)).assertTextContains(text(R.string.info_password))
        inDialog(text(R.string.info_capacity)).assertTextContains("6")
        inDialog(text(R.string.info_entry_mic)).assertTextContains(text(R.string.info_default_muted))
        val rotation = inDialog(text(R.string.rotation_details))
        val protocol = inDialog(text(R.string.info_protocol_details))
        rotation.assertDoesNotExist()
        protocol.assertDoesNotExist()
        val close = compose.onNode(hasContentDescription(text(R.string.close)) and hasAnyAncestor(isDialog()))
        close.performClick()
        compose.onNodeWithContentDescription(text(R.string.room_options)).performClick()
        compose.onNodeWithText(text(R.string.room_information)).performClick()
        inDialog(text(R.string.info_prejoin)).assertExists()

        val serverTime = System.currentTimeMillis()
        val info = RoomPublicInformation(serverTime, 30_000, 1UL, 2, "scheduled_rotation",
            serverTime - 60_000, serverTime - 30_000, null, "switching", 2, 1, SystemClock.elapsedRealtime())
        compose.runOnIdle { call = CallState(room = room, phase = CallPhase.Connected,
            information = info.copy(started = SystemClock.elapsedRealtime())) }
        inDialog(text(R.string.info_updating)).assertIsDisplayed()
        inDialog(text(R.string.info_round, "2")).assertDoesNotExist()
        inDialog("MLS").assertDoesNotExist()
        snapshot("room-information-overview.png")
        rotation.performScrollTo().performClick()
        inDialog(text(R.string.info_round_label)).assertTextContains(text(R.string.info_round, "2"))
        inDialog(text(R.string.info_progress)).assertTextContains(text(R.string.info_switching))
        inDialog(text(R.string.info_confirmed_devices)).assertTextContains("2 / 2")
        inDialog(text(R.string.info_switched_devices)).assertTextContains("1 / 2").performScrollTo()
        close.assertIsDisplayed()
        snapshot("room-information-rotation.png")
        compose.runOnIdle { call = call.copy(information = info.copy(started = SystemClock.elapsedRealtime() - 7_000)) }
        inDialog(text(R.string.info_stale)).assertExists()
        inDialog(text(R.string.info_round, "2")).assertDoesNotExist()
        inDialog(text(R.string.info_switched_devices)).assertDoesNotExist()
        inDialog(text(R.string.last_confirmation)).assertExists()
        rotation.performScrollTo().performClick()
        protocol.performScrollTo().performClick()
        inDialog(text(R.string.info_cipher)).assertTextContains("MLS")
        inDialog(text(R.string.info_protocol_version)).assertTextContains("V5")
        inDialog(text(R.string.info_coverage_label)).assertTextContains(text(R.string.info_encrypted_media))
        close.performClick()
        compose.onNodeWithText(room.name).performClick()
        inDialog("MLS").assertDoesNotExist()
        inDialog(text(R.string.last_confirmation)).assertDoesNotExist()
    }

    @Test fun roomInformationHidesPreviousRoundDuringVerificationAndSwipesClosed() {
        val room = RoomInfo("studio", "声音工作室", false, false, GROUP_PROTOCOL, 0, "available", emptyList())
        val info = RoomPublicInformation(10_000, 30_000, 6UL, 2, "members_changed",
            5_000, 9_000, null, "switching", 2, 1, SystemClock.elapsedRealtime())
        val call = CallState(room = room, phase = CallPhase.Securing, trust = RoomTrustView(pending = true), information = info)
        var open by mutableStateOf(true)
        compose.setContent { ChirpTheme(darkTheme = true) {
            if (open) RoomInformationSheet(room, call) { open = false }
        } }
        inDialog(text(R.string.verify_wait)).assertIsDisplayed()
        inDialog(text(R.string.info_access)).assertTextContains(text(R.string.info_open))
        inDialog(text(R.string.info_capacity)).assertTextContains(text(R.string.unlimited))
        inDialog(text(R.string.rotation_details)).performScrollTo().performClick()
        inDialog(text(R.string.info_round_label)).assertDoesNotExist()
        inDialog(text(R.string.info_confirmed_devices)).assertDoesNotExist()
        inDialog(text(R.string.info_update_reason)).assertDoesNotExist()
        val dialog = compose.onNode(isDialog())
        val start = inDialog(room.name).fetchSemanticsNode().boundsInRoot.center - dialog.fetchSemanticsNode().boundsInRoot.topLeft
        dialog.performTouchInput { swipe(start, Offset(start.x, height - 1f), durationMillis = 240) }
        dialog.assertDoesNotExist()
    }

    @Test fun roomInformationStaysSyncedOnEveryFrameOfALiveRefresh() {
        val room = RoomInfo("garden", "Garden", false, false, GROUP_PROTOCOL, 6, "available", emptyList())
        fun snapshot() = RoomPublicInformation(10_000, 30_000, 1UL, 2, "scheduled_rotation",
            5_000, 9_000, 30_000, null, 0, 0, SystemClock.elapsedRealtime())
        var info by mutableStateOf(snapshot())
        compose.setContent { ChirpTheme {
            RoomInformationSheet(room, CallState(room = room, phase = CallPhase.Connected, information = info)) {}
        } }
        val synced = inDialog(text(R.string.room_synced))
        val stale = inDialog(text(R.string.info_stale))
        synced.assertExists()
        val rules = inDialog(text(R.string.info_rules))
        rules.performScrollTo().assertIsDisplayed()
        val rulesPosition = rules.fetchSemanticsNode().boundsInRoot
        compose.mainClock.autoAdvance = false
        try {
            repeat(3) {
                compose.runOnUiThread { info = snapshot() }
                compose.mainClock.advanceTimeByFrame()
                stale.assertDoesNotExist()
                synced.assertExists()
                assertEquals(rulesPosition, rules.fetchSemanticsNode().boundsInRoot)
                compose.mainClock.advanceTimeByFrame()
            }
        } finally { compose.mainClock.autoAdvance = true }
        compose.runOnIdle { info = snapshot().copy(started = SystemClock.elapsedRealtime() - 5_000) }
        synced.assertExists()
        compose.waitUntil(3_000) {
            compose.onAllNodesWithText(text(R.string.info_stale)).fetchSemanticsNodes().isNotEmpty()
        }
        synced.assertDoesNotExist()
        compose.runOnIdle { info = snapshot() }
        synced.assertExists()
    }

    @Test fun publicRoomReportsOnlyItsOwnFailureAndReopensPasswordEntry() {
        val room = RoomInfo("garden", "Garden", false, false, GROUP_PROTOCOL, 6, "available", emptyList())
        val directory = Directory("example", 1UL, listOf(room), emptyList())
        var state by mutableStateOf(MainState(directory = directory))
        val activity = compose.activity
        val application = app
        compose.setContent {
            val model = viewModel { MainViewModel(application, restoreOnStart = false) }
            ChirpTheme { RoomScreen(activity, room, state, CallState(), model, {}, {}) }
        }
        fun fail(target: String, code: String) = compose.runOnIdle {
            state = state.copy(joinFailure = JoinFailure(target, ClientFailure(code)))
        }
        fail("other", "NEW_PREFLIGHT_ERROR")
        compose.onNodeWithText("NEW_PREFLIGHT_ERROR", substring = true).assertDoesNotExist()
        fail(room.id, "NEW_PREFLIGHT_ERROR")
        compose.onNodeWithText("(NEW_PREFLIGHT_ERROR)", substring = true).assertExists()
        fail(room.id, "ROOM_PREFLIGHT_EXPIRED")
        compose.onNode(isDialog()).assertDoesNotExist()
        fail(room.id, "ROOM_PASSWORD_CHANGED")
        val field = compose.onNode(hasSetTextAction() and hasAnyAncestor(isDialog()))
        val join = compose.onNode(hasText(text(R.string.verify_and_join)) and hasClickAction() and hasAnyAncestor(isDialog()))
        join.assertIsNotEnabled()
        compose.onNodeWithText(compose.activity.getString(R.string.room_password_for_room, "Garden")).assertExists()
        compose.onNodeWithContentDescription(text(R.string.password_show)).performClick()
        compose.onNodeWithContentDescription(text(R.string.password_hide)).performClick()
        field.performTextReplacement("橘".repeat(171))
        join.assertIsNotEnabled()
        field.performTextReplacement("橘".repeat(170))
        join.assertIsEnabled()
    }

    @Test fun bothLanguagesRenderServerErrorsRetryInstructionsAndVersionBuilds() {
        val activity = compose.activity
        var tag by mutableStateOf("en")
        var failure by mutableStateOf(ClientFailure("ATTACHMENT_QUOTA", 37))
        fun localized(tag: String): android.content.Context {
            val config = android.content.res.Configuration(activity.resources.configuration)
            config.setLocale(java.util.Locale.forLanguageTag(tag))
            return activity.createConfigurationContext(config)
        }
        compose.setContent {
            val ctx = androidx.compose.runtime.remember(tag) { localized(tag) }
            androidx.compose.runtime.CompositionLocalProvider(androidx.compose.ui.platform.LocalContext provides ctx,
                androidx.compose.ui.platform.LocalConfiguration provides ctx.resources.configuration) {
                ChirpTheme { ErrorNote(failure) }
            }
        }
        for (lang in listOf("en", "zh-CN")) {
            compose.runOnIdle { tag = lang; failure = ClientFailure("ATTACHMENT_QUOTA", 37) }
            val catalog = localized(lang).resources.getStringArray(R.array.client_error_messages)
            assertEquals(145, catalog.map { it.substringBefore('=') }.toSet().size)
            val quota = catalog.single { it.startsWith("ATTACHMENT_QUOTA=") }.substringAfter('=')
            assertTrue(quota.contains("20 MiB") && quota.contains("100 MiB"))
            compose.onNodeWithText(quota + localized(lang).getString(R.string.retry_after, 37)).assertExists()
            val policy = VersionPolicy(ClientVersion("3.0.0", 220), ClientVersion("2.0.0", 123))
            compose.runOnIdle { failure = ClientFailure("CLIENT_UPDATE_REQUIRED", policy = policy) }
            compose.onNodeWithText(localized(lang).getString(R.string.version_policy, "3.0.0", "220", "2.0.0", "123"),
                substring = true).assertExists()
            compose.runOnIdle { failure = ClientFailure("invalid server prose") }
            compose.onNodeWithText("invalid server prose", substring = true).assertDoesNotExist()
        }
    }

    @Test fun chatOpensAtTheBottomKeepsTheReadersPlaceAndFollowsTheirOwnSend() {
        fun message(i: Int, own: Boolean = false) = ChatMessage(i.toString(), "Reader", "Message $i", own)
        var messages by mutableStateOf((0..65).map { message(it) })
        val calls = app.calls
        compose.setContent {
            ChirpTheme { RoomChatPanel(CallState(messages = messages, chatVisible = true, draftTooLong = true), calls) }
        }
        compose.onNodeWithText("Message 65").assertIsDisplayed()
        compose.onNodeWithText(text(R.string.chat_too_long)).assertIsDisplayed()
        val transcript = compose.onNode(SemanticsMatcher.keyIsDefined(SemanticsActions.ScrollToIndex))
        transcript.performScrollToIndex(0)
        compose.onNodeWithText("Message 0").assertIsDisplayed()
        compose.runOnIdle { messages = messages + message(66) }
        compose.onNodeWithText("Message 0").assertIsDisplayed()
        compose.runOnIdle { messages = messages + message(67, own = true) }
        compose.onNodeWithText("Message 67").assertIsDisplayed()
        compose.runOnIdle { messages = messages + message(68) }
        compose.onNodeWithText("Message 68").assertIsDisplayed()
        transcript.performScrollToIndex(0)
        compose.onNodeWithText(text(R.string.return_to_latest)).performClick()
        compose.onNodeWithText("Message 68").assertIsDisplayed()
        compose.onNodeWithText(text(R.string.return_to_latest)).assertDoesNotExist()
    }

    @Test fun cacheClearExplainsTheImpactAndWaitsForConfirmation() {
        val application = app
        compose.setContent {
            val model = viewModel { MainViewModel(application, restoreOnStart = false) }
            ChirpTheme { StorageSettings(model) {} }
        }
        val clear = compose.onNode(hasText(text(R.string.cache_clear)) and hasClickAction() and !hasAnyAncestor(isDialog()))
        val modal = hasAnyAncestor(isDialog())
        clear.performScrollTo().performClick()
        compose.onNode(hasText(text(R.string.cache_clear_question)) and modal).assertIsDisplayed()
        compose.onNode(hasText(text(R.string.cache_clear_effects)) and modal).assertExists()
        compose.onNode(hasText(text(R.string.cancel)) and hasClickAction() and modal).performClick()
        compose.onNode(isDialog()).assertDoesNotExist()
        compose.onNodeWithText(text(R.string.cache_cleared)).assertDoesNotExist()
        clear.performScrollTo().performClick()
        compose.onNode(hasText(text(R.string.cache_clear)) and hasClickAction() and modal).performClick()
        compose.waitUntil(5_000) {
            compose.onAllNodesWithText(text(R.string.cache_cleared)).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(text(R.string.cache_cleared)).assertIsDisplayed()
    }

    @Test fun roomWarningNamesOnlyPendingDevicesAndOpensTheirVerification() {
        val alice = GroupMember("alice.entry-a", "小舟", "", "")
        val bob = GroupMember("bob.entry-b", "北辰", "", "")
        val trusted = GroupMember("lin.entry-c", "阿林", "", "")
        val peers = listOf(alice, bob, trusted)
        val room = RoomInfo("studio", "声音工作室", false, false, GROUP_PROTOCOL, 0, "available", emptyList())
        val state = MainState(directory = Directory("fixture", 1UL, listOf(room), emptyList(), fresh = true))
        val initial = RoomTrustView(peers = peers, trusted = setOf(trusted.identity), pending = true,
            localMember = GroupMember("myself.local", "小柚", "", ""))
        var call by mutableStateOf(CallState(room = room, entryID = "local", phase = CallPhase.Securing,
            chatVisible = true, trust = initial))
        var displayed by mutableStateOf(room)
        val activity = compose.activity
        val application = app
        compose.setContent {
            val model = viewModel { MainViewModel(application, restoreOnStart = false) }
            ChirpTheme(darkTheme = false) { RoomScreen(activity, displayed, state, call, model, {}, {}) }
        }
        fun target(name: String) = text(R.string.trust_target, name)
        val title = compose.onNodeWithText(text(R.string.room_verification_paused))
        title.assertIsDisplayed()
        val identityEntry = compose.onNode(hasText(text(R.string.manage_identity)) and hasClickAction())
        identityEntry.assertDoesNotExist()
        val warningTop = title.getUnclippedBoundsInRoot().top
        val canvasY = title.fetchSemanticsNode().boundsInRoot.center.y.toInt()
        fun canvas() = compose.onRoot().captureToImage().toPixelMap()[2, canvasY]
        val pendingCanvas = canvas()
        assertTrue(pendingCanvas.red > pendingCanvas.green)
        fun deviceButton(name: String) = compose.onNode(hasText(name) and hasContentDescription(text(R.string.verify_identity)))
        deviceButton(alice.name).assertIsDisplayed()
        deviceButton(bob.name).assertIsDisplayed()
        deviceButton(trusted.name).assertDoesNotExist()
        compose.onNodeWithText(text(R.string.room_empty_title)).assertDoesNotExist()
        snapshot("room-verification-warning.png")
        val grid = compose.onNode(SemanticsMatcher.keyIsDefined(SemanticsActions.ScrollToIndex) and
            SemanticsMatcher.keyIsDefined(SemanticsProperties.VerticalScrollAxisRange))
        grid.performScrollToKey(alice.identity)
        compose.onNode(hasClickAction() and hasAnyDescendant(hasText(alice.name)) and
            hasAnyDescendant(hasText(text(R.string.trust_your_turn))), useUnmergedTree = true).performClick()
        inDialog(text(R.string.verify_identity)).performScrollTo().performClick()
        inDialog(target(alice.name)).assertIsDisplayed()
        inDialog(text(R.string.cancel)).performClick()
        inDialog(text(R.string.close)).performClick()
        assertEquals(warningTop, title.getUnclippedBoundsInRoot().top)
        grid.performScrollToKey("room")
        compose.onNodeWithContentDescription(text(R.string.choose_verification_device)).performClick()
        compose.onNode(hasText(trusted.name) and hasAnyAncestor(isPopup())).assertDoesNotExist()
        compose.onNode(hasText(bob.name) and hasAnyAncestor(isPopup())).assertIsDisplayed()
        compose.onNode(hasText(alice.name) and hasAnyAncestor(isPopup())).performClick()
        inDialog(target(alice.name)).assertIsDisplayed()
        inDialog(text(R.string.sas_external)).assertIsDisplayed()
        inDialog(text(R.string.sas_confirm_hint)).assertDoesNotExist()
        inDialog(text(R.string.sas_start)).assertIsDisplayed()
        snapshot("room-verification-prepare.png")
        inDialog(text(R.string.verification_steps)).performClick()
        inDialog(text(R.string.sas_confirm_hint)).performScrollTo().assertIsDisplayed()
        inDialog(text(R.string.cancel)).performClick()
        compose.onNode(hasText(text(R.string.chat)) and hasClickAction()).performClick()
        compose.onNodeWithText(text(R.string.chat_paused_untrusted)).assertIsDisplayed()
        identityEntry.assertDoesNotExist()
        assertEquals(warningTop, title.getUnclippedBoundsInRoot().top)
        compose.runOnIdle { call = call.copy(trust = initial.copy(trusted = setOf(trusted.identity, bob.identity))) }
        compose.onNodeWithText(target(alice.name)).performClick()
        inDialog(text(R.string.sas_confirm_hint)).assertDoesNotExist()
        compose.runOnIdle { call = call.copy(trust = initial.copy(trusted = peers.map { it.identity }.toSet())) }
        compose.onAllNodes(isDialog()).assertCountEquals(0)
        compose.onNodeWithText(text(R.string.verify_wait_others)).assertIsDisplayed()
        compose.onNodeWithText(target(alice.name)).assertDoesNotExist()
        compose.runOnIdle { displayed = room.copy(id = "other") }
        title.assertDoesNotExist()
        compose.runOnIdle { displayed = room; call = call.copy(trust = call.trust.copy(pending = false)) }
        title.assertDoesNotExist()
        assertTrue(canvas().green >= canvas().red)
    }

    @Test fun sameNameDevicesCanBeSelectedSeparatelyInTheWarning() {
        fun member(entry: String, seed: Byte): GroupMember {
            val device = DeviceIdentity.issue(ByteArray(32) { 1 }, publicKey(ByteArray(32) { seed }))
            val id = "member.$entry"
            return GroupMember(id, "River", "", "", binding =
                EntryBinding(device, "origin", "room", "trust", "policy", id, "", "", 1, 2))
        }
        val first = member("one", 2)
        val second = member("two", 3)
        val peers = listOf(first, second)
        var selected: String? = null
        compose.setContent {
            ChirpTheme(darkTheme = true) {
                RoomVerificationBanner(RoomTrustView(peers = peers, pending = true)) { selected = it.identity }
            }
        }
        for (peer in peers) {
            val suffix = sha256(peer.requireBinding().device.leaf.base64Bytes(32)).toHexString().takeLast(8)
            compose.onNodeWithContentDescription(text(R.string.choose_verification_device)).performClick()
            compose.onNode(hasText("River · $suffix") and hasAnyAncestor(isPopup())).performClick()
            compose.runOnIdle { assertEquals(peer.identity, selected) }
        }
    }

    @Test fun busyInvitationNamesThePeerAndOffersAnotherInvitationWhileTheyAreInTheRoom() {
        val peer = GroupMember("peer.entry", "Riley", "", "")
        val another = GroupMember("other.entry", "Morgan", "", "")
        var trust by mutableStateOf(RoomTrustView(peers = listOf(peer, another),
            notice = VerificationNotice("invitation", peer.identity, VerificationPhase.PeerBusy)))
        val calls = app.calls
        compose.setContent { ChirpTheme { RoomVerificationDialogs(trust, calls) } }
        inDialog(text(R.string.sas_peer_busy)).assertIsDisplayed()
        inDialog(peer.name).assertIsDisplayed()
        inDialog(text(R.string.sas_peer_busy_detail)).assertExists()
        inDialog(text(R.string.sas_invite_again)).assertIsEnabled()
        inDialog(text(R.string.sas_back_room)).assertIsEnabled()
        inDialog(text(R.string.verify_match)).assertDoesNotExist()
        compose.runOnIdle { trust = trust.copy(peers = listOf(another)) }
        inDialog(text(R.string.sas_invite_again)).assertDoesNotExist()
        inDialog(text(R.string.sas_back_room)).assertIsEnabled()
    }

    @Test fun accountAndDeviceFingerprintsExpandDuringVerification() {
        val root = ByteArray(32) { 1 }
        val seed = ByteArray(32) { 2 }
        val device = DeviceIdentity.issue(root, publicKey(seed))
        val peer = GroupMember("peer.entry", "阿林", "", "", binding =
            EntryBinding(device, "origin", "room", "trust", "policy", "peer.entry", "", "", 1, 2))
        val numbers = listOf(1432, 2856, 8119)
        val room = RoomInfo("studio", "声音工作室", false, false, GROUP_PROTOCOL, 0, "available", emptyList())
        val trust = RoomTrustView(peers = listOf(peer), verification =
            Verification("verification", peer.identity, accepted = true, numbers = numbers), pending = true,
            expires = SystemClock.elapsedRealtime() + 110_000, localMember = GroupMember("myself.local", "小柚", "", ""))
        val call = CallState(room = room, entryID = "local", phase = CallPhase.Securing, chatVisible = true, trust = trust)
        val activity = compose.activity
        val application = app
        compose.setContent {
            val model = viewModel { MainViewModel(application, restoreOnStart = false) }
            ChirpTheme {
                RoomScreen(activity, room, MainState(), call, model, {}, {})
                RoomVerificationDialogs(trust, model.calls)
            }
        }
        val groups = numbers.mapIndexed { index, number ->
            val description = text(R.string.sas_group_accessible, index + 1) + ", " + number.toString().toList().joinToString(" ")
            compose.onNodeWithContentDescription(description)
        }
        val bounds = groups.map { it.getUnclippedBoundsInRoot() }
        assertTrue(bounds.zipWithNext().all { (a, b) -> a.top == b.top && a.right <= b.left })
        inDialog(text(R.string.verify_match)).assertIsDisplayed()
        inDialog(text(R.string.numbers_differ)).assertIsDisplayed()
        snapshot("room-code-comparison.png")
        val fingerprint = sha256(device.leaf.base64Bytes(32)).toHexString()
        inDialog(peer.identity.substringBefore('.')).assertDoesNotExist()
        inDialog(fingerprint.take(8) + "…" + fingerprint.takeLast(8)).assertExists()
        inDialog(text(R.string.verification_fingerprints)).performScrollTo().performClick()
        inDialog(peer.identity.substringBefore('.')).assertExists()
        inDialog(sha256(device.accountKey.base64Bytes(32)).toHexString()).assertExists()
        inDialog(sha256(device.leaf.base64Bytes(32)).toHexString()).assertExists()
        inDialog(text(R.string.verification_fingerprints)).performScrollTo().performClick()
        inDialog(sha256(device.leaf.base64Bytes(32)).toHexString()).assertDoesNotExist()
    }

    @Test fun codeComparisonSeparatesCancelMismatchAndMatchAndShowsTheWaitingState() {
        var confirmed by mutableStateOf(false)
        var remaining by mutableStateOf(75L)
        val actions = mutableListOf<String>()
        compose.setContent { ChirpTheme {
            RoomCodeComparison("Riley", listOf(1432, 2856, 8119), confirmed, remaining,
                onMatch = { actions.add("match"); confirmed = true },
                onMismatch = { actions.add("mismatch") }, onCancel = { actions.add("cancel") }) {}
        } }
        val match = inDialog(text(R.string.verify_match))
        val mismatch = inDialog(text(R.string.numbers_differ))
        assertTrue(match.getUnclippedBoundsInRoot().height >= 48.dp)
        assertTrue(mismatch.getUnclippedBoundsInRoot().height >= 48.dp)
        mismatch.performClick()
        compose.onNodeWithContentDescription(text(R.string.verify_mismatch)).performScrollTo().performClick()
        compose.runOnIdle {
            assertEquals(listOf("mismatch", "cancel"), actions)
            remaining = 0
        }
        match.assertIsNotEnabled()
        mismatch.assertIsNotEnabled()
        compose.runOnIdle { remaining = 30 }
        match.performClick()
        match.assertDoesNotExist()
        mismatch.assertDoesNotExist()
        inDialog(text(R.string.sas_compared_all)).assertIsDisplayed()
        inDialog(text(R.string.sas_peer_proof)).assertIsDisplayed()
        compose.runOnIdle { assertEquals(listOf("mismatch", "cancel", "match"), actions) }
    }

    @Test fun callStatusFollowsSetupConnectionAndRecovery() {
        val room = RoomInfo("garden", "Garden", false, false, GROUP_PROTOCOL, 0, "available", emptyList())
        var call by mutableStateOf(CallState(room = room, phase = CallPhase.Securing))
        compose.setContent { androidx.compose.material3.Text(call.status()) }
        compose.onNodeWithText(text(R.string.secure_status)).assertIsDisplayed()
        compose.runOnIdle { call = call.copy(connectingMedia = true) }
        compose.onNodeWithText(text(R.string.connecting_media)).assertIsDisplayed()
        compose.runOnIdle { call = call.copy(phase = CallPhase.Connected, connectingMedia = false) }
        compose.onNodeWithText(text(R.string.connected)).assertIsDisplayed()
        compose.runOnIdle { call = call.copy(phase = CallPhase.Securing, chatVisible = true) }
        compose.onNodeWithText(text(R.string.recovering_voice)).assertIsDisplayed()
    }

    @Test fun systemHeldAudioOffersAResumeButton() {
        var held by mutableStateOf(true)
        val room = RoomInfo("garden", "Garden", false, false, GROUP_PROTOCOL, 0, "available", emptyList())
        compose.setContent { ChirpTheme { AudioSettingsForm(AudioState(), CallState(held = held, room = room),
            back = {}, resumeAudio = { held = false }) } }
        compose.onNodeWithText(text(R.string.audio_resume_call)).performScrollTo().performClick()
        compose.runOnIdle { assertFalse(held) }
        compose.onNodeWithText(text(R.string.audio_resume_call)).assertDoesNotExist()
    }

    @Test fun audioRoutesShowCurrentChoicesAndOpenIndependently() {
        val mic = AudioDevice(7, "USB microphone", android.media.AudioDeviceInfo.TYPE_USB_DEVICE)
        val headset = AudioDevice(9, "USB headset", android.media.AudioDeviceInfo.TYPE_USB_HEADSET)
        var audio by mutableStateOf(AudioState(inputs = listOf(mic), outputs = listOf(headset)))
        compose.setContent { ChirpTheme {
            AudioSettingsForm(audio, CallState(), back = {}, chooseInput = { audio = audio.copy(input = it) },
                chooseOutput = { audio = audio.copy(output = it) })
        } }
        fun row(id: Int) = compose.onNodeWithText(text(id))
        val input = row(R.string.audio_input)
        val output = row(R.string.audio_output)
        compose.onNodeWithText(mic.name).assertDoesNotExist()
        compose.onNodeWithText(headset.name).assertDoesNotExist()
        input.performScrollTo().performClick()
        compose.onNodeWithText(mic.name).performScrollTo().performClick()
        input.performScrollTo().performClick()
        input.assertTextContains(mic.name)
        compose.onNodeWithText(headset.name).assertDoesNotExist()
        output.performScrollTo().performClick()
        compose.onNodeWithText(headset.name).performScrollTo().performClick()
        output.performScrollTo().performClick()
        output.assertTextContains(headset.name)
    }

    @Test fun memberCardAndOpenDetailsFollowThePeersMicrophoneAndPlayback() {
        val room = RoomInfo("garden", "Garden", false, false, GROUP_PROTOCOL, 0, "available", emptyList())
        val self = RoomMember("self.local", "Local member", microphoneEnabled = false, listening = true)
        val peer = RoomMember("peer.remote", "River", microphoneEnabled = true, listening = false, speaking = true)
        var call by mutableStateOf(CallState(room = room, phase = CallPhase.Connected, entryID = "local",
            members = listOf(self, peer), volumes = mapOf(peer.identity to 0f)))
        val activity = compose.activity
        val application = app
        compose.setContent {
            val model = viewModel { MainViewModel(application, restoreOnStart = false) }
            ChirpTheme { RoomScreen(activity, room, MainState(), call, model, {}, {}) }
        }
        fun card(mic: Int, playback: Int) = compose.onNode(hasText(peer.name) and
            hasContentDescription(text(mic)) and hasContentDescription(text(playback)))
        val speakingCard = card(R.string.microphone_on, R.string.listening_paused).performScrollTo()
        val height = speakingCard.getUnclippedBoundsInRoot().let { it.bottom - it.top }
        speakingCard.assertTextContains(text(R.string.speaking)).performClick()
        inDialog(text(R.string.microphone_on)).assertIsDisplayed()
        inDialog(text(R.string.listening_paused)).assertIsDisplayed()
        compose.runOnIdle {
            call = call.copy(members = listOf(self, peer.copy(microphoneEnabled = false, listening = true, speaking = false)))
        }
        inDialog(text(R.string.microphone_muted)).assertIsDisplayed()
        inDialog(text(R.string.listening_on)).assertIsDisplayed()
        inDialog(text(R.string.close)).performClick()
        val mutedCard = card(R.string.microphone_muted, R.string.listening_on).assertIsDisplayed()
        mutedCard.assertHeightIsEqualTo(height)
        compose.runOnIdle {
            call = call.copy(members = listOf(self, RoomMember(peer.identity, peer.name, present = false)))
        }
        card(R.string.microphone_pending, R.string.listening_pending).assertIsDisplayed().performClick()
        inDialog(text(R.string.microphone_pending)).assertIsDisplayed()
        inDialog(text(R.string.listening_pending)).assertIsDisplayed()
    }

    @Test fun audioSettingsHasNoCallDiagnosticsOrExport() {
        compose.setContent { ChirpTheme { AudioSettingsForm(AudioState(), CallState(), back = {}) } }
        compose.onNodeWithText(text(R.string.microphone_test_start)).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(text(R.string.call_diagnostics)).assertDoesNotExist()
        compose.onNodeWithText(text(R.string.diagnostics_export)).assertDoesNotExist()
    }
}
