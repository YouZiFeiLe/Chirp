package cn.youzifeile.chirp.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.text.InputType
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.unit.dp
import cn.youzifeile.chirp.R
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.awaitCancellation
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class PairingCodeFieldsTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val input = PairingCodeInputState()
    private val activeEditor = AtomicReference<Pair<EditorInfo, InputConnection>?>()

    private fun show() {
        val activity = compose.activity
        compose.setContent { ChirpTheme {
            ChirpDialog(icon = R.drawable.ic_key, onDismissRequest = {}, title = { Text(activity.getString(R.string.pair_device)) },
                text = { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(activity.getString(R.string.pair_code_title))
                    Text(activity.getString(R.string.pair_type_digits))
                    InterceptPlatformTextInput(interceptor = { request, _ ->
                        // This test acts as the IME and owns the connection for this focus session.
                        val info = EditorInfo()
                        val editor = info to request.createInputConnection(info)
                        activeEditor.set(editor)
                        try {
                            awaitCancellation()
                        } finally {
                            activeEditor.compareAndSet(editor, null)
                            editor.second.closeConnection()
                        }
                    }) { PairingCodeFields(input, enabled = true) }
                } }, confirmButton = { TextButton({}, enabled = input.completeCode != null) {
                    Text(activity.getString(R.string.pair_authorize))
                } })
        } }
    }

    private fun field(group: Int) = compose.onNodeWithContentDescription(compose.activity.getString(R.string.sas_group_accessible, group))
    private fun authorize() = compose.onNodeWithText(compose.activity.getString(R.string.pair_authorize))

    private fun numericEditor(action: Int, previous: InputConnection? = null): InputConnection {
        compose.waitUntil(5_000) { activeEditor.get()?.let { (info, connection) ->
            connection !== previous && info.imeOptions and EditorInfo.IME_MASK_ACTION == action
        } == true }
        val (info, connection) = checkNotNull(activeEditor.get())
        assertEquals(InputType.TYPE_CLASS_NUMBER, info.inputType and InputType.TYPE_MASK_CLASS)
        assertEquals(InputType.TYPE_NUMBER_VARIATION_PASSWORD, info.inputType and InputType.TYPE_MASK_VARIATION)
        assertEquals(0, info.inputType and (InputType.TYPE_NUMBER_FLAG_SIGNED or InputType.TYPE_NUMBER_FLAG_DECIMAL))
        return connection
    }

    @Test fun threeNumericEditorsAdvanceAndBackspaceAcrossEmptyGroups() {
        show()
        compose.onAllNodes(hasSetTextAction()).assertCountEquals(3)
        val first = field(1).performScrollTo()
        val second = field(2)
        val third = field(3)
        val bounds = listOf(first, second, third).map { it.getUnclippedBoundsInRoot() }
        assertEquals(bounds[0].top, bounds[2].top)
        assertTrue(bounds[0].right < bounds[1].left && bounds[1].right < bounds[2].left)
        authorize().assertIsNotEnabled()
        first.performClick()
        val one = numericEditor(EditorInfo.IME_ACTION_NEXT)
        compose.runOnUiThread { one.commitText("1234", 1) }
        second.assertIsFocused()
        val two = numericEditor(EditorInfo.IME_ACTION_NEXT, one)
        compose.runOnUiThread { two.deleteSurroundingText(1, 0) }
        first.assertIsFocused().assertTextContains("123")
        val oneAgain = numericEditor(EditorInfo.IME_ACTION_NEXT, two)
        compose.runOnUiThread { oneAgain.commitText("4", 1) }
        val twoAgain = numericEditor(EditorInfo.IME_ACTION_NEXT, oneAgain)
        compose.runOnUiThread { twoAgain.commitText("5678", 1) }
        third.assertIsFocused()
        val three = numericEditor(EditorInfo.IME_ACTION_DONE)
        compose.runOnUiThread { three.deleteSurroundingTextInCodePoints(1, 0) }
        second.assertIsFocused().assertTextContains("567")
        second.performTextInput("8")
        third.performTextInput("9012")
        authorize().assertIsEnabled()
        compose.runOnIdle { assertEquals("123456789012", input.completeCode) }
    }

    @Test fun pasteAndCorrectionsPreserveGroupBoundaries() {
        show()
        field(1).performClick().performTextInput("0123 4567-890")
        field(1).assertTextContains("0123")
        field(2).assertTextContains("4567")
        field(3).assertIsFocused().assertTextContains("890")
        authorize().assertIsNotEnabled()
        field(3).performTextInput("1")
        authorize().assertIsEnabled()
        field(2).performClick().performTextInputSelection(TextRange(1, 2))
        field(2).performTextInput("8")
        field(2).assertTextContains("4867")
        field(2).performTextInputSelection(TextRange(4))
        field(2).performTextInput("9")
        field(2).performTextInput("abc")
        compose.runOnIdle { assertEquals("012348678901", input.completeCode) }
        val clipboard = compose.activity.getSystemService(ClipboardManager::class.java)
        val originalClip = compose.runOnIdle { clipboard.primaryClip }
        try {
            compose.runOnIdle { clipboard.setPrimaryClip(ClipData.newPlainText("test", "9876-5432-1098")) }
            field(2).performSemanticsAction(SemanticsActions.PasteText)
            field(1).assertTextContains("9876")
            field(2).assertTextContains("5432")
            field(3).assertTextContains("1098")
        } finally {
            compose.runOnIdle {
                if (originalClip == null) clipboard.clearPrimaryClip() else clipboard.setPrimaryClip(originalClip)
            }
        }
        field(1).performTextClearance()
        authorize().assertIsNotEnabled()
    }
}
