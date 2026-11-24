package cn.youzifeile.chirp.ui

import android.accessibilityservice.AccessibilityService
import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.ParcelFileDescriptor
import android.view.WindowInsets
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.content.FileProvider
import androidx.test.platform.app.InstrumentationRegistry
import cn.youzifeile.chirp.MainActivity
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.*
import cn.youzifeile.chirp.media.CallPhase
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain

class ProductionFlowTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    private val seedFixture = ProductionLoginFixture()
    private val app get() = seedFixture.app
    private val data get() = seedFixture.data
    private val connection get() = seedFixture.connection
    private val login get() = seedFixture.login

    @get:Rule val activityRule: RuleChain = RuleChain.outerRule(seedFixture).around(compose)
    private fun text(id: Int) = compose.activity.getString(id)
    private fun click(value: String) {
        val action = hasText(value) and hasClickAction() and isEnabled()
        compose.waitUntil(10_000) { compose.onAllNodes(action).fetchSemanticsNodes().isNotEmpty() }
        compose.onNode(action).performClick()
    }
    private fun hideKeyboard() {
        val activity = compose.activity
        compose.runOnUiThread { activity.window.insetsController?.hide(WindowInsets.Type.ime()) }
    }

    private fun openRoom(name: String) {
        val room = hasText(name) and hasClickAction()
        val entries = compose.onAllNodes(room)
        if (entries.fetchSemanticsNodes().isEmpty()) {
            compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsActions.ScrollToIndex)).onFirst().performScrollToNode(hasText(name))
        }
        entries.onFirst().performClick()
    }

    private fun verifyAvatarEdit(model: MainViewModel, session: SessionRepository) {
        val before = runBlocking { session.profile() }
        val side = 512
        val pixels = IntArray(side * side) { offset ->
            if (offset / side < side / 2 || offset % side < side / 2) 0xff36764f.toInt() else 0xffcb294e.toInt()
        }
        val directory = File(app.cacheDir, "android-protocol").apply { mkdirs() }
        val source = File.createTempFile("profile-", ".png", directory)
        val instrument = InstrumentationRegistry.getInstrumentation()
        fun button(id: Int) = compose.onNode(hasText(text(id)) and hasClickAction())
        fun verifyPixels(bitmap: Bitmap) {
            assertEquals(side, bitmap.width)
            assertEquals(side, bitmap.height)
            val actual = IntArray(pixels.size)
            bitmap.getPixels(actual, 0, side, 0, 0, side, side)
            assertArrayEquals(pixels, actual)
        }
        try {
            val image = Bitmap.createBitmap(pixels, side, side, Bitmap.Config.ARGB_8888)
            try { source.outputStream().use { assertTrue(image.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
            finally { image.recycle() }
            val uri = FileProvider.getUriForFile(app, "${app.packageName}.test-files", source)
            val documents = IntentFilter(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                addDataType("*/*")
            }
            val selection = Intent().setData(uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val monitor = instrument.addMonitor(documents, Instrumentation.ActivityResult(Activity.RESULT_OK, selection), true)
            try {
                button(R.string.choose_file).performScrollTo().performClick()
                assertEquals("The edit form must open Android's document picker", 1, monitor.hits)
                compose.waitUntil(10_000) { model.state.value.avatarDraft != null && !model.state.value.preparingAvatar }
            } finally { instrument.removeMonitor(monitor) }
            compose.onNodeWithContentDescription(text(R.string.avatar_preview)).assertExists()
            verifyPixels(requireNotNull(model.state.value.avatarDraft).preview)
            button(R.string.avatar_save).performScrollTo().performClick()
            compose.waitUntil(20_000) { model.state.value.let {
                it.profileNotice == R.string.profile_avatar_saved && !it.editingProfile && it.avatarDraft == null
            } }
            val saved = runBlocking { session.profile() }
            assertTrue(saved.revision > before.revision)
            assertEquals(saved.avatar, model.state.value.account?.avatar)
            val downloaded = requireNotNull(runBlocking { session.avatar(saved) })
            assertEquals(saved.avatar, sha256(downloaded).toHexString())
            val format = BitmapFactory.Options()
            val fetched = requireNotNull(BitmapFactory.decodeByteArray(downloaded, 0, downloaded.size, format))
            try {
                assertEquals("image/png", format.outMimeType)
                verifyPixels(fetched)
            } finally { fetched.recycle() }
            button(R.string.avatar_remove).performScrollTo().performClick()
            val inDialog = hasAnyAncestor(isDialog())
            compose.onNode(hasText(text(R.string.avatar_remove_detail)) and inDialog).assertExists()
            compose.onNode(hasText(text(R.string.cancel)) and hasClickAction() and inDialog).performClick()
            assertNotNull(model.state.value.account?.avatar)
            button(R.string.avatar_remove).performScrollTo().performClick()
            compose.onNode(hasText(text(R.string.avatar_remove)) and hasClickAction() and inDialog).performClick()
            compose.waitUntil(20_000) { model.state.value.let {
                it.profileNotice == R.string.profile_avatar_removed && !it.editingProfile && it.account?.avatar == null
            } }
            val removed = runBlocking { session.profile() }
            assertTrue(removed.revision > saved.revision)
            assertNull(removed.avatar)
            button(R.string.avatar_remove).assertDoesNotExist()
        } finally { source.delete() }
    }

    @Test fun startsSignedOutEditsProfileKeepsTheBackgroundCallAndSwitchesPasswordProtectedRooms() {
        compose.waitForIdle()
        val activity = compose.activity
        val model = activity.model
        seedFixture.signIn(model)
        val calls = app.calls
        fun awaitState(stage: String, timeout: Long = 30_000, predicate: () -> Boolean) {
            try { compose.waitUntil(timeout) { predicate() } }
            catch (failure: Throwable) {
                val call = calls.state.value
                throw AssertionError("$stage: phase=${call.phase} callError=${call.error} sessionError=${model.state.value.error}", failure)
            }
        }
        awaitState("sign in") { model.state.value.account?.id == login.memberID && model.state.value.directory?.fresh == true && model.state.value.identity.synced }
        click(text(R.string.account))
        click(text(R.string.edit_profile))
        val edited = "Flow saved ${System.currentTimeMillis() % 100000}"
        compose.onNode(hasSetTextAction()).performTextReplacement(edited)
        hideKeyboard()
        compose.onNode(hasText(text(R.string.save)) and hasClickAction()).performScrollTo().performClick()
        awaitState("save profile") { model.state.value.account?.name == edited && !model.state.value.editingProfile }
        val profileSession = SessionRepository(connection, login, app.http)
        assertEquals(edited, runBlocking { profileSession.profile().name })
        verifyAvatarEdit(model, profileSession)
        compose.onNodeWithContentDescription(text(R.string.back)).performClick()
        click(text(R.string.rooms))

        openRoom(data.text("room_name"))
        click(text(R.string.join_room))
        awaitState("first secure call") { calls.state.value.let { it.room?.id == data.text("room_id") && it.phase == CallPhase.Connected } }
        val first = requireNotNull(calls.state.value.entryID)
        click(text(R.string.enable_mic))
        awaitState("publish encrypted microphone") { calls.state.value.micOn && calls.audio.state.value.applied }
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        assertTrue(automation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME))
        awaitState("background call") { model.state.value.directory?.fresh == false }
        assertEquals(CallPhase.Connected, calls.state.value.phase)
        assertEquals(first, calls.state.value.entryID)
        assertTrue(calls.state.value.micOn)
        val launch = "am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n ${app.packageName}/${MainActivity::class.java.name}"
        ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand(launch)).use { it.readBytes() }
        awaitState("return to the same call") { model.state.value.directory?.fresh == true }
        compose.activityRule.scenario.recreate()
        compose.waitForIdle()
        assertSame(model, compose.activity.model)
        assertEquals(first, calls.state.value.entryID)
        assertTrue(calls.state.value.micOn)
        compose.onNodeWithContentDescription(text(R.string.room_options)).performClick()
        click(text(R.string.room_information))
        val inRoomInfo = hasAnyAncestor(isDialog())
        compose.onNode(hasText(text(R.string.room_synced)) and inRoomInfo).assertExists()
        compose.onNode(hasText(text(R.string.rotation_details)) and inRoomInfo).performScrollTo().performClick()
        awaitState("smooth key rotation", 45_000) { calls.state.value.let {
            it.entryID == first && it.micOn && (it.information?.epoch ?: 0UL) >= 1UL
        } }
        val round = (requireNotNull(calls.state.value.information).epoch + 1UL).toString()
        compose.onNode(hasText(activity.getString(R.string.info_round, round)) and inRoomInfo).assertExists()
        compose.onNode(hasContentDescription(text(R.string.close)) and inRoomInfo).performClick()
        click(text(R.string.chat))
        val editor = compose.onNodeWithContentDescription(text(R.string.chat_hint))
        editor.performTextReplacement("draft before system hold")
        hideKeyboard()
        compose.runOnUiThread { calls.setHeld(true) }
        awaitState("hold pauses the microphone and preserves chat") {
            calls.state.value.let { it.held && !it.micOn && it.chatVisible && it.draft == "draft before system hold" }
        }
        editor.assertIsNotEnabled()
        compose.runOnUiThread { calls.setHeld(false) }
        awaitState("reauthorized microphone returns with the same admission", 45_000) {
            calls.state.value.let { it.entryID == first && it.phase == CallPhase.Connected && it.micOn }
        }
        editor.assertIsEnabled()
        click(text(R.string.mute_mic))
        awaitState("mute") { !calls.state.value.micOn && !calls.state.value.micChanging }
        editor.assertIsDisplayed()
        val back = compose.onAllNodesWithContentDescription(text(R.string.back))
        if (back.fetchSemanticsNodes().isNotEmpty()) back.onFirst().performClick()
        openRoom(data.text("locked_room_name"))
        click(text(R.string.room_switch))
        val password = compose.onNode(hasSetTextAction() and hasAnyAncestor(isDialog()))
        val confirm = compose.onNode(hasText(text(R.string.verify_and_join)) and hasAnyAncestor(isDialog()) and hasClickAction())
        password.performTextReplacement("incorrect fixture password")
        hideKeyboard()
        confirm.performClick()
        awaitState("wrong password") { model.state.value.joinFailure?.reason?.code == "ROOM_PASSWORD_INCORRECT" }
        password.assertExists()
        assertEquals(first, calls.state.value.entryID)
        assertEquals(CallPhase.Connected, calls.state.value.phase)
        password.performTextReplacement(data.text("room_password"))
        hideKeyboard()
        confirm.performClick()
        awaitState("second secure call") { calls.state.value.let { it.room?.id == data.text("locked_room_id") && it.phase == CallPhase.Connected } }
        assertNotEquals(first, calls.state.value.entryID)
        assertFalse(calls.state.value.micOn)
        click(text(R.string.leave_room))
        awaitState("leave") { calls.state.value.phase == CallPhase.Idle }

        if (back.fetchSemanticsNodes().isNotEmpty()) back.onFirst().performClick()
        click(text(R.string.account))
        val signOut = hasText(text(R.string.sign_out)) and hasClickAction()
        compose.onNode(signOut).performScrollTo().performClick()
        compose.onNode(signOut and hasAnyAncestor(isDialog())).performClick()
        awaitState("sign out") { model.state.value.account == null && !model.state.value.checking }
        assertEquals(connection, model.state.value.connection)

        val address = compose.onNode(hasSetTextAction())
        address.performTextReplacement("http://127.0.0.1:1")
        awaitState("invalidate previous server") { model.state.value.connection == null }
        address.performTextReplacement(connection.origin.toString())
        compose.runOnIdle { assertNull(model.state.value.connection) }
        compose.onNodeWithText(text(R.string.server_verified)).assertDoesNotExist()
        hideKeyboard()
        compose.onNode(hasText(text(R.string.server_confirm)) and hasClickAction()).performScrollTo().performClick()
        awaitState("reconfirm server") { model.state.value.connection != null && !model.state.value.checking }
        val reconfirmed = requireNotNull(model.state.value.connection)
        assertEquals(connection.passkeyOrigin, reconfirmed.passkeyOrigin)
        assertEquals(connection.passkeyOrigin.path("authorization", "v5", ""), reconfirmed.authorizationBase)
        compose.onNodeWithText(text(R.string.server_verified)).assertExists()
    }
}
