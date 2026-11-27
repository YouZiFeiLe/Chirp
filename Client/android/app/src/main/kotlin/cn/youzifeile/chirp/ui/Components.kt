package cn.youzifeile.chirp.ui

import cn.youzifeile.chirp.data.LogEvent
import cn.youzifeile.chirp.data.LogOutcome
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.TopAppBarScrollBehavior
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfoV2
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import androidx.window.core.layout.WindowSizeClass
import cn.youzifeile.chirp.data.ClientFailure
import cn.youzifeile.chirp.data.VersionPolicy
import cn.youzifeile.chirp.data.clientErrorCode
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.Profile
import cn.youzifeile.chirp.data.RoomInfo
import cn.youzifeile.chirp.media.CallPhase
import cn.youzifeile.chirp.media.CallState

@Composable
internal fun Glyph(@DrawableRes icon: Int, modifier: Modifier = Modifier,
    label: String? = null, tint: Color = LocalContentColor.current) {
    Icon(painterResource(icon), label, modifier.size(24.dp), tint)
}

@Composable
internal fun SectionHeading(title: String, modifier: Modifier = Modifier, trailing: String? = null) {
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f).semantics { heading() }, style = MaterialTheme.typography.titleMedium)
        if (trailing != null) Text(trailing, style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
internal fun Note(@DrawableRes icon: Int, text: String, modifier: Modifier = Modifier,
    color: Color = MaterialTheme.colorScheme.onSurfaceVariant) {
    Row(modifier.semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Glyph(icon, Modifier.size(18.dp), tint = color)
        Text(text, style = MaterialTheme.typography.bodyMedium, color = color)
    }
}

@Composable
internal fun Notice(text: String, modifier: Modifier = Modifier, @DrawableRes icon: Int = R.drawable.ic_notice,
    isError: Boolean = false) {
    val scheme = MaterialTheme.colorScheme
    Surface(modifier.fillMaxWidth(), shape = MaterialTheme.shapes.medium,
        color = if (isError) scheme.errorContainer else scheme.tertiaryContainer) {
        Note(icon, text, Modifier.padding(16.dp), color = if (isError) scheme.onErrorContainer else scheme.onTertiaryContainer)
    }
}

@Composable
internal fun EmptyState(@DrawableRes icon: Int, title: String, detail: String, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Surface(shape = CircleShape, color = MaterialTheme.colorScheme.secondaryContainer) {
            Glyph(icon, Modifier.padding(16.dp), tint = MaterialTheme.colorScheme.onSecondaryContainer)
        }
        Text(title, Modifier.semantics { heading() }, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
        Text(detail, Modifier.widthIn(max = 360.dp), style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
    }
}

@Composable
internal fun Avatar(
    identity: String,
    name: String,
    profile: Profile?,
    load: (suspend (Profile) -> android.graphics.Bitmap?)?,
    size: Dp = 44.dp,
    speaking: Boolean = false,
) {
    val index = remember(identity) { identity.substringBefore(".login_").codePoints().sum() and 3 }
    val colors = MaterialTheme.colorScheme
    val (fill, ink) = when (index) {
        0 -> colors.primaryContainer to colors.onPrimaryContainer
        1 -> colors.tertiaryContainer to colors.onTertiaryContainer
        2 -> colors.secondaryContainer to colors.onSecondaryContainer
        else -> colors.surfaceContainerHighest to colors.onSurface
    }
    val bitmap = androidx.compose.runtime.key(profile?.id, profile?.avatar) {
        produceState<android.graphics.Bitmap?>(null) {
            if (profile?.avatar != null && load != null) value = load(profile)
        }.value
    }
    val mark = remember(name) {
        if (name.isEmpty()) "?" else String(Character.toChars(name.codePointAt(0))).uppercase()
    }
    val outer = if (speaking) Modifier.border(2.dp, colors.tertiary, CircleShape).padding(4.dp) else Modifier.padding(4.dp)
    Box(outer.size(size).clip(CircleShape).background(fill).clearAndSetSemantics {}, contentAlignment = Alignment.Center) {
        val portrait = bitmap
        if (portrait != null) Image(portrait.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        else Text(mark, color = ink, style = MaterialTheme.typography.titleMedium)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ScreenBar(title: String, onBack: (() -> Unit)? = null, brand: Boolean = false,
    scrollBehavior: TopAppBarScrollBehavior? = null, containerColor: Color = MaterialTheme.colorScheme.surface,
    actions: @Composable () -> Unit = {}) {
    val titleContent: @Composable () -> Unit = {
        if (brand) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Glyph(R.drawable.ic_waveform, tint = MaterialTheme.colorScheme.primary)
            Text(stringResource(R.string.app_name), style = MaterialTheme.typography.titleLarge)
        } else if (title.isNotEmpty()) Text(title, Modifier.semantics { heading() }, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
    val navigation: @Composable () -> Unit = {
        if (onBack != null) IconButton(onBack) { Glyph(R.drawable.ic_back, label = stringResource(R.string.back)) }
    }
    TopAppBar(titleContent, navigationIcon = navigation, actions = { actions() }, scrollBehavior = scrollBehavior,
        colors = TopAppBarDefaults.topAppBarColors(containerColor = containerColor),
        expandedHeight = if (compactWindowHeight()) 48.dp else TopAppBarDefaults.TopAppBarExpandedHeight)
}

@OptIn(androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi::class)
@Composable
internal fun compactWindowHeight(): Boolean = !currentWindowAdaptiveInfoV2().windowSizeClass
    .isHeightAtLeastBreakpoint(WindowSizeClass.HEIGHT_DP_MEDIUM_LOWER_BOUND)

@Composable
internal fun SettingRow(@DrawableRes icon: Int, title: String, supporting: String? = null,
    onClick: (() -> Unit)? = null, enabled: Boolean = true, expanded: Boolean? = null,
    destructive: Boolean = false, supportingColor: Color = MaterialTheme.colorScheme.onSurfaceVariant,
    onClickLabel: String? = null) {
    val colors = MaterialTheme.colorScheme
    val disabledInk = colors.onSurface.copy(alpha = .38f)
    val titleColor = if (destructive) colors.error else colors.onSurface
    val detailColor = if (enabled) supportingColor else disabledInk
    val expansionState = expanded?.let {
        stringResource(if (it) R.string.settings_expanded else R.string.settings_collapsed)
    }
    val row = if (onClick == null) Modifier else Modifier.clickable(
        enabled = enabled, role = Role.Button, onClickLabel = onClickLabel, onClick = onClick)
    ListItem(
        headlineContent = { Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold) },
        supportingContent = supporting?.let { { Text(it, Modifier.padding(top = 2.dp), style = MaterialTheme.typography.bodyMedium) } },
        leadingContent = {
            Surface(shape = MaterialTheme.shapes.medium,
                color = if (destructive) colors.errorContainer else colors.primaryContainer,
                contentColor = if (!enabled) disabledInk else if (destructive) colors.onErrorContainer else colors.primary) {
                Glyph(icon, Modifier.padding(8.dp).size(20.dp))
            }
        },
        trailingContent = onClick?.let { {
            if (expanded == null) Glyph(R.drawable.ic_chevron, Modifier.size(18.dp))
            else Glyph(R.drawable.ic_expand_more, Modifier.size(18.dp).rotate(if (expanded) 180f else 0f))
        } },
        modifier = if (expansionState == null) row else row.semantics { stateDescription = expansionState },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent,
            headlineColor = if (enabled) titleColor else disabledInk, supportingColor = detailColor,
            trailingIconColor = if (enabled) colors.onSurfaceVariant else disabledInk),
    )
}

@Composable
internal fun RadioSetting(label: String, selected: Boolean, onSelect: () -> Unit, enabled: Boolean = true) {
    Row(Modifier.fillMaxWidth().selectable(selected, enabled = enabled, role = Role.RadioButton, onClick = onSelect)
        .heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected, onClick = null, enabled = enabled)
        Text(label, style = MaterialTheme.typography.bodyLarge,
            color = if (enabled) LocalContentColor.current else MaterialTheme.colorScheme.onSurface.copy(alpha = .38f))
    }
}

@Composable
internal fun ErrorNote(code: String) = ErrorNote(ClientFailure(code))

@Composable
internal fun VersionPolicy.description(): String =
    stringResource(R.string.version_policy, latest.version, latest.build.toString(), minimum.version, minimum.build.toString())

@Composable
internal fun ErrorNote(failure: ClientFailure) {
    val resources = androidx.compose.ui.platform.LocalResources.current
    val messages = androidx.compose.runtime.remember(resources, androidx.compose.ui.platform.LocalConfiguration.current) {
        resources.getStringArray(R.array.client_error_messages).associate { it.substringBefore('=') to it.substringAfter('=') }
    }
    val code = failure.code.takeIf(clientErrorCode::matches) ?: "CLIENT_HTTP_FAILURE"
    val specific = messages[code] ?: messages["CLIENT_$code"] ?: messages[localMessageKeys[code]]
    val label = errorLabel(code)
    var message = specific ?: if (label != null) stringResource(label) else messages.getValue("CLIENT_UNKNOWN_SERVER_ERROR") + " ($code)"
    if (code == "CLIENT_UPDATE_REQUIRED") failure.policy?.let { message += "\n" + it.description() }
    failure.retryAfterSeconds?.takeIf { it > 0 }?.let { message += stringResource(R.string.retry_after, it) }
    Notice(message, Modifier.semantics { liveRegion = LiveRegionMode.Polite }, isError = true)
}

private val localMessageKeys = mapOf(
    "ATTACHMENT_FAILED" to "CLIENT_ATTACHMENT_TRANSFER_FAILED",
    "CALL_SERVICE_UNAVAILABLE" to "CLIENT_AUDIO_CONTROL_UNAVAILABLE",
    "GROUP_CHANGED" to "CLIENT_GROUP_STATE_CHANGED",
    "GROUP_CONFLICT" to "CLIENT_GROUP_STATE_CHANGED",
    "GROUP_EVENTS_CLOSED" to "CLIENT_GROUP_CONNECTION_LOST",
    "GROUP_LEASE_LOST" to "CLIENT_GROUP_LEASE_EXPIRED",
    "GROUP_SUSPENDED" to "CLIENT_GROUP_UNAVAILABLE",
    "GROUP_REKEY_REQUIRED" to "CLIENT_GROUP_STATE_CHANGED",
    "GROUP_TRANSITION_TIMEOUT" to "CLIENT_GROUP_UPDATE_TIMED_OUT",
    "IDENTITY_KEY_CHANGED" to "CLIENT_IDENTITY_CHANGED",
    "INVALID_GROUP" to "CLIENT_INVALID_GROUP_RESPONSE",
    "INVALID_MEDIA_IDENTITY" to "CLIENT_GROUP_IDENTITY_INVALID",
    "INVALID_MEDIA_ORIGIN" to "CLIENT_INVALID_MEDIA_LEASE",
    "MEDIA_CONNECT_FAILED" to "CLIENT_VOICE_CONNECTION_FAILED",
    "MEDIA_CONNECT_TIMEOUT" to "CLIENT_NETWORK_TIMEOUT",
    "MEDIA_DISCONNECTED" to "CLIENT_VOICE_DISCONNECTED",
    "MEDIA_KEY_REJECTED" to "CLIENT_LOCAL_ENCRYPTION_FAILED",
    "MLS_CONFIRMATION_MISMATCH" to "CLIENT_GROUP_CONFIRMATION_MISMATCH",
    "MLS_KEY_MISSING" to "CLIENT_GROUP_CRYPTO_FAILED",
    "MLS_PACKAGE_CHANGED" to "CLIENT_GROUP_STATE_CHANGED",
    "MLS_REQUEST_TOO_LARGE" to "CLIENT_GROUP_REQUEST_REJECTED",
    "MLS_UNAVAILABLE" to "CLIENT_GROUP_UNAVAILABLE",
    "SERVER_UNAVAILABLE" to "CLIENT_NETWORK_FAILURE",
    "SESSION_EXPIRED" to "CLIENT_LOGIN_EXPIRED",
    "BROWSER_UNAVAILABLE" to "CLIENT_BROWSER_OPEN_FAILED",
)

internal fun isKnownLocalError(code: String) = code in localMessageKeys || errorLabel(code) != null

@StringRes
private fun errorLabel(code: String): Int? = when (code) {
    "AUDIO_DECRYPTION_RECOVERY_FAILED" -> R.string.remote_decryption_failed
    "REMOTE_TRACK_UNENCRYPTED" -> R.string.remote_track_unencrypted
    "AUDIO_ENCRYPTION_FAILED" -> R.string.track_encryption_failed
    "IDENTITY_INVALID", "DEVICE_IDENTITY_REQUIRED", "MLS_FAILED" -> R.string.identity_invalid
    "IDENTITY_STORAGE_INVALID" -> R.string.identity_store_corrupt
    "IDENTITY_HISTORY_CHANGED", "IDENTITY_CONFLICT" -> R.string.identity_conflict
    "AUDIO_RESUME_DECLINED" -> R.string.audio_resume_declined
    "ROOM_IDENTITY_REVOKED" -> R.string.room_identity_revoked
    "ROOM_TRUST_SYNC_UNAVAILABLE" -> R.string.room_trust_sync_unavailable
    "PEER_IDENTITY_REVOKED" -> R.string.peer_device_revoked
    "IDENTITY_BLACKLISTED" -> R.string.identity_blocked
    "AUTHORIZATION_TRUST_INVALID" -> R.string.authority_key_needed
    "AUTHORIZATION_STALE" -> R.string.auth_stale
    "RECOVERY_PASSWORD_INVALID" -> R.string.recovery_password_rules
    "RECOVERY_INVALID" -> R.string.recovery_failure_password
    "RESET_FAILED" -> R.string.reset_failed
    "RECOVERY_SAVE_REQUIRED" -> R.string.recovery_save_required
    "RECOVERY_STATE_WRITE_FAILED" -> R.string.recovery_state_write_failed
    "RECOVERY_EXPORT_FAILED" -> R.string.backup_save_error
    "RECOVERY_READ_FAILED" -> R.string.backup_read_error
    "RECOVERY_TOO_LARGE" -> R.string.recovery_file_large
    "RECOVERY_ACCOUNT_MISMATCH" -> R.string.recovery_other_account
    "IDENTITY_CHANGE_PENDING" -> R.string.friend_change_pending
    "PAIR_INVALID_QR" -> R.string.pair_bad_qr
    "NETWORK_TIME_REQUIRED" -> R.string.clock_required
    "DEVICE_PAIRING_EXPIRED" -> R.string.pair_expired
    "PAIR_IDENTITY_CHANGED" -> R.string.pair_identity_changed
    "PAIR_IMAGE_SIZE" -> R.string.pair_image_size
    "PAIR_IMAGE_READ_FAILED" -> R.string.pair_image_read_failed
    "PAIR_IMAGE_UNREADABLE" -> R.string.pair_image_unreadable
    "PAIR_IMAGE_SAVE_FAILED" -> R.string.pair_image_save_failed
    "PAIR_ONE_QR" -> R.string.pair_one_qr
    "DEVICE_PAIRING_CANCELLED" -> R.string.pair_cancelled_detail
    "PAIR_CODE_MISMATCH" -> R.string.pair_wrong_digits
    "PAIR_UNLOCK_REQUIRED" -> R.string.pair_unlock_required
    "LOGIN_BIOMETRICS_CHANGED" -> R.string.login_biometrics_changed
    "INVALID_SERVER_ADDRESS" -> R.string.error_address
    "INVALID_RESPONSE" -> R.string.error_response
    "CLIENT_UPDATE_REQUIRED" -> R.string.error_upgrade
    "MEMBER_DISABLED" -> R.string.member_disabled
    "SESSION_EXPIRED" -> R.string.error_session
    "SERVER_CONFIGURATION_CHANGED" -> R.string.parity_configuration_changed
    "INVALID_LOGIN_CALLBACK" -> R.string.parity_callback_invalid
    "DEVICE_AUTHORIZATION_EXPIRED" -> R.string.error_auth_expired
    "BROWSER_UNAVAILABLE" -> R.string.error_browser
    "ROOM_PASSWORD_REQUIRED", "ROOM_PASSWORD_INVALID", "ROOM_PASSWORD_INCORRECT", "ROOM_PASSWORD_CHANGED" -> R.string.error_password
    "ROOM_PASSWORD_RATE_LIMITED", "ROOM_PASSWORD_BUSY" -> R.string.error_rate_limit
    "ADMISSION_EXPIRED", "ADMISSION_CHANGED", "ROOM_JOIN_OUTCOME_UNKNOWN" -> R.string.error_admission
    "MICROPHONE_UNAVAILABLE", "MICROPHONE_PERMISSION_REQUIRED" -> R.string.error_mic
    "AUDIO_ROUTE_UNAVAILABLE" -> R.string.error_route
    "AUDIO_PRESET_FAILED" -> R.string.error_audio_preset
    "MICROPHONE_NO_SAMPLE" -> R.string.error_microphone_sample
    "AUDIO_TEST_BUSY" -> R.string.microphone_test_leave
    "CHAT_SEND_FAILED", "INVALID_CHAT_TEXT" -> R.string.error_chat
    "INVALID_DISPLAY_NAME", "AVATAR_INVALID", "AVATAR_TOO_LARGE" -> R.string.error_profile
    "LOGOUT_OFFLINE" -> R.string.error_logout
    "ATTACHMENT_TOO_LARGE" -> R.string.error_file_size
    "ATTACHMENT_CACHE_FULL" -> R.string.error_cache_full
    "ATTACHMENT_CACHE_CLEAR_FAILED" -> R.string.cache_clear_failed
    "ATTACHMENT_EXPORT_FAILED" -> R.string.error_export
    "AUDIO_PREFERENCE_SAVE_FAILED" -> R.string.audio_preference_save_failed
    "DIAGNOSTICS_EXPORT_FAILED" -> R.string.diagnostics_export_failed
    else -> null
}

@Composable
internal fun RoomInfo.title(): String = if (isDefault && (name.isEmpty() || name == "公开大厅")) stringResource(R.string.default_room) else name

@Composable
internal fun RoomInfo.displayDescription(): String =
    description?.takeIf { it.isNotBlank() } ?: stringResource(R.string.room_overview)

@Composable
internal fun CallState.status(): String = stringResource(when {
    held -> R.string.call_held
    phase == CallPhase.Joining -> R.string.join_status
    phase == CallPhase.Securing && trust.pending -> R.string.verify_wait
    phase == CallPhase.Securing && chatVisible -> R.string.recovering_voice
    phase == CallPhase.Securing && connectingMedia -> R.string.connecting_media
    phase == CallPhase.Securing -> R.string.secure_status
    phase == CallPhase.Connected -> R.string.connected
    phase == CallPhase.Leaving -> R.string.leaving
    else -> R.string.room_not_joined
})

@Composable
internal fun rememberPermission(
    activity: ComponentActivity,
    request: ChirpPermission,
    onGranted: () -> Unit,
): () -> Unit {
    val operation = when (request) {
        ChirpPermission.Microphone -> LogEvent.permissionMicrophone
        ChirpPermission.Camera -> LogEvent.permissionCamera
        ChirpPermission.LocalNetwork -> LogEvent.permissionNetwork
    }
    val permission = request.value
    val granted by rememberUpdatedState(onGranted)
    var prompt by remember(permission) { mutableStateOf<PermissionPrompt?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { allowed ->
        operation.record(if (allowed) LogOutcome.succeeded else LogOutcome.cancelled)
        if (allowed) granted()
        else if (!activity.shouldShowRequestPermissionRationale(permission)) prompt = PermissionPrompt.Settings
    }
    val action: () -> Unit = {
        when {
            ContextCompat.checkSelfPermission(activity, permission) == PackageManager.PERMISSION_GRANTED -> granted()
            activity.shouldShowRequestPermissionRationale(permission) -> prompt = PermissionPrompt.Rationale
            else -> { operation.record(LogOutcome.started); launcher.launch(permission) }
        }
    }
    if (prompt != null) {
        val needsSettings = prompt == PermissionPrompt.Settings
        ChirpDialog(
            onDismissRequest = { prompt = null },
            icon = request.icon,
            title = { Text(stringResource(request.title)) },
            text = { Text(stringResource(if (needsSettings) request.settingsHelp else request.rationale)) },
            confirmButton = {
                Button(onClick = {
                    prompt = null
                    if (needsSettings) {
                        activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            "package:${activity.packageName}".toUri()))
                    } else { operation.record(LogOutcome.started); launcher.launch(permission) }
                }) { Text(stringResource(if (needsSettings) R.string.permission_settings else R.string.continue_label)) }
            },
            dismissButton = { TextButton(onClick = { prompt = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }
    return action
}

internal enum class ChirpPermission(
    val value: String,
    @DrawableRes val icon: Int,
    @StringRes val title: Int,
    @StringRes val rationale: Int,
    @StringRes val settingsHelp: Int,
) {
    Microphone(Manifest.permission.RECORD_AUDIO, R.drawable.ic_mic, R.string.permission_mic_title,
        R.string.permission_mic_help, R.string.permission_mic_settings_detail),
    Camera(Manifest.permission.CAMERA, R.drawable.ic_camera, R.string.permission_camera_title,
        R.string.permission_camera_purpose, R.string.permission_camera_settings_detail),
    LocalNetwork("android.permission.ACCESS_LOCAL_NETWORK", R.drawable.ic_link, R.string.permission_network_title,
        R.string.permission_network_purpose, R.string.permission_network_settings_detail),
}

private enum class PermissionPrompt { Rationale, Settings }
