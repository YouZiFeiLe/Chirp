package cn.youzifeile.chirp.ui

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import cn.youzifeile.chirp.ChirpApplication
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.AttachmentInfo
import cn.youzifeile.chirp.media.*
import org.junit.Rule
import org.junit.Test

class AttachmentPreviewTest {
    @get:Rule val compose = createComposeRule()

    @Test fun openImageClosesWhenItsItemExpiresOrItsRoomAuthorizationEnds() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val controller = (context.applicationContext as ChirpApplication).calls
        val image = AttachmentInfo(id = "a".repeat(32), roomID = "friends", sender = "sender",
            name = "room-photo.png", mimeType = "image/png", size = 123, digest = "0".repeat(64))
        val message = ChatMessage(image.id, "Sender", "", false, attachment = image)
        val ready = CallState(phase = CallPhase.Connected, chatVisible = true, entryID = "entry",
            messages = listOf(message), attachments = mapOf(image.id to TransferState(TransferPhase.Available, 100)))
        val state = mutableStateOf(ready)
        val export = context.getString(R.string.file_export)
        val attach = context.getString(R.string.attach)
        compose.setContent { ChirpTheme { RoomChatPanel(state.value, controller) } }

        compose.onNodeWithText(image.name).performClick()
        compose.onNodeWithText(export).assertIsDisplayed()
        // This display-only fixture has no cached bytes. A failed decode must end the loading state.
        compose.onNodeWithText(context.getString(R.string.attachment_preview_failed)).assertIsDisplayed()
        compose.runOnIdle { state.value = ready.copy(attachments = mapOf(image.id to TransferState(TransferPhase.Expired))) }
        compose.onNodeWithText(export).assertDoesNotExist()
        compose.onNodeWithText(context.getString(R.string.file_expired)).assertIsDisplayed()
        compose.onNodeWithContentDescription(attach).assertIsEnabled()

        compose.runOnIdle { state.value = ready }
        compose.onNodeWithText(image.name).performClick()
        compose.onNodeWithText(export).assertIsDisplayed()
        compose.runOnIdle { state.value = ready.copy(attachments = emptyMap(), cacheRevision = 1, attachmentsRevoked = true) }
        compose.onNodeWithText(export).assertDoesNotExist()
        compose.onNodeWithContentDescription(attach).assertIsNotEnabled()
    }
}
