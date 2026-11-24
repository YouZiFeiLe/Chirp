package cn.youzifeile.chirp.ui

import cn.youzifeile.chirp.data.LogEvent
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.telecom.CallEndpointCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.media.*
import kotlinx.coroutines.launch
import java.util.UUID

@Composable
internal fun AudioSettings(activity: ComponentActivity, call: CallState, model: MainViewModel, back: () -> Unit) {
    LogScreen(LogEvent.audioSettings)
    val control = model.calls.audio
    val audio by control.state.collectAsStateWithLifecycle()
    val owner = rememberSaveable { UUID.randomUUID().toString() }
    val requestMic = rememberPermission(activity, ChirpPermission.Microphone) {
        control.startTest(owner)
    }
    DisposableEffect(control, owner) {
        control.openSettings(owner)
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_PAUSE) control.stopTest(owner = owner) }
        activity.lifecycle.addObserver(observer)
        onDispose { activity.lifecycle.removeObserver(observer); control.closeSettings(owner) }
    }
    AudioSettingsForm(audio, call, back, model::configureAudio, control::chooseInput, control::chooseIdleOutput,
        model.calls::chooseEndpoint, requestMic, { control.stopTest(play = it, owner = owner) }, model.calls::resumeAudio)
}

@Composable
internal fun AudioSettingsForm(audio: AudioState, call: CallState, back: () -> Unit,
    change: (AudioPreset, Boolean, Float) -> Unit = { _, _, _ -> }, chooseInput: (Int) -> Unit = {},
    chooseOutput: (Int) -> Unit = {}, chooseEndpoint: (CallEndpointCompat) -> Unit = {},
    startTest: () -> Unit = {}, stopTest: (Boolean) -> Unit = {}, resumeAudio: () -> Unit = {}) {
    fun configure(preset: AudioPreset = audio.preset, enabled: Boolean = audio.activation, threshold: Float = audio.threshold) =
        change(preset, enabled, threshold)
    SettingsPage(stringResource(R.string.audio_settings), back) {
        SettingsGroup(stringResource(R.string.audio_presets), inset = true) {
            Note(R.drawable.ic_lock, stringResource(R.string.audio_process_locally))
            Column(Modifier.selectableGroup()) {
                AudioPreset.entries.forEach { preset ->
                    RadioSetting(stringResource(preset.label()), audio.preset == preset,
                        onSelect = { configure(preset = preset) }, enabled = audio.test != MicrophoneTestPhase.Playing)
                }
            }
            if (audio.reading.processing && !audio.applied && audio.reading.preset != audio.preset) {
                Text(stringResource(R.string.preset_changing))
            }
            Text(stringResource(when {
                audio.applied -> R.string.preset_in_use
                call.micOn || audio.test == MicrophoneTestPhase.Starting -> R.string.preset_applying
                call.room != null -> R.string.preset_selected_muted
                else -> R.string.preset_saved
            }, stringResource(audio.preset.label())), style = MaterialTheme.typography.titleSmall)
            SettingsDescription(stringResource(when (audio.preset) {
                AudioPreset.RNNoise -> R.string.preset_desc_rnnoise
                AudioPreset.WebRTC -> R.string.preset_desc_webrtc
                AudioPreset.EchoOnly -> R.string.preset_desc_echo
            }))
            Note(R.drawable.ic_tune, stringResource(if (audio.preset.rnnoise) R.string.audio_rnnoise_on else R.string.audio_rnnoise_off))
            SettingsDescription(stringResource(R.string.audio_switch_help))
        }
        SettingsGroup(stringResource(R.string.voice_activation), inset = true) {
            AudioToggle(stringResource(R.string.voice_activation_enable), audio.activation) { configure(enabled = it) }
            Text(stringResource(R.string.voice_threshold, audio.threshold.toInt()))
            Slider(audio.threshold, { configure(threshold = it) }, valueRange = -80f..-10f, steps = 69, enabled = audio.activation)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                SettingsDescription(stringResource(R.string.more_sensitive))
                SettingsDescription(stringResource(R.string.more_quiet))
            }
            LinearProgressIndicator(progress = { audio.reading.level }, modifier = Modifier.fillMaxWidth(), color = if (audio.reading.open) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
            Text(if (audio.reading.processing) stringResource(R.string.voice_input_level, audio.reading.db.toInt()) else stringResource(R.string.voice_no_input), color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(stringResource(when {
                !audio.activation -> R.string.audio_activation_off
                !audio.reading.processing -> R.string.audio_wait_input
                audio.reading.open -> R.string.audio_activation_open
                else -> R.string.audio_activation_wait
            }))
            SettingsDescription(stringResource(R.string.audio_threshold_help))
            SettingsDescription(stringResource(R.string.audio_wait_capture))
        }
        val defaultRoute = stringResource(R.string.audio_default)
        val inputName = audio.inputs.find { it.id == audio.input }?.name ?: defaultRoute
        val outputName = if (call.room != null) call.endpoint?.outputLabel() else audio.outputs.find { it.id == audio.output }?.outputLabel()
        SettingsGroup {
            SettingsDisclosure(R.drawable.ic_mic, stringResource(R.string.audio_input), inputName) {
                Column(Modifier.selectableGroup()) {
                    RadioSetting(defaultRoute, audio.input == 0, { chooseInput(0) })
                    audio.inputs.forEach { device ->
                        RadioSetting(device.name, audio.input == device.id, { chooseInput(device.id) })
                    }
                }
            }
            SettingsDivider()
            SettingsDisclosure(R.drawable.ic_speaker, stringResource(R.string.audio_output), outputName ?: defaultRoute) {
                SettingsDescription(stringResource(R.string.audio_listening_help))
                Column(Modifier.selectableGroup()) {
                    if (call.room != null) call.endpoints.forEach { endpoint ->
                        RadioSetting(endpoint.outputLabel(), call.endpoint?.identifier == endpoint.identifier, { chooseEndpoint(endpoint) })
                    } else {
                        RadioSetting(defaultRoute, audio.output == 0, { chooseOutput(0) })
                        audio.outputs.forEach { device ->
                            RadioSetting(device.outputLabel(), audio.output == device.id, { chooseOutput(device.id) })
                        }
                    }
                }
            }
        }
        if (audio.fellBack) Notice(stringResource(R.string.audio_device_fallback))
        if (call.room != null && !call.listening) Note(R.drawable.ic_speaker, stringResource(R.string.listening_paused))
        if (call.routeChanging) Text(stringResource(R.string.audio_route_changing))
        SettingsGroup(stringResource(R.string.microphone_test), inset = true) {
            SettingsDescription(stringResource(R.string.microphone_test_detail))
            if (audio.test == MicrophoneTestPhase.Idle) {
                Button(startTest, enabled = call.room == null) { Text(stringResource(R.string.microphone_test_start)) }
            } else {
                Text(stringResource(when (audio.test) {
                    MicrophoneTestPhase.Starting -> R.string.microphone_test_starting
                    MicrophoneTestPhase.Measuring -> R.string.microphone_test_measuring
                    MicrophoneTestPhase.Playing -> R.string.microphone_test_playing
                    else -> R.string.microphone_test_stopping
                }))
                if (audio.test == MicrophoneTestPhase.Playing) LinearProgressIndicator(progress = { audio.progress }, modifier = Modifier.fillMaxWidth())
                FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedButton({ stopTest(false) }) { Text(stringResource(R.string.microphone_test_stop)) }
                    Button({ stopTest(true) }, enabled = audio.test == MicrophoneTestPhase.Measuring) {
                        Text(stringResource(R.string.microphone_test_listen))
                    }
                }
            }
            SettingsDescription(stringResource(R.string.permission_mic_purpose))
            if (call.room != null) SettingsDescription(stringResource(R.string.microphone_test_leave))
        }
        if (call.held) {
            Notice(stringResource(R.string.manual_resume_hint))
            Button(resumeAudio) { Text(stringResource(R.string.audio_resume_call)) }
        }
        if (audio.error == "AUDIO_PRESET_FAILED") {
            Text(stringResource(R.string.audio_kept, stringResource(audio.preset.label())))
            Text(stringResource(R.string.preset_unconfirmed_help))
        }
        if (audio.error != null) ErrorNote(audio.error) else call.failure?.let { ErrorNote(it) }
    }
}

@Composable
internal fun AudioToggle(title: String, checked: Boolean, change: (Boolean) -> Unit) {
    androidx.compose.foundation.layout.Row(Modifier.fillMaxWidth().toggleable(checked, role = androidx.compose.ui.semantics.Role.Switch, onValueChange = change).heightIn(min = 48.dp), horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f)); Switch(checked, null)
    }
}

internal fun AudioPreset.label() = when (this) {
    AudioPreset.RNNoise -> R.string.preset_rnnoise
    AudioPreset.WebRTC -> R.string.preset_webrtc
    AudioPreset.EchoOnly -> R.string.preset_echo
}

@Composable
private fun AudioDevice.outputLabel() = when (type) {
    android.media.AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> stringResource(R.string.audio_earpiece)
    android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> stringResource(R.string.audio_speaker)
    else -> name
}

@Composable
private fun CallEndpointCompat.outputLabel() = when (type) {
    CallEndpointCompat.TYPE_EARPIECE -> stringResource(R.string.audio_earpiece)
    CallEndpointCompat.TYPE_SPEAKER -> stringResource(R.string.audio_speaker)
    else -> name.toString()
}

@Composable
internal fun MemberAudioDialog(member: RoomMember, call: CallState, model: CallController, dismiss: () -> Unit) {
    val volume = call.volumes[member.identity] ?: 1f
    ChirpDialog(icon = R.drawable.ic_speaker, onDismissRequest = dismiss, title = { Text(member.name) }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            val tracks = call.diagnostics.filter { it.identity == member.identity }
            Text(stringResource(R.string.member_audio_title), style = MaterialTheme.typography.titleMedium)
            val status = memberAudioStatus(member.present, tracks)
            val statusText = if (status == MemberAudioStatus.DecryptionFailed && tracks.any { it.decryptionFailure == VoiceFailure.MissingKey })
                R.string.track_key_missing else status.label()
            Text(stringResource(R.string.member_status_heading), style = MaterialTheme.typography.labelMedium)
            MemberAudioIndicators(member, showLabels = true)
            Text(stringResource(statusText), color = if (status == MemberAudioStatus.DecryptionFailed) MaterialTheme.colorScheme.error
                else MaterialTheme.colorScheme.onSurface)
            HorizontalDivider()
            Text(stringResource(R.string.member_volume, (volume * 100).toInt()), style = MaterialTheme.typography.titleSmall)
            SettingsDescription(stringResource(R.string.volume_local_help))
            Slider(volume, { model.setMemberVolume(member.identity, it) }, valueRange = 0f..2f, steps = 39)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton({ model.toggleMemberMute(member.identity) }) {
                    Text(stringResource(if (volume == 0f) R.string.member_restore_volume else R.string.member_local_mute))
                }
                TextButton({ model.setMemberVolume(member.identity, 1f) }) { Text(stringResource(R.string.member_reset_volume)) }
            }
            call.trust.peers.find { it.identity == member.identity }?.let { peer ->
                RoomPeerActions(peer, call.trust, model, dismiss)
            }
            if (tracks.isNotEmpty()) SettingsGroup {
                SettingsDisclosure(R.drawable.ic_waveform, stringResource(R.string.connections_heading),
                    stringResource(R.string.track_local_observations)) {
                    if (member.microphoneEnabled == false) SettingsDescription(stringResource(R.string.muted_stats_note))
                    tracks.forEachIndexed { index, track ->
                        Text(stringResource(R.string.track_index, index + 1), style = MaterialTheme.typography.titleSmall)
                        Text(stringResource(if (track.subscribed) R.string.track_subscribed else R.string.track_unsubscribed))
                        Text(qualityLabel(track.quality))
                        track.jitterMS?.let { Text(stringResource(R.string.track_jitter, it.toInt())) }
                        track.averageJitterBufferMS?.let { Text(stringResource(R.string.track_average_jitter_buffer, it.toInt())) }
                        track.roundTripMS?.let { Text(stringResource(R.string.track_rtt, it.toInt())) }
                        track.lost?.let { Text(stringResource(R.string.track_lost, it)) }
                        track.received?.let { Text(stringResource(R.string.track_received, it)) }
                        track.decryptionFailure?.let {
                            Text(stringResource(R.string.encryption_track_label), style = MaterialTheme.typography.labelSmall)
                            Text(stringResource(if (it == VoiceFailure.MissingKey) R.string.track_key_missing else R.string.track_decrypt_failed))
                        }
                        track.lastDecryptionMS?.let {
                            val seconds = (it / 1000).coerceIn(0, Int.MAX_VALUE.toLong()).toInt()
                            Text(pluralStringResource(R.plurals.track_decrypted, seconds, seconds))
                        }
                    }
                }
            }
        }
    }, confirmButton = { TextButton(dismiss) { Text(stringResource(R.string.close)) } })
}

private fun MemberAudioStatus.label(): Int = when (this) {
    MemberAudioStatus.NoTransport -> R.string.track_no_transport
    MemberAudioStatus.NoTrack -> R.string.track_not_published
    MemberAudioStatus.Muted -> R.string.microphone_off
    MemberAudioStatus.NetworkLost -> R.string.track_network_lost
    MemberAudioStatus.SubscriptionFailed -> R.string.track_subscription_failed
    MemberAudioStatus.Unsubscribed -> R.string.track_unsubscribed
    MemberAudioStatus.DecryptionFailed -> R.string.track_decrypt_failed
    MemberAudioStatus.Verified -> R.string.track_verified
    MemberAudioStatus.Waiting -> R.string.track_waiting
}

@Composable
private fun qualityLabel(quality: String): String = stringResource(when (quality) {
    "EXCELLENT" -> R.string.quality_excellent
    "GOOD" -> R.string.quality_good
    "POOR" -> R.string.quality_poor
    "LOST" -> R.string.quality_lost
    else -> R.string.quality_unknown
})

@Composable
internal fun StorageSettings(model: MainViewModel, back: () -> Unit) {
    LogScreen(LogEvent.storageSettings)
    var bytes by remember { mutableLongStateOf(0L) }
    var busy by remember { mutableStateOf(false) }
    var cleared by remember { mutableStateOf(false) }
    var confirmClear by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val context = androidx.compose.ui.platform.LocalContext.current
    LaunchedEffect(model) { while (true) { bytes = model.calls.attachmentCacheSize(); kotlinx.coroutines.delay(1000) } }
    SettingsPage(stringResource(R.string.storage_cache), back) {
        Surface(Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.secondaryContainer) {
            Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Note(R.drawable.ic_attach, stringResource(R.string.cache_size), color = MaterialTheme.colorScheme.onSecondaryContainer)
                Text(android.text.format.Formatter.formatFileSize(context, bytes), style = MaterialTheme.typography.displaySmall)
            }
        }
        SettingsGroup {
            SettingRow(R.drawable.ic_attach, stringResource(R.string.cache_clear), stringResource(R.string.cache_auto_clear),
                onClick = { confirmClear = true }, enabled = !busy, destructive = true)
        }
        if (busy) {
            LinearProgressIndicator(Modifier.fillMaxWidth())
            Text(stringResource(R.string.cache_clearing))
        }
        if (cleared) Notice(stringResource(R.string.cache_cleared), icon = R.drawable.ic_check)
        error?.let { ErrorNote(it) }
    }
    if (confirmClear) {
        ConfirmDestructiveAction(
            R.string.cache_clear_question, stringResource(R.string.cache_clear_effects), R.string.cache_clear,
            close = { confirmClear = false },
            action = {
                busy = true
                error = null
                cleared = false
                scope.launch {
                    try {
                        model.calls.clearAttachmentCache()
                        bytes = model.calls.attachmentCacheSize()
                        cleared = true
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        throw e
                    } catch (_: Exception) {
                        error = "ATTACHMENT_CACHE_CLEAR_FAILED"
                    } finally {
                        busy = false
                    }
                }
            },
            icon = R.drawable.ic_attach,
        )
    }
}
