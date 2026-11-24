package cn.youzifeile.chirp.ui

import cn.youzifeile.chirp.data.LogEvent
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfoV2
import androidx.compose.material3.adaptive.layout.calculatePaneScaffoldDirective
import androidx.compose.material3.adaptive.layout.calculatePaneScaffoldDirectiveWithTwoPanesOnMediumWidth
import androidx.compose.material3.adaptive.navigation3.ListDetailSceneStrategy
import androidx.compose.material3.adaptive.navigation3.rememberListDetailSceneStrategy
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffoldDefaults
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.ui.NavDisplay
import androidx.window.core.layout.WindowSizeClass
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.media.CallState
import kotlinx.serialization.Serializable

private enum class HomeTab { Rooms, Friends, Account }

@Serializable private data object DirectoryRoute : NavKey
@Serializable private data class RoomRoute(val roomID: String) : NavKey
@Serializable private data object AccountRoute : NavKey
@Serializable private data object LogRoute : NavKey
@Serializable private data object ProfileRoute : NavKey
@Serializable private data object AudioRoute : NavKey
@Serializable private data object StorageRoute : NavKey
@Serializable private data object DevicesRoute : NavKey
@Serializable private data object BlacklistRoute : NavKey
@Serializable private data object LocalIdentityRoute : NavKey

@Composable
internal fun ChirpApp(activity: ComponentActivity, state: MainState, call: CallState, model: MainViewModel) {
    androidx.lifecycle.compose.LifecycleStartEffect(model) {
        model.setDirectoryVisible(true)
        onStopOrDispose { model.setDirectoryVisible(false) }
    }
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
        if (state.setupStep != null) {
            LogScreen(LogEvent.identitySetup, state.setupStep)
            IdentitySetupScreen(activity, state, model)
        } else if (state.account == null) {
            var settings by rememberSaveable { mutableStateOf(false) }
            LaunchedEffect(Unit) { model.reloadLocalIdentities() }
            if (settings) {
                androidx.activity.compose.BackHandler { settings = false }
                SignedOutSettings(activity, state, model, back = { settings = false })
                return@Surface
            }
            val localPermission = rememberPermission(activity, ChirpPermission.LocalNetwork) {}
            LogScreen(LogEvent.login)
            FormPane {
                LoginScreen(state, model::editAddress, model::confirm, model::authorize, model::cancelAuthorization, model::openRegistration,
                    localPermission, onSettings = { settings = true }, onRetryClock = { model.checkClock(manual = true) })
            }
        } else {
            SignedIn(activity, state, call, model)
        }
    }
}

@OptIn(androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi::class)
@Composable
private fun SignedIn(activity: ComponentActivity, state: MainState, call: CallState, model: MainViewModel) {
    val tabState = androidx.compose.runtime.saveable.rememberSaveableStateHolder()
    val roomsStack = rememberNavBackStack(DirectoryRoute)
    val accountStack = rememberNavBackStack(AccountRoute)
    var tab by rememberSaveable { mutableStateOf(HomeTab.Rooms) }
    var roomAudioOpen by rememberSaveable { mutableStateOf(false) }
    var friendRoot by rememberSaveable { mutableStateOf<String?>(null) }
    val friend = state.identity.friends.find { it.root == friendRoot }
    val selected = roomsStack.lastOrNull() as? RoomRoute
    val currentRoom = call.room
    val directory = state.directory ?: state.connection?.let { cn.youzifeile.chirp.data.Directory.loading(it.defaultRoom) }
    if (call.entryID != null && call.phase != cn.youzifeile.chirp.media.CallPhase.Leaving) {
        androidx.compose.runtime.key(call.entryID) { RoomVerificationDialogs(call.trust, model.calls) }
    }
    val info = currentWindowAdaptiveInfoV2()
    val splitAtHinge = info.windowPosture.hingeList.any { it.isVertical && (it.isSeparating || it.isOccluding) }
    val directive = if (splitAtHinge) calculatePaneScaffoldDirectiveWithTwoPanesOnMediumWidth(info) else calculatePaneScaffoldDirective(info)
    val twoPanes = directive.maxHorizontalPartitions > 1
    val wide = info.windowSizeClass.isWidthAtLeastBreakpoint(WindowSizeClass.WIDTH_DP_MEDIUM_LOWER_BOUND)
    val shortWideWindow = wide && !info.windowPosture.isTabletop &&
        !info.windowSizeClass.isHeightAtLeastBreakpoint(WindowSizeClass.HEIGHT_DP_MEDIUM_LOWER_BOUND)
    val showTabs = wide || when (tab) {
        HomeTab.Rooms -> selected == null
        HomeTab.Friends -> friend == null
        HomeTab.Account -> accountStack.size == 1
    }
    val adaptive = rememberListDetailSceneStrategy<NavKey>(directive = directive)
    val openRoom: (String) -> Unit = { id ->
        roomAudioOpen = false
        tab = HomeTab.Rooms
        if (roomsStack.lastOrNull() != RoomRoute(id)) {
            if (roomsStack.size > 1) roomsStack.removeLastOrNull()
            roomsStack.add(RoomRoute(id))
        }
    }
    val onReturn = { if (currentRoom != null) openRoom(currentRoom.id) }
    val openAccount = { tab = HomeTab.Account }
    LaunchedEffect(state.directory) {
        if (state.directory?.fresh == true && selected != null && state.directory.rooms.none { it.id == selected.roomID }) {
            roomsStack.removeLastOrNull()
        }
    }

    NavigationSuiteScaffold(
        navigationSuiteItems = {
            item(selected = tab == HomeTab.Rooms, onClick = { tab = HomeTab.Rooms },
                icon = { Glyph(R.drawable.ic_waveform) },
                label = { Text(stringResource(R.string.rooms)) })
            item(selected = tab == HomeTab.Friends, onClick = { tab = HomeTab.Friends },
                icon = { Glyph(R.drawable.ic_group) },
                label = { Text(stringResource(R.string.friends)) })
            item(selected = tab == HomeTab.Account, onClick = openAccount,
                icon = { Glyph(R.drawable.ic_account) },
                label = { Text(stringResource(R.string.account)) })
        },
        layoutType = when {
            !showTabs -> NavigationSuiteType.None
            shortWideWindow -> NavigationSuiteType.NavigationRail
            else -> NavigationSuiteScaffoldDefaults.calculateFromAdaptiveInfo(info)
        },
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.weight(1f).fillMaxWidth()) {
                tabState.SaveableStateProvider(tab.name) {
                    if (tab == HomeTab.Friends) {
                        FriendsScreen(state, model, friend, onSelect = { friendRoot = it })
                    } else if (tab == HomeTab.Account) {
                        NavDisplay(
                            backStack = accountStack,
                            onBack = { if (accountStack.size > 1) accountStack.removeLastOrNull() },
                            entryProvider = entryProvider {
                                entry<AccountRoute> {
                                    AccountScreen(activity, state, call, model, onProfile = { accountStack.add(ProfileRoute) },
                                        onAudio = { accountStack.add(AudioRoute) }, onLogs = { accountStack.add(LogRoute) },
                                        onDevices = { accountStack.add(DevicesRoute) }, onBlacklist = { accountStack.add(BlacklistRoute) },
                                        onLocalIdentity = { accountStack.add(LocalIdentityRoute) })
                                }
                                entry<LogRoute> { LogSettings(activity) { accountStack.removeLastOrNull() } }
                                entry<ProfileRoute> { ProfileScreen(state, model) { accountStack.removeLastOrNull() } }
                                entry<AudioRoute> {
                                    AudioSettings(activity, call, model) {
                                        accountStack.removeLastOrNull()
                                    }
                                }
                                entry<StorageRoute> { StorageSettings(model) { accountStack.removeLastOrNull() } }
                                entry<DevicesRoute> { DevicesScreen(state, model) { accountStack.removeLastOrNull() } }
                                entry<BlacklistRoute> { BlacklistScreen(state, model) { accountStack.removeLastOrNull() } }
                                entry<LocalIdentityRoute> {
                                    LogScreen(LogEvent.localIdentity)
                                    SettingsPage(stringResource(R.string.local_identity_data), { accountStack.removeLastOrNull() }) {
                                        LocalIdentityContents(state, model, onStorage = { accountStack.add(StorageRoute) })
                                    }
                                }
                            },
                        )
                    } else {
                        NavDisplay(
                            backStack = roomsStack,
                            onBack = { if (roomsStack.size > 1) roomsStack.removeLastOrNull() },
                            sceneStrategies = listOf(adaptive),
                            entryProvider = entryProvider {
                                entry<DirectoryRoute>(metadata = ListDetailSceneStrategy.listPane(detailPlaceholder = { PickRoom() })) {
                                    LogScreen(LogEvent.rooms)
                                    DirectoryScreen(directory, call, openRoom, openAccount, selected?.roomID, state.directoryLoadFailed)
                                }
                                entry<RoomRoute>(metadata = ListDetailSceneStrategy.detailPane()) { route ->
                                    val room = state.directory?.rooms?.find { it.id == route.roomID }
                                        ?: currentRoom?.takeIf { it.id == route.roomID }
                                        ?: directory?.rooms?.find { it.id == route.roomID }
                                    val back: (() -> Unit)? = if (twoPanes) null else ({ roomsStack.removeLastOrNull() })
                                    val closeAudio = { roomAudioOpen = false }
                                    androidx.activity.compose.BackHandler(enabled = roomAudioOpen, onBack = closeAudio)
                                    when {
                                        roomAudioOpen -> AudioSettings(activity, call, model, closeAudio)
                                        room == null -> PickRoom()
                                        else -> FormPane {
                                            RoomScreen(activity, room, state, call, model, back,
                                                audio = { roomAudioOpen = true })
                                        }
                                    }
                                }
                            },
                        )
                    }
                }
            }
            if (currentRoom != null && (tab != HomeTab.Rooms || selected?.roomID != currentRoom.id || roomAudioOpen)) {
                ReturnToCall(call, onReturn)
            }
        }
    }
}

@Composable
private fun PickRoom() {
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        EmptyState(R.drawable.ic_waveform, stringResource(R.string.room_select), stringResource(R.string.room_select_detail))
    }
}
