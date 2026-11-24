package cn.youzifeile.chirp.ui

import android.os.SystemClock
import android.view.WindowInsets
import androidx.activity.ComponentActivity
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import cn.youzifeile.chirp.ChirpApplication
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.*
import cn.youzifeile.chirp.media.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** Navigation test. The real signed-in root renders supplied call and directory snapshots. */
class RootNavigationParityTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val room = RoomInfo("garden", "Garden room", false, false, GROUP_PROTOCOL, 0, "available", emptyList())
    private val profile = Profile("member_" + "1".repeat(16), "River", 0)
    private val state = MainState(checking = false, account = profile,
        directory = Directory("server", 1UL, listOf(room), listOf(profile)), identity = AccountView(synced = true))

    private fun text(id: Int) = compose.activity.getString(id)

    private fun peer(): GroupMember {
        val deviceSeed = randomBytes(32)
        val device = DeviceIdentity.issue(randomBytes(32), publicKey(deviceSeed))
        val context = MutualRoom("https://fixture.example:443", room.id)
        val identity = "member_" + "2".repeat(16) + ".login_" + "3".repeat(16) + ".entry_" + "4".repeat(32)
        val mls = publicKey(randomBytes(32))
        val now = nowSeconds()
        val unsigned = EntryBinding(device, context.origin, room.id, context.trust, context.hash, identity,
            mls, base64(randomBytes(32)), now - 1, now + 300)
        val binding = unsigned.copy(signature = sign(deviceSeed, unsigned.message()))
        return GroupMember(identity, "Riley", mls, "", binding = binding).also { binding.validate(context, it, now) }
    }

    private fun show(trust: RoomTrustView = RoomTrustView(), screenState: MainState = state): androidx.compose.runtime.MutableState<CallState> {
        val activity = compose.activity
        val call = mutableStateOf(CallState(room = room, entryID = "entry_" + "5".repeat(32), phase = CallPhase.Connected,
            members = trust.peers.map { RoomMember(it.identity, it.name) }, trust = trust, chatVisible = true))
        compose.setContent {
            val model = viewModel { MainViewModel(activity.application as ChirpApplication, restoreOnStart = false) }
            ChirpTheme { ChirpApp(activity, screenState, call.value, model) }
        }
        return call
    }

    private fun openTab(label: Int) =
        compose.onNode(hasText(text(label)) and hasClickAction()).performClick()

    private fun returnFromPage() {
        val target = hasContentDescription(compose.activity.getString(R.string.return_room_status, room.name, text(R.string.connected)))
        compose.onAllNodes(target).assertCountEquals(1)
        compose.onNode(target).assertIsDisplayed().performClick()
        compose.onNodeWithContentDescription(text(R.string.room_options)).assertIsDisplayed()
        compose.onAllNodes(target).assertCountEquals(0)
    }

    @Test fun logManagementIsReachableBeforeLogin() {
        show(screenState = MainState(checking = false))
        compose.onNodeWithContentDescription(text(R.string.security_settings)).performClick()
        compose.onNodeWithText(text(R.string.log_management)).performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.log_recording)).assertIsDisplayed()
    }

    @Test fun logManagementIsReachableFromTheAccountTab() {
        show()
        openTab(R.string.account)
        compose.onNodeWithText(text(R.string.log_management)).performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.log_recording)).assertIsDisplayed()
    }

    @Test fun homeTitlesStayPinnedAndShortListsStayInPlace() {
        val call = show()
        compose.runOnIdle { call.value = CallState() }
        compose.onNodeWithText(text(R.string.app_name)).assertIsDisplayed()
        compose.onNodeWithText(text(R.string.rooms_intro_eyebrow)).assertIsDisplayed()
        compose.onNodeWithText(text(R.string.rooms_intro)).assertIsDisplayed()
        compose.onNodeWithText(text(R.string.rooms_intro_body)).assertIsDisplayed()
        val topInset = compose.runOnUiThread {
            val insets = requireNotNull(compose.activity.window.decorView.rootWindowInsets)
            insets.getInsets(WindowInsets.Type.statusBars() or WindowInsets.Type.displayCutout()).top
        }
        val compactBarBottom = with(compose.density) { topInset.toDp() } + 65.dp
        fun swipePage(tab: Int, firstItem: String, fits: Boolean) {
            val title = compose.onNode(hasText(text(tab)) and SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))
            val content = compose.onNode(SemanticsMatcher.keyIsDefined(SemanticsProperties.VerticalScrollAxisRange) and
                hasAnyDescendant(hasText(firstItem)))
            val first = compose.onNodeWithText(firstItem)
            val titleBounds = title.getUnclippedBoundsInRoot()
            val itemBounds = first.getUnclippedBoundsInRoot()
            assertTrue("Content starts below a single-line app bar", content.getUnclippedBoundsInRoot().top <= compactBarBottom)
            content.performTouchInput { swipeUp() }
            assertEquals(titleBounds, title.getUnclippedBoundsInRoot())
            if (fits) assertEquals(itemBounds, first.getUnclippedBoundsInRoot())
        }

        swipePage(R.string.rooms, room.name, fits = true)
        openTab(R.string.friends)
        swipePage(R.string.friends, text(R.string.friends_empty_title), fits = true)
        openTab(R.string.account)
        swipePage(R.string.account, text(R.string.edit_profile), fits = false)
        compose.onNodeWithText(text(R.string.sign_out)).performScrollTo().assertIsDisplayed()
    }

    @Test fun incomingVerificationAppearsOnFriendsAndReturnOpensTheTrustedPeerForReverification() {
        val peer = peer()
        val trusted = RoomTrustView(peers = listOf(peer), trusted = setOf(peer.identity))
        val call = show(trusted)
        openTab(R.string.friends)
        val request = Verification(base64(randomBytes(32)), peer.identity, commitment = base64(randomBytes(32)))
        compose.runOnIdle {
            call.value = call.value.copy(trust = trusted.copy(verification = request, expires = SystemClock.elapsedRealtime() + 120000))
        }
        fun inDialog(label: String) = compose.onNode(hasText(label) and hasAnyAncestor(isDialog()))
        inDialog(peer.name).assertIsDisplayed()
        inDialog(text(R.string.verify_accept)).assertIsEnabled()
        val numbers = listOf(1432, 2856, 8119)
        compose.runOnIdle {
            call.value = call.value.copy(trust = call.value.trust.copy(verification = request.copy(accepted = true, numbers = numbers)))
        }
        for ((index, number) in numbers.withIndex()) {
            val label = compose.activity.getString(R.string.sas_group_accessible, index + 1) + ", " + number.toString().toList().joinToString(" ")
            compose.onNodeWithContentDescription(label).performScrollTo().assertIsDisplayed()
        }
        compose.runOnIdle { call.value = call.value.copy(trust = trusted) }
        returnFromPage()

        if (compose.onAllNodesWithText(peer.name).fetchSemanticsNodes().isEmpty()) {
            val lists = compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsActions.ScrollToIndex))
            for (index in lists.fetchSemanticsNodes().indices) {
                if (runCatching { lists[index].performScrollToKey(peer.identity) }.isSuccess) break
            }
        }
        compose.onNodeWithText(peer.name).performScrollTo().performClick()
        inDialog(text(R.string.verified_device)).performScrollTo().assertIsDisplayed()
        inDialog(text(R.string.verify_again)).performScrollTo().assertIsEnabled().performClick()
        inDialog(text(R.string.sas_external)).assertExists()
        inDialog(text(R.string.sas_start)).performClick()
        compose.onAllNodes(isDialog()).assertCountEquals(0)
    }

    @Test fun friendSearchSurvivesSwitchingTabsAndClearsToTheFullList() {
        val friends = listOf(Friend("river", base64(ByteArray(32) { 1 }), "River Stone"),
            Friend("riley", base64(ByteArray(32) { 2 }), "Riley"))
        show(screenState = state.copy(identity = AccountView(friends = friends, synced = true)))
        openTab(R.string.friends)
        val search = compose.onNode(hasSetTextAction())
        search.performTextReplacement("stone")
        search.performImeAction()
        compose.onNodeWithText("River Stone").assertIsDisplayed()
        compose.onNodeWithText("Riley").assertDoesNotExist()
        openTab(R.string.account)
        openTab(R.string.friends)
        search.assertTextContains("stone")
        compose.onNodeWithContentDescription(text(R.string.clear_search)).performClick()
        compose.onNodeWithText("Riley").assertIsDisplayed()
    }

    @Test fun directoryOnlyShowsMemberNamesOnceTheListIsFresh() {
        val lobby = room.copy(id = "lobby", name = "Lobby", isDefault = true,
            participants = listOf(DirectoryMember("fern", "Fern")))
        val directory = mutableStateOf(Directory("server", 1UL, listOf(lobby, room), emptyList(), fresh = false))
        val firstSyncFailed = mutableStateOf(true)
        var opened: String? = null
        compose.setContent { ChirpTheme {
            DirectoryScreen(directory.value.takeUnless { firstSyncFailed.value }, CallState(),
                { opened = it }, {}, null, firstSyncFailed.value)
        } }
        compose.onNodeWithText(text(R.string.directory_retry_detail)).assertIsDisplayed()
        compose.runOnIdle { firstSyncFailed.value = false }
        compose.onNodeWithText(text(R.string.room_list_stale_help)).assertIsDisplayed()
        compose.onNodeWithText("Fern").assertDoesNotExist()
        val count = compose.activity.resources.getQuantityString(R.plurals.room_count, 2, 2)
        compose.onNodeWithText(count).assertIsDisplayed()
        val lobbyCard = compose.onNode(hasText(lobby.name) and hasClickAction())
        val otherCard = compose.onNode(hasText(room.name) and hasClickAction())
        assertEquals(lobbyCard.fetchSemanticsNode().size, otherCard.fetchSemanticsNode().size)
        compose.runOnIdle { directory.value = directory.value.copy(fresh = true) }
        compose.onNodeWithText("Fern").assertIsDisplayed()
        lobbyCard.performClick()
        compose.runOnIdle { org.junit.Assert.assertEquals(lobby.id, opened) }
        otherCard.performClick()
        compose.runOnIdle { org.junit.Assert.assertEquals(room.id, opened) }
    }

    @Test fun roomDescriptionFollowsTheSelectedRoomAndLiveUpdatesDuringACall() {
        val activity = compose.activity
        val lobbyDescription = "Meet in the lobby."
        val lobby = room.copy(id = "lobby", name = "Lobby", isDefault = true, description = lobbyDescription)
        val directory = mutableStateOf(requireNotNull(state.directory).copy(rooms = listOf(lobby, room)))
        val call = CallState(room = room, entryID = "garden-entry", phase = CallPhase.Connected)
        compose.setContent {
            val model = viewModel { MainViewModel(activity.application as ChirpApplication, restoreOnStart = false) }
            ChirpTheme { ChirpApp(activity, state.copy(directory = directory.value), call, model) }
        }
        fun openCard(name: String) = compose.onNode(hasText(name) and hasText(text(R.string.room_kind_open)) and hasClickAction())
            .performClick()
        fun setDescription(value: String) = compose.runOnIdle {
            val previous = directory.value
            directory.value = previous.copy(revision = previous.revision + 1UL, rooms = listOf(lobby, room.copy(description = value)))
        }
        openCard(room.name)
        val fallback = text(R.string.room_overview)
        compose.onNodeWithText(fallback).assertIsDisplayed().performClick()
        val dialog = hasAnyAncestor(isDialog())
        compose.onNode(hasText(fallback) and dialog).assertIsDisplayed()
        val updated = "周五 8:00 🎵\n<朋友> %@ **歌单**\nSee you there!"
        setDescription(updated)
        compose.onNode(hasText(updated) and dialog).assertIsDisplayed()
        compose.onNode(hasContentDescription(text(R.string.close)) and dialog).performClick()
        compose.onNodeWithText(updated).assertIsDisplayed()
        compose.onNodeWithText(text(R.string.leave_room)).assertIsDisplayed()
        setDescription("  \n ")
        compose.onNodeWithText(fallback).assertIsDisplayed()
        val back = compose.onAllNodesWithContentDescription(text(R.string.back))
        if (back.fetchSemanticsNodes().isNotEmpty()) back[0].performClick()
        openCard(lobby.name)
        compose.onNodeWithText(lobbyDescription).assertIsDisplayed()
    }

    @Test fun backFromRoomAudioSettingsReturnsToTheSameCall() {
        show()
        returnFromPage()
        compose.onNodeWithContentDescription(text(R.string.room_options)).performClick()
        compose.onNode(hasText(text(R.string.audio_settings)) and hasAnyAncestor(isPopup())).performClick()
        compose.onNodeWithText(text(R.string.audio_presets)).assertIsDisplayed()
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.onNodeWithContentDescription(text(R.string.room_options)).assertIsDisplayed()
    }

    @Test fun nestedStorageSettingsKeepExactlyOneReturnToCurrentCall() {
        show()
        openTab(R.string.account)
        val storage = compose.onNodeWithText(text(R.string.storage_cache))
        val localIdentity = compose.onNodeWithText(text(R.string.local_identity_data))
        storage.assertDoesNotExist()
        localIdentity.performScrollTo().performClick()
        storage.performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.cache_size)).assertIsDisplayed()
        compose.onNodeWithContentDescription(text(R.string.back)).performClick()
        localIdentity.assertIsDisplayed()
        storage.performScrollTo().assertIsDisplayed()
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        storage.assertDoesNotExist()
        localIdentity.performScrollTo().performClick()
        storage.performScrollTo().performClick()
        returnFromPage()
    }
}
