package cn.youzifeile.chirp.data

import kotlinx.coroutines.CancellationException

internal enum class LogTable { application, navigation, account, identity, network, room, call, audio, crypto, chat, attachment, settings }

/** Operation names are client constants. No overload accepts a URL, request, exception text or user input. */
internal enum class LogEvent(val table: LogTable) {
    launch(LogTable.application), active(LogTable.application), background(LogTable.application), storageOverflow(LogTable.application),

    login(LogTable.navigation), identitySetup(LogTable.navigation), rooms(LogTable.navigation), room(LogTable.navigation),
    roomChat(LogTable.navigation), roomMembers(LogTable.navigation), roomInformation(LogTable.navigation), memberAudio(LogTable.navigation),
    friends(LogTable.navigation), friendDetails(LogTable.navigation), settings(LogTable.navigation), profile(LogTable.navigation),
    audioSettings(LogTable.navigation), logSettings(LogTable.navigation), storageSettings(LogTable.navigation),
    devices(LogTable.navigation), blacklist(LogTable.navigation), localIdentity(LogTable.navigation), fingerprint(LogTable.navigation),
    pairingRequest(LogTable.navigation), expandProtocol(LogTable.navigation),
    disclosure(LogTable.navigation),

    browserLogin(LogTable.account), phoneLogin(LogTable.account), loginCallback(LogTable.account),
    loginAccepted(LogTable.account), sessionEnded(LogTable.account), logout(LogTable.account), openRegistration(LogTable.account), openBrowser(LogTable.account),
    chooseAvatar(LogTable.account), discardAvatar(LogTable.account), changeAvatar(LogTable.account), removeAvatar(LogTable.account),
    renameProfile(LogTable.account), cancelLogin(LogTable.account),

    createIdentity(LogTable.identity), resumeSetup(LogTable.identity), restoreIdentity(LogTable.identity), verifyBackup(LogTable.identity),
    chooseRecoveryFile(LogTable.identity), exportRecoveryFile(LogTable.identity), confirmBackup(LogTable.identity), selectIdentity(LogTable.identity), findIdentity(LogTable.identity),
    newDevicePairing(LogTable.identity), approveDevice(LogTable.identity), confirmNewDevice(LogTable.identity), stopPairing(LogTable.identity),
    scanPairingCode(LogTable.identity), importPairingImage(LogTable.identity), savePairingImage(LogTable.identity), sharePairingImage(LogTable.identity),
    renameDevice(LogTable.identity), revokeDevice(LogTable.identity), addFriend(LogTable.identity), removeFriend(LogTable.identity),
    trustDevice(LogTable.identity), untrustDevice(LogTable.identity), identityChange(LogTable.identity),
    verification(LogTable.identity), acceptVerification(LogTable.identity), verificationMatches(LogTable.identity),
    verificationMismatch(LogTable.identity), cancelVerification(LogTable.identity), syncIdentity(LogTable.identity),

    request(LogTable.network), clientConfig(LogTable.network), health(LogTable.network), exchangeLogin(LogTable.network),
    deviceLoginStart(LogTable.network), deviceLoginPoll(LogTable.network), deviceLoginCancel(LogTable.network),
    directoryEvents(LogTable.network), directorySnapshot(LogTable.network), validateSession(LogTable.network),
    preflight(LogTable.network), admit(LogTable.network), refreshMedia(LogTable.network), leaveRoom(LogTable.network),
    endSession(LogTable.network), getProfile(LogTable.network), updateProfile(LogTable.network), getAvatar(LogTable.network), updateAvatar(LogTable.network),
    identityChallenge(LogTable.network), identityComplete(LogTable.network), identitySnapshot(LogTable.network), identityAppend(LogTable.network),
    listDevices(LogTable.network), listBlacklist(LogTable.network), identitySignals(LogTable.network), sendSignal(LogTable.network),
    deleteDevice(LogTable.network), updateDevice(LogTable.network), pairingStart(LogTable.network), pairingAction(LogTable.network),
    groupConfig(LogTable.network), groupJoin(LogTable.network), groupSnapshot(LogTable.network), groupRefresh(LogTable.network),
    groupPackage(LogTable.network), groupPublish(LogTable.network), groupAck(LogTable.network), groupHeartbeat(LogTable.network),
    mediaLease(LogTable.network), groupEvents(LogTable.network), rotationPackage(LogTable.network), rotationPublish(LogTable.network),
    rotationAck(LogTable.network), rotationActivate(LogTable.network), groupAction(LogTable.network),
    attachmentEvents(LogTable.network), attachmentCatalog(LogTable.network), attachmentReserve(LogTable.network),
    attachmentStatus(LogTable.network), uploadChunk(LogTable.network), downloadChunk(LogTable.network), attachmentCancel(LogTable.network),
    attachmentPause(LogTable.network), attachmentComplete(LogTable.network), attachmentReceived(LogTable.network),

    join(LogTable.room), leave(LogTable.room), lifecycle(LogTable.call), trackSample(LogTable.call),
    selectInput(LogTable.audio), preferOutput(LogTable.audio), selectPreset(LogTable.audio),
    enableVoiceActivation(LogTable.audio), disableVoiceActivation(LogTable.audio), changeActivationThreshold(LogTable.audio),
    microphoneTestStarted(LogTable.audio), microphoneTestStopped(LogTable.audio), microphoneTestPlayback(LogTable.audio),
    captureInitialized(LogTable.audio), captureFailed(LogTable.audio),
    voiceDecrypt(LogTable.crypto), attachmentDecrypt(LogTable.crypto), attachmentEncrypt(LogTable.crypto),
    thumbnailDecrypt(LogTable.crypto), thumbnailEncrypt(LogTable.crypto), recoveryEncrypt(LogTable.crypto), recoveryDecrypt(LogTable.crypto),
    compose(LogTable.chat), discardDraft(LogTable.chat), restoreDraft(LogTable.chat), sendMessage(LogTable.chat), sendAttachment(LogTable.chat),
    receiveMessage(LogTable.chat), receiveAttachment(LogTable.chat),
    prepareAttachment(LogTable.attachment), selectFile(LogTable.attachment), selectPhoto(LogTable.attachment), upload(LogTable.attachment), download(LogTable.attachment),
    pauseDownload(LogTable.attachment), retryUpload(LogTable.attachment), retryDownload(LogTable.attachment),
    cancelUpload(LogTable.attachment), cancelPreparation(LogTable.attachment), previewAttachment(LogTable.attachment), exportAttachment(LogTable.attachment),
    permissionMicrophone(LogTable.settings), permissionCamera(LogTable.settings), permissionNetwork(LogTable.settings),
    editServer(LogTable.settings), confirmServer(LogTable.settings), changeLanguage(LogTable.settings), clearAttachmentCache(LogTable.settings),
    clearLocalData(LogTable.settings), recordingEnabled(LogTable.settings), recordingDisabled(LogTable.settings), exportLogs(LogTable.settings);

    fun record(outcome: LogOutcome? = null, error: String? = null) {
        ClientLog.current?.record(this, outcome = outcome, error = error)
    }

    fun begin(started: Boolean = false): LogSpan? = ClientLog.current?.begin(this, started)

    inline fun <T> measure(started: Boolean = false, block: () -> T): T {
        val span = begin(started) ?: return block()
        var failure: Throwable? = null
        try {
            return block()
        } catch (e: Throwable) {
            failure = e
            throw e
        } finally {
            span.finish(failure)
        }
    }
}

internal enum class LogOutcome { started, succeeded, failed, cancelled }

internal class LogSpan(private val log: ClientLog, private val event: LogEvent, private val generation: Long) {
    @Volatile var httpStatus: Int? = null
    private val start = System.nanoTime()
    fun finish(error: Throwable? = null, status: Int? = httpStatus) {
        val cancelled = error is CancellationException && error !is kotlinx.coroutines.TimeoutCancellationException
        val outcome = when {
            cancelled -> LogOutcome.cancelled
            error != null || (status != null && status !in 200..299) -> LogOutcome.failed
            else -> LogOutcome.succeeded
        }
        val code = when {
            error == null || cancelled -> null
            error is kotlinx.coroutines.TimeoutCancellationException -> "CLIENT_NETWORK_TIMEOUT"
            error is ChirpException -> error.diagnosticCode
            error is Exception -> error.clientFailure().code
            else -> "CLIENT_UNEXPECTED"
        }
        log.record(event, outcome, code,
            (System.nanoTime() - start) / 1000, status ?: (error as? ChirpException)?.status?.takeIf { it > 0 },
            expected = generation)
    }
}
