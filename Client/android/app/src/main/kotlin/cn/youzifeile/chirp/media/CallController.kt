package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.CallStage
import cn.youzifeile.chirp.data.ClientLog
import cn.youzifeile.chirp.data.DiagnosticPhase
import cn.youzifeile.chirp.data.LogEvent
import cn.youzifeile.chirp.data.LogOutcome
import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import androidx.core.content.ContextCompat
import androidx.core.telecom.CallEndpointCompat
import cn.youzifeile.chirp.data.ClientFailure
import cn.youzifeile.chirp.data.clientFailure
import cn.youzifeile.chirp.data.Admission
import cn.youzifeile.chirp.data.AttachmentDescriptor
import cn.youzifeile.chirp.data.ChirpException
import cn.youzifeile.chirp.data.Profile
import cn.youzifeile.chirp.data.RoomInfo
import cn.youzifeile.chirp.data.SessionRepository
import cn.youzifeile.chirp.data.verify
import cn.youzifeile.chirp.data.nowSeconds
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.updateAndGet
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal enum class CallPhase { Idle, Joining, Securing, Connected, Leaving }

internal data class CallState(
    val trust: RoomTrustView = RoomTrustView(),
    val information: RoomPublicInformation? = null,
    val room: RoomInfo? = null,
    val phase: CallPhase = CallPhase.Idle,
    val members: List<RoomMember> = emptyList(),
    val micOn: Boolean = false,
    val micChanging: Boolean = false,
    val listening: Boolean = true,
    val messages: List<ChatMessage> = emptyList(),
    val sending: Boolean = false,
    val draft: String = "",
    val draftTooLong: Boolean = false,
    val failure: ClientFailure? = null,
    val errorRoom: String? = null,
    val leftRoom: String? = null,
    val routeChanging: Boolean = false,
    val endpoints: List<CallEndpointCompat> = emptyList(),
    val endpoint: CallEndpointCompat? = null,
    val held: Boolean = false,
    val chatVisible: Boolean = false,
    val connectingMedia: Boolean = false,
    val attachments: Map<String, TransferState> = emptyMap(),
    val attachmentPreparing: Boolean = false,
    val unpublished: List<cn.youzifeile.chirp.data.AttachmentInfo> = emptyList(),
    val entryID: String? = null,
    val cacheRevision: Long = 0,
    val attachmentsRevoked: Boolean = false,
    val volumes: Map<String, Float> = emptyMap(),
    val lastAudibleVolumes: Map<String, Float> = emptyMap(),
    val diagnostics: List<TrackDiagnostic> = emptyList(),
    val attachmentPolicy: cn.youzifeile.chirp.data.AttachmentPolicy = cn.youzifeile.chirp.data.AttachmentPolicy.Normal,
) {
    val error: String? get() = failure?.code
}

internal fun CallState.withMemberVolume(identity: String, volume: Float): CallState {
    val level = volume.coerceIn(0f, 2f)
    return copy(volumes = volumes + (identity to level), lastAudibleVolumes =
        if (level > 0f) lastAudibleVolumes + (identity to level) else lastAudibleVolumes)
}

internal fun CallState.toggledVolume(identity: String): Float =
    if ((volumes[identity] ?: 1f) == 0f) lastAudibleVolumes[identity] ?: 1f else 0f

internal fun CallState.editDraft(text: String): CallState {
    if (!chatVisible || held || phase != CallPhase.Connected) return this
    val tooLong = text.length > MAX_CHAT_TEXT || text.encodeToByteArray().size > MAX_CHAT_TEXT
    return if (tooLong) copy(draftTooLong = true) else copy(draft = text, draftTooLong = false)
}

internal class JoinRequest(val session: SessionRepository, val admission: Admission) {
    val room get() = admission.room
    var releasing = false
}

internal class CallController(
    private val context: Context,
    private val startCallService: (String) -> Unit = { entryID ->
        context.startService(Intent(context, CallService::class.java).setIdentifier(entryID))
    },
) {
    private val mutableState = MutableStateFlow(CallState())
    val state = mutableState.asStateFlow()
    val audio = AudioControl(context, { state.value.room != null }, { leave() })
    private val sounds = RoomPresenceSounds(context)
    private var presence = RoomPresenceTracker()
    private val diagnostics = CallDiagnostics()
    fun callStage(stage: CallStage, failure: String? = null, phase: DiagnosticPhase = state.value.diagnosticPhase(),
        expected: Long = ClientLog.current?.generation ?: 0L) {
        if (expected != 0L) diagnostics.lifecycle(stage, state.value, audio.settings.preset, failure, phase, expected)
    }
    private var request: JoinRequest? = null
    private var claimed = false
    private var work: Job? = null
    private var scope: CoroutineScope? = null
    private var media: RoomMedia? = null
    private var chat: RoomChat? = null
    private var files: RoomAttachments? = null
    private var service: CallService? = null
    private var systemMuted = false
    private var micRequested = false
    private var sendJob: Job? = null
    private var micJob: Job? = null
    private var fileJob: Job? = null
    private var activeEntry: Admission? = null
    private var roomTrust: RoomTrust? = null
    private var rawTrust = RoomTrustView()
    private var profileNames: Map<String, String> = emptyMap()

    fun updateProfileNames(profiles: List<Profile>) {
        profileNames = profiles.associate { it.id to it.name }
        refreshDisplayNames()
    }

    private fun displayName(identity: String, fallback: String): String {
        val join = request ?: return fallback
        if (identity == join.admission.identity) return profileNames[join.session.login.memberID] ?: join.session.login.name
        val account = join.session.accountIdentity
        val root = rawTrust.peers.firstOrNull { it.identity == identity }?.binding?.device?.accountKey
        return roomDisplayName(identity, root, account.view.value.friends, profileNames, fallback)
    }

    private fun refreshDisplayNames() {
        val peers = rawTrust.peers.map { it.copy(name = displayName(it.identity, it.name)) }
        val roster = media?.roster.orEmpty()
        mutableState.update { state ->
            state.copy(trust = rawTrust.copy(peers = peers), members = state.members.map {
                it.copy(name = displayName(it.identity, roster[it.identity] ?: it.name))
            })
        }
    }

    fun identityAction(action: String, peer: String = "", transaction: String? = null) {
        val trust = roomTrust ?: return
        scope?.launch { trust.act(action, peer, transaction) }
    }
    private val packetMutex = Mutex()
    private val attachmentReset = Mutex()
    private val held = MutableStateFlow(false)

    fun join(session: SessionRepository, admission: Admission): Boolean {
        if (request != null) return false
        val next = JoinRequest(session, admission)
        val room = admission.room
        presence = RoomPresenceTracker()
        rawTrust = RoomTrustView()
        request = next
        held.value = false
        mutableState.value = CallState(room = room, phase = CallPhase.Joining)
        diagnostics.resetTransport()
        callStage(CallStage.admissionAccepted)
        try {
            startCallService(admission.entryID)
        } catch (e: RuntimeException) {
            finish(next, ClientFailure("CALL_SERVICE_UNAVAILABLE"))
        }
        return true
    }

    fun claim(owner: CallService, entryID: String?): JoinRequest? {
        if (claimed || request?.releasing == true) return null
        val pending = request ?: return null
        if (pending.admission.entryID != entryID) return null
        claimed = true
        service = owner
        return pending
    }

    fun bind(job: Job) {
        work = job
    }

    fun leaveEntry(entryID: String?) {
        if (entryID != null && request?.admission?.entryID == entryID) leave()
    }

    fun leave() {
        val pending = request ?: return
        micRequested = false
        LogEvent.leave.record()
        callStage(CallStage.leaving, phase = DiagnosticPhase.leaving)
        sounds.stop()
        media?.gate?.revoke()
        files?.revoke()
        mutableState.update { it.copy(phase = CallPhase.Leaving, micOn = false, chatVisible = false,
            messages = emptyList(), attachments = emptyMap(), unpublished = emptyList(), draft = "") }
        if (claimed) work?.cancel() else finish(pending, null)
    }

    suspend fun leaveAndWait() {
        leave()
        state.first { it.phase == CallPhase.Idle }
    }

    fun finish(join: JoinRequest, error: ClientFailure?) {
        if (request !== join || join.releasing) return
        join.releasing = true
        mutableState.update { it.copy(phase = CallPhase.Leaving) }
        CoroutineScope(kotlinx.coroutines.Dispatchers.Main.immediate).launch {
            try { runCatching { join.session.leave(join.admission) } }
            finally { finishReleased(join, error) }
        }
    }

    private fun finishReleased(join: JoinRequest, error: ClientFailure?) {
        if (request !== join) return
        callStage(if (error == null) CallStage.cleanedUp else CallStage.failed, error?.code)
        diagnostics.resetTransport()
        request = null
        rawTrust = RoomTrustView()
        claimed = false
        service = null
        work = null
        scope = null
        media = null
        chat = null
        files = null
        activeEntry = null
        sendJob = null
        fileJob = null
        micJob = null
        systemMuted = false
        micRequested = false
        mutableState.value = CallState(failure = error, errorRoom = join.room.id, leftRoom = join.room.id.takeIf { error == null })
        audio.resumeSettingsIfIdle()
    }

    fun updateDirectory(session: SessionRepository, directory: cn.youzifeile.chirp.data.Directory) {
        if (!directory.fresh) return
        val join = request
        if (join != null && join.session.login.credential != session.login.credential) return
        updateProfileNames(directory.members)
        if (join == null || join.releasing) return
        val room = directory.rooms.firstOrNull { it.id == join.room.id }
        if (room == null) leave()
        else mutableState.update { it.copy(room = room) }
    }

    fun clearError() {
        mutableState.update { it.copy(failure = null) }
    }

    suspend fun run(join: JoinRequest): Nothing = coroutineScope {
        scope = this
        val recovery = DecryptionRecovery()
        var firstAccess = true
        try {
            val entry = join.admission
            activeEntry = entry
            mutableState.update { it.copy(entryID = entry.entryID) }
            val transcript = RoomChat(entry.identity, ::displayName)
            chat = transcript
            val attachments = openAttachments(join, entry, this)
            files = attachments
            mutableState.update { it.copy(phase = CallPhase.Securing) }
            callStage(CallStage.groupStarted)
            val trust = RoomTrust(join.session.accountIdentity, entry) { value ->
                if (activeEntry === entry) {
                    if (!rawTrust.pending && value.pending) callStage(CallStage.verificationPending, phase = DiagnosticPhase.verifying)
                    rawTrust = value
                    refreshDisplayNames()
                    if (value.pending) { micRequested = false; pauseMedia() }
                }
            }
            roomTrust = trust
            launch { trust.follow() }
            launch { join.session.accountIdentity.view.collect { if (activeEntry === entry) refreshDisplayNames() } }
            SecureGroup(
                join.session, entry,
                install = { group, keys ->
                    retireMedia()
                    recovery.resetTracks()
                    val access = if (firstAccess && entry.access.deadline > nowSeconds() + 5) entry.access
                        else join.session.refreshMedia(entry)
                    firstAccess = false
                    lateinit var current: RoomMedia
                    current = RoomMedia(
                        context, join.session, entry, group, keys, this,
                        onMembers = { members ->
                            if (media === current) mutableState.update { state ->
                                state.copy(members = members.map { it.copy(name = displayName(it.identity, it.name)) })
                            }
                        },
                        onData = { sender, bytes ->
                            if (media === current && transcript.receive(current.gate.groupID, current.roster, sender, bytes, { files?.accept(it) == true })) refreshChat()
                        },
                        onFault = {
                            if (media === current) {
                                presence.resynchronize(); sounds.stop()
                                callStage(CallStage.recoveryStarted)
                                micRequested = false
                                pauseMedia()
                            }
                        },
                        onReady = {
                            if (media === current && !held.value) {
                                files?.setMedia(current)
                                mutableState.update { it.copy(phase = CallPhase.Connected, chatVisible = true, connectingMedia = false) }
                                callStage(CallStage.activated)
                                val cues = presence.confirm(current.roster.keys, entry.identity)
                                if (state.value.listening && !state.value.held) sounds.play(cues)
                                if (micRequested) changeMic(true, restoring = true)
                            }
                        },
                        audio = audio,
                        onStage = { stage ->
                            if (media === current) {
                                if (stage == CallStage.keysInstalled) diagnostics.keyRevision++
                                callStage(stage)
                            }
                        },
                        onDiagnostics = { tracks, generation ->
                            if (media === current) {
                                if (generation != 0L) diagnostics.sample(state.value, audio.settings.preset, current.gate.remainingIfGranted(), tracks, generation)
                                val policy = when {
                                    state.value.phase != CallPhase.Connected || tracks.any { it.quality == "LOST" && it.subscribed && !it.muted } -> cn.youzifeile.chirp.data.AttachmentPolicy.Paused
                                    tracks.any { it.subscribed && !it.muted && (it.quality == "POOR" || (it.jitterMS ?: 0.0) >= 40) } -> cn.youzifeile.chirp.data.AttachmentPolicy.Constrained
                                    else -> cn.youzifeile.chirp.data.AttachmentPolicy.Normal
                                }
                                if (state.value.phase == CallPhase.Connected) {
                                    when (recovery.observe(tracks, android.os.SystemClock.elapsedRealtime())) {
                                        DecryptionRecovery.Action.Recover -> {
                                            callStage(CallStage.decryptionRecovery)
                                            micRequested = false
                                            pauseMedia()
                                            return@RoomMedia
                                        }
                                        DecryptionRecovery.Action.Stop -> throw ChirpException("AUDIO_DECRYPTION_RECOVERY_FAILED")
                                        null -> Unit
                                    }
                                }
                                files?.bandwidth?.policy = policy
                                mutableState.update { it.copy(diagnostics = tracks, attachmentPolicy = policy) }
                            }
                        },
                    )
                    current.gate.systemMuted = systemMuted
                    current.listening = state.value.listening && !state.value.held
                    current.volumes = state.value.volumes
                    media = current
                    transcript.install(current)
                    mutableState.update { it.copy(connectingMedia = true) }
                    diagnostics.transport++
                    diagnostics.keyRevision++
                    callStage(CallStage.keysInstalled)
                    callStage(CallStage.mediaConnectStarted)
                    current.connect(access)
                    callStage(CallStage.mediaConnected)
                    current
                },
                closeMedia = ::retireMedia,
                makeTransport = { session, admission, native -> GroupTransport(session,admission,native,trust) { info ->
                    mutableState.update { it.copy(information = info) }
                } },
            ).run(held)
        } finally {
            roomTrust?.close()
            roomTrust = null
            pauseMedia()
            files?.revoke()
            withContext(NonCancellable) {
                sendJob?.cancelAndJoin()
                fileJob?.cancelAndJoin()
                micJob?.cancelAndJoin()
                try { files?.close() } finally {
                    retireMedia()
                }
            }
        }
    }

    private fun pauseMedia() {
        val current = media ?: return
        current.pause()
        sounds.stop()
        files?.bandwidth?.policy = cn.youzifeile.chirp.data.AttachmentPolicy.Paused
        files?.setMedia(null)
        sendJob?.cancel()
        micJob?.cancel()
        if (state.value.phase != CallPhase.Leaving) {
            mutableState.update { it.copy(phase = CallPhase.Securing, connectingMedia = false, micOn = false, micChanging = false,
                members = emptyList(), diagnostics = emptyList()) }
        }
    }

    private suspend fun retireMedia() {
        val current = media ?: return
        pauseMedia()
        media = null
        sendJob?.cancelAndJoin()
        micJob?.cancelAndJoin()
        if (!micRequested) service?.demoteMicrophone()
        current.close()
    }

    fun setListening(enabled: Boolean) {
        val state = state.value
        if (!enabled) { sounds.stop(); presence.resynchronize() }
        mutableState.update { it.copy(listening = enabled) }
        media?.listening = enabled && !state.held
        callStage(CallStage.listeningChanged)
    }

    fun setHeld(held: Boolean) {
        if (request == null || request?.releasing == true || state.value.phase == CallPhase.Leaving || this.held.value == held) return
        if (held) {
            presence.resynchronize()
            sounds.stop()
            pauseMedia()
            sendJob?.cancel()
            fileJob?.cancel()
            if (!micRequested) service?.demoteMicrophone()
        }
        mutableState.update { it.copy(held = held, phase = CallPhase.Securing, micOn = false) }
        this.held.value = held
        callStage(if (held) CallStage.audioInterrupted else CallStage.audioResumed)
    }

    fun resumeAudio() {
        if (held.value) service?.resumeHeldCall()
    }

    fun setMemberVolume(identity: String, volume: Float) {
        val current = media ?: return
        if (identity !in current.recipients || !volume.isFinite()) return
        val updated = mutableState.updateAndGet { it.withMemberVolume(identity, volume) }
        current.volumes = updated.volumes
        callStage(CallStage.memberVolumeChanged)
    }

    fun toggleMemberMute(identity: String) {
        setMemberVolume(identity, state.value.toggledVolume(identity))
    }

    fun setSystemMute(muted: Boolean) {
        systemMuted = muted
        val current = media ?: return
        current.setSystemMuted(muted)
        mutableState.update { it.copy(micOn = current.gate.micAllowed && !muted) }
        callStage(CallStage.microphoneChanged)
        if (!muted && micRequested && !current.gate.micAllowed) changeMic(true, restoring = true)
    }

    fun setEndpoints(endpoints: List<CallEndpointCompat>) {
        mutableState.update { it.copy(endpoints = endpoints) }
    }

    fun setEndpoint(endpoint: CallEndpointCompat) {
        mutableState.update { it.copy(endpoint = endpoint) }
        callStage(CallStage.audioRouteChanged)
    }

    fun setRouteChanging(entryID: String, changing: Boolean) {
        mutableState.update { if (it.entryID == entryID) it.copy(routeChanging = changing) else it }
    }

    fun chooseEndpoint(endpoint: CallEndpointCompat) {
        LogEvent.preferOutput.record()
        service?.route(endpoint)
    }

    fun setMic(enabled: Boolean) = changeMic(enabled, restoring = false)

    private fun changeMic(enabled: Boolean, restoring: Boolean) {
        callStage(CallStage.microphoneRequested)
        if (!enabled) micRequested = false
        val owner = service ?: return
        val current = media
        if (current == null) {
            if (!enabled) owner.demoteMicrophone()
            return
        }
        if (!enabled) current.gate.micAllowed = false
        if (enabled && (state.value.phase != CallPhase.Connected || state.value.held || systemMuted ||
                current.gate.remaining() <= 0 || micJob?.isActive == true)
        ) return
        if (enabled && ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            micRequested = false
            owner.demoteMicrophone()
            showError("MICROPHONE_PERMISSION_REQUIRED")
            return
        }
        val previous = micJob
        previous?.cancel()
        micJob = scope?.launch {
            previous?.join()
            mutableState.update { it.copy(micChanging = true) }
            try {
                if (enabled && !restoring) {
                    owner.promoteMicrophone()
                    micRequested = true
                }
                withTimeout(5_000) { current.setMic(enabled) }
            } catch (_: TimeoutCancellationException) {
                micRequested = false
                current.gate.micAllowed = false
                showError("MICROPHONE_UNAVAILABLE")
            } catch (e: CancellationException) {
                current.gate.micAllowed = false
                throw e
            } catch (_: Exception) {
                micRequested = false
                current.gate.micAllowed = false
                showError("MICROPHONE_UNAVAILABLE")
            } finally {
                if (!current.gate.micAllowed) {
                    if (enabled) withContext(NonCancellable) { runCatching { current.setMic(false) } }
                    if (!micRequested) owner.demoteMicrophone()
                }
                if (media === current) {
                    mutableState.update { it.copy(micChanging = false, micOn = current.gate.micAllowed && !systemMuted) }
                    callStage(CallStage.microphoneChanged)
                }
            }
        }
    }

    fun updateDraft(text: String, entryID: String?): String? {
        if (entryID == null) return null
        val wasEmpty = state.value.draft.isEmpty()
        val current = mutableState.updateAndGet { if (it.entryID == entryID) it.editDraft(text) else it }
        if (current.entryID == entryID && current.chatVisible && wasEmpty != current.draft.isEmpty()) {
            (if (wasEmpty) LogEvent.compose else LogEvent.discardDraft).record()
        }
        return current.draft.takeIf { current.entryID == entryID && current.chatVisible }
    }

    fun restoreFailed(id: String, entryID: String?) {
        if (entryID == null || state.value.entryID != entryID || state.value.draft.isNotEmpty() || !state.value.chatVisible) return
        val message = chat?.messages?.find { it.id == id && it.own && it.delivery == Delivery.Failed && it.attachment == null } ?: return
        LogEvent.restoreDraft.record()
        updateDraft(message.text, entryID)
    }

    suspend fun thumbnail(id: String): Bitmap? = try { files?.thumbnail(id) }
        catch (e: CancellationException) { throw e } catch (_: Exception) { null }

    fun sendDraft(entryID: String?) {
        if (entryID == null || state.value.entryID != entryID) return
        val text = state.value.draft
        if (!validChatText(text)) return
        val current = media ?: return
        val transcript = chat ?: return
        val owner = scope ?: return
        if (sendJob?.isActive == true || state.value.phase != CallPhase.Connected || current.gate.remaining() == 0L) return
        val span = LogEvent.sendMessage.begin(started = true)
        try {
            val (id, bytes) = transcript.prepare(current, text)
            mutableState.update { it.copy(draft = "", draftTooLong = false, sending = true) }
            refreshChat()
            sendJob = owner.launch {
                try { sendPrepared(current, transcript, id, bytes); span?.finish() }
                catch (e: TimeoutCancellationException) { span?.finish(e); if (chat === transcript) showError("CHAT_SEND_FAILED") }
                catch (e: CancellationException) { span?.finish(e); throw e }
                catch (e: Exception) {
                    span?.finish(e)
                    if (chat === transcript) showError("CHAT_SEND_FAILED")
                }
                finally { if (chat === transcript) mutableState.update { it.copy(sending = false) } }
            }
        } catch (e: Exception) {
            span?.finish(e)
            showError("CHAT_SEND_FAILED")
        }
    }

    fun sendFile(uri: Uri) {
        val current = media ?: return
        val transcript = chat ?: return
        val attachments = files ?: return
        if (state.value.phase != CallPhase.Connected || held.value || fileJob?.isActive == true ||
            state.value.attachmentPreparing || current.gate.remaining() == 0L) return
        fileJob = scope?.launch {
            mutableState.update { it.copy(attachmentPreparing = true) }
            try {
                val audience = current.recipients.toSet()
                val groupID = current.gate.groupID
                attachments.send(uri, current) { descriptor ->
                    while (sendJob?.isActive == true) kotlinx.coroutines.delay(25)
                    val publisher = media ?: throw ChirpException("GROUP_CHANGED")
                    verify(files === attachments && chat === transcript && publisher.gate.groupID == groupID &&
                        publisher.recipients.toSet() == audience, "GROUP_CHANGED")
                    LogEvent.sendAttachment.measure(started = true) { sendPacket(publisher, transcript, "", descriptor) }
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (files === attachments) showError(e.clientFailure("ATTACHMENT_FAILED")) }
            finally { if (files === attachments) mutableState.update { it.copy(attachmentPreparing = false) } }
        }
    }

    fun sendFile(uri: Uri, entryID: String?, cacheRevision: Long) {
        if (entryID != null && entryID == state.value.entryID && cacheRevision == state.value.cacheRevision) sendFile(uri)
    }
    fun cancelAttachmentPreparation() { files?.cancelPreparation() }
    fun cancelAttachment(id: String) { files?.cancelUpload(id) }
    fun pauseAttachment(id: String) { files?.pauseDownload(id) }

    suspend fun clearAttachmentCache() = withContext(NonCancellable) {
        LogEvent.clearAttachmentCache.measure(started = true) { attachmentReset.withLock { resetAttachments() } }
    }

    private suspend fun resetAttachments() {
        val join = request
        val entry = activeEntry
        val previous = files
        if (previous?.authorizationEnded == true) { previous.close(); return }
        if (previous == null && entry != null) return
        files = null
        previous?.revoke()
        mutableState.update { it.copy(attachments = emptyMap(), unpublished = emptyList(), attachmentPreparing = false,
            cacheRevision = it.cacheRevision + 1) }
        fileJob?.cancelAndJoin()
        previous?.close()
        if (join == null || entry == null) {
            RoomAttachments.clearIfIdle(context) { state.value.room == null }
            return
        }
        if (request !== join || activeEntry !== entry) return
        val owner = scope ?: return
        if (state.value.phase == CallPhase.Leaving) return
        val fresh = openAttachments(join, entry, owner)
        if (activeEntry !== entry || request !== join) { fresh.close(); return }
        files = fresh
        fresh.bandwidth.policy = state.value.attachmentPolicy
        fresh.setMedia(media)
    }

    private suspend fun openAttachments(join: JoinRequest, entry: Admission, owner: CoroutineScope): RoomAttachments =
        RoomAttachments.open(context, join.session, entry, owner, onAuthorizationEnded = {
            if (activeEntry === entry) mutableState.update {
                it.copy(attachmentsRevoked = true, attachments = emptyMap(), unpublished = emptyList(),
                    attachmentPreparing = false, cacheRevision = it.cacheRevision + 1)
            }
        }) { states ->
            if (activeEntry === entry) mutableState.update { it.copy(attachments = states, unpublished = files?.unpublished.orEmpty()) }
        }

    suspend fun attachmentCacheSize(): Long = RoomAttachments.cacheSize(context)

    fun retryAttachment(id: String) {
        files?.retry(id)
    }

    fun export(id: String, destination: Uri, entryID: String?, cacheRevision: Long) {
        val active = state.value
        if (entryID == null || entryID != active.entryID || cacheRevision != active.cacheRevision ||
            active.attachments[id]?.phase != TransferPhase.Available) return
        val attachments = files ?: return
        scope?.launch {
            try {
                attachments.export(id, destination)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                if (files === attachments && state.value.entryID == entryID) showError("ATTACHMENT_EXPORT_FAILED")
            }
        }
    }

    suspend fun preview(id: String): Bitmap? {
        return try {
            files?.preview(id)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            showError("ATTACHMENT_INVALID")
            null
        }
    }

    private suspend fun sendPacket(current: RoomMedia, transcript: RoomChat, text: String,
        descriptor: AttachmentDescriptor? = null) {
        val (id, bytes) = transcript.prepare(current, text, descriptor)
        sendPrepared(current, transcript, id, bytes)
    }

    private suspend fun sendPrepared(current: RoomMedia, transcript: RoomChat, id: String, bytes: ByteArray) {
        var sent = false
        try {
            refreshChat()
            packetMutex.withLock { withTimeout(5_000) { current.send(bytes) } }
            verify(media === current && chat === transcript && current.gate.remaining() > 0, "CHAT_NOT_READY")
            sent = true
        } finally {
            bytes.fill(0)
            transcript.finish(id, sent)
            if (state.value.phase != CallPhase.Leaving) refreshChat()
        }
    }

    private fun refreshChat() {
        val transcript = chat ?: return
        mutableState.update { it.copy(messages = transcript.messages) }
    }

    fun showError(code: String) = showError(ClientFailure(code))

    private fun showError(failure: ClientFailure) {
        callStage(CallStage.failed, failure.code)
        mutableState.update { it.copy(failure = failure, errorRoom = request?.room?.id) }
    }
}
