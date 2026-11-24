package cn.youzifeile.chirp.ui

import cn.youzifeile.chirp.data.LogEvent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.*
import cn.youzifeile.chirp.media.*
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.launch

@Composable internal fun ResetLocal(model: MainViewModel, resetting: Boolean) {
    var confirm by remember { mutableStateOf(false) }
    if (resetting) {
        Text(stringResource(R.string.reset_in_progress))
        LinearProgressIndicator(Modifier.fillMaxWidth())
        return
    }
    SettingRow(R.drawable.ic_notice, stringResource(R.string.reset_local), stringResource(R.string.local_reset_hint),
        onClick = { confirm = true }, destructive = true)
    if (confirm) ConfirmDestructiveAction(
        R.string.reset_confirm, stringResource(R.string.reset_local_warning), R.string.reset_local,
        close = { confirm = false }, action = model::resetLocal,
    )
}

@Composable internal fun LocalIdentityContents(state: MainState, model: MainViewModel, onStorage: () -> Unit) {
    val account = state.account ?: return
    state.accountDevice?.let { device ->
        SettingsGroup {
            key(device.accountKey) {
                SettingsDisclosure(R.drawable.ic_key, stringResource(R.string.parity_account_fingerprint), account.name) {
                    SelectionContainer { Text(account.id) }
                    IdentityFingerprint(device.accountKey)
                }
            }
        }
    }
    SettingsGroup {
        SettingRow(R.drawable.ic_attach, stringResource(R.string.storage_cache), stringResource(R.string.storage_settings_detail), onStorage)
    }
    SettingsGroup { ResetLocal(model, state.resettingLocal) }
    state.error?.let { ErrorNote(it) }
}

@Composable internal fun IdentityFingerprint(key: String) {
    LogScreen(LogEvent.fingerprint)
    FingerprintText(remember(key) { sha256(key.base64Bytes(32)).toHexString() })
}

@Composable private fun FingerprintText(fingerprint: String) {
    SelectionContainer { Text(fingerprint, style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)) }
}
internal fun displayTime(ms: Long) = DateFormat.getDateTimeInstance().format(Date(ms))

@Composable internal fun FriendsScreen(state: MainState, model: MainViewModel, friend: Friend?, onSelect: (String?) -> Unit) {
    LogScreen(if (friend == null) LogEvent.friends else LogEvent.friendDetails, friend?.root)
    var change by remember { mutableStateOf<SocialChange?>(null) }
    var query by rememberSaveable { mutableStateOf("") }
    BackHandler(enabled = friend != null) { onSelect(null) }
    if (friend == null) {
        FormPane { FriendDirectory(state, model, query, onQuery = { query = it }, onSelect = onSelect) }
    } else SettingsPage(friend.name, { onSelect(null) }) {
        if (state.identity.bans.any { it.blocks(friend.id, friend.root) }) Notice(stringResource(R.string.ban_account), isError = true)
        SettingsDescription(stringResource(R.string.friend_private_status))
        SettingsGroup(stringResource(R.string.friend_manage_title)) {
            key(friend.root) {
                SettingsDisclosure(R.drawable.ic_account, stringResource(R.string.parity_account_fingerprint), friend.id) {
                    IdentityFingerprint(friend.root)
                }
            }
            if (friend.devices.isEmpty()) {
                SettingsDivider()
                SettingRow(R.drawable.ic_key, stringResource(R.string.no_verified_devices), stringResource(R.string.friend_trust_help))
            }
            for (device in friend.devices.sorted()) key(device) {
                SettingsDivider()
                val revoked = state.identity.bans.any { it.blocks(friend.id, friend.root, device) }
                val fingerprint = remember(device) { sha256(device.base64Bytes(32)).toHexString() }
                SettingsDisclosure(R.drawable.ic_key, stringResource(if (revoked) R.string.device_revoked else R.string.trust_saved),
                    fingerprint.take(12).chunked(4).joinToString(" "), summaryColor = if (revoked) MaterialTheme.colorScheme.error
                    else MaterialTheme.colorScheme.onSurfaceVariant) {
                    Text(stringResource(R.string.verification_device_fp), style = MaterialTheme.typography.labelLarge)
                    FingerprintText(fingerprint)
                    TextButton({ change = SocialChange("untrust", friend.id, friend.root, device, friend.name) }) {
                        Text(stringResource(R.string.untrust_device), color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        }
        SettingsGroup {
            SettingRow(R.drawable.ic_group, stringResource(R.string.remove_friend), destructive = true,
                onClick = { change = SocialChange("remove_friend", friend.id, friend.root, "", friend.name) })
        }
        IdentityStatus(state, model)
    }
    change?.let { event ->
        val actionLabel = if (event.operation == "untrust") R.string.untrust_device else R.string.friend_remove_all
        ConfirmDestructiveAction(actionLabel, stringResource(R.string.friend_sync_warning), actionLabel,
            close = { change = null }, action = { model.accountAction { it.change(event) } }, icon = R.drawable.ic_group)
    }
}
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FriendDirectory(state: MainState, model: MainViewModel, query: String,
    onQuery: (String) -> Unit, onSelect: (String) -> Unit) {
    val friends = state.identity.friends
    val search = query.trim()
    val matches = remember(friends, search) {
        friends.filter { it.name.contains(search, true) || it.id.contains(search, true) }.sortedBy { it.name }
    }
    val bar = TopAppBarDefaults.pinnedScrollBehavior()
    val focus = LocalFocusManager.current
    Scaffold(Modifier.nestedScroll(bar.nestedScrollConnection),
        topBar = { ScreenBar(stringResource(R.string.friends), scrollBehavior = bar) }) { insets ->
        Box(Modifier.fillMaxSize().padding(insets).consumeWindowInsets(insets).imePadding(), contentAlignment = Alignment.TopCenter) {
            LazyColumn(Modifier.widthIn(max = 640.dp).fillMaxSize(), contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (friends.isNotEmpty()) {
                    item {
                        val hint = stringResource(R.string.friends_search)
                        TextField(query, onQuery, Modifier.fillMaxWidth(), singleLine = true,
                            label = { Text(hint) }, leadingIcon = { Glyph(R.drawable.ic_search) },
                            trailingIcon = if (query.isEmpty()) null else ({
                                IconButton({ onQuery("") }) { Glyph(R.drawable.ic_close, label = stringResource(R.string.clear_search)) }
                            }), shape = MaterialTheme.shapes.extraLarge,
                            colors = TextFieldDefaults.colors(focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent),
                            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                            keyboardActions = KeyboardActions(onSearch = { focus.clearFocus() }))
                    }
                    if (state.identity.synced) item {
                        Text(stringResource(R.string.friends_total, matches.size), Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                            style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                    }
                }
                if (matches.isEmpty() && state.identity.synced) item {
                    EmptyState(if (search.isEmpty()) R.drawable.ic_group else R.drawable.ic_search,
                        stringResource(if (search.isEmpty()) R.string.friends_empty_title else R.string.friends_no_matches),
                        stringResource(if (search.isEmpty()) R.string.friends_guide else R.string.friends_search_help))
                }
                items(matches, key = { it.root }) { friend ->
                    val summary = when {
                        state.identity.bans.any { it.blocks(friend.id, friend.root) } -> stringResource(R.string.ban_account)
                        friend.devices.isEmpty() -> stringResource(R.string.no_verified_devices)
                        else -> stringResource(R.string.friend_device_count, friend.devices.size)
                    }
                    SettingsGroup {
                        ListItem(modifier = Modifier.clickable(role = androidx.compose.ui.semantics.Role.Button) { focus.clearFocus(); onSelect(friend.root) },
                            headlineContent = { Text(friend.name, style = MaterialTheme.typography.titleMedium) },
                            supportingContent = { SettingsDescription(summary) },
                            leadingContent = { Avatar(friend.id, friend.name, state.directory?.members?.find { it.id == friend.id }, model::avatar, 36.dp) },
                            trailingContent = { Glyph(R.drawable.ic_chevron, Modifier.size(18.dp)) },
                            colors = ListItemDefaults.colors(containerColor = Color.Transparent))
                    }
                }
                item { Column { IdentityStatus(state, model) } }
            }
        }
    }
}

@Composable private fun IdentityStatus(state: MainState, model: MainViewModel) {
    if (state.identity.refreshing) {
        LinearProgressIndicator(Modifier.fillMaxWidth())
        Text(stringResource(R.string.identity_refreshing), style = MaterialTheme.typography.bodyMedium)
    }
    else if (!state.identity.synced) Text(stringResource(R.string.identity_unsynced))
    if (state.identity.pending) Text(stringResource(if (state.identity.pendingRevoke != null) R.string.device_revoke_pending else R.string.sync_pending))
    state.error?.let { ErrorNote(it) }
    TextButton({ model.accountAction { it.refresh() } }) { Text(stringResource(R.string.identity_sync)) }
}
@Composable internal fun DevicesScreen(state: MainState, model: MainViewModel, back: () -> Unit) {
    LogScreen(LogEvent.devices)
    var revoke by remember { mutableStateOf<String?>(null) }
    var edit by rememberSaveable(state.account?.id) { mutableStateOf<String?>(null) }
    var name by rememberSaveable(state.account?.id) { mutableStateOf("") }
    val identity = state.identity
    SettingsPage(stringResource(R.string.devices), back) {
        SettingsGroup(stringResource(R.string.devices_title), inset = true) {
            Text(stringResource(R.string.devices_intro), style = MaterialTheme.typography.titleMedium)
            SettingsDescription(stringResource(R.string.device_minimum))
        }
        if (identity.synced && identity.devices.isEmpty()) {
            EmptyState(R.drawable.ic_key, stringResource(R.string.devices_empty_title), stringResource(R.string.devices_empty))
        }
        if (identity.devices.isNotEmpty()) SettingsGroup {
            val devices = identity.devices.entries.sortedByDescending { it.key == identity.currentKey }
            devices.forEachIndexed { index, (device, label) ->
                key(device) {
                    if (index > 0) SettingsDivider()
                    DeviceSettingsRow(device, label, identity, onRename = { name = label?.name.orEmpty(); edit = device },
                        onRevoke = { revoke = device })
                }
            }
        }
        IdentityStatus(state, model)
    }
    revoke?.let { key ->
        ConfirmDestructiveAction(
            R.string.revoke_authority, stringResource(R.string.device_revoke_warning), R.string.revoke_device,
            close = { revoke = null }, action = { model.accountAction { it.revoke(key) } }, icon = R.drawable.ic_key,
        )
    }
    edit?.let { key ->
        val scope = rememberCoroutineScope()
        var saving by remember(key) { mutableStateOf(false) }
        var failure by remember(key) { mutableStateOf<ClientFailure?>(null) }
        val trimmed = name.trim()
        val changed = validName(trimmed) && trimmed != state.identity.devices[key]?.name.orEmpty()
        val close = { if (!saving) edit = null }
        ChirpDialog(icon = R.drawable.ic_tune, onDismissRequest = close, title = { Text(stringResource(R.string.device_rename)) },
            text = { Column {
                Text(stringResource(R.string.rename_device_hint))
                val invalid = name.isNotBlank() && !validName(trimmed)
                OutlinedTextField(name, { name = it; failure = null }, Modifier.fillMaxWidth(),
                    enabled = !saving, singleLine = true, isError = invalid,
                    label = { Text(stringResource(R.string.device_name)) },
                    supportingText = { if (invalid) Text(stringResource(R.string.device_name_rules)) })
                failure?.let { ErrorNote(it) }
            } },
            confirmButton = { TextButton({
                saving = true
                scope.launch {
                    try {
                        failure = model.renameDevice(key, trimmed)
                        if (failure == null) edit = null
                    } finally { saving = false }
                }
            }, enabled = changed && !saving) { Text(stringResource(R.string.save)) } },
            dismissButton = { TextButton(close, enabled = !saving) { Text(stringResource(R.string.cancel)) } })
    }
}
@Composable
private fun DeviceSettingsRow(device: String, label: DeviceLabel?, identity: AccountView, onRename: () -> Unit, onRevoke: () -> Unit) {
    val platform = label?.platform?.takeIf { it.isNotBlank() }
    val title = label?.name?.takeIf { it.isNotBlank() } ?: platform ?: stringResource(R.string.device_unnamed)
    val current = device == identity.currentKey
    val revoking = device == identity.pendingRevoke
    val revoked = device in identity.revoked
    val status = when {
        revoking -> stringResource(R.string.device_revoking)
        revoked -> stringResource(R.string.device_revoked)
        !current && identity.synced -> stringResource(R.string.device_authorized)
        else -> null
    }
    val summary = listOfNotNull(platform?.takeIf { it != title },
        if (current) stringResource(R.string.device_current) else null, status).joinToString(" · ").ifEmpty { null }
    SettingsDisclosure(R.drawable.ic_key, title, summary, summaryColor = if (revoked || revoking) MaterialTheme.colorScheme.error
        else MaterialTheme.colorScheme.onSurfaceVariant) {
        if (device in identity.enrollingDevices) Note(R.drawable.ic_key, stringResource(R.string.device_can_enroll))
        Text(stringResource(R.string.verification_device_fp), style = MaterialTheme.typography.labelLarge)
        IdentityFingerprint(device)
        val unknown = stringResource(R.string.device_no_record)
        SettingsDescription(stringResource(R.string.device_registered, label?.created?.takeIf { it > 0 }?.let { displayTime(it * 1000) } ?: unknown))
        SettingsDescription(stringResource(R.string.device_last_login, label?.lastLogin?.takeIf { it > 0 }?.let { displayTime(it * 1000) } ?: unknown))
        SettingsDescription(stringResource(R.string.devices_login_help))
        if (!revoking && !revoked) {
            if (current) SettingsDescription(stringResource(R.string.device_no_self_revoke))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onRename) { Text(stringResource(R.string.device_rename)) }
                if (!current) TextButton(onRevoke, enabled = identity.currentKey in identity.enrollingDevices,
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                    Text(stringResource(R.string.revoke_device))
                }
            }
        }
    }
}

@Composable internal fun BlacklistScreen(state: MainState, model: MainViewModel, back: () -> Unit) {
    LogScreen(LogEvent.blacklist)
    SettingsPage(stringResource(R.string.blocked_identities), back) {
        SettingsGroup(inset = true) {
            Text(stringResource(R.string.blacklist_intro), style = MaterialTheme.typography.titleMedium)
            SettingsDescription(stringResource(R.string.blacklist_explain))
            if (state.identity.synced) Note(R.drawable.ic_check, stringResource(R.string.blacklist_synced))
        }
        val groups = state.identity.bans.sortedBy(Ban::sequence).groupBy { it.account to it.root }
        if (groups.isEmpty() && state.identity.synced) {
            SettingsGroup { SettingRow(R.drawable.ic_lock, stringResource(R.string.no_bans)) }
        }
        if (groups.isNotEmpty()) SettingsGroup(stringResource(R.string.banned_users) + " · " + stringResource(R.string.blacklist_count, groups.size)) {
            groups.entries.sortedByDescending { it.value.last().sequence }.forEachIndexed { index, (identity, records) ->
                key(identity) {
                    if (index > 0) SettingsDivider()
                    val accountBlocked = records.any { it.kind == "account" }
                    val name = records.lastOrNull { it.username.isNotBlank() }?.username ?: identity.first
                    SettingsDisclosure(R.drawable.ic_lock, name, stringResource(if (accountBlocked) R.string.ban_account else R.string.banned_device),
                        summaryColor = MaterialTheme.colorScheme.error) {
                        SelectionContainer { Text(identity.first) }
                        if (accountBlocked) SettingsDescription(stringResource(R.string.account_ban_applies_to_all))
                        val devices = records.filter { it.kind == "device" }
                        if (devices.isEmpty()) {
                            SettingsDescription(stringResource(R.string.device_fingerprint_empty))
                            if (identity.second.isNotEmpty()) {
                                Text(stringResource(R.string.parity_account_fingerprint), style = MaterialTheme.typography.labelLarge)
                                IdentityFingerprint(identity.second)
                            }
                        } else {
                            Text(stringResource(R.string.verification_device_fp), style = MaterialTheme.typography.labelLarge)
                            devices.forEach { device ->
                                IdentityFingerprint(device.subject)
                                if (device.createdAt > 0) SettingsDescription(displayTime(device.createdAt * 1000))
                            }
                        }
                    }
                }
            }
        }
        IdentityStatus(state, model)
    }
}
