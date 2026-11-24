package cn.youzifeile.chirp.ui

import cn.youzifeile.chirp.data.LogEvent
import cn.youzifeile.chirp.data.LogOutcome
import cn.youzifeile.chirp.data.CallStage
import cn.youzifeile.chirp.data.DiagnosticPhase
import cn.youzifeile.chirp.data.ClientLog
import android.graphics.Bitmap
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.youzifeile.chirp.ChirpApplication
import cn.youzifeile.chirp.data.ClientFailure
import cn.youzifeile.chirp.data.ClockReading
import cn.youzifeile.chirp.data.ClockStatus
import cn.youzifeile.chirp.data.DevicePairing
import cn.youzifeile.chirp.data.LocalDevice
import cn.youzifeile.chirp.data.clientFailure
import cn.youzifeile.chirp.data.ChirpException
import cn.youzifeile.chirp.data.Directory
import cn.youzifeile.chirp.data.NativeLogin
import cn.youzifeile.chirp.data.NetworkClock
import cn.youzifeile.chirp.data.NtpTime
import cn.youzifeile.chirp.data.SavedIdentity
import cn.youzifeile.chirp.data.IdentityGrant
import cn.youzifeile.chirp.data.memberIDPattern
import cn.youzifeile.chirp.data.parseServerAddress
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import cn.youzifeile.chirp.data.Profile
import cn.youzifeile.chirp.data.RoomInfo
import cn.youzifeile.chirp.data.ServerConnection
import cn.youzifeile.chirp.data.SessionRepository
import cn.youzifeile.chirp.data.nowSeconds
import cn.youzifeile.chirp.data.AccountIdentity
import cn.youzifeile.chirp.data.AccountView
import cn.youzifeile.chirp.data.IdentitySetup
import cn.youzifeile.chirp.data.SetupStep
import cn.youzifeile.chirp.data.identityOrigin
import cn.youzifeile.chirp.data.verify
import kotlinx.coroutines.cancelAndJoin
import cn.youzifeile.chirp.media.PreparedAvatar
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.updateAndGet
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal data class JoinFailure(val roomId: String, val reason: ClientFailure)

internal data class MainState(
    val address: String = "",
    val connection: ServerConnection? = null,
    val checking: Boolean = true,
    val clock: ClockReading = ClockReading(),
    val authorizing: Boolean = false,
    val openingRegistration: Boolean = false,
    val resettingLocal: Boolean = false,
    val browser: String? = null,
    val loginQr: String? = null,
    val account: Profile? = null,
    val accountDevice: cn.youzifeile.chirp.data.DeviceIdentity? = null,
    val directory: Directory? = null,
    val directoryLoadFailed: Boolean = false,
    val editingProfile: Boolean = false,
    val profileNotice: Int? = null,
    val profileSession: String? = null,
    val avatarDraft: PreparedAvatar? = null,
    val preparingAvatar: Boolean = false,
    val error: ClientFailure? = null,
    val joinFailure: JoinFailure? = null,
    val preparingRoom: String? = null,
    val setupStep: SetupStep? = null,
    val setupAccount: String = "",
    val setupPairing: DevicePairing? = null,
    val backupVerified: Boolean = false,
    val savedIdentities: List<SavedIdentity> = emptyList(),
    val selectedIdentity: SavedIdentity? = null,
    val identity: AccountView = AccountView(),
)

internal fun Directory.withKnownProfiles(previous: Directory?, local: Profile?): Directory {
    val known = previous?.members.orEmpty().associateBy(Profile::id)
    return copy(members = members.map { incoming ->
        val prior = known[incoming.id]?.takeIf { it.revision > incoming.revision } ?: incoming
        if (local != null && local.id == incoming.id && local.revision > prior.revision) local else prior
    })
}

internal class MainViewModel(
    private val app: ChirpApplication,
    private val restoreOnStart: Boolean = true,
    private val taskId: Int? = null,
    private val networkClock: NetworkClock = NetworkClock { NtpTime.query(app) },
) : ViewModel() {
    private val mutableState = MutableStateFlow(MainState())
    val state = mutableState.asStateFlow()
    val calls = app.calls
    private var session: SessionRepository? = null
    private var disabledJob: Job? = null
    private var directoryJob: Job? = null
    private var directoryVisible = false
    private val startup = CompletableDeferred<Unit>()
    private var pendingCallback: Pair<NativeLogin, CompletableDeferred<String>>? = null
    private var loginJob: Job? = null
    private var unconfirmedAddressEdit = false
    private var joinJob: Job? = null
    private var syncJob: Job? = null
    private var avatarJob: Job? = null
    private var profileImages: ProfileImages? = null
    private var setupJob: Job? = null
    internal var setup: IdentitySetup? = null
        private set

    init {
        checkClock()
        viewModelScope.launch {
            try {
                val saved = if (restoreOnStart) app.settings.server() else ""
                if (restoreOnStart) {
                    app.settings.discardPersistedLogin()
                    refreshLocalIdentities()
                }
                val audio = app.settings.audioSettings()
                calls.audio.configure(audio.first, audio.second, audio.third)
                mutableState.update { it.copy(address = saved) }
                if (saved.isNotBlank()) {
                    val previous = app.settings.savedConnection(saved)
                    if (previous != null) mutableState.update { it.copy(connection = previous) }
                    val connection = if (previous == null) app.server.discover(saved) else app.server.refresh(previous)
                    app.settings.saveServer(connection)
                    mutableState.update { it.copy(connection = connection) }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error(e)
            } finally {
                mutableState.update { it.copy(checking = false) }
                startup.complete(Unit)
            }
        }
    }

    fun checkClock(manual: Boolean = false) {
        viewModelScope.launch { networkClock.check(manual, ::showClock) }
    }

    private fun showClock(reading: ClockReading) {
        val previous = state.value.clock
        if (previous == reading) return
        mutableState.update { it.copy(clock = reading) }
        if (previous.ready && !reading.ready) {
            loginJob?.cancel()
            closeSetupPairing()
        }
    }

    fun clockReady(): Boolean = networkClock.read().also(::showClock).ready

    private fun requireClock() = verify(clockReady(), "NETWORK_TIME_REQUIRED")

    fun editAddress(address: String) {
        if (address.length > 2048 || state.value.checking || state.value.authorizing || session != null || state.value.address == address) return
        if (!unconfirmedAddressEdit) {
            LogEvent.editServer.record()
            unconfirmedAddressEdit = true
            viewModelScope.launch {
                try { app.identities.pendingLogin()?.let { app.identities.removePendingLogin(it.state) } }
                catch (_: IOException) { /* Expired pending logins are removed when read. */ }
            }
        }
        mutableState.update { it.copy(address = address, connection = null, error = null) }
    }

    fun confirm(address: String) {
        if (state.value.checking || state.value.authorizing || session != null) return
        mutableState.update { it.copy(address = address, connection = null, checking = true, error = null) }
        viewModelScope.launch {
            try {
                LogEvent.confirmServer.measure(started = true) {
                    val confirmed = app.server.discover(address)
                    app.settings.saveServer(confirmed)
                    unconfirmedAddressEdit = false
                    mutableState.update { it.copy(connection = confirmed) }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error(e)
            } finally {
                mutableState.update { it.copy(checking = false) }
            }
        }
    }

    fun authorize(showQr: Boolean) {
        val current = state.value.connection ?: return
        if (state.value.authorizing || state.value.checking || session != null || !clockReady()) return
        mutableState.update { it.copy(authorizing = true, error = null) }
        loginJob = viewModelScope.launch {
            try {
                (if (showQr) LogEvent.phoneLogin else LogEvent.browserLogin).measure(started = true) {
                    val connection = app.server.refresh(current)
                    requireClock()
                    mutableState.update { it.copy(connection = connection) }
                    if (!showQr && connection.nativeLogin) {
                        val native = NativeLogin.create(connection, taskId)
                        val callback = CompletableDeferred<String>()
                        pendingCallback = native to callback
                        try {
                            app.identities.savePendingLogin(native)
                            requireClock()
                            mutableState.update { it.copy(browser = native.authorizationURL(connection).toString()) }
                            val code = withTimeoutOrNull((native.expires - nowSeconds()).coerceAtLeast(1) * 1_000) { callback.await() }
                                ?: throw ChirpException("DEVICE_AUTHORIZATION_EXPIRED")
                            exchangeLoginCode(connection, native, code)
                        } finally {
                            if (pendingCallback?.first === native) pendingCallback = null
                            withContext(NonCancellable) { app.identities.removePendingLogin(native.state) }
                        }
                        return@launch
                    }
                    val device = app.server.beginLogin(connection)
                    val url = device.browserURL.toString()
                    var claimed = false
                    try {
                        requireClock()
                        mutableState.update { it.copy(browser = url.takeUnless { showQr }, loginQr = url.takeIf { showQr }) }
                        while (nowSeconds() < device.expiresAt) {
                            delay(device.interval * 1000)
                            requireClock()
                            val grant = try {
                                app.server.poll(connection, device)
                            } catch (e: IOException) {
                                if (e is ChirpException && e.status in 400..499 && e.status != 429) throw e
                                continue
                            } ?: continue
                            claimed = true
                            acceptGrant(grant, device.verifier, connection)
                            return@launch
                        }
                        throw ChirpException("DEVICE_AUTHORIZATION_EXPIRED")
                    } finally {
                        if (!claimed) withContext(NonCancellable) {
                            runCatching { app.server.cancel(connection, device) }
                        }
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error(e)
            } finally {
                mutableState.update { it.copy(authorizing = false, browser = null, loginQr = null) }
            }
        }
    }

    private suspend fun exchangeLoginCode(connection: ServerConnection, native: NativeLogin, code: String) {
        requireClock()
        // Claim the saved transaction before sending, including when Android redelivers a callback after process death.
        if (app.identities.removePendingLogin(native.state)) {
            acceptGrant(app.server.exchange(connection, native, code), native.verifier, connection)
        }
    }

    private suspend fun acceptGrant(grant: IdentityGrant, verifier: String, connection: ServerConnection) {
        requireClock()
        val pending = IdentitySetup(grant, verifier, connection, app.http, app.identities)
        pending.load()
        requireClock()
        closeSetupPairing()
        setup = pending
        mutableState.update { it.copy(setupStep = pending.step, setupAccount = grant.username, backupVerified = false) }
        if (pending.step == SetupStep.Activate) finishSetup(pending)
    }

    fun loginCallback(uri: String) {
        if (!uri.startsWith(NativeLogin.REDIRECT + "?")) return
        viewModelScope.launch {
            startup.await()
            // A cold-start browser callback may arrive before the first NTP reply.
            networkClock.check(false, ::showClock)
            state.first { it.clock.status != ClockStatus.Checking }
            if (!clockReady()) return@launch
            if (session != null || setup != null) return@launch
            val inMemory = pendingCallback
            if (inMemory != null) {
                try { inMemory.second.complete(LogEvent.loginCallback.measure { inMemory.first.code(uri) }) }
                catch (e: ChirpException) { error(e) }
                return@launch
            }
            if (loginJob?.isActive == true) return@launch
            // A Custom Tab can outlive the process. Resume its transaction only in the original Android task.
            loginJob = viewModelScope.launch resumeLogin@{
                try {
                    LogEvent.loginCallback.measure(started = true) {
                        verify(!unconfirmedAddressEdit, "INVALID_LOGIN_CALLBACK")
                        val native = app.identities.pendingLogin()?.takeIf { it.taskId == taskId } ?: return@resumeLogin
                        requireClock()
                        val configured = state.value.address.trim()
                        verify(configured.isEmpty() || parseServerAddress(configured, cn.youzifeile.chirp.BuildConfig.DEBUG).toString() == native.discovery,
                            "INVALID_LOGIN_CALLBACK")
                        val code = native.code(uri)
                        mutableState.update { it.copy(authorizing = true, error = null) }
                        val connection = app.server.discover(native.discovery)
                        verify(native.matches(connection), "INVALID_LOGIN_CALLBACK")
                        mutableState.update { it.copy(connection = connection, address = native.discovery) }
                        exchangeLoginCode(connection, native, code)
                    }
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) { error(e) }
                finally { mutableState.update { it.copy(authorizing = false) } }
            }
        }
    }

    fun cancelAuthorization() {
        LogEvent.cancelLogin.record()
        loginJob?.cancel()
        setupJob?.cancel()
        closeSetupPairing()
        setup = null
        mutableState.update { it.copy(browser = null, loginQr = null, setupStep = null, checking = false) }
    }

    private suspend fun finishSetup(pending: IdentitySetup) {
        val login = pending.finish(::requireClock)
        if (setup !== pending) return
        requireClock()
        closeSetupPairing()
        val local = pending.record.active ?: throw ChirpException("DEVICE_IDENTITY_REQUIRED")
        activateSession(SessionRepository(pending.connection, login, app.http), local)
        setup = null
    }
    fun setupAction(action: suspend (IdentitySetup) -> Unit) {
        val pending = setup ?: return
        if (setupJob?.isActive == true || !clockReady()) return
        mutableState.update { it.copy(checking = true, error = null) }
        setupJob = viewModelScope.launch {
            try {
                action(pending)
                if (setup === pending && pending.step == SetupStep.Activate) {
                    mutableState.update { it.copy(setupStep = pending.step) }
                    finishSetup(pending)
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (setup === pending) error(e) }
            finally { mutableState.update { it.copy(checking = false, setupStep = setup?.step, backupVerified = setup?.backupVerified == true) } }
        }
    }
    fun exportBackup(uri: Uri, expected: IdentitySetup) {
        if (setup !== expected) return
        setupAction { pending ->
            LogEvent.exportRecoveryFile.measure(started = true) {
                val bytes = pending.backupBytes()
                withContext(Dispatchers.IO) {
                    try { (app.contentResolver.openOutputStream(uri, "wt") ?: throw IOException()).use { it.write(bytes) } }
                    catch (e: CancellationException) { throw e }
                    catch (_: Exception) { throw ChirpException("RECOVERY_EXPORT_FAILED") }
                }
                pending.exported()
            }
        }
    }
    fun recover(uri: Uri, password: String, verifyOnly: Boolean = false) = setupAction { pending ->
        if (verifyOnly) pending.clearBackupVerification()
        val bytes = withContext(Dispatchers.IO) {
            try { (app.contentResolver.openInputStream(uri) ?: throw IOException()).use { it.readNBytes(65607) } }
            catch (e: CancellationException) { throw e }
            catch (_: Exception) { throw ChirpException("RECOVERY_READ_FAILED") }
        }
        if (verifyOnly) pending.verifyBackup(bytes, password) else pending.restore(bytes, password)
    }

    fun openRegistration() {
        val current = state.value.connection ?: return
        if (current.register == null || state.value.checking || state.value.authorizing) return
        mutableState.update { it.copy(checking = true, openingRegistration = true, error = null) }
        viewModelScope.launch {
            try {
                LogEvent.openRegistration.measure(started = true) {
                    val connection = app.server.refresh(current)
                    mutableState.update { it.copy(connection = connection, browser = connection.register?.toString()) }
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { error(e) }
            finally { mutableState.update { it.copy(checking = false, openingRegistration = false) } }
        }
    }

    fun browserOpened(success: Boolean) {
        LogEvent.openBrowser.record(if (success) LogOutcome.succeeded else LogOutcome.failed, if (success) null else "BROWSER_UNAVAILABLE")
        mutableState.update { it.copy(browser = null, error = if (success) it.error else ClientFailure("BROWSER_UNAVAILABLE")) }
        if (!success) cancelAuthorization()
    }

    internal fun activateSession(next: SessionRepository, local: LocalDevice, authorityKey: String = app.authorityKey) {
        local.validate()
        verify(local.device == next.login.device, "DEVICE_IDENTITY_REQUIRED")
        next.accountIdentity = AccountIdentity(next, local, app.identities, authorityKey)
        directoryJob?.cancel()
        profileImages?.close()
        profileImages = ProfileImages(viewModelScope, next)
        session = next
        LogEvent.loginAccepted.record(LogOutcome.succeeded)
        disabledJob?.cancel()
        mutableState.update { it.copy(account = Profile(next.login.memberID, next.login.name, 0), accountDevice = local.device, directory = null, directoryLoadFailed = false,
            connection = next.connection, profileSession = next.login.identity, profileNotice = null, editingProfile = false,
            authorizing = false, setupStep = null, identity = AccountView(), error = null, browser = null) }
        disabledJob = viewModelScope.launch(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {
            val disabled = launch(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {
                next.http.awaitDisabled(next.login.credential)
                clearSession(next, "MEMBER_DISABLED")
            }
            try { clearSession(next, next.awaitSessionFailure()) }
            finally { disabled.cancel() }
        }
        if (directoryVisible && session === next) startVisibleSync(next)
    }

    fun setDirectoryVisible(visible: Boolean) {
        if (directoryVisible == visible) return
        directoryVisible = visible
        directoryJob?.cancel()
        syncJob?.cancel()
        if (visible) session?.let(::startVisibleSync)
        else mutableState.update { it.copy(directory = it.directory?.copy(fresh = false)) }
    }

    private fun startVisibleSync(next: SessionRepository) {
        syncJob?.cancel()
        directoryJob?.cancel()
        syncJob = viewModelScope.launch {
            launch { next.accountIdentity.view.collect { value ->
                if (session === next) mutableState.update { it.copy(identity = value) }
            } }
            while (session === next) {
                try { next.accountIdentity.refresh() }
                catch (e: CancellationException) { throw e }
                catch (e: Exception) {
                    if (session !== next) return@launch
                    if (e is ChirpException && e.sessionFailure != null) {
                        clearSession(next, e.sessionFailure)
                        return@launch
                    }
                    error(e)
                }
                delay(20_000)
            }
        }
        directoryJob = viewModelScope.launch {
            try {
                next.followDirectory().collect { incoming ->
                    if (session !== next || !directoryVisible) return@collect
                    val current = state.value
                    val directory = incoming?.withKnownProfiles(current.directory, current.account)
                    if (directory != null) {
                        if (directory.fresh) profileImages?.retain(directory.members)
                        calls.updateDirectory(next, directory)
                    }
                    val profile = directory?.members?.find { it.id == next.login.memberID }
                    mutableState.update {
                        it.copy(
                            directory = directory ?: it.directory?.copy(fresh = false),
                            directoryLoadFailed = directory == null && it.directory == null,
                            account = profile?.takeIf { p -> p.revision >= (it.account?.revision ?: 0) } ?: it.account,
                        )
                    }
                }
            } catch (e: ChirpException) {
                e.sessionFailure?.let { clearSession(next, it) }
            }
        }
    }

    fun join(room: RoomInfo, password: String) {
        val current = session ?: return
        if (state.value.directory?.fresh != true || joinJob?.isActive == true || calls.state.value.room?.id == room.id) return
        mutableState.update { it.copy(preparingRoom = room.id, joinFailure = null) }
        val generation = ClientLog.current?.generation ?: 0L
        calls.callStage(CallStage.authorizationStarted, phase = DiagnosticPhase.authorizing, expected = generation)
        joinJob = viewModelScope.launch {
            var entry: cn.youzifeile.chirp.data.Admission? = null
            var handedOff = false
            try {
                calls.audio.prepareForCall()
                entry = LogEvent.join.measure(started = true) { current.join(room, password) }
                if (session !== current) return@launch
                calls.leaveAndWait()
                if (session !== current) return@launch
                handedOff = calls.join(current, entry)
            } catch (e: CancellationException) {
                calls.callStage(CallStage.authorizationCancelled, phase = DiagnosticPhase.authorizing, expected = generation)
                throw e
            } catch (e: Exception) {
                calls.callStage(CallStage.authorizationRejected, e.clientFailure().code, DiagnosticPhase.authorizing, generation)
                if (session === current) {
                    val signedOut = (e as? ChirpException)?.sessionFailure
                    if (signedOut != null) clearSession(current, signedOut)
                    else mutableState.update { it.copy(joinFailure = JoinFailure(room.id, e.clientFailure())) }
                }
            } finally {
                if (!handedOff) entry?.let { withContext(NonCancellable) { runCatching { current.leave(it) } } }
                if (!handedOff) calls.audio.resumeSettingsIfIdle()
                if (session === current) mutableState.update { it.copy(preparingRoom = null) }
            }
        }
    }

    fun dismissJoinError(roomId: String) = mutableState.update {
        if (it.joinFailure?.roomId == roomId) it.copy(joinFailure = null) else it
    }

    fun cancelJoin() { joinJob?.cancel() }

    fun configureAudio(preset: cn.youzifeile.chirp.media.AudioPreset, activation: Boolean, threshold: Float) {
        val old = calls.audio.state.value
        val operation = when {
            old.preset != preset -> LogEvent.selectPreset
            old.activation != activation -> if (activation) LogEvent.enableVoiceActivation else LogEvent.disableVoiceActivation
            old.threshold != threshold -> LogEvent.changeActivationThreshold
            else -> null
        }
        val span = operation?.begin(started = true)
        try { calls.audio.configure(preset, activation, threshold) } catch (e: Exception) { span?.finish(e); calls.audio.reportError(e.clientFailure("AUDIO_PRESET_FAILED").code); return }
        viewModelScope.launch {
            try { app.settings.saveAudioSettings(preset, activation, threshold); span?.finish() }
            catch (e: CancellationException) { span?.finish(e); throw e }
            catch (e: Exception) { span?.finish(e); calls.audio.reportError("AUDIO_PREFERENCE_SAVE_FAILED") }
        }
    }

    fun logout() {
        val current = session ?: return
        if (state.value.checking) return
        viewModelScope.launch {
            clearSession(current, null)
            val signedOut = state.value.takeIf { session == null && it.connection === current.connection && !it.authorizing && setup == null }
            try {
                LogEvent.logout.measure(started = true) { current.logout() }
            } catch (e: CancellationException) { throw e }
            catch (e: IOException) {
                val reason = when {
                    e is ChirpException && e.code == "MEMBER_DISABLED" -> e.code
                    e is ChirpException && e.status == 401 -> null
                    else -> "LOGOUT_OFFLINE"
                }
                if (reason != null && signedOut != null) mutableState.compareAndSet(signedOut, signedOut.copy(error = ClientFailure(reason)))
            }
        }
    }

    private fun sessionError(current: SessionRepository, e: Exception) {
        if (session !== current) return
        val failure = (e as? ChirpException)?.sessionFailure
        if (failure == null) error(e) else clearSession(current, failure)
    }

    internal fun endTaskSession(): SessionRepository? = session?.also { clearSession(it, null) }

    private fun clearSession(current: SessionRepository, failure: String?) {
        if (session !== current) return
        calls.leave()
        discardAvatar()
        profileImages?.close()
        profileImages = null
        session = null
        LogEvent.sessionEnded.record(error = failure)
        disabledJob?.cancel()
        mutableState.update { it.copy(account = null, accountDevice = null, directory = null, directoryLoadFailed = false, profileSession = null, profileNotice = null, editingProfile = false, checking = false, identity = AccountView(), error = failure?.let(::ClientFailure), joinFailure = null, preparingRoom = null) }
        directoryJob?.cancel()
        syncJob?.cancel()
        joinJob?.cancel()
    }

    suspend fun renameDevice(key: String, name: String): ClientFailure? {
        val current = session ?: return ClientFailure("SESSION_EXPIRED")
        return try {
            current.accountIdentity.rename(key, name)
            null
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) {
            (e as? ChirpException)?.sessionFailure?.let { clearSession(current, it) }
            e.clientFailure()
        }
    }

    fun accountAction(action: suspend (AccountIdentity) -> Unit) {
        val current = session ?: return
        viewModelScope.launch {
            try { action(current.accountIdentity) }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { sessionError(current, e) }
        }
    }

    fun newPairing(owner: IdentitySetup) {
        if (setup !== owner || setupJob?.isActive == true || state.value.setupPairing != null || !clockReady()) return
        mutableState.update { it.copy(checking = true, error = null) }
        setupJob = viewModelScope.launch {
            try {
                val session = DevicePairing.create(owner, app.http, ::requireClock) { setup === owner }
                if (setup === owner) mutableState.update { it.copy(setupPairing = session) } else session.close()
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (setup === owner) error(e) }
            finally { if (setup === owner) mutableState.update { it.copy(checking = false) } }
        }
    }
    fun closeSetupPairing() {
        val session = state.value.setupPairing ?: return
        mutableState.update { it.copy(setupPairing = null) }
        session.close()
    }
    override fun onCleared() {
        closeSetupPairing()
    }
    fun reloadLocalIdentities() {
        viewModelScope.launch {
            try { startup.await(); refreshLocalIdentities() }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { error(e) }
        }
    }

    private suspend fun refreshLocalIdentities() {
        val identities = app.identities.savedIdentities()
        val selected = app.identities.read("selected-account-identity")
        mutableState.update { it.copy(savedIdentities = identities, selectedIdentity = identities.find { item -> item.scope == selected }) }
    }

    fun selectLocalIdentity(identity: SavedIdentity?) {
        LogEvent.selectIdentity.record()
        viewModelScope.launch {
            try {
                verify(identity == null || identity in state.value.savedIdentities, "DEVICE_IDENTITY_REQUIRED")
                app.identities.write("selected-account-identity", identity?.scope.orEmpty())
                mutableState.update { it.copy(selectedIdentity = identity) }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { error(e) }
        }
    }

    fun findSavedIdentity(address: String, account: String) {
        viewModelScope.launch {
            try {
                LogEvent.findIdentity.measure(started = true) {
                    val url = parseServerAddress(address, cn.youzifeile.chirp.BuildConfig.DEBUG)
                    verify(url.encodedPath == "/" && memberIDPattern.matches(account), "DEVICE_IDENTITY_REQUIRED")
                    val origin = url.identityOrigin
                    val local = IdentitySetup.loadRecord(app.identities, IdentitySetup.scope(origin, account)).active
                        ?: throw ChirpException("DEVICE_IDENTITY_REQUIRED")
                    local.validate()
                    val item = app.identities.savedIdentities().find { it.origin == origin && it.account == account }
                        ?: SavedIdentity(origin, account, account, local.device.accountKey, url.toString())
                    app.identities.rememberIdentity(item)
                    app.identities.write("selected-account-identity", item.scope)
                    refreshLocalIdentities()
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { error(e) }
        }
    }

    suspend fun approvePairing(code: String): cn.youzifeile.chirp.data.DevicePairing = LogEvent.approveDevice.measure(started = true) {
        requireClock()
        val request = cn.youzifeile.chirp.data.PairRequest.parse(code)
        val signedIn = session
        if (signedIn != null) verify(request.origin == signedIn.connection.passkeyOrigin.identityOrigin &&
            request.account == signedIn.login.memberID && request.root == signedIn.login.device?.accountKey, "DEVICE_PAIRING_INVALID")
        val selected = if (signedIn == null) state.value.selectedIdentity else null
        verify(selected == null || (request.origin == selected.origin && request.account == selected.account), "DEVICE_PAIRING_INVALID")
        val known = selected ?: state.value.savedIdentities.find { it.origin == request.origin && it.account == request.account }
        val local = IdentitySetup.loadRecord(app.identities, IdentitySetup.scope(request.origin, request.account)).active
            ?: throw ChirpException("DEVICE_IDENTITY_REQUIRED")
        local.validate()
        verify(local.device.accountKey == request.root, "DEVICE_PAIRING_INVALID")
        val current = signedIn?.connection ?: state.value.connection
        val connection = current?.takeIf { it.passkeyOrigin.identityOrigin == request.origin }
            ?: app.server.discover(known?.discovery ?: request.origin)
        verify(connection.passkeyOrigin.identityOrigin == request.origin, "DEVICE_PAIRING_INVALID")
        val pairing = cn.youzifeile.chirp.data.DevicePairing.approve(request,local,connection,app.http, ::requireClock) {
            session === signedIn && (signedIn != null || state.value.selectedIdentity == selected)
        }
        try {
            if (known == null) {
                app.identities.rememberIdentity(SavedIdentity(request.origin, request.account, request.account, local.device.accountKey, connection.origin.toString()))
                refreshLocalIdentities()
            }
            requireClock()
            pairing
        } catch (e: Throwable) {
            pairing.close()
            throw e
        }
    }
    fun resetLocal() {
        if (state.value.resettingLocal) return
        LogEvent.clearLocalData.record()
        mutableState.update { it.copy(checking = true, resettingLocal = true, error = null) }
        viewModelScope.launch {
            try {
                loginJob?.cancelAndJoin(); setupJob?.cancelAndJoin(); joinJob?.cancelAndJoin()
                calls.leaveAndWait()
                // Android clears the app's private data and terminates this process.
                verify(app.getSystemService(android.app.ActivityManager::class.java).clearApplicationUserData(), "RESET_FAILED")
            } catch (e: CancellationException) { throw e }
            catch (_: Exception) { mutableState.update { it.copy(checking = false, resettingLocal = false, error = ClientFailure("RESET_FAILED")) } }
        }
    }

    fun rename(name: String) = editProfile(cn.youzifeile.chirp.R.string.profile_renamed) { it.rename(name.trim()) }

    fun selectAvatar(uri: Uri, ownerID: String? = state.value.profileSession) {
        if (ownerID == null || ownerID != state.value.profileSession) return
        val owner = session ?: return
        discardAvatar()
        mutableState.update { it.copy(preparingAvatar = true, profileNotice = null, error = null) }
        avatarJob = viewModelScope.launch {
            try {
                LogEvent.chooseAvatar.measure(started = true) {
                    val avatar = withContext(Dispatchers.IO) {
                        val stream = app.contentResolver.openInputStream(uri) ?: throw ChirpException("AVATAR_INVALID")
                        stream.use(PreparedAvatar::read)
                    }
                    if (session === owner) mutableState.update { it.copy(avatarDraft = avatar, preparingAvatar = false) }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (session === owner) mutableState.update { it.copy(preparingAvatar = false,
                    error = e.clientFailure("AVATAR_INVALID")) }
            }
        }
    }

    fun discardAvatar() {
        if (state.value.avatarDraft != null) LogEvent.discardAvatar.record()
        avatarJob?.cancel()
        mutableState.update { it.copy(avatarDraft = null, preparingAvatar = false) }
    }

    fun changeAvatar(avatar: PreparedAvatar?) {
        if (avatar != null && state.value.avatarDraft !== avatar) return
        val notice = if (avatar == null) cn.youzifeile.chirp.R.string.profile_avatar_removed else cn.youzifeile.chirp.R.string.profile_avatar_saved
        editProfile(notice, ::discardAvatar) { current -> current.updateAvatar(avatar?.png) }
    }

    private fun editProfile(notice: Int, onSaved: () -> Unit = {}, save: suspend (SessionRepository) -> Profile) {
        val current = session ?: return
        if (state.value.editingProfile) return
        mutableState.update { it.copy(editingProfile = true, profileNotice = null, error = null) }
        viewModelScope.launch {
            try {
                val profile = save(current)
                if (session === current) {
                    val saved = mutableState.updateAndGet { before ->
                        val latest = before.account?.takeIf { it.id == profile.id && it.revision > profile.revision } ?: profile
                        before.copy(account = latest, directory = before.directory?.withKnownProfiles(null, latest), profileNotice = notice)
                    }
                    saved.directory?.let { calls.updateProfileNames(it.members) }
                    onSaved()
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                sessionError(current, e)
            } finally {
                if (session === current) mutableState.update { it.copy(editingProfile = false) }
            }
        }
    }

    suspend fun avatar(profile: Profile): Bitmap? {
        val current = session ?: return null
        return try {
            profileImages?.forDisplay(profile)
        } catch (e: CancellationException) {
            throw e
        } catch (e: ChirpException) {
            e.sessionFailure?.let { clearSession(current, it) }
            null
        } catch (_: Exception) {
            null
        }
    }

    fun clearError() = mutableState.update { it.copy(error = null, profileNotice = null) }

    private fun error(e: Exception) {
        if (e is ChirpException && e.code == "NETWORK_TIME_REQUIRED") return
        val failure = e.clientFailure()
        mutableState.update { it.copy(error = failure,
            connection = if (failure.code == "SERVER_CONFIGURATION_CHANGED") null else it.connection) }
    }
}
