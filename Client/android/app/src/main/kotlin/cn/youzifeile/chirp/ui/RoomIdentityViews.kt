package cn.youzifeile.chirp.ui

import android.os.SystemClock
import androidx.annotation.StringRes
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.base64Bytes
import cn.youzifeile.chirp.data.sha256
import cn.youzifeile.chirp.media.*
import kotlinx.coroutines.delay

@Composable
private fun VerificationInstruction(@StringRes title: Int, @StringRes detail: Int) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(stringResource(title), Modifier.semantics { heading() }, style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold)
        SettingsDescription(stringResource(detail))
    }
}

@Composable
internal fun RoomVerificationLauncher(view: RoomTrustView, controller: CallController, onStarted: () -> Unit = {},
    content: @Composable (prepare: (GroupMember) -> Unit) -> Unit) {
    var target by rememberSaveable { mutableStateOf<String?>(null) }
    val peer = view.peers.find { it.identity == target }
    val trusted = target in view.trusted
    val initiallyTrusted = rememberSaveable(target) { trusted }
    val available = peer != null && trusted == initiallyTrusted && view.verification == null && view.notice == null
    LaunchedEffect(target, available) { if (!available) target = null }
    content { target = it.identity }
    if (available && peer != null) key(peer.identity) {
        PrepareRoomVerification(view.verificationName(peer), trusted, dismiss = { target = null }, start = {
            target = null
            onStarted()
            controller.identityAction("start", peer.identity)
        })
    }
}

@Composable
private fun PrepareRoomVerification(name: String, trusted: Boolean, dismiss: () -> Unit, start: () -> Unit) {
    ChirpDialog(icon = R.drawable.ic_key, onDismissRequest = dismiss,
        title = { Text(stringResource(R.string.trust_target, name)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.primaryContainer) {
                    Column(Modifier.fillMaxWidth().padding(16.dp)) {
                        VerificationInstruction(R.string.sas_contact_person, R.string.sas_external)
                    }
                }
                SettingsDescription(stringResource(if (trusted) R.string.sas_already_trusted else R.string.sas_trust_result))
                SettingsGroup {
                    SettingsDisclosure(R.drawable.ic_key, stringResource(R.string.verification_steps), null) {
                        VerificationInstruction(R.string.sas_compare_together, R.string.sas_invite_hint)
                        HorizontalDivider()
                        VerificationInstruction(R.string.sas_confirm_each, R.string.sas_confirm_hint)
                    }
                }
            }
        }, confirmButton = { Button(start) { Text(stringResource(R.string.sas_start)) } },
        dismissButton = { TextButton(dismiss) { Text(stringResource(R.string.cancel)) } })
}

@Composable internal fun RoomVerificationDialogs(view: RoomTrustView, controller: CallController) {
    view.verification?.let { v ->
        var now by remember(v.id, view.expires) { mutableLongStateOf(SystemClock.elapsedRealtime()) }
        LaunchedEffect(v.id, view.expires) {
            while (now < view.expires) {
                delay(minOf(1_000L, view.expires - now))
                now = SystemClock.elapsedRealtime()
            }
        }
        val secondsLeft = ((view.expires - now + 999) / 1_000).coerceAtLeast(0)
        val peer = view.peers.find { it.identity == v.peer }
        fun act(action: String) = controller.identityAction(action, v.peer, v.id)
        if (v.numbers.size == 3) {
            key(v.id, v.peer) {
                RoomCodeComparison(peer?.let(view::verificationName), v.numbers, v.confirmed, secondsLeft,
                    onMatch = { if (SystemClock.elapsedRealtime() < view.expires) act("confirm") },
                    onMismatch = { act("mismatch") }, onCancel = { act("cancel") }) {
                    if (peer != null) PeerFingerprints(peer)
                }
            }
            return@let
        }
        ChirpDialog(icon = R.drawable.ic_key, onDismissRequest = { act("cancel") },
            title = { Text(peer?.let(view::verificationName) ?: stringResource(R.string.manage_identity)) },
            text = { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                val (title, detail) = when {
                    !v.accepted -> R.string.sas_incoming to R.string.sas_incoming_detail
                    v.commitment == null -> R.string.sas_outgoing to R.string.sas_outgoing_detail
                    else -> R.string.sas_generating to R.string.sas_generating_detail
                }
                Text(stringResource(R.string.sas_step, 1),
                    style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                VerificationInstruction(title, detail)
                Notice(stringResource(R.string.sas_channel_warning), icon = R.drawable.ic_lock)
                Text(stringResource(R.string.verification_remaining, secondsLeft),
                    style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (peer != null) PeerFingerprints(peer)
            } },confirmButton = {
                if (!v.accepted && v.commitment != null && now < view.expires) Button({ act("accept") }) { Text(stringResource(R.string.verify_accept)) }
            },dismissButton = {
                TextButton({ act("cancel") }) {
                    Text(stringResource(if (!v.accepted && v.commitment != null) R.string.verify_defer else R.string.verify_mismatch))
                }
            })
    }
    view.notice?.let { notice ->
        val peer = view.peers.find { it.identity == notice.peer }
        fun act(action: String) = controller.identityAction(action, notice.peer, notice.id)
        val dismiss = { act("dismiss") }
        ChirpDialog(icon = R.drawable.ic_lock, onDismissRequest = dismiss,title = { Text(stringResource(when (notice.phase) {
            VerificationPhase.Saving -> R.string.verification_saving
            VerificationPhase.SyncPending -> R.string.sas_unsynced
            VerificationPhase.Verified -> R.string.verification_completed
            VerificationPhase.Mismatch -> R.string.verification_mismatch
            VerificationPhase.PeerCancelled -> R.string.sas_peer_cancelled
            VerificationPhase.PeerBusy -> R.string.sas_peer_busy
            VerificationPhase.RoomChanged -> R.string.sas_room_changed
            VerificationPhase.Cancelled -> R.string.verification_cancelled
            VerificationPhase.Expired -> R.string.verification_expired
            VerificationPhase.Failed -> R.string.verification_failed
        })) }, text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (peer != null) {
                    Text(view.verificationName(peer), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                }
                Text(stringResource(when (notice.phase) {
                    VerificationPhase.Saving -> R.string.sas_saving_detail
                    VerificationPhase.SyncPending -> R.string.sas_sync_detail
                    VerificationPhase.Verified -> R.string.sas_verified_detail
                    VerificationPhase.Mismatch -> R.string.sas_mismatch_detail
                    VerificationPhase.Expired -> R.string.sas_expired_detail
                    VerificationPhase.PeerCancelled -> R.string.sas_peer_cancelled_detail
                    VerificationPhase.PeerBusy -> R.string.sas_peer_busy_detail
                    VerificationPhase.RoomChanged -> R.string.sas_room_changed_detail
                    VerificationPhase.Cancelled -> R.string.sas_cancelled_detail
                    VerificationPhase.Failed -> R.string.sas_failed_detail
                }))
                if (notice.phase == VerificationPhase.Verified) {
                    SettingsDescription(stringResource(if (view.pending) R.string.other_devices_pending else R.string.media_returns_after_trust))
                    SettingsGroup {
                        SettingsDisclosure(R.drawable.ic_lock, stringResource(R.string.sas_this_device), null) {
                            SettingsDescription(stringResource(R.string.sas_new_device_hint))
                            SettingsDescription(stringResource(R.string.sas_manual_mic))
                        }
                    }
                }
                if (notice.phase == VerificationPhase.Saving) Text(stringResource(R.string.sas_auto_continue))
                if (notice.phase == VerificationPhase.SyncPending) {
                    Text(stringResource(R.string.sas_trust_pending), style = MaterialTheme.typography.labelLarge)
                    Text(stringResource(R.string.sas_sync_action_help))
                }
                if (peer == null && notice.phase == VerificationPhase.RoomChanged) Text(stringResource(R.string.sas_peer_left))
                if (notice.phase == VerificationPhase.Saving) {
                    Text(stringResource(R.string.sas_syncing))
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                }
                if (notice.phase == VerificationPhase.SyncPending || notice.phase == VerificationPhase.Failed) view.failure?.let { ErrorNote(it) }
                if (peer != null) PeerFingerprints(peer)
            }
        }, confirmButton = {
            if (notice.phase == VerificationPhase.SyncPending) TextButton({ act("sync") }) { Text(stringResource(R.string.sas_retry_sync)) }
            else if (peer != null && notice.phase == VerificationPhase.PeerBusy) {
                Button({ act("start") }) { Text(stringResource(R.string.sas_invite_again)) }
            } else if (peer != null && notice.phase in setOf(VerificationPhase.Cancelled, VerificationPhase.RoomChanged, VerificationPhase.PeerCancelled,
                    VerificationPhase.Expired, VerificationPhase.Failed, VerificationPhase.Mismatch)) {
                TextButton({ act("start") }) { Text(stringResource(R.string.sas_restart)) }
            }
        }, dismissButton = { TextButton(dismiss) {
            Text(stringResource(when (notice.phase) {
                VerificationPhase.Verified -> R.string.sas_finish_room
                VerificationPhase.SyncPending -> R.string.sas_later
                else -> R.string.sas_back_room
            }))
        } })
    }
}

@Composable internal fun SasDigits(numbers: List<Int>) {
    Surface(Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.primaryContainer) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
            numbers.forEachIndexed { index, number ->
                val group = stringResource(R.string.sas_group, index + 1)
                val spoken = spokenCodeGroup(index + 1, number)
                Row(Modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = spoken }.padding(vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Text(group, style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
                    Text(number.toString(), style = MaterialTheme.typography.headlineMedium.copy(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace))
                }
            }
        }
    }
}

@Composable internal fun RoomPeerActions(peer: GroupMember, view: RoomTrustView, controller: CallController, close: () -> Unit) {
    val trusted = peer.identity in view.trusted
    val friend = peer.identity in view.friends
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.member_identity_heading), Modifier.semantics { heading() },
            style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Note(if (trusted) R.drawable.ic_check else R.drawable.ic_notice,
            stringResource(if (trusted) R.string.verified_device else R.string.peer_device_unverified),
            color = if (trusted) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error)
        key(peer.identity) {
            RoomVerificationLauncher(view, controller, onStarted = close) { prepare ->
                FilledTonalButton({ prepare(peer) }) {
                    Text(stringResource(if (trusted) R.string.verify_again else R.string.verify_identity))
                }
            }
        }
        PeerFingerprints(peer)
        SettingsGroup {
            SettingsDisclosure(R.drawable.ic_person_add, stringResource(R.string.member_friendship),
                stringResource(if (friend) R.string.member_is_friend else R.string.members)) {
                if (friend) SettingsDescription(stringResource(R.string.identity_friend_added))
                else {
                    SettingsDescription(stringResource(R.string.friend_one_way))
                    TextButton({ controller.identityAction("friend", peer.identity) }) { Text(stringResource(R.string.add_friend)) }
                }
            }
        }
    }
}

@Composable private fun PeerFingerprints(peer: GroupMember) {
    val device = peer.binding?.device ?: return
    val fingerprint = remember(device.leaf) { sha256(device.leaf.base64Bytes(32)).toHexString() }
    key(peer.identity, device.leaf) {
        SettingsGroup {
            SettingsDisclosure(R.drawable.ic_key, stringResource(R.string.verification_fingerprints),
                fingerprint.take(8) + "…" + fingerprint.takeLast(8)) {
                Text(stringResource(R.string.peer_account_id), style = MaterialTheme.typography.labelLarge)
                SelectionContainer { Text(peer.identity.substringBefore('.')) }
                Text(stringResource(R.string.verification_account_fp), style = MaterialTheme.typography.labelLarge)
                IdentityFingerprint(device.accountKey)
                Text(stringResource(R.string.verification_device_fp), style = MaterialTheme.typography.labelLarge)
                IdentityFingerprint(device.leaf)
            }
        }
    }
}
