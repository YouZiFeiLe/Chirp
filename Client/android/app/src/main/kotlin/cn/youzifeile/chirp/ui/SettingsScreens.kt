package cn.youzifeile.chirp.ui

import cn.youzifeile.chirp.data.LogEvent
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.foundation.layout.size
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import cn.youzifeile.chirp.BuildConfig
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.validName
import cn.youzifeile.chirp.media.CallState

@Composable
internal fun AccountScreen(
    activity: ComponentActivity, state: MainState, call: CallState, model: MainViewModel,
    onProfile: () -> Unit, onAudio: () -> Unit,
    onLogs: () -> Unit, onDevices: () -> Unit, onBlacklist: () -> Unit, onLocalIdentity: () -> Unit,
) {
    LogScreen(LogEvent.settings)
    val profile = state.account ?: return
    var signOut by rememberSaveable { mutableStateOf(false) }
    SettingsPage(stringResource(R.string.account)) {
        val colors = MaterialTheme.colorScheme
        Surface(onClick = { model.clearError(); onProfile() }, shape = MaterialTheme.shapes.large,
            color = colors.secondaryContainer, contentColor = colors.onSecondaryContainer) {
            Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Avatar(profile.id, profile.name, profile, model::avatar, 52.dp)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(profile.name, style = MaterialTheme.typography.headlineSmall)
                    Text(stringResource(R.string.edit_profile), style = MaterialTheme.typography.bodyMedium)
                }
                Glyph(R.drawable.ic_chevron)
            }
        }
        SettingsGroup(stringResource(R.string.preferences)) {
            SettingRow(R.drawable.ic_tune, stringResource(R.string.audio_settings),
                stringResource(model.calls.audio.state.collectAsStateWithLifecycle().value.preset.label()), onAudio)
            if (Build.VERSION.SDK_INT >= 37) {
                SettingsDivider()
                LocalNetworkSetting(activity)
            }
            SettingsDivider()
            LanguageSetting(activity)
            SettingsDivider()
            LogSettingsRow(onLogs)
        }
        SettingsGroup(stringResource(R.string.device_security)) {
            SettingRow(R.drawable.ic_key, stringResource(R.string.devices), stringResource(R.string.device_list_blurb), onDevices)
            SettingsDivider()
            key(profile.id) { DeviceAuthorization(activity, model, state, accountShortcut = true) }
            SettingsDivider()
            SettingRow(R.drawable.ic_lock, stringResource(R.string.blocked_identities), stringResource(R.string.blacklist_settings_detail), onBlacklist)
            SettingsDivider()
            SettingRow(R.drawable.ic_account, stringResource(R.string.local_identity_data), stringResource(R.string.identity_blurb), onLocalIdentity)
        }
        SettingsGroup(stringResource(R.string.about)) {
            SettingRow(R.drawable.ic_waveform, stringResource(R.string.version),
                stringResource(R.string.version_with_build, BuildConfig.VERSION_NAME, BuildConfig.CLIENT_BUILD))
        }
        SettingsGroup {
            SettingRow(R.drawable.ic_logout, stringResource(R.string.sign_out), onClick = { signOut = true },
                enabled = !state.checking, destructive = true)
        }
    }
    if (signOut) {
        val detail = stringResource(R.string.sign_out_detail)
        val body = if (call.room != null) detail + "\n\n" + stringResource(R.string.sign_out_info) else detail
        ConfirmDestructiveAction(
            R.string.sign_out_question, body, R.string.sign_out,
            close = { signOut = false }, action = model::logout, icon = R.drawable.ic_account,
        )
    }
}

@Composable
internal fun ProfileScreen(state: MainState, model: MainViewModel, back: () -> Unit) {
    val profile = state.account ?: return
    LogScreen(LogEvent.profile)
    var name by rememberSaveable(profile.id) { mutableStateOf(profile.name) }
    var lastName by rememberSaveable(profile.id) { mutableStateOf(profile.name) }
    androidx.compose.runtime.LaunchedEffect(profile.name) {
        if (name == lastName || name.trim() == profile.name) name = profile.name
        lastName = profile.name
    }
    var pickerSession by rememberSaveable { mutableStateOf<String?>(null) }
    var confirmRemove by rememberSaveable(profile.id) { mutableStateOf(false) }
    val canEdit = !state.preparingAvatar && !state.editingProfile
    val preview = state.avatarDraft
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> uri?.let { model.selectAvatar(it, pickerSession) } }
    val file = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let { model.selectAvatar(it, pickerSession) } }
    val leave = { model.discardAvatar(); back() }
    androidx.activity.compose.BackHandler(onBack = leave)
    SettingsPage(stringResource(R.string.edit_profile), leave) {
        Note(R.drawable.ic_key, stringResource(R.string.signed_in))
        SettingsGroup(inset = true) {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                val selected = preview
                if (selected != null) androidx.compose.foundation.Image(selected.preview.asImageBitmap(), stringResource(R.string.avatar_preview),
                    Modifier.size(66.dp).clip(androidx.compose.foundation.shape.CircleShape), contentScale = androidx.compose.ui.layout.ContentScale.Crop)
                else Avatar(profile.id, profile.name, profile, model::avatar, 66.dp)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(profile.name, style = MaterialTheme.typography.titleLarge)
                    OutlinedButton(onClick = { pickerSession = state.profileSession; pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                        enabled = canEdit) { Text(stringResource(R.string.avatar_change)) }
                }
            }
            SettingsDescription(stringResource(R.string.profile_avatar_help))
            TextButton({ pickerSession = state.profileSession; file.launch(arrayOf("image/jpeg", "image/png", "image/heic", "image/heif")) }, enabled = canEdit) {
                Text(stringResource(R.string.choose_file))
            }
            if (state.preparingAvatar) {
                Text(stringResource(R.string.avatar_preparing), style = MaterialTheme.typography.bodySmall)
                androidx.compose.material3.LinearProgressIndicator(Modifier.fillMaxWidth())
            }
            if (preview != null) {
                Button({ model.changeAvatar(preview) }, enabled = canEdit) {
                    Text(stringResource(R.string.avatar_save))
                }
            }
            if (preview != null || state.preparingAvatar) {
                TextButton(model::discardAvatar, enabled = !state.editingProfile) { Text(stringResource(R.string.avatar_cancel)) }
            }
            if (profile.avatar != null) TextButton(onClick = { confirmRemove = true }, enabled = canEdit) {
                Text(stringResource(R.string.avatar_remove))
            }
        }
        SettingsGroup(inset = true) {
            OutlinedTextField(name, { input ->
                val length = input.codePointCount(0, input.length)
                name = if (length > 80) input.substring(0, input.offsetByCodePoints(0, 80)) else input
            }, Modifier.fillMaxWidth(), enabled = canEdit, singleLine = true,
                label = { Text(stringResource(R.string.display_name)) },
                supportingText = { Text(stringResource(R.string.profile_name_help)) })
            Button(onClick = { model.rename(name) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                enabled = canEdit && validName(name.trim()) && name.trim() != profile.name) {
                Text(stringResource(R.string.save))
            }
        }
        state.profileNotice?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.primary) }
        if (state.directory?.fresh == false) Note(R.drawable.ic_notice, stringResource(R.string.profile_stale))
        state.error?.let { ErrorNote(it) }
    }
    if (confirmRemove && profile.avatar != null && canEdit) {
        ConfirmDestructiveAction(
            R.string.avatar_remove_question, stringResource(R.string.avatar_remove_detail), R.string.avatar_remove,
            close = { confirmRemove = false }, action = { model.changeAvatar(null) }, icon = R.drawable.ic_image,
        )
    }
}

@Composable
private fun LocalNetworkSetting(activity: ComponentActivity) {
    val permission = ChirpPermission.LocalNetwork
    var allowed by remember { mutableStateOf(false) }
    LifecycleResumeEffect(permission, lifecycleOwner = activity) {
        allowed = ContextCompat.checkSelfPermission(activity, permission.value) == PackageManager.PERMISSION_GRANTED
        onPauseOrDispose {}
    }
    val request = rememberPermission(activity, permission) { allowed = true }
    SettingRow(permission.icon, stringResource(if (allowed) R.string.local_network_allowed else R.string.local_network),
        stringResource(permission.rationale), onClick = if (allowed) null else request)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SettingsPage(
    title: String,
    back: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val bar = TopAppBarDefaults.pinnedScrollBehavior()
    FormPane {
        Scaffold(modifier = Modifier.nestedScroll(bar.nestedScrollConnection),
            topBar = { ScreenBar(title, back, scrollBehavior = bar) }) { insets ->
            Box(Modifier.fillMaxSize().padding(insets).consumeWindowInsets(insets).imePadding(), contentAlignment = Alignment.TopCenter) {
                Column(Modifier.widthIn(max = 640.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)) { content() }
            }
        }
    }
}
