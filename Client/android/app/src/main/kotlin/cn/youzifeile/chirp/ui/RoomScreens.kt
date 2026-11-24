package cn.youzifeile.chirp.ui

import cn.youzifeile.chirp.data.LogEvent
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.ComponentActivity
import androidx.compose.foundation.Image
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Badge
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Tab
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.AttachmentInfo
import cn.youzifeile.chirp.data.Profile
import cn.youzifeile.chirp.data.RoomInfo
import cn.youzifeile.chirp.media.CallController
import cn.youzifeile.chirp.media.CallPhase
import cn.youzifeile.chirp.media.CallState
import cn.youzifeile.chirp.media.ChatMessage
import cn.youzifeile.chirp.media.Delivery
import cn.youzifeile.chirp.media.RoomMember
import cn.youzifeile.chirp.media.TransferPhase
import cn.youzifeile.chirp.media.TransferState
import cn.youzifeile.chirp.media.validChatText
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.launch

@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class, androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun RoomScreen(
    activity: ComponentActivity, room: RoomInfo, state: MainState, call: CallState, model: MainViewModel,
    back: (() -> Unit)?, audio: () -> Unit,
) {
    LogScreen(LogEvent.room, room.id)
    val controller = model.calls
    val here = call.room?.id == room.id
    val pending = here && call.phase != CallPhase.Leaving && call.trust.pending
    val colors = MaterialTheme.colorScheme
    val canvas = if (pending) lerp(colors.surface, colors.errorContainer, .55f) else colors.surface
    val chatVisible = here && call.chatVisible
    var chat by rememberSaveable(room.id) { mutableStateOf(false) }
    var password by remember(room.id) { mutableStateOf(false) }
    val joinError = state.joinFailure?.takeIf { it.roomId == room.id }?.reason
    LaunchedEffect(room.id, joinError) {
        if (joinError?.code in setOf("ROOM_PASSWORD_REQUIRED", "ROOM_PASSWORD_CHANGED", "ROOM_PASSWORD_INCORRECT") ||
            joinError?.code == "ROOM_PREFLIGHT_EXPIRED" && room.passwordRequired) {
            password = true
        }
    }
    var menu by remember { mutableStateOf(false) }
    LogScreen(if (chatVisible && chat) LogEvent.roomChat else LogEvent.roomMembers, room.id)
    var showInformation by rememberSaveable(room.id) { mutableStateOf(false) }
    if (showInformation) RoomInformationSheet(room, call.takeIf { here }) { showInformation = false }
    var lastRead by rememberSaveable(call.entryID) { mutableStateOf<String?>(null) }
    val unread = remember(chat, lastRead, call.messages) {
        if (chat) 0 else {
            val messages = call.messages
            val start = messages.indexOfFirst { it.id == lastRead } + 1
            messages.subList(start, messages.size).count { !it.own }
        }
    }
    LaunchedEffect(chat, call.messages.lastOrNull()?.id) { if (chat) lastRead = call.messages.lastOrNull()?.id }
    val membersScroll = rememberLazyGridState()
    val scrolledPastHeader by remember { derivedStateOf { membersScroll.firstVisibleItemIndex > 0 } }
    var microphoneEntry by remember(call.entryID) { mutableStateOf<String?>(null) }
    val requestMic = rememberPermission(activity, ChirpPermission.Microphone) {
        if (microphoneEntry != null && microphoneEntry == controller.state.value.entryID) controller.setMic(true)
    }
    val join = {
        controller.clearError()
        model.dismissJoinError(room.id)
        if (room.passwordRequired) password = true else model.join(room, "")
    }
    LaunchedEffect(chatVisible) { if (!chatVisible) chat = false }
    val typing = chat && WindowInsets.isImeVisible
    val compactTyping = compactWindowHeight() && typing
    Scaffold(
        modifier = Modifier.imePadding(),
        topBar = {
            if (!compactTyping) {
                val title = if (chat || scrolledPastHeader) room.title() else if (back != null) stringResource(R.string.rooms) else ""
                ScreenBar(title, back, containerColor = canvas) {
                    Box {
                        IconButton(onClick = { menu = true }) {
                            Glyph(R.drawable.ic_more, label = stringResource(R.string.room_options))
                        }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(text = { Text(stringResource(R.string.room_information)) },
                                leadingIcon = { Glyph(R.drawable.ic_notice) }, onClick = { menu = false; showInformation = true })
                            DropdownMenuItem(text = { Text(stringResource(R.string.audio_settings)) },
                                leadingIcon = { Glyph(R.drawable.ic_tune) }, onClick = { menu = false; audio() })
                        }
                    }
                }
            }
        },
        containerColor = canvas, contentColor = colors.onSurface,
        bottomBar = {
            if (!typing) RoomActions(room, here, state.directory?.fresh == true, call, join,
                controller::leave, { if (call.micOn) controller.setMic(false) else { microphoneEntry = call.entryID; requestMic() } },
                { controller.setListening(!call.listening) }, state.preparingRoom, model::cancelJoin)
        },
    ) { insets ->
        Column(Modifier.fillMaxSize().padding(insets).consumeWindowInsets(insets)) {
            if (pending) key(room.id, call.entryID) {
                RoomVerificationLauncher(call.trust, controller) { prepare -> RoomVerificationBanner(call.trust, prepare) }
            }
            if (call.leftRoom == room.id && state.preparingRoom == null) {
                Note(R.drawable.ic_group, stringResource(R.string.room_left),
                    Modifier.padding(horizontal = 20.dp, vertical = 4.dp).semantics { liveRegion = LiveRegionMode.Polite })
            }
            if (!password) joinError?.let {
                Box(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) { ErrorNote(it) }
            }
            if (here && !compactTyping && call.trust.notice == null) call.trust.failure?.let {
                Box(Modifier.align(Alignment.CenterHorizontally).widthIn(max = 640.dp).fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp)) { ErrorNote(it) }
            }
            if (chatVisible && !compactTyping) {
                RoomTabs(chat, unread, canvas, onSelectChat = { chat = it })
            }
            val members: @Composable () -> Unit = {
                RoomMembers(
                    room, state.directory?.fresh == true, call.takeIf { here },
                    call.failure?.takeIf { call.errorRoom == room.id }, state.directory?.members.orEmpty(),
                    state.account?.id, membersScroll, model::avatar, audio, controller, { showInformation = true },
                )
            }
            if (chatVisible) {
                AnimatedContent(
                    targetState = chat,
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    transitionSpec = {
                        val enter = fadeIn(tween(210)) + slideInHorizontally(tween(240)) {
                            if (targetState) it / 32 else -it / 32
                        }
                        enter togetherWith fadeOut(tween(100))
                    },
                    label = "Room tab",
                ) { showChat ->
                    if (showChat) RoomChatPanel(call, controller, canvas) else members()
                }
            } else members()
        }
    }
    if (password) {
        var value by remember { mutableStateOf("") }
        val checking = state.preparingRoom == room.id
        val tooLong = value.length > 512 || value.toByteArray(Charsets.UTF_8).size > 512
        val canJoin = value.isNotEmpty() && !tooLong && !checking && state.directory?.fresh == true
        val dismiss = { if (!checking) { value = ""; password = false; model.dismissJoinError(room.id) } }
        val confirm = { if (canJoin) model.join(room, value) }
        val switch = call.room != null && !here
        LaunchedEffect(here) { if (here) { value = ""; password = false } }
        ChirpDialog(
            icon = R.drawable.ic_lock,
            onDismissRequest = dismiss,
            title = { Text(stringResource(R.string.room_password)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(stringResource(if (switch) R.string.room_password_switch_target else R.string.room_password_for_room,
                        room.title()))
                    PasswordField(value, { value = it; model.dismissJoinError(room.id) }, R.string.room_password,
                        enabled = !checking, isError = tooLong || joinError?.code == "ROOM_PASSWORD_INCORRECT", onDone = confirm)
                    if (tooLong) ErrorNote("CLIENT_PASSWORD_TOO_LONG")
                    if (checking) {
                        LinearProgressIndicator(Modifier.fillMaxWidth())
                        Text(stringResource(if (switch) R.string.join_verifying_switch else R.string.room_verifying),
                            Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                    } else if (state.directory?.fresh != true) {
                        Note(R.drawable.ic_link, stringResource(R.string.waiting_directory))
                    }
                    joinError?.let { ErrorNote(it) }
                }
            },
            confirmButton = { Button(confirm, enabled = canJoin) { Text(stringResource(R.string.verify_and_join)) } },
            dismissButton = { TextButton(dismiss, enabled = !checking) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

@Composable
private fun RoomTabs(chatSelected: Boolean, unread: Int, canvas: Color, onSelectChat: (Boolean) -> Unit) {
    val label = stringResource(R.string.room_content)
    val unreadDescription = if (unread > 0) stringResource(R.string.room_unread_description, unread) else null
    PrimaryTabRow(selectedTabIndex = if (chatSelected) 1 else 0, containerColor = canvas,
        modifier = Modifier.semantics { contentDescription = label }) {
        Tab(selected = !chatSelected, onClick = { onSelectChat(false) },
            text = { Text(stringResource(R.string.members)) })
        Tab(selected = chatSelected, onClick = { onSelectChat(true) }, text = {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.chat))
                if (unreadDescription != null) Badge(Modifier.clearAndSetSemantics { contentDescription = unreadDescription }) {
                    Text(if (unread > 99) "99+" else unread.toString())
                }
            }
        })
    }
}

@Composable
private fun RoomMembers(
    room: RoomInfo, fresh: Boolean, call: CallState?, error: cn.youzifeile.chirp.data.ClientFailure?, profiles: List<Profile>,
    ownID: String?, scroll: LazyGridState, load: (suspend (Profile) -> android.graphics.Bitmap?)?, audio: () -> Unit,
    controller: CallController, information: () -> Unit,
) {
    var audioMember by rememberSaveable(call?.entryID) { mutableStateOf<String?>(null) }
    val secure = call?.phase == CallPhase.Connected && !call.trust.pending
    val members = when {
        call != null && call.trust.pending -> {
            // The media directory can be empty while the room is waiting for mutual verification.
            (call.trust.peers + listOfNotNull(call.trust.localMember)).map { RoomMember(it.identity, it.name) }
        }
        call?.phase == CallPhase.Connected -> call.members
        fresh -> room.participants.orEmpty().map { RoomMember(it.id, it.name) }
        else -> emptyList()
    }
    val membersKnown = secure || call?.trust?.pending == true || fresh && room.participants != null
    val profileMap = remember(profiles) { profiles.associateBy { it.id } }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        val minimumColumn = if (LocalDensity.current.fontScale > 1.3f) 280.dp else 216.dp
        LazyVerticalGrid(
            GridCells.Adaptive(minimumColumn),
            Modifier.widthIn(max = 640.dp).fillMaxSize(),
            state = scroll,
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item("room", span = { GridItemSpan(maxLineSpan) }) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    RoomBanner(room, information)
                    if (error != null) {
                        ErrorNote(error)
                        if (error.code == "ROOM_IDENTITY_REVOKED") {
                            Text(stringResource(R.string.voice_stopped), style = MaterialTheme.typography.titleSmall)
                            Text(stringResource(R.string.voice_stopped_help))
                        }
                    }
                }
            }
            item("members", span = { GridItemSpan(maxLineSpan) }) {
                SectionHeading(stringResource(R.string.members), Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                    trailing = if (membersKnown) members.size.toString() else null)
            }
            if (members.isEmpty()) item("empty", span = { GridItemSpan(maxLineSpan) }) {
                val unknown = !membersKnown
                EmptyState(R.drawable.ic_group, stringResource(if (unknown) R.string.room_unavailable else R.string.room_empty_title),
                    stringResource(if (unknown) R.string.room_members_stale_help else R.string.room_empty_body))
            }
            items(members, key = RoomMember::identity) { member ->
                val memberID = member.identity.substringBefore('.')
                val profile = profileMap[memberID]
                val peer = call?.trust?.peers?.find { it.identity == member.identity }
                val own = call?.entryID?.let { it == member.identity.substringAfterLast('.') } ?: (memberID == ownID)
                val display = if (secure) member.copy(speaking = member.speaking && call?.held != true)
                    else member.copy(name = peer?.name ?: profile?.name ?: member.name)
                MemberCard(display, call != null, own, profile, load,
                    verified = peer?.let { it.identity in call.trust.trusted },
                    onClick = if (secure && !own) ({ audioMember = member.identity }) else peer?.let { { audioMember = it.identity } })
            }
            item("audio", span = { GridItemSpan(maxLineSpan) }) {
                Box(Modifier.padding(top = 10.dp)) {
                    SettingRow(R.drawable.ic_tune, stringResource(R.string.audio_settings),
                        stringResource(controller.audio.state.collectAsStateWithLifecycle().value.preset.label()), audio)
                }
            }
        }
    }
    if (call != null && audioMember != null && call.trust.verification == null && call.trust.notice == null) {
        LogScreen(LogEvent.memberAudio, audioMember)
        val member = call.members.find { it.identity == audioMember }
        val peer = call.trust.peers.find { it.identity == audioMember }
        val dismiss = { audioMember = null }
        if (secure && member != null) MemberAudioDialog(member, call, controller, dismiss)
        else if (peer != null) ChirpDialog(icon = R.drawable.ic_group, onDismissRequest = dismiss, title = { Text(peer.name) },
            text = { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                MemberAudioIndicators(RoomMember(peer.identity, peer.name), showLabels = true)
                RoomPeerActions(peer, call.trust, controller, dismiss)
            } },
            confirmButton = { TextButton(dismiss) { Text(stringResource(R.string.close)) } })
        else if (secure) ChirpDialog(icon = R.drawable.ic_group, onDismissRequest = dismiss,
            title = { Text(stringResource(R.string.room_peer_left)) },
            text = { Text(stringResource(R.string.room_member_left_detail)) }, confirmButton = { TextButton(dismiss) { Text(stringResource(R.string.close)) } })
    }
}

@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun RoomBanner(room: RoomInfo, open: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val info = stringResource(R.string.room_info_open)
    val shape = MaterialTheme.shapes.extraLarge
    Surface(Modifier.fillMaxWidth(), shape = shape, color = colors.surfaceContainerLow) {
        Box(Modifier.clip(shape).clickable(onClickLabel = info, role = Role.Button, onClick = open)) {
            if (LocalDensity.current.fontScale <= 1.4f) {
                SignalArtwork(Modifier.matchParentSize(), colors.primary, colors.tertiary,
                    trailing = true, emphasis = .24f)
            }
            Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Note(if (room.passwordRequired) R.drawable.ic_lock else R.drawable.ic_waveform,
                        stringResource(if (room.passwordRequired) R.string.room_kind_locked else R.string.room_kind_open),
                        modifier = Modifier.weight(1f), color = colors.primary)
                    Glyph(R.drawable.ic_notice, tint = colors.onSurfaceVariant)
                }
                Text(room.title(), Modifier.semantics { heading() }, style = MaterialTheme.typography.headlineLarge)
                Text(room.displayDescription(), style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant,
                    maxLines = 2, overflow = TextOverflow.Ellipsis)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Note(R.drawable.ic_lock, stringResource(R.string.encrypted_voice))
                    Note(R.drawable.ic_group, if (room.maxParticipants > 0) stringResource(R.string.info_limit, room.maxParticipants)
                        else stringResource(R.string.unlimited))
                }
            }
        }
    }
}

@Composable
private fun MemberCard(member: RoomMember, inRoom: Boolean, own: Boolean, profile: Profile?,
    load: (suspend (Profile) -> android.graphics.Bitmap?)?, verified: Boolean?, onClick: (() -> Unit)? = null) {
    val colors = MaterialTheme.colorScheme
    val talking = inRoom && member.speaking && member.microphoneEnabled == true && member.present
    val background by animateColorAsState(
        if (talking) colors.tertiaryContainer else colors.surfaceContainerLow,
        animationSpec = tween(180), label = "Speaking highlight",
    )
    val foreground = if (talking) colors.onTertiaryContainer else colors.onSurface
    val action = if (onClick == null) Modifier else Modifier.clickable(
        role = Role.Button, onClickLabel = stringResource(R.string.member_action_label), onClick = onClick)
    Surface(Modifier.clip(MaterialTheme.shapes.medium).then(action), shape = MaterialTheme.shapes.medium,
        color = background, contentColor = foreground,
        border = if (verified == false) BorderStroke(1.dp, colors.error.copy(alpha = .48f)) else null) {
        Row(Modifier.fillMaxWidth().padding(12.dp).semantics(mergeDescendants = true) {},
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Avatar(member.identity, member.name, profile, load, 46.dp, talking)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(member.name, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                if (own) Text(stringResource(R.string.me), style = MaterialTheme.typography.labelMedium)
                if (verified == false) Row(verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Glyph(R.drawable.ic_notice, Modifier.size(16.dp), tint = colors.error)
                    Text(stringResource(R.string.trust_your_turn), style = MaterialTheme.typography.labelMedium, color = colors.error)
                }
                if (inRoom) Row(horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    MemberAudioIndicators(member)
                    if (talking) {
                        SpeechSignal(colors.onTertiaryContainer, Modifier.size(16.dp))
                        Text(stringResource(R.string.speaking), style = MaterialTheme.typography.labelMedium,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            if (verified == true) Glyph(R.drawable.ic_check, Modifier.size(18.dp), label = stringResource(R.string.room_trust_signature))
        }
    }
}

@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
internal fun MemberAudioIndicators(member: RoomMember, showLabels: Boolean = false) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        MemberAudioIndicator(member.microphoneEnabled, R.drawable.ic_mic, R.drawable.ic_mic_off,
            stringResource(when (member.microphoneEnabled) {
                true -> R.string.microphone_on
                false -> R.string.microphone_muted
                null -> R.string.microphone_pending
            }), showLabels)
        MemberAudioIndicator(member.listening, R.drawable.ic_speaker, R.drawable.ic_speaker_off,
            stringResource(when (member.listening) {
                true -> R.string.listening_on
                false -> R.string.listening_paused
                null -> R.string.listening_pending
            }), showLabels)
    }
}

@Composable
private fun MemberAudioIndicator(enabled: Boolean?, onIcon: Int, offIcon: Int, label: String, showLabel: Boolean) {
    val icon = if (enabled == false) offIcon else onIcon
    val color = if (enabled == true) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
    if (showLabel) {
        Note(icon, label, color = color)
    } else {
        Row(Modifier.clearAndSetSemantics { contentDescription = label }, verticalAlignment = Alignment.CenterVertically) {
            Glyph(icon, Modifier.size(20.dp), tint = color)
            if (enabled == null) Text("?", color = color, style = MaterialTheme.typography.labelSmall)
        }
    }
}

@Composable
private fun RoomActions(
    room: RoomInfo, here: Boolean, fresh: Boolean, call: CallState, join: () -> Unit,
    leave: () -> Unit, mic: () -> Unit, listen: () -> Unit,
    preparingRoom: String?, cancelJoin: () -> Unit,
) {
    val compact = compactWindowHeight()
    val colors = MaterialTheme.colorScheme
    Surface(color = colors.surfaceContainerLow) {
        Box(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)),
            contentAlignment = Alignment.Center) {
            Column(Modifier.widthIn(max = 640.dp).fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = if (compact) 4.dp else 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                val other = call.room
                if (preparingRoom != null) {
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(stringResource(when {
                            other != null && other.id != preparingRoom && call.phase == CallPhase.Leaving -> R.string.leaving_for_switch
                            other != null && other.id != preparingRoom -> R.string.join_verifying_switch
                            else -> R.string.joining_voice
                        }), Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                        TextButton(cancelJoin) { Text(stringResource(R.string.cancel)) }
                    }
                } else if (!here) {
                    val available = fresh && room.participants != null
                    Note(if (other == null) R.drawable.ic_mic_off else R.drawable.ic_waveform, when {
                        other != null -> stringResource(R.string.current_call, other.title())
                        available -> stringResource(R.string.join_muted)
                        else -> stringResource(R.string.waiting_directory)
                    })
                    Button(join, Modifier.fillMaxWidth().heightIn(min = 48.dp), enabled = available) {
                        Glyph(R.drawable.ic_waveform)
                        Text(stringResource(if (other == null) R.string.join_room else R.string.room_switch), Modifier.padding(start = 8.dp))
                    }
                } else {
                    if (call.phase == CallPhase.Securing && !call.held && !call.chatVisible && !call.trust.pending) {
                        Text(stringResource(R.string.secure_preparing_mic), style = MaterialTheme.typography.bodyMedium)
                    }
                    if (!compact || call.phase != CallPhase.Connected || call.held) {
                        Note(if (call.phase == CallPhase.Connected) R.drawable.ic_lock else R.drawable.ic_waveform, call.status(),
                            Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                    }
                    val ready = call.phase == CallPhase.Connected && !call.held && !call.trust.pending
                    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        CallControl(Modifier.weight(1f), if (call.micOn) R.drawable.ic_mic else R.drawable.ic_mic_off,
                            stringResource(when { call.micChanging -> R.string.mic_changing; call.micOn -> R.string.mute_mic; else -> R.string.enable_mic }),
                            ready && !call.micChanging,
                            if (call.micOn) colors.tertiaryContainer else colors.primary,
                            if (call.micOn) colors.onTertiaryContainer else colors.onPrimary, mic,
                            state = stringResource(if (call.micOn) R.string.microphone_on else R.string.microphone_off),
                            active = call.micOn)
                        CallControl(Modifier.weight(1f), if (call.listening) R.drawable.ic_speaker else R.drawable.ic_speaker_off,
                            stringResource(if (call.listening) R.string.listen_off else R.string.resume_listening),
                            ready,
                            if (call.listening) colors.secondaryContainer else colors.surfaceContainerHighest,
                            if (call.listening) colors.onSecondaryContainer else colors.onSurface, listen,
                            state = stringResource(if (call.listening) R.string.room_listening_active else R.string.listening_paused),
                            active = call.listening)
                        CallControl(Modifier.weight(1f), R.drawable.ic_call_end, stringResource(R.string.leave_room),
                            call.phase != CallPhase.Leaving, colors.errorContainer, colors.onErrorContainer, leave)
                    }
                }
            }
        }
    }
}

@Composable
private fun CallControl(modifier: Modifier, icon: Int, label: String, enabled: Boolean,
    container: Color, ink: Color, onClick: () -> Unit, state: String? = null, active: Boolean = false) {
    val corner by animateDpAsState(if (active) 14.dp else 24.dp,
        spring(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = Spring.StiffnessMedium), label = "Call control shape")
    val fill by animateColorAsState(container, animationSpec = tween(180), label = "Call control color")
    val textColor by animateColorAsState(ink, animationSpec = tween(180), label = "Call control content color")
    FilledTonalButton(onClick, modifier.fillMaxHeight().semantics { if (state != null) stateDescription = state },
        enabled = enabled, shape = RoundedCornerShape(corner),
        colors = ButtonDefaults.filledTonalButtonColors(containerColor = fill, contentColor = textColor),
        contentPadding = PaddingValues(horizontal = 6.dp, vertical = 8.dp)) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Glyph(icon, Modifier.size(20.dp))
            Text(label, style = MaterialTheme.typography.labelMedium, textAlign = TextAlign.Center)
        }
    }
}

@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
internal fun RoomChatPanel(call: CallState, controller: CallController, canvas: Color = MaterialTheme.colorScheme.surface) {
    var chooser by remember(call.entryID, call.cacheRevision) { mutableStateOf(false) }
    var file by remember(call.entryID, call.cacheRevision) { mutableStateOf<AttachmentInfo?>(null) }
    var exportID by rememberSaveable { mutableStateOf<String?>(null) }
    var exportEntry by rememberSaveable { mutableStateOf<String?>(null) }
    var exportRevision by rememberSaveable { mutableLongStateOf(0L) }
    var pickerEntry by rememberSaveable { mutableStateOf<String?>(null) }
    var pickerRevision by rememberSaveable { mutableLongStateOf(0L) }
    val choosePhoto = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri?.let { controller.sendFile(it, pickerEntry, pickerRevision) }
    }
    val chooseFile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let { controller.sendFile(it, pickerEntry, pickerRevision) }
    }
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val id = exportID
        exportID = null
        if (id != null && uri != null) controller.export(id, uri, exportEntry, exportRevision)
    }
    val selectedFile = file
    if (selectedFile != null) {
        val ready = call.attachments[selectedFile.id]?.phase == TransferPhase.Available
        if (ready) {
            AttachmentDialog(selectedFile, controller, onDismiss = { file = null }) {
                exportID = selectedFile.id
                exportEntry = call.entryID
                exportRevision = call.cacheRevision
                export.launch(selectedFile.name)
            }
        } else {
            LaunchedEffect(selectedFile) { file = null }
        }
    }
    var editor by remember(call.entryID) {
        mutableStateOf(TextFieldValue(call.draft, TextRange(call.draft.length)))
    }
    LaunchedEffect(call.entryID, call.draft) {
        // Activity collects call state asynchronously. Only apply an external clear or restoration
        // if this snapshot still matches the controller, preserving newer IME text and selection.
        val current = controller.state.value
        if (current.entryID == call.entryID && current.draft == call.draft && editor.text != call.draft) {
            editor = TextFieldValue(call.draft, TextRange(call.draft.length))
        }
    }
    val draft = editor.text
    val messages = call.messages
    val scroll = rememberLazyListState(initialFirstVisibleItemIndex = messages.lastIndex.coerceAtLeast(0))
    val scrollScope = rememberCoroutineScope()
    var followLatest by rememberSaveable(call.entryID) { mutableStateOf(true) }
    val threshold = with(LocalDensity.current) { 100.dp.roundToPx() }
    LaunchedEffect(scroll, threshold, call.entryID, messages.lastOrNull()?.id) {
        val newest = messages.lastOrNull() ?: return@LaunchedEffect
        if (newest.own || followLatest) {
            scroll.scrollToItem(messages.lastIndex)
            val layout = scroll.layoutInfo
            layout.visibleItemsInfo.lastOrNull { it.key == newest.id }?.let { item ->
                val remaining = item.offset + item.size + layout.afterContentPadding - layout.viewportEndOffset
                if (remaining > 0) scroll.scrollBy(remaining.toFloat())
            }
        }
        snapshotFlow {
            val layout = scroll.layoutInfo
            val last = layout.visibleItemsInfo.lastOrNull()
            when {
                layout.totalItemsCount != messages.size || last == null -> null
                last.index != messages.lastIndex -> false
                last.key != newest.id -> null
                else -> last.offset + last.size + layout.afterContentPadding - layout.viewportEndOffset < threshold
            }
        }.collect { near -> if (near != null) followLatest = near }
    }
    Box(Modifier.fillMaxSize().background(canvas), contentAlignment = Alignment.TopCenter) {
        Column(Modifier.widthIn(max = 640.dp).fillMaxSize()) {
            if (messages.isEmpty()) {
                BoxWithConstraints(Modifier.fillMaxWidth().weight(1f).padding(16.dp), contentAlignment = Alignment.Center) {
                    if (maxHeight < 180.dp) {
                        if (maxHeight >= 32.dp) Note(R.drawable.ic_chat, stringResource(R.string.chat_empty_title))
                    } else {
                        Column(Modifier.widthIn(max = 320.dp), horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            EmptyState(R.drawable.ic_chat, stringResource(R.string.chat_empty_invitation), stringResource(R.string.chat_empty_body))
                            Note(R.drawable.ic_lock, stringResource(R.string.encrypted_chat))
                        }
                    }
                }
            } else {
                if (!compactWindowHeight() && !WindowInsets.isImeVisible) Note(R.drawable.ic_lock, stringResource(R.string.encrypted_chat),
                    Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = scroll,
                    verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(20.dp)) {
                    items(messages, key = ChatMessage::id) { message ->
                        val info = message.attachment
                        MessageBubble(message, call.attachments[info?.id], controller, call.cacheRevision, call.entryID,
                            draft.isEmpty() && !call.held && call.phase == CallPhase.Connected, onFile = {
                            if (info != null) {
                                if (call.attachments[info.id]?.phase in setOf(TransferPhase.Waiting, TransferPhase.Retryable, TransferPhase.Paused)) controller.retryAttachment(info.id)
                                else file = info
                            }
                        })
                    }
                }
                if (!followLatest && !WindowInsets.isImeVisible) {
                    OutlinedButton(
                        onClick = { scrollScope.launch { scroll.animateScrollToItem(messages.lastIndex) } },
                        modifier = Modifier.align(Alignment.CenterHorizontally).padding(top = 4.dp),
                    ) { Text(stringResource(R.string.return_to_latest)) }
                }
            }
            val error = call.error
            if (call.phase != CallPhase.Connected || call.held || call.trust.pending) Text(stringResource(when {
                call.held -> R.string.call_held
                error == "AUTHORIZATION_STALE" -> R.string.chat_auth_expired
                call.trust.pending -> R.string.chat_paused_untrusted
                else -> R.string.chat_reconnecting
            }), Modifier.padding(horizontal = 16.dp))
            call.unpublished.forEach { pending ->
                Column(Modifier.padding(horizontal = 16.dp)) {
                    Text(pending.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Row {
                        if (call.attachments[pending.id]?.phase == TransferPhase.Retryable) TextButton({ controller.retryAttachment(pending.id) }) {
                            Text(stringResource(R.string.retry_upload))
                        }
                        TextButton({ controller.cancelAttachment(pending.id) }) {
                            Text(stringResource(if (call.attachments[pending.id]?.phase == TransferPhase.Cancelling)
                                R.string.attachment_retry_cancel else R.string.file_cancel_upload))
                        }
                    }
                }
            }
            if (call.attachmentPreparing) Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.file_preparing), Modifier.weight(1f))
                TextButton(controller::cancelAttachmentPreparation) { Text(stringResource(R.string.cancel)) }
            }
            if (call.attachments.values.any { it.busy } && call.attachmentPolicy != cn.youzifeile.chirp.data.AttachmentPolicy.Normal) {
                Text(stringResource(if (call.attachmentPolicy == cn.youzifeile.chirp.data.AttachmentPolicy.Paused) R.string.file_voice_paused else R.string.file_voice_slow), Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (call.attachmentsRevoked) {
                Note(R.drawable.ic_attach, stringResource(R.string.attachment_access_ended),
                    Modifier.padding(horizontal = 16.dp, vertical = 4.dp).semantics { liveRegion = LiveRegionMode.Polite })
            }
            call.failure?.let { failure -> Box(Modifier.padding(horizontal = 12.dp)) { ErrorNote(failure) } }
            if (call.draftTooLong) Text(stringResource(R.string.chat_too_long), Modifier.padding(horizontal = 16.dp),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            val canCompose = call.phase == CallPhase.Connected && !call.held && !call.trust.pending
            Surface(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                shape = MaterialTheme.shapes.extraLarge, color = MaterialTheme.colorScheme.surfaceContainerHigh) {
                Row(Modifier.padding(horizontal = 4.dp, vertical = 3.dp), verticalAlignment = Alignment.Bottom) {
                    Box {
                        IconButton(onClick = { chooser = true }, enabled = canCompose && !call.attachmentsRevoked && !call.attachmentPreparing &&
                            call.attachments.values.none { it.outgoing && it.phase == TransferPhase.Sending }) {
                            Glyph(R.drawable.ic_attach, label = stringResource(R.string.attach))
                        }
                        DropdownMenu(chooser && canCompose && !call.attachmentsRevoked, onDismissRequest = { chooser = false }) {
                            DropdownMenuItem(text = { Text(stringResource(R.string.choose_photo)) },
                                leadingIcon = { Glyph(R.drawable.ic_image) }, onClick = {
                                chooser = false
                                pickerEntry = call.entryID
                                pickerRevision = call.cacheRevision
                                LogEvent.selectPhoto.record()
                                choosePhoto.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                            })
                            DropdownMenuItem(text = { Text(stringResource(R.string.choose_file)) },
                                leadingIcon = { Glyph(R.drawable.ic_attach) }, onClick = {
                                chooser = false
                                pickerEntry = call.entryID
                                pickerRevision = call.cacheRevision
                                LogEvent.selectFile.record()
                                chooseFile.launch(arrayOf("*/*"))
                            })
                        }
                    }
                    val hint = stringResource(R.string.chat_hint)
                    TextField(editor, { change ->
                        if (change.text == editor.text || controller.updateDraft(change.text, call.entryID) == change.text) {
                            editor = change
                        }
                    }, Modifier.weight(1f).semantics { contentDescription = hint }, enabled = canCompose,
                        placeholder = { Text(hint, color = MaterialTheme.colorScheme.onSurfaceVariant) }, maxLines = 4,
                        colors = TextFieldDefaults.colors(
                            focusedContainerColor = Color.Transparent,
                            unfocusedContainerColor = Color.Transparent,
                            focusedIndicatorColor = Color.Transparent,
                            unfocusedIndicatorColor = Color.Transparent,
                        ))
                    FilledIconButton(onClick = { controller.sendDraft(call.entryID) }, enabled = canCompose && !call.sending && validChatText(draft),
                        modifier = Modifier.size(48.dp)) {
                        Glyph(R.drawable.ic_send, label = stringResource(R.string.send), tint = LocalContentColor.current)
                    }
                }
            }
        }
    }
}

@Composable
private fun MessageBubble(message: ChatMessage, transfer: TransferState?, controller: CallController,
    cacheRevision: Long, entryID: String?, canRestore: Boolean, onFile: () -> Unit) {
    val formatter = remember { DateFormat.getTimeInstance(DateFormat.SHORT) }
    Box(Modifier.fillMaxWidth(), contentAlignment = if (message.own) Alignment.CenterEnd else Alignment.CenterStart) {
        Column(
            Modifier.widthIn(max = 440.dp).fillMaxWidth(0.86f),
            horizontalAlignment = if (message.own) Alignment.End else Alignment.Start,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text("${if (message.own) stringResource(R.string.me) else message.name}  ${formatter.format(Date(message.time))}",
                color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelSmall)
            val file = message.attachment
            if (file != null) {
                val supporting = when (transfer?.phase) {
                    TransferPhase.Available -> stringResource(when (transfer.remote) {
                        "delivered", "removed" -> R.string.attachment_local_copy
                        "expired" -> R.string.attachment_expired_local_copy
                        else -> R.string.file_ready
                    })
                    TransferPhase.Waiting -> stringResource(when (transfer.remote) {
                        "completed" -> R.string.attachment_download_available
                        "paused" -> R.string.attachment_sender_paused
                        else -> R.string.file_waiting
                    })
                    TransferPhase.AwaitingUpload -> stringResource(R.string.attachment_awaiting_upload)
                    TransferPhase.Sending -> stringResource(R.string.file_uploading, transfer.progress)
                    TransferPhase.Receiving -> stringResource(R.string.file_downloading, transfer.progress)
                    TransferPhase.Failed -> stringResource(if (message.own) R.string.file_failed else R.string.file_integrity_failure)
                    TransferPhase.Paused -> stringResource(R.string.file_paused)
                    TransferPhase.Retryable -> stringResource(R.string.file_resume)
                    TransferPhase.Cancelling -> stringResource(R.string.file_cancelling)
                    TransferPhase.Cancelled -> stringResource(if (message.own) R.string.file_cancelled else R.string.file_sender_cancelled)
                    TransferPhase.Expired -> stringResource(R.string.file_expired)
                    TransferPhase.Verifying -> stringResource(R.string.file_verifying)
                    else -> stringResource(R.string.file_unavailable)
                }
                if (file.hasThumbnail && transfer != null &&
                    transfer.phase !in setOf(TransferPhase.Cancelled, TransferPhase.Expired, TransferPhase.Failed)) {
                    androidx.compose.runtime.key(file.id, cacheRevision) {
                        val thumbnail by produceState<android.graphics.Bitmap?>(null) { value = controller.thumbnail(file.id) }
                        thumbnail?.let { bitmap -> Image(bitmap.asImageBitmap(), file.name,
                            Modifier.fillMaxWidth().heightIn(max = 180.dp).clickable(enabled = transfer.phase == TransferPhase.Available,
                                onClickLabel = stringResource(R.string.show_image), onClick = onFile),
                            contentScale = ContentScale.Fit) }
                    }
                }
                if (transfer != null && transfer.phase in setOf(TransferPhase.Sending, TransferPhase.Receiving)) {
                    LinearProgressIndicator(progress = { transfer.progress.coerceIn(0, 100) / 100f }, modifier = Modifier.fillMaxWidth())
                }
                Text(Formatter.formatFileSize(LocalContext.current, file.size), style = MaterialTheme.typography.labelSmall)
                SettingRow(R.drawable.ic_attach, file.name, supporting,
                    if (transfer?.phase == TransferPhase.Available ||
                        transfer?.phase in setOf(TransferPhase.Retryable, TransferPhase.Paused)) onFile else null)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (message.own && transfer?.phase in setOf(TransferPhase.Sending, TransferPhase.Retryable, TransferPhase.Cancelling)) {
                        TextButton({ controller.cancelAttachment(file.id) }) {
                            Text(stringResource(if (transfer?.phase == TransferPhase.Cancelling) R.string.attachment_retry_cancel else R.string.file_cancel_upload))
                        }
                    }
                    if (!message.own && transfer?.phase in setOf(TransferPhase.Retryable, TransferPhase.Paused)) {
                        TextButton(onFile) { Text(stringResource(R.string.file_resume_download)) }
                    }
                    if (!message.own && transfer?.phase == TransferPhase.Waiting) {
                        TextButton(onFile) { Text(stringResource(R.string.attachment_download)) }
                    }
                    if (!message.own && transfer?.phase in setOf(TransferPhase.AwaitingUpload, TransferPhase.Receiving, TransferPhase.Verifying)) {
                        TextButton({ controller.pauseAttachment(file.id) }) { Text(stringResource(R.string.file_pause_download)) }
                    }
                }
            } else Surface(color = if (message.own) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh,
                contentColor = if (message.own) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurface,
                shape = MaterialTheme.shapes.large) {
                SelectionContainer {
                    Text(message.text, Modifier.padding(horizontal = 13.dp, vertical = 9.dp))
                }
            }
            if (message.own && message.attachment == null) {
                Text(stringResource(when (message.delivery) {
                    Delivery.Failed -> R.string.chat_not_submitted
                    Delivery.Sending -> R.string.sending
                    else -> R.string.chat_submitted
                }),
                    color = if (message.delivery == Delivery.Failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.labelSmall)
            }
            if (message.delivery == Delivery.Failed && message.own && message.attachment == null) {
                Text(stringResource(R.string.chat_restore_hint), style = MaterialTheme.typography.labelSmall)
                TextButton({ controller.restoreFailed(message.id, entryID) }, enabled = canRestore) { Text(stringResource(R.string.chat_restore_draft)) }
            }
        }
    }
}


@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun AttachmentDialog(info: AttachmentInfo, controller: CallController,
    onDismiss: () -> Unit, onExport: () -> Unit) {
    val context = LocalContext.current
    var loaded by remember(info.id) { mutableStateOf(false) }
    val preview by produceState<android.graphics.Bitmap?>(null, info.id) {
        if (info.image) {
            value = controller.preview(info.id)
            loaded = true
        }
    }
    if (info.image) {
        androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss,
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
            Scaffold(modifier = Modifier.fillMaxSize(), topBar = { ScreenBar(info.name, onDismiss) },
                bottomBar = { Box(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom)).padding(16.dp), contentAlignment = Alignment.Center) {
                    Button(onExport) { Text(stringResource(R.string.file_export)) }
                } }, containerColor = MaterialTheme.colorScheme.surface) { insets ->
                Box(Modifier.fillMaxSize().padding(insets), contentAlignment = Alignment.Center) {
                    val image = preview
                    if (image != null) Image(image.asImageBitmap(), info.name, Modifier.fillMaxSize().padding(16.dp), contentScale = ContentScale.Fit)
                    else if (loaded) {
                        EmptyState(R.drawable.ic_image, stringResource(R.string.attachment_preview_failed),
                            stringResource(R.string.attachment_preview_export_help))
                    } else Column(horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        CircularProgressIndicator()
                        Text(stringResource(R.string.attachment_preview_loading))
                    }
                }
            }
        }
        return
    }
    ChirpDialog(
        icon = R.drawable.ic_attach,
        onDismissRequest = onDismiss,
        title = { Text(info.name, maxLines = 3, overflow = TextOverflow.Ellipsis) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(Formatter.formatFileSize(context, info.size), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = { Button(onExport) { Text(stringResource(R.string.file_export)) } },
        dismissButton = { TextButton(onDismiss) { Text(stringResource(R.string.close)) } },
    )
}
