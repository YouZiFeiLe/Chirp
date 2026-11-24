package cn.youzifeile.chirp.ui

import android.view.inputmethod.InputConnectionWrapper
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.*
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.PlatformTextInputInterceptor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.pairingCodeDigits
import cn.youzifeile.chirp.data.pairingInputDigits

private const val GroupLength = 4

internal class PairingCodeInputState {
    private val values = mutableStateListOf(TextFieldValue(), TextFieldValue(), TextFieldValue())
    val fields: List<TextFieldValue> get() = values
    val completeCode: String? get() = if (values.all { it.text.length == GroupLength }) values.joinToString("") { it.text } else null

    // Return the group that should receive the next keystroke.
    fun edit(index: Int, next: TextFieldValue): Int? {
        val old = values[index]
        if (next.text == old.text) {
            values[index] = next
            return null
        }
        val digits = next.text.pairingInputDigits() ?: return null
        val prefix = old.text.take(old.selection.min)
        val suffix = old.text.drop(old.selection.max)
        val inserted = if (next.text.length >= prefix.length + suffix.length && next.text.startsWith(prefix) && next.text.endsWith(suffix))
            next.text.substring(prefix.length, next.text.length - suffix.length) else next.text
        val wholeCode = inserted.pairingCodeDigits()
        val first = if (wholeCode != null) 0 else index
        if (digits.length <= GroupLength) {
            fun digitOffset(offset: Int) = next.text.take(offset).count { it in '0'..'9' }
            values[index] = if (digits == next.text) next else TextFieldValue(digits,
                TextRange(digitOffset(next.selection.start), digitOffset(next.selection.end)))
            if (digits.length < GroupLength || old.text.length == GroupLength) return null
        } else {
            val entry = wholeCode ?: digits
            if (entry.length > (values.size - first) * GroupLength) return null
            val chunks = entry.chunked(GroupLength)
            // A partial paste may fill empty neighbors. Only a whole code replaces other entered groups.
            if (wholeCode == null && (1 until chunks.size).any { values[first + it].text.isNotEmpty() }) return null
            chunks.forEachIndexed { offset, part -> values[first + offset] = TextFieldValue(part, TextRange(part.length)) }
        }
        return (first until values.size).firstOrNull { values[it].text.length < GroupLength }
            ?: values.indices.firstOrNull { values[it].text.length < GroupLength }
    }

    fun backspaceFromEmpty(index: Int): Boolean {
        if (index == 0 || values[index].text.isNotEmpty()) return false
        val previous = values[index - 1].text.dropLast(1)
        values[index - 1] = TextFieldValue(previous, TextRange(previous.length))
        return true
    }
}

@Composable
internal fun PairingCodeFields(input: PairingCodeInputState, enabled: Boolean) {
    val focus = LocalFocusManager.current
    val requesters = remember(input) { List(input.fields.size) { FocusRequester() } }
    val colors = MaterialTheme.colorScheme
    val numberStyle = MaterialTheme.typography.titleLarge.copy(fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, letterSpacing = 1.sp)
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val fieldWidth = if (maxWidth >= 280.dp) (maxWidth - 16.dp) / 3 else maxWidth
            FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                input.fields.forEachIndexed { index, value ->
                    val label = stringResource(R.string.sas_group, index + 1)
                    val spoken = stringResource(R.string.sas_group_accessible, index + 1)
                    var focused by remember { mutableStateOf(false) }
                    val last = index == requesters.lastIndex
                    fun backspace(): Boolean {
                        if (!enabled || !focused || !input.backspaceFromEmpty(index)) return false
                        requesters[index - 1].requestFocus()
                        return true
                    }
                    Column(Modifier.width(fieldWidth), horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(label, Modifier.clearAndSetSemantics {}, style = MaterialTheme.typography.labelMedium,
                            color = if (focused) colors.primary else colors.onSurfaceVariant)
                        GroupBackspaceHandler(::backspace) {
                            OutlinedTextField(value, { next ->
                                val wasComplete = input.completeCode != null
                                val target = input.edit(index, next)
                                if (!wasComplete && input.completeCode != null) focus.clearFocus()
                                else if (target != null && target != index) requesters[target].requestFocus()
                            }, modifier = Modifier.fillMaxWidth().focusRequester(requesters[index])
                                .onFocusChanged { focused = it.isFocused }.semantics { contentDescription = spoken }
                                .onPreviewKeyEvent { it.type == KeyEventType.KeyDown && it.key == Key.Backspace && backspace() },
                                enabled = enabled, singleLine = true, textStyle = numberStyle,
                                placeholder = { Text("····", Modifier.fillMaxWidth().clearAndSetSemantics {}, style = numberStyle) },
                                shape = MaterialTheme.shapes.medium,
                                colors = OutlinedTextFieldDefaults.colors(focusedContainerColor = colors.surfaceContainerLow,
                                    unfocusedContainerColor = colors.surfaceContainerLow),
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, autoCorrectEnabled = false,
                                    imeAction = if (last) ImeAction.Done else ImeAction.Next),
                                keyboardActions = KeyboardActions(onNext = { if (!last) requesters[index + 1].requestFocus() },
                                    onDone = { focus.clearFocus() }))
                        }
                    }
                }
            }
        }
        Text(stringResource(R.string.pair_input_format), style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
    }
}

// Soft keyboards may delete surrounding text without sending a Backspace key event.
@Composable
private fun GroupBackspaceHandler(onBackspace: () -> Boolean, content: @Composable () -> Unit) {
    val backspace by rememberUpdatedState(onBackspace)
    val interceptor = remember {
        PlatformTextInputInterceptor { request, session ->
            session.startInputMethod { info ->
                object : InputConnectionWrapper(request.createInputConnection(info), false) {
                    override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean =
                        (beforeLength == 1 && afterLength == 0 && backspace()) || super.deleteSurroundingText(beforeLength, afterLength)

                    override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int): Boolean =
                        (beforeLength == 1 && afterLength == 0 && backspace()) || super.deleteSurroundingTextInCodePoints(beforeLength, afterLength)
                }
            }
        }
    }
    InterceptPlatformTextInput(interceptor, content)
}
