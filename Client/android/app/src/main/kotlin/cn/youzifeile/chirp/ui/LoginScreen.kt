package cn.youzifeile.chirp.ui

import android.os.Build
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.background
import androidx.compose.ui.graphics.Brush
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import cn.youzifeile.chirp.R

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun LoginScreen(
    state: MainState,
    onAddressChange: (String) -> Unit,
    onConfirm: (String) -> Unit,
    onLogin: (Boolean) -> Unit,
    onCancel: () -> Unit,
    onRegister: () -> Unit,
    onLocalPermission: () -> Unit,
    onSettings: () -> Unit,
    onRetryClock: () -> Unit,
) {
    Scaffold(topBar = {
        ScreenBar("", brand = true) {
            IconButton(onSettings) { Glyph(R.drawable.ic_tune, label = stringResource(R.string.security_settings)) }
        }
    }) { insets ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(insets).consumeWindowInsets(insets).imePadding(),
            contentAlignment = Alignment.TopCenter) {
            val wide = maxWidth >= 840.dp && LocalDensity.current.fontScale <= 1.3f
            val form: @Composable () -> Unit = {
                ConnectionForm(state, state.address, onAddressChange, onConfirm, onLogin, onCancel, onRegister, onLocalPermission, onRetryClock)
            }
            Column(Modifier.widthIn(max = if (wide) 960.dp else 512.dp).fillMaxWidth()
                .verticalScroll(rememberScrollState()).heightIn(min = maxHeight)
                .padding(horizontal = 24.dp, vertical = if (wide) 32.dp else 16.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp)) {
                if (wide) {
                    Row(horizontalArrangement = Arrangement.spacedBy(48.dp)) {
                        LoginHeader(Modifier.weight(1f))
                        Column(Modifier.weight(1f)) { form() }
                    }
                } else {
                    LoginHeader()
                    form()
                }
            }
        }
    }
}

@Composable
private fun LoginHeader(modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (!compactWindowHeight()) ConversationArtwork()
        Text(stringResource(R.string.connection_title), Modifier.semantics { heading() },
            style = MaterialTheme.typography.headlineLarge)
        Text(stringResource(R.string.welcome_body), style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant)
    }
}

@Composable
private fun ConversationArtwork() {
    val colors = MaterialTheme.colorScheme
    Surface(Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.extraLarge, color = colors.primaryContainer) {
        SignalArtwork(
            Modifier.fillMaxWidth().height(144.dp).background(
                Brush.horizontalGradient(listOf(colors.secondaryContainer, colors.primaryContainer, colors.secondaryContainer)),
            ),
            ink = colors.primary,
            accent = colors.tertiary,
        )
    }
}

@Composable
private fun ConnectionForm(
    state: MainState,
    address: String,
    onAddressChange: (String) -> Unit,
    onConfirm: (String) -> Unit,
    onLogin: (Boolean) -> Unit,
    onCancel: () -> Unit,
    onRegister: () -> Unit,
    onLocalPermission: () -> Unit,
    onRetryClock: () -> Unit,
) {
    val connection = state.connection
    val focus = LocalFocusManager.current
    val addressLabel = stringResource(R.string.server_address)
    val confirmed = connection != null
    val busy = state.authorizing || state.checking
    val invalidAddress = state.error?.code == "INVALID_SERVER_ADDRESS"
    val confirm = {
        if (address.isNotBlank() && !busy) {
            focus.clearFocus()
            onConfirm(address)
        }
    }

    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        ClockNotice(state.clock, onRetryClock)
        Text(addressLabel, Modifier.clearAndSetSemantics {}, style = MaterialTheme.typography.labelLarge)
        OutlinedTextField(
            address, onAddressChange,
            Modifier.fillMaxWidth().semantics { contentDescription = addressLabel },
            enabled = !busy,
            singleLine = true,
            placeholder = { Text(stringResource(R.string.server_address_example), color = MaterialTheme.colorScheme.onSurfaceVariant) },
            isError = invalidAddress,
            leadingIcon = { Glyph(R.drawable.ic_link) },
            supportingText = {
                Text(stringResource(when {
                    invalidAddress -> R.string.error_address
                    confirmed -> R.string.server_verified
                    else -> R.string.server_help
                }))
            },
            trailingIcon = if (confirmed) ({ Glyph(R.drawable.ic_check, tint = MaterialTheme.colorScheme.primary) }) else null,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = if (confirmed) ImeAction.Done else ImeAction.Go),
            keyboardActions = KeyboardActions(onGo = { confirm() }, onDone = { focus.clearFocus() }),
        )
        if (!confirmed || state.checking && !state.openingRegistration) {
            Button(confirm, Modifier.fillMaxWidth().heightIn(min = 52.dp),
                enabled = address.isNotBlank() && !busy) {
                if (state.checking) {
                    CircularProgressIndicator(Modifier.size(20.dp), color = LocalContentColor.current, strokeWidth = 2.dp)
                    Text(stringResource(R.string.server_checking), Modifier.padding(start = 8.dp))
                }
                else Text(stringResource(R.string.server_confirm))
            }
        }
        if (confirmed) {
            if (state.authorizing) {
                state.loginQr?.let { url ->
                    val bitmap = androidx.compose.runtime.remember(url) { qrBitmap(url).asImageBitmap() }
                    androidx.compose.foundation.Image(bitmap, stringResource(R.string.phone_login),
                        Modifier.align(Alignment.CenterHorizontally).widthIn(max = 240.dp).fillMaxWidth().aspectRatio(1f))
                }
                Text(stringResource(if (state.loginQr != null) R.string.phone_login_scan_help else R.string.passkey_waiting), color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium)
                TextButton(onCancel) { Text(stringResource(R.string.cancel)) }
            } else {
                Button({ onLogin(false) }, Modifier.fillMaxWidth().heightIn(min = 52.dp), enabled = !busy && state.clock.ready) {
                    Glyph(R.drawable.ic_key, tint = LocalContentColor.current)
                    Text(stringResource(R.string.passkey), Modifier.padding(start = 8.dp))
                }
                if (connection.deviceLogin || connection.register != null) {
                    FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterHorizontally)) {
                        if (connection.deviceLogin) {
                            TextButton({ onLogin(true) }, modifier = Modifier.heightIn(min = 48.dp), enabled = !busy && state.clock.ready) {
                                Glyph(R.drawable.ic_qr, Modifier.size(18.dp))
                                Text(stringResource(R.string.phone_login), Modifier.padding(start = 6.dp))
                            }
                        }
                        if (connection.register != null) {
                            TextButton(onRegister, modifier = Modifier.heightIn(min = 48.dp), enabled = !busy) {
                                Glyph(R.drawable.ic_person_add, Modifier.size(18.dp))
                                Text(stringResource(if (state.openingRegistration) R.string.opening_registration else R.string.register),
                                    Modifier.padding(start = 6.dp))
                            }
                        }
                    }
                }
            }
            connection.availableUpdate?.let {
                Note(R.drawable.ic_notice, stringResource(R.string.new_version, it))
                connection.updatePolicy?.let { policy -> Text(policy.description()) }
            }
        }
        if (!invalidAddress) state.error?.let { ErrorNote(it) }
        if (Build.VERSION.SDK_INT >= 37 && state.error?.code in setOf("CLIENT_NETWORK_FAILURE", "CLIENT_NETWORK_UNAVAILABLE", "CLIENT_NETWORK_TIMEOUT", "SERVER_UNAVAILABLE")) {
            TextButton(onLocalPermission) { Text(stringResource(R.string.local_network)) }
        }
    }
}
