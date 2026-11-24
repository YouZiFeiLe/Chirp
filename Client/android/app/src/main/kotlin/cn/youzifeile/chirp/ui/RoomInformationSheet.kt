package cn.youzifeile.chirp.ui

import cn.youzifeile.chirp.data.LogEvent
import android.os.SystemClock
import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.RoomInfo
import cn.youzifeile.chirp.media.CallPhase
import cn.youzifeile.chirp.media.CallState
import cn.youzifeile.chirp.media.RoomPublicInformation
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun RoomInformationSheet(room: RoomInfo, call: CallState?, close: () -> Unit) {
    LogScreen(LogEvent.roomInformation)
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val colors = MaterialTheme.colorScheme
    val info = call?.information
    // Use the new snapshot's clock immediately, including the frame before its timer starts.
    var now by remember(info?.started) { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    LaunchedEffect(info?.started) {
        while (info != null && info.fresh(now)) {
            delay(500)
            now = SystemClock.elapsedRealtime()
        }
    }
    val live = info?.takeIf { it.fresh(now) }
    ModalBottomSheet(onDismissRequest = close, sheetState = sheet, sheetMaxWidth = 560.dp,
        containerColor = colors.surfaceContainerLow, contentColor = colors.onSurface) {
        Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(stringResource(R.string.room_information), style = MaterialTheme.typography.labelLarge, color = colors.primary)
                Text(room.title(), Modifier.semantics { heading() }, style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            FilledTonalIconButton(onClick = {
                scope.launch {
                    sheet.hide()
                    if (!sheet.isVisible) close()
                }
            }) {
                Glyph(R.drawable.ic_close, label = stringResource(R.string.close))
            }
        }
        HorizontalDivider(color = colors.outlineVariant)
        Column(Modifier.fillMaxWidth().weight(1f, fill = false).verticalScroll(rememberScrollState())
            .padding(start = 20.dp, end = 20.dp, top = 16.dp, bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            SelectionContainer {
                Text(room.displayDescription(), style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
            }
            RoomSecuritySummary(call, live)
            Surface(Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.large, color = colors.surfaceContainerLowest) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeading(stringResource(R.string.info_rules))
                    RoomFact(R.string.info_access, stringResource(if (room.passwordRequired) R.string.info_password else R.string.info_open))
                    RoomFact(R.string.info_capacity, if (room.maxParticipants > 0) room.maxParticipants.toString() else stringResource(R.string.unlimited))
                    RoomFact(R.string.info_entry_mic, stringResource(R.string.info_default_muted))
                }
            }
            if (call != null) key(room.id, call.entryID) {
                SettingsGroup {
                    val waiting = call.trust.pending
                    val countdown = live?.countdown(now)
                    val next = when {
                        waiting -> stringResource(R.string.rotation_after_trust)
                        live == null -> stringResource(R.string.info_plan_unknown)
                        live.phase == "switching" -> stringResource(R.string.info_plan_switching)
                        countdown == null -> stringResource(R.string.info_plan_unscheduled)
                        countdown == 0L -> stringResource(R.string.info_plan_due)
                        else -> stringResource(R.string.info_next, countdown)
                    }
                    SettingsDisclosure(R.drawable.ic_key, stringResource(R.string.rotation_details), next) {
                        if (waiting) SettingsDescription(stringResource(R.string.room_plan_trust))
                        else if (info != null) RotationFacts(info, fresh = live != null)
                        else SettingsDescription(stringResource(R.string.stale_rotation_help))
                        SettingsDescription(stringResource(R.string.rotation_may_change))
                    }
                    SettingsDivider()
                    SettingsDisclosure(R.drawable.ic_lock, stringResource(R.string.info_protocol_details), null, logEvent = LogEvent.expandProtocol) {
                        RoomFact(R.string.info_cipher, "MLS")
                        RoomFact(R.string.info_protocol_version, "V5")
                        RoomFact(R.string.info_coverage_label, stringResource(R.string.info_encrypted_media))
                    }
                }
            }
        }
    }
}

private enum class RoomStatus(@StringRes val title: Int, @DrawableRes val icon: Int, @StringRes val detail: Int? = null) {
    BeforeJoining(R.string.info_prejoin, R.drawable.ic_group, R.string.room_prejoin_explain),
    Held(R.string.call_held, R.drawable.ic_mic_off),
    Verifying(R.string.verify_wait, R.drawable.ic_notice, R.string.room_plan_trust),
    AwaitingSync(R.string.info_stale, R.drawable.ic_link, R.string.stale_rotation_help),
    Establishing(R.string.info_establishing, R.drawable.ic_key),
    Securing(R.string.info_establishing, R.drawable.ic_key, R.string.trust_establishing),
    Recovering(R.string.security_updating, R.drawable.ic_key, R.string.trust_establishing),
    Rotating(R.string.info_updating, R.drawable.ic_key),
    Alone(R.string.info_solo, R.drawable.ic_group, R.string.solo_detail),
    Ready(R.string.info_ready, R.drawable.ic_lock, R.string.ready_trust_all),
}

@Composable
private fun RoomSecuritySummary(call: CallState?, live: RoomPublicInformation?) {
    val status = when {
        call == null -> RoomStatus.BeforeJoining
        call.held -> RoomStatus.Held
        call.trust.pending -> RoomStatus.Verifying
        live == null -> RoomStatus.AwaitingSync
        call.phase == CallPhase.Securing -> if (call.chatVisible) RoomStatus.Recovering else RoomStatus.Securing
        call.phase != CallPhase.Connected -> RoomStatus.Establishing
        live.phase != null -> RoomStatus.Rotating
        live.members == 1 -> RoomStatus.Alone
        else -> RoomStatus.Ready
    }
    val colors = MaterialTheme.colorScheme
    val (fill, ink) = when (status) {
        RoomStatus.Verifying -> colors.errorContainer to colors.onErrorContainer
        RoomStatus.Ready, RoomStatus.Alone -> colors.primaryContainer to colors.onPrimaryContainer
        else -> colors.secondaryContainer to colors.onSecondaryContainer
    }
    Surface(Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.large, color = fill, contentColor = ink) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Glyph(status.icon, Modifier.size(24.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(stringResource(status.title), Modifier.semantics { heading() }, style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold)
                    status.detail?.let { Text(stringResource(it), style = MaterialTheme.typography.bodyMedium) }
                }
            }
            if (call != null && status != RoomStatus.AwaitingSync) {
                HorizontalDivider(color = ink.copy(alpha = .18f))
                Note(R.drawable.ic_link, stringResource(if (live != null) R.string.room_synced else R.string.room_not_synced),
                    color = ink)
            }
        }
    }
}

@Composable
private fun RoomFact(@StringRes label: Int, value: String) {
    Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(stringResource(label), Modifier.weight(.9f), style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, Modifier.weight(1.1f), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.End, color = MaterialTheme.colorScheme.onSurface)
    }
}

@Composable
private fun RotationFacts(info: RoomPublicInformation, fresh: Boolean) {
    if (fresh) {
        RoomFact(R.string.info_round_label, stringResource(R.string.info_round, (info.epoch + 1UL).toString()))
        RoomFact(R.string.members, info.members.toString())
        RoomFact(R.string.info_progress, stringResource(when (info.phase) {
            "collecting", "welcoming" -> R.string.info_preparing
            "confirming", "ready" -> R.string.info_confirming
            "switching" -> R.string.info_switching
            else -> if (info.established == null) R.string.group_unestablished else R.string.info_completed
        }))
        if (info.phase != null) {
            DeviceProgress(R.string.info_confirmed_devices, info.confirmed, info.members)
            DeviceProgress(R.string.info_switched_devices, info.activated, info.members)
        }
        HorizontalDivider()
    }
    RoomFact(R.string.info_update_reason, stringResource(when (info.reason) {
        "initial_connection" -> R.string.info_initial
        "members_changed" -> R.string.info_members
        "scheduled_rotation" -> R.string.info_scheduled
        else -> R.string.info_reconnect
    }))
    RoomFact(R.string.info_schedule_interval, stringResource(R.string.info_interval_seconds, info.interval / 1000))
    (info.last ?: info.established)?.let { date ->
        val label = when {
            !fresh -> R.string.last_confirmation
            info.last != null -> R.string.info_last_rotation_label
            else -> R.string.info_established_label
        }
        RoomFact(label, displayTime(date))
    }
}

@Composable
private fun DeviceProgress(@StringRes label: Int, count: Int, total: Int) {
    Column(Modifier.semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        RoomFact(label, "$count / $total")
        LinearProgressIndicator(progress = { count.toFloat() / total }, modifier = Modifier.fillMaxWidth())
    }
}
