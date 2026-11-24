package cn.youzifeile.chirp.ui

import cn.youzifeile.chirp.data.LogEvent
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.SavedIdentity

@Composable
internal fun SignedOutSettings(activity: ComponentActivity, state: MainState, model: MainViewModel, back: () -> Unit) {
    var logs by rememberSaveable { mutableStateOf(false) }
    if (logs) {
        androidx.activity.compose.BackHandler { logs = false }
        LogSettings(activity) { logs = false }
        return
    }
    LogScreen(LogEvent.settings)
    SettingsPage(stringResource(R.string.security_settings), back) {
        SettingsGroup(stringResource(R.string.preferences)) {
            LanguageSetting(activity)
            SettingsDivider()
            LogSettingsRow { logs = true }
        }
        SettingsGroup(stringResource(R.string.device_security)) {
            key(state.selectedIdentity?.scope) { DeviceAuthorization(activity, model, state) }
            SettingsDivider()
            SavedIdentitySettings(state, model::selectLocalIdentity, model::findSavedIdentity)
        }
        SettingsGroup { ResetLocal(model, state.resettingLocal) }
        state.error?.let { ErrorNote(it) }
    }
}

@Composable
internal fun SavedIdentitySettings(state: MainState, onSelect: (SavedIdentity?) -> Unit, onFind: (String, String) -> Unit) {
    var lookup by rememberSaveable { mutableStateOf(false) }
    var address by rememberSaveable { mutableStateOf("") }
    var account by rememberSaveable { mutableStateOf("") }
    val count = state.savedIdentities.size
    val summary = state.selectedIdentity?.name ?: if (count == 0) stringResource(R.string.parity_no_saved_identities)
        else pluralStringResource(R.plurals.saved_identity_count, count, count)
    SettingsDisclosure(R.drawable.ic_key, stringResource(R.string.parity_saved_identities), summary) {
        Column(Modifier.selectableGroup(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            state.savedIdentities.forEach { item ->
                val selected = item.scope == state.selectedIdentity?.scope
                Column {
                    RadioSetting(item.name, selected, onSelect = { onSelect(item) })
                    Column(Modifier.padding(start = 16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(item.origin, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(item.account, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (selected) {
                            Text(stringResource(R.string.parity_account_fingerprint), style = MaterialTheme.typography.labelLarge)
                            IdentityFingerprint(item.root)
                        }
                    }
                }
            }
        }
        if (state.selectedIdentity != null) TextButton({ onSelect(null) }) {
            Text(stringResource(R.string.parity_use_qr_identity))
        }
        TextButton({ lookup = !lookup }) { Text(stringResource(R.string.parity_find_identity)) }
        if (lookup) {
            OutlinedTextField(address, { address = it }, Modifier.fillMaxWidth(), singleLine = true,
                label = { Text(stringResource(R.string.parity_identity_origin)) })
            OutlinedTextField(account, { account = it }, Modifier.fillMaxWidth(), singleLine = true,
                label = { Text(stringResource(R.string.parity_account_id)) })
            Button({ onFind(address.trim(), account.trim()) }, enabled = address.isNotBlank() && account.isNotBlank()) {
                Text(stringResource(R.string.parity_select_identity))
            }
        }
    }
}
