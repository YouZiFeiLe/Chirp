package cn.youzifeile.chirp.ui

import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.BasicAlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import cn.youzifeile.chirp.R

@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable
internal fun ChirpDialog(
    onDismissRequest: () -> Unit,
    title: @Composable () -> Unit,
    text: (@Composable () -> Unit)? = null,
    confirmButton: @Composable () -> Unit,
    dismissButton: (@Composable () -> Unit)? = null,
    @DrawableRes icon: Int = R.drawable.ic_notice,
    destructive: Boolean = false,
) {
    val colors = MaterialTheme.colorScheme
    val compact = compactWindowHeight()
    BasicAlertDialog(
        onDismissRequest = onDismissRequest,
        modifier = Modifier
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Vertical))
            .imePadding()
            .padding(horizontal = 16.dp, vertical = if (compact) 2.dp else 12.dp),
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        BoxWithConstraints {
            val typing = WindowInsets.isImeVisible
            val condensed = compact || typing
            val actionsBesideContent = compact && maxWidth >= 500.dp && text != null
            val body: @Composable (Modifier) -> Unit = { modifier ->
                if (text != null) {
                    Box(modifier.verticalScroll(rememberScrollState())) {
                        ProvideTextStyle(MaterialTheme.typography.bodyMedium) { text() }
                    }
                }
            }
            val actions: @Composable () -> Unit = {
                dismissButton?.invoke()
                confirmButton()
            }
            Surface(Modifier.widthIn(max = if (actionsBesideContent) 560.dp else 420.dp).fillMaxWidth(),
                shape = MaterialTheme.shapes.extraLarge, color = colors.surfaceContainerHigh, contentColor = colors.onSurface) {
                Column(Modifier.padding(horizontal = if (condensed) 16.dp else 24.dp, vertical = if (condensed) 6.dp else 20.dp)) {
                    if (!condensed) {
                        Surface(
                            modifier = Modifier.align(Alignment.CenterHorizontally).padding(bottom = 12.dp),
                            shape = MaterialTheme.shapes.large,
                            color = if (destructive) colors.errorContainer else colors.secondaryContainer,
                            contentColor = if (destructive) colors.onErrorContainer else colors.onSecondaryContainer,
                        ) {
                            Glyph(icon, Modifier.padding(11.dp).size(22.dp))
                        }
                    }
                    if (!compact || !typing) {
                        Box(Modifier.align(if (condensed) Alignment.Start else Alignment.CenterHorizontally)
                            .padding(bottom = if (condensed) 6.dp else 12.dp).semantics { heading() }) {
                            ProvideTextStyle(if (condensed) MaterialTheme.typography.titleMedium else MaterialTheme.typography.headlineSmall) {
                                title()
                            }
                        }
                    }
                    if (actionsBesideContent) {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            body(Modifier.weight(1f))
                            Row(
                                Modifier.widthIn(max = 324.dp),
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) { actions() }
                        }
                    } else {
                        if (text != null) body(Modifier.weight(1f, fill = false))
                        FlowRow(
                            Modifier.fillMaxWidth().padding(top = if (condensed) 4.dp else 12.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) { actions() }
                    }
                }
            }
        }
    }
}

@Composable
internal fun ConfirmDestructiveAction(
    @StringRes title: Int,
    text: String,
    @StringRes actionLabel: Int,
    close: () -> Unit,
    action: () -> Unit,
    @DrawableRes icon: Int = R.drawable.ic_notice,
) {
    val colors = MaterialTheme.colorScheme
    ChirpDialog(
        onDismissRequest = close,
        title = { Text(stringResource(title)) },
        text = { Text(text) },
        confirmButton = {
            Button(
                onClick = { close(); action() },
                colors = ButtonDefaults.buttonColors(containerColor = colors.error, contentColor = colors.onError),
            ) { Text(stringResource(actionLabel)) }
        },
        dismissButton = { TextButton(close) { Text(stringResource(R.string.cancel)) } },
        icon = icon,
        destructive = true,
    )
}

@Composable
internal fun PasswordField(
    value: String,
    change: (String) -> Unit,
    @StringRes label: Int,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    isError: Boolean = false,
    onDone: (() -> Unit)? = null,
    imeAction: ImeAction = if (onDone == null) ImeAction.Default else ImeAction.Done,
    supportingText: (@Composable () -> Unit)? = null,
) {
    var visible by remember { mutableStateOf(false) }
    OutlinedTextField(
        value, change, modifier.fillMaxWidth(),
        enabled = enabled, isError = isError, singleLine = true,
        keyboardOptions = KeyboardOptions(
            keyboardType = KeyboardType.Password,
            imeAction = imeAction,
        ),
        keyboardActions = KeyboardActions(onDone = onDone?.let { done -> { done() } }),
        visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
        label = { Text(stringResource(label)) },
        supportingText = supportingText,
        trailingIcon = {
            IconButton(onClick = { visible = !visible }, enabled = enabled) {
                Glyph(if (visible) R.drawable.ic_visibility_off else R.drawable.ic_visibility,
                    label = stringResource(if (visible) R.string.password_hide else R.string.password_show))
            }
        },
    )
}
