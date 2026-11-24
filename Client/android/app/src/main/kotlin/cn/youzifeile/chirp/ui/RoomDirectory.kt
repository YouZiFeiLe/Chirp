package cn.youzifeile.chirp.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.Directory
import cn.youzifeile.chirp.data.RoomInfo
import cn.youzifeile.chirp.media.CallState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun DirectoryScreen(directory: Directory?, call: CallState, openRoom: (String) -> Unit,
    openAccount: () -> Unit, selected: String?, initialSyncFailed: Boolean = false) {
    val bar = TopAppBarDefaults.pinnedScrollBehavior()
    val rooms = directory?.rooms.orEmpty()
    Scaffold(modifier = Modifier.nestedScroll(bar.nestedScrollConnection), topBar = {
        DirectoryBar(bar, openAccount)
    }) { insets ->
        Box(Modifier.fillMaxSize().padding(insets).consumeWindowInsets(insets), contentAlignment = Alignment.TopCenter) {
            LazyColumn(Modifier.widthIn(max = 680.dp).fillMaxSize(),
                contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                item { DirectoryIntro() }
                if (initialSyncFailed) {
                    item {
                        EmptyState(R.drawable.ic_link, stringResource(R.string.directory_retry_title),
                            stringResource(R.string.directory_retry_detail))
                    }
                } else if (directory == null) {
                    item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
                    item { Text(stringResource(R.string.room_loading), Modifier.padding(16.dp)) }
                } else {
                    val loading = !directory.fresh && rooms.firstOrNull()?.mediaStatus == "loading"
                    if (loading) item {
                        LinearProgressIndicator(Modifier.fillMaxWidth())
                    } else if (!directory.fresh) item {
                        Notice(stringResource(R.string.room_list_stale_help), icon = R.drawable.ic_link)
                    }
                    if (rooms.isEmpty()) item {
                        EmptyState(R.drawable.ic_waveform, stringResource(R.string.directory_empty),
                            stringResource(R.string.directory_empty_detail))
                    } else {
                        if (!loading) item {
                            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp),
                                horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text(stringResource(R.string.room_select), Modifier.weight(1f).semantics { heading() },
                                    style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                                Surface(shape = CircleShape, color = MaterialTheme.colorScheme.secondaryContainer) {
                                    Text(pluralStringResource(R.plurals.room_count, rooms.size, rooms.size),
                                        Modifier.padding(horizontal = 10.dp, vertical = 4.dp), maxLines = 1,
                                        style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSecondaryContainer)
                                }
                            }
                        }
                        items(rooms, key = RoomInfo::id) { room ->
                            DirectoryRoom(room, directory.fresh, room.id == selected,
                                call = call.takeIf { it.room?.id == room.id }, open = { openRoom(room.id) })
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DirectoryBar(scrollBehavior: TopAppBarScrollBehavior, openAccount: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    CenterAlignedTopAppBar(
        title = {
            Text(stringResource(R.string.rooms), Modifier.semantics { heading() }, style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        },
        navigationIcon = {
            Row(Modifier.padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Surface(shape = MaterialTheme.shapes.small, color = colors.primary, contentColor = colors.onPrimary) {
                    Glyph(R.drawable.ic_waveform, Modifier.padding(6.dp).size(18.dp))
                }
                Text(stringResource(R.string.app_name), style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold, maxLines = 1)
            }
        },
        actions = {
            OutlinedIconButton(onClick = openAccount, modifier = Modifier.padding(end = 8.dp),
                colors = IconButtonDefaults.outlinedIconButtonColors(containerColor = colors.surfaceContainerLow, contentColor = colors.primary),
                border = BorderStroke(1.dp, colors.outlineVariant)) {
                Glyph(R.drawable.ic_account, label = stringResource(R.string.account))
            }
        },
        expandedHeight = if (compactWindowHeight()) 48.dp else TopAppBarDefaults.TopAppBarExpandedHeight,
        scrollBehavior = scrollBehavior,
    )
}

@Composable
private fun DirectoryIntro() {
    val colors = MaterialTheme.colorScheme
    Column(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Spacer(Modifier.size(width = 18.dp, height = 3.dp).background(colors.primary, CircleShape))
            Text(stringResource(R.string.rooms_intro_eyebrow), color = colors.primary,
                style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, letterSpacing = 1.sp)
        }
        Text(stringResource(R.string.rooms_intro), Modifier.semantics { heading() },
            style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
        Text(stringResource(R.string.rooms_intro_body), style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DirectoryRoom(room: RoomInfo, fresh: Boolean, isSelected: Boolean,
    call: CallState?, open: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val people = room.participants
    val summary = when {
        !fresh && room.mediaStatus == "loading" -> stringResource(R.string.room_loading)
        !fresh -> stringResource(R.string.room_stale)
        people == null -> stringResource(R.string.room_unavailable)
        people.isEmpty() -> stringResource(R.string.room_quiet)
        else -> pluralStringResource(R.plurals.people_online, people.size, people.size)
    }
    val names = if (fresh) people.orEmpty().take(4).joinToString(" · ") { it.name } else ""
    val status = listOfNotNull(call?.status(), summary).joinToString(" · ")
    val locked = room.passwordRequired
    val type = stringResource(if (locked) R.string.room_kind_locked else R.string.room_kind_open)
    val icon = if (locked) R.drawable.ic_lock else R.drawable.ic_waveform
    val fill by animateColorAsState(if (isSelected) colors.secondaryContainer else colors.surfaceContainerLow,
        label = "Room selection")
    OutlinedCard(onClick = open, modifier = Modifier.fillMaxWidth().semantics {
        role = Role.Button
        selected = isSelected
    }, shape = MaterialTheme.shapes.large, colors = CardDefaults.outlinedCardColors(containerColor = fill),
        border = BorderStroke(1.dp, if (isSelected || call != null) colors.primary else colors.outlineVariant)) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Surface(shape = MaterialTheme.shapes.medium, color = colors.primary, contentColor = colors.onPrimary) {
                    Glyph(icon, Modifier.padding(10.dp).size(24.dp))
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(room.title(), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
                        color = colors.onSurface, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text(type, style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
                }
                Surface(shape = CircleShape, color = colors.primaryContainer, contentColor = colors.primary) {
                    Glyph(R.drawable.ic_chevron, Modifier.padding(6.dp).size(18.dp))
                }
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(status, style = MaterialTheme.typography.labelMedium,
                    color = if (call != null) colors.primary else colors.onSurfaceVariant)
                if (names.isNotEmpty()) Text(names, style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
internal fun ReturnToCall(call: CallState, onClick: () -> Unit) {
    val room = call.room ?: return
    val colors = MaterialTheme.colorScheme
    Surface(color = colors.secondaryContainer) {
        Box(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)),
            contentAlignment = Alignment.Center) {
            Surface(onClick = onClick, modifier = Modifier.widthIn(max = 680.dp).fillMaxWidth(), color = colors.secondaryContainer) {
                Row(Modifier.padding(horizontal = 24.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(16.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Surface(shape = MaterialTheme.shapes.medium,
                        color = colors.primaryContainer, contentColor = colors.onPrimaryContainer) {
                        if (call.members.any { it.speaking && it.microphoneEnabled == true } && call.phase == cn.youzifeile.chirp.media.CallPhase.Connected && !call.held) {
                            SpeechSignal(LocalContentColor.current, Modifier.padding(10.dp).size(20.dp))
                        } else Glyph(R.drawable.ic_waveform, Modifier.padding(10.dp).size(20.dp))
                    }
                    Column(Modifier.weight(1f)) {
                        Text(room.title(), style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(call.status(), style = MaterialTheme.typography.labelMedium)
                    }
                    Glyph(R.drawable.ic_chevron, label = stringResource(R.string.return_room_status, room.title(), call.status()))
                }
            }
        }
    }
}
