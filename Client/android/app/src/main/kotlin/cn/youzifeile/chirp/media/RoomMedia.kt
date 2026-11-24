package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.ClientLog
import cn.youzifeile.chirp.data.CallStage
import android.content.Context
import android.os.SystemClock
import cn.youzifeile.chirp.data.Admission
import cn.youzifeile.chirp.data.ChirpException
import cn.youzifeile.chirp.data.SessionRepository
import cn.youzifeile.chirp.data.verify
import cn.youzifeile.chirp.data.randomBytes
import okhttp3.HttpUrl.Companion.toHttpUrl
import io.livekit.android.AudioOptions
import io.livekit.android.ConnectOptions
import io.livekit.android.LiveKit
import io.livekit.android.LiveKitOverrides
import io.livekit.android.RoomOptions
import io.livekit.android.audio.NoAudioHandler
import io.livekit.android.audio.AudioProcessorOptions
import io.livekit.android.e2ee.BaseKeyProvider
import io.livekit.android.e2ee.ChirpDataGate
import io.livekit.android.e2ee.E2EEOptions
import io.livekit.android.e2ee.E2EEState
import io.livekit.android.e2ee.KeyProvider
import io.livekit.android.events.RoomEvent
import io.livekit.android.room.Room
import io.livekit.android.room.network.ReconnectPolicy
import io.livekit.android.room.participant.Participant
import io.livekit.android.room.track.RemoteTrackPublication
import io.livekit.android.room.track.Track
import io.livekit.android.room.track.LocalAudioTrack
import io.livekit.android.room.track.RemoteAudioTrack
import livekit.LivekitModels.Encryption
import livekit.org.webrtc.FrameCryptorKeyDerivationAlgorithm
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext

private const val LISTENING_ATTRIBUTE = "chirp.listening"

internal data class RoomMember(
    val identity: String,
    val name: String,
    val microphoneEnabled: Boolean? = null,
    val listening: Boolean? = null,
    val speaking: Boolean = false,
    val present: Boolean = true,
)

internal class RoomMedia(
    context: Context,
    private val session: SessionRepository,
    private val admission: Admission,
    val group: GroupSnapshot,
    keys: Map<String, ByteArray>,
    private val scope: CoroutineScope,
    private val onMembers: (List<RoomMember>) -> Unit,
    private val onData: (String, ByteArray) -> Unit,
    private val onFault: () -> Unit,
    private val onReady: () -> Unit,
    private val audio: AudioControl,
    private val onDiagnostics: (List<TrackDiagnostic>, Long) -> Unit,
    private val onStage: (CallStage) -> Unit,
) : GroupMedia, AttachmentAccess {
    override val gate = MediaGate(group.position.groupID)
    private val denoiser = RNNoiseProcessor(gate, audio.settings)
    val roster = group.members.associate { it.identity to it.name }
    override val recipients = roster.keys.filter { it != admission.identity }
    private val keyProvider: RoomKeys
    private val room: Room
    private var events: Job? = null
    private var statistics: Job? = null
    private val trackChanges = Channel<Unit>(Channel.CONFLATED)
    private val remoteDecryptionOK = mutableMapOf<String, Long>()
    private val remoteFailures = mutableMapOf<String, Pair<VoiceFailure, Long>>()
    private val failedSubscriptions = mutableSetOf<String>()
    var volumes: Map<String, Float> = emptyMap()
        set(value) { field = value; refreshTracks() }
    private var active = false
    private var retired = false
    private var subscribed = mutableSetOf<String>()
    private var nextListeningUpdateAt = 0L
    var listening = true
        set(value) {
            if (field == value) return
            field = value
            refreshTracks()
            publishListening(force = true)
            publishMembers()
        }

    init {
        LiveKit.init(context)
        keyProvider = RoomKeys(gate, scope)
        var allocated: Room? = null
        try {
            keyProvider.install(keys, 0)
            val signalingOrigin = admission.signaling.replaceFirst("wss:", "https:").replaceFirst("ws:", "http:").toHttpUrl()
            val secureClient = session.http.client.newBuilder()
                .addInterceptor { chain ->
                    val request = chain.request()
                    val url = request.url
                    val origin = signalingOrigin
                    if (url.host != origin.host || url.port != origin.port || url.scheme != origin.scheme) {
                        throw ChirpException("INVALID_MEDIA_ORIGIN")
                    }
                    chain.proceed(request)
                }.build()
            room = LiveKit.create(
                context,
                RoomOptions(
                    e2eeOptions = E2EEOptions(keyProvider),
                    audioTrackCaptureDefaults = audio.settings.preset.options(),
                    reconnectPolicy = object : ReconnectPolicy {
                        override fun getNextRetryDelay(context: io.livekit.android.room.network.ReconnectContext) = null
                    },
                ),
                LiveKitOverrides(
                    okHttpClient = secureClient,
                    audioOptions = AudioOptions(
                        audioHandler = NoAudioHandler(),
                        disableAudioPrewarming = true,
                        disableCommunicationModeWorkaround = true,
                        audioProcessorOptions = AudioProcessorOptions(capturePostProcessor = denoiser),
                        javaAudioDeviceModuleCustomizer = { builder ->
                            builder.setUseLowLatency(true)
                            builder.setUseHardwareNoiseSuppressor(false)
                            builder.setUseHardwareAcousticEchoCanceler(false)
                            builder.setUseStereoInput(false)
                            builder.setAudioBufferCallback { buffer, _, _, _, bytesRead, time ->
                                if (!gate.micAllowed || gate.systemMuted || gate.remaining() == 0L) {
                                    for (i in 0 until minOf(bytesRead, buffer.limit())) buffer.put(i, 0)
                                }
                                time
                            }
                        },
                    ),
                ),
            )
            allocated = room
            audio.attach(denoiser, room.lkObjects.audioDeviceModule as? livekit.org.webrtc.audio.JavaAudioDeviceModule) { preset ->
                val track = room.localParticipant.getTrackPublication(Track.Source.MICROPHONE)?.track as? LocalAudioTrack
                track?.applyOptions(preset.options())?.getOrThrow()
                room.audioTrackCaptureDefaults = preset.options()
                denoiser.resetCapture()
            }
        } catch (failure: Exception) {
            audio.detach(denoiser)
            runCatching { keyProvider.stop() }.onFailure(failure::addSuppressed)
            runCatching { allocated?.release() }.onFailure(failure::addSuppressed)
            runCatching { denoiser.close() }.onFailure(failure::addSuppressed)
            runCatching { keyProvider.rtcKeyProvider.dispose() }.onFailure(failure::addSuppressed)
            throw failure
        }
    }

    suspend fun connect(access: cn.youzifeile.chirp.data.MediaAccess) {
        events = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            room.events.events.collect { event ->
                if (retired) return@collect
                when (event) {
                    is RoomEvent.Disconnected, is RoomEvent.Reconnecting, is RoomEvent.FailedToConnect -> {
                        gate.revoke()
                        onFault()
                    }
                    is RoomEvent.DataReceived -> {
                        val sender = event.participant?.identity?.value
                        try {
                            if (event.topic == CHAT_TOPIC && event.encryptionType == Encryption.Type.GCM &&
                                sender != null && sender in roster && keyProvider.mayDeliverData(event.keyEpoch)
                            ) onData(sender, event.data)
                        } finally {
                            event.data.fill(0)
                        }
                    }
                    is RoomEvent.TrackE2EEStateEvent -> {
                        if (event.participant.identity?.value in roster &&
                            event.state in setOf(E2EEState.ENCRYPTION_FAILED, E2EEState.INTERNAL_ERROR)) {
                            gate.revoke()
                            throw ChirpException("AUDIO_ENCRYPTION_FAILED")
                        }
                        if (event.participant == room.localParticipant && gate.micAllowed &&
                            event.state == E2EEState.MISSING_KEY
                        ) {
                            gate.revoke()
                            onFault()
                        } else if (event.participant != room.localParticipant && event.participant.identity?.value in roster &&
                            event.publication.source == Track.Source.MICROPHONE) {
                            val sid = event.publication.sid
                            if (event.state == E2EEState.OK) remoteDecryptionOK[sid] = android.os.SystemClock.elapsedRealtime()
                            val failure = when (event.state) {
                                E2EEState.MISSING_KEY -> VoiceFailure.MissingKey
                                E2EEState.DECRYPTION_FAILED -> VoiceFailure.DecryptionFailed
                                else -> null
                            }
                            if (failure == null) remoteFailures.remove(sid)
                            else remoteFailures[sid] = failure to android.os.SystemClock.elapsedRealtime()
                        }
                    }
                    is RoomEvent.TrackSubscriptionFailed -> failedSubscriptions.add(event.sid)
                    is RoomEvent.ParticipantAttributesChanged -> {
                        if (LISTENING_ATTRIBUTE in event.changedAttributes) publishMembers()
                    }
                    is RoomEvent.TrackSubscriptionPermissionChanged -> {
                        if (event.subscriptionAllowed) {
                            failedSubscriptions.remove(event.trackPublication.sid)
                            subscribed.remove(event.trackPublication.sid)
                            refreshTracks()
                        } else failedSubscriptions.add(event.trackPublication.sid)
                    }
                    is RoomEvent.TrackSubscribed -> {
                        failedSubscriptions.remove(event.publication.sid)
                        refreshTracks()
                        publishMembers()
                    }
                    // Initial track events can be suppressed while LiveKit is connecting.
                    // Reconcile the publications once the transport is connected as well.
                    is RoomEvent.Connected, is RoomEvent.TrackPublished, is RoomEvent.TrackUnpublished,
                    is RoomEvent.TrackMuted, is RoomEvent.TrackUnmuted, is RoomEvent.ParticipantConnected,
                    is RoomEvent.ParticipantDisconnected, is RoomEvent.ActiveSpeakersChanged -> {
                        refreshTracks()
                        publishMembers()
                    }
                    else -> Unit
                }
                if ((ClientLog.current?.generation ?: 0L) != 0L) {
                    when (event) {
                        is RoomEvent.TrackPublished, is RoomEvent.TrackUnpublished, is RoomEvent.TrackMuted,
                        is RoomEvent.TrackUnmuted, is RoomEvent.TrackSubscribed, is RoomEvent.TrackUnsubscribed,
                        is RoomEvent.TrackSubscriptionFailed, is RoomEvent.TrackSubscriptionPermissionChanged,
                        is RoomEvent.TrackE2EEStateEvent, is RoomEvent.ParticipantDisconnected,
                        is RoomEvent.ConnectionQualityChanged -> trackChanges.trySend(Unit)
                        else -> Unit
                    }
                }
            }
        }
        try {
            room.connect(admission.signaling, access.token,
                ConnectOptions(autoSubscribe = false, audio = false, video = false))
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            throw ChirpException("MEDIA_CONNECT_FAILED")
        }
        verify(room.localParticipant.identity?.value == admission.identity && room.name == admission.room.id,
            "INVALID_MEDIA_IDENTITY")
        statistics = scope.launch {
            var nextTimingWindow = 0L
            while (kotlinx.coroutines.currentCoroutineContext().isActive) {
                val generation = ClientLog.current?.generation ?: 0L
                val now = android.os.SystemClock.elapsedRealtime()
                if (now >= nextTimingWindow) {
                    keyProvider.voice.flushTiming()
                    nextTimingWindow = now + 1000
                }
                publishListening()
                val tracks = mutableListOf<TrackDiagnostic>()
                for ((identity, participant) in room.remoteParticipants) {
                    if (identity.value !in roster) continue
                    for (publication in participant.trackPublications.values.filterIsInstance<RemoteTrackPublication>()) {
                        if (publication.source != Track.Source.MICROPHONE || publication.kind != Track.Kind.AUDIO) continue
                        val report = publication.track?.getRTCStats()?.statsMap?.values.orEmpty()
                        val inbound = report.firstOrNull { it.type == "inbound-rtp" && (it.members["kind"] == "audio" || it.members["mediaType"] == "audio") }
                        val transportID = inbound?.members?.get("transportId")
                        val transport = report.firstOrNull { it.type == "transport" && (transportID == null || it.id == transportID) }
                        val selectedPair = transport?.members?.get("selectedCandidatePairId")
                        val pair = report.firstOrNull { it.type == "candidate-pair" && it.id == selectedPair }
                        fun number(value: Any?): Double? = (value as? Number)?.toDouble()?.takeIf { it.isFinite() && it >= 0 }
                        val bufferDelaySeconds = number(inbound?.members?.get("jitterBufferDelay"))
                        val emittedSamples = number(inbound?.members?.get("jitterBufferEmittedCount"))
                        val averageBufferMS = if (bufferDelaySeconds != null && emittedSamples != null && emittedSamples > 0) {
                            bufferDelaySeconds / emittedSamples * 1000
                        } else null
                        val trackID = publication.track?.rtcTrack?.id() ?: publication.sid
                        val success = keyProvider.voice.lastDecryption(trackID)
                        val remoteFailure = remoteFailures[publication.sid]?.takeIf { success == null || success < it.second }?.first
                        tracks += TrackDiagnostic(identity.value, publication.subscribed, publication.muted,
                            participant.connectionQuality.name, number(inbound?.members?.get("jitter"))?.times(1000),
                            number(pair?.members?.get("currentRoundTripTime"))?.times(1000),
                            number(inbound?.members?.get("packetsLost"))?.toLong(), number(inbound?.members?.get("packetsReceived"))?.toLong(),
                            success,
                            publication.encryptionType == Encryption.Type.GCM, trackID, keyProvider.voice.failure(trackID) ?: remoteFailure,
                            android.os.SystemClock.elapsedRealtime(), publication.sid in failedSubscriptions || !publication.subscriptionAllowed,
                            firstDecryptedAt = keyProvider.voice.firstDecryption(trackID), averageJitterBufferMS = averageBufferMS,
                            lastDecryptionEventAt = remoteDecryptionOK[publication.sid])
                    }
                }
                val publications = room.remoteParticipants.values.flatMap { it.trackPublications.keys }
                remoteDecryptionOK.keys.retainAll(publications)
                remoteFailures.keys.retainAll(publications)
                failedSubscriptions.retainAll(publications)
                if (!retired) onDiagnostics(tracks, generation)
                if (generation == 0L) kotlinx.coroutines.delay(1000)
                else if (withTimeoutOrNull(1000) { trackChanges.receive() } != null) {
                    // Coalesce publication changes before asking WebRTC for fresh statistics.
                    kotlinx.coroutines.delay(100)
                }
            }
        }
    }

    override fun granted(index: Int) {
        verify(!retired, "MEDIA_DISCONNECTED")
        keyProvider.authorize(index)
        if (!active) {
            active = true
            onStage(CallStage.mediaLeaseGranted)
            refreshTracks()
            if (gate.remaining() == 0L) return
            publishListening(force = true)
            publishMembers()
            onReady()
        }
    }

    fun setSystemMuted(muted: Boolean) {
        gate.systemMuted = muted
        if (!retired && (muted || gate.micAllowed)) {
            room.localParticipant.getTrackPublication(Track.Source.MICROPHONE)?.muted = muted
        }
        publishMembers()
    }

    suspend fun setMic(enabled: Boolean) {
        val participant = room.localParticipant
        if (!enabled) {
            gate.micAllowed = false
            participant.getTrackPublication(Track.Source.MICROPHONE)?.track?.let { participant.unpublishTrack(it) }
            denoiser.resetCapture()
            publishMembers()
            return
        }
        verify(!retired && gate.remaining() > 0, "GROUP_LEASE_LOST")
        denoiser.resetCapture()
        val changed = participant.setMicrophoneEnabled(true)
        val publication = participant.getTrackPublication(Track.Source.MICROPHONE)
        val identity = participant.identity
        if (!changed || gate.systemMuted || publication?.encryptionType != Encryption.Type.GCM || identity == null ||
            room.e2eeManager?.chirpSenderReady(publication.sid, identity) != true || gate.remaining() <= 0 || retired) {
            publication?.track?.let { participant.unpublishTrack(it) }
            throw ChirpException("MICROPHONE_UNAVAILABLE")
        }
        gate.micAllowed = true
        try {
            kotlinx.coroutines.withTimeout(3_000) {
                while (!denoiser.reading.processing) {
                    verify(!denoiser.reading.failed && !retired && gate.remaining() > 0 && !gate.systemMuted, "MICROPHONE_UNAVAILABLE")
                    kotlinx.coroutines.delay(25)
                }
            }
        } catch (failure: Exception) {
            gate.micAllowed = false
            throw failure
        }
        publishMembers()
    }

    suspend fun send(data: ByteArray) {
        fun requireLease() = verify(!retired && gate.remaining() > 0, "CHAT_NOT_READY")
        requireLease()
        publishChatBatches(recipients, authorizedEpoch = {
            requireLease()
            keyProvider.dataEpoch.takeIf(keyProvider::maySendData)
        }) { batch ->
            room.localParticipant.publishData(data, topic = CHAT_TOPIC, identities = batch.map { Participant.Identity(it) }).getOrThrow()
        }
    }

    override suspend fun prepareKeys(keys: Map<String, ByteArray>, index: Int) {
        verify(!retired && gate.remaining() > 0 && index in 0..1 && index != keyProvider.sendIndex && keys.keys == roster.keys,
            "MEDIA_KEY_REJECTED")
        keyProvider.install(keys, index)
        onStage(CallStage.keysInstalled)
    }

    override suspend fun switchKeys(index: Int) {
        verify(!retired, "MEDIA_KEY_REJECTED")
        keyProvider.switch(index) { checkNotNull(room.e2eeManager).chirpSwitchKey(index) }
    }

    override fun retireKeys(index: Int) {
        verify(!retired && index in 0..1 && index != keyProvider.sendIndex, "MEDIA_KEY_REJECTED")
        keyProvider.retire(index)
    }

    private fun refreshTracks() {
        val allowed = !retired && active && gate.remaining() > 0
        val present = mutableSetOf<String>()
        for ((identity, participant) in room.remoteParticipants) {
            for (publication in participant.trackPublications.values.filterIsInstance<RemoteTrackPublication>()) {
                val microphone = identity.value in roster && publication.kind == Track.Kind.AUDIO && publication.source == Track.Source.MICROPHONE
                if (active && !retired && gate.remaining() > 0 && microphone && publication.encryptionType != Encryption.Type.GCM) {
                    gate.revoke()
                    scope.launch { throw ChirpException("REMOTE_TRACK_UNENCRYPTED") }
                    return
                }
                val eligible = microphone && publication.encryptionType == Encryption.Type.GCM && publication.subscriptionAllowed
                val enable = allowed && eligible
                if (enable) {
                    present.add(publication.sid)
                    if (publication.sid !in subscribed) publication.setSubscribed(true)
                } else if (publication.sid in subscribed || publication.subscribed) {
                    publication.setSubscribed(false)
                }
                publication.track?.enabled = enable
                val volume = if (listening) volumes[identity.value] ?: 1f else 0f
                (publication.track as? RemoteAudioTrack)?.setVolume(volume.toDouble())
            }
        }
        subscribed = present
    }

    private fun publishListening(force: Boolean = false) {
        val participant = room.localParticipant
        if (!active || retired || room.state != Room.State.CONNECTED || participant.permissions?.canUpdateMetadata != true) return
        val value = listening.toString()
        val now = SystemClock.elapsedRealtime()
        // A switch can change back before the server echoes the previous value.
        if (!force && (participant.attributes[LISTENING_ATTRIBUTE] == value || now < nextListeningUpdateAt)) return
        nextListeningUpdateAt = now + 3_000
        participant.updateAttributes(mapOf(LISTENING_ATTRIBUTE to value))
    }

    private fun publishMembers() {
        if (!active || retired) return
        val speaking = room.activeSpeakers.mapNotNull { it.identity?.value }.toSet()
        onMembers(roster.map { (identity, name) ->
            val self = identity == admission.identity
            val remote = room.remoteParticipants[Participant.Identity(identity)]
            val participant = if (self) room.localParticipant else remote
            val microphoneEnabled = participant?.let {
                val publication = it.getTrackPublication(Track.Source.MICROPHONE)
                publication?.muted == false && publication.encryptionType == Encryption.Type.GCM &&
                    (!self || gate.micAllowed && !gate.systemMuted)
            }
            RoomMember(identity, name, microphoneEnabled = microphoneEnabled,
                listening = if (self) listening else remote?.attributes?.get(LISTENING_ATTRIBUTE)?.toBooleanStrictOrNull(),
                speaking = microphoneEnabled == true && identity in speaking, present = self || remote != null)
        })
    }

    override fun pause() {
        if (retired) return
        gate.revoke()
        active = false
        retired = true
        try { keyProvider.stop() } finally {
            events?.cancel()
            statistics?.cancel()
            audio.detach(denoiser)
            refreshTracks()
        }
    }

    suspend fun close() {
        try { pause() } finally {
            withContext(kotlinx.coroutines.NonCancellable + Dispatchers.IO) {
                try { room.release() } finally {
                    try { denoiser.close() } finally { keyProvider.rtcKeyProvider.dispose() }
                }
            }
        }
    }
}

internal class RoomKeys(
    private val gate: MediaGate,
    private val scope: CoroutineScope,
    provider: BaseKeyProvider = BaseKeyProvider(
        ratchetSalt = "LKFrameEncryptionKey",
        uncryptedMagicBytes = "",
        ratchetWindowSize = 0,
        enableSharedKey = false,
        keyRingSize = 2,
        discardFrameWhenCryptorNotReady = true,
        keyDerivationAlgorithm = FrameCryptorKeyDerivationAlgorithm.HKDF,
    ),
) : KeyProvider by provider, ChirpDataGate {
    @Volatile override var dataEpoch = 0L
        private set
    val sendIndex get() = (dataEpoch and 1L).toInt()
    @Volatile private var authorizedEpoch: Long? = null
    private val installedEpochs = java.util.concurrent.atomic.AtomicReferenceArray<Long?>(2)
    private val incoming = PendingRoomData(::receiveDataEpoch) { index ->
        val epoch = dataEpoch
        if (index in 0..1 && installedEpochs.get(index) == epoch + 1 && gate.maySend(epoch)) epoch + 1 else null
    }
    private val slots = mutableMapOf<Int, Set<String>>()
    private val expires = mutableMapOf<Int, Long>()
    private var stopped = false
    private val clock = android.os.SystemClock::elapsedRealtime
    val voice = VoiceKeys({ gate.remaining() > 0 }, clock, receiveAllowed = { receiveDataEpoch(it) != null })
    private val timer = java.util.concurrent.Executors.newSingleThreadScheduledExecutor {
        Thread(it, "Chirp media key expiry").apply { isDaemon = true }
    }
    @Synchronized fun install(keys: Map<String, ByteArray>, index: Int) {
        verify(!stopped && index in 0..1 && keys.isNotEmpty() && keys.values.all { it.size == 32 }, "MEDIA_KEY_REJECTED")
        val epoch = if (index == sendIndex) dataEpoch else dataEpoch + 1
        installedEpochs.set(index, null)
        expires.remove(index)
        slots[index] = keys.keys.toSet()
        try {
            for ((identity, key) in keys) {
                verify(rtcKeyProvider.setKey(identity, index, key), "MEDIA_KEY_REJECTED")
                voice.install(identity, index, key)
            }
            installedEpochs.set(index, epoch)
        } catch (e: Exception) { stop(); throw e }
    }
    @Synchronized fun authorize(index: Int) {
        verify(!stopped && index == sendIndex && installedEpochs.get(index) == dataEpoch && gate.maySend(dataEpoch),
            "GROUP_LEASE_LOST")
        if (authorizedEpoch != dataEpoch) {
            if (authorizedEpoch == null) timer.scheduleWithFixedDelay(::expire, 20, 20, java.util.concurrent.TimeUnit.MILLISECONDS)
            voice.activate(index)
            authorizedEpoch = dataEpoch
            scope.launch(Dispatchers.Default) { incoming.drain() }
        }
    }
    @Synchronized private fun expire() {
        if (stopped) return
        if (gate.remaining() == 0L) { stop(); return }
        expires.filterValues { it <= clock() }.keys.forEach(::retire)
    }
    @Synchronized fun switch(index: Int, cutover: () -> Unit) {
        val next = dataEpoch + 1
        verify(!stopped && index in 0..1 && index != sendIndex && installedEpochs.get(index) == next && gate.maySend(next),
            "MEDIA_KEY_REJECTED")
        val previous = sendIndex
        expires[previous] = clock() + 1000
        voice.expire(previous, 1000)
        dataEpoch = next
        cutover()
    }
    @Synchronized fun retire(index: Int) {
        installedEpochs.set(index, null)
        voice.retire(index)
        expires.remove(index)
        slots.remove(index)?.forEach { identity ->
            val tombstone = randomBytes(32)
            try { check(rtcKeyProvider.setKey(identity, index, tombstone)) } finally { tombstone.fill(0) }
        }
    }
    @Synchronized fun stop() {
        if (stopped) return
        stopped = true
        gate.revoke()
        incoming.clear()
        timer.shutdown()
        authorizedEpoch = null
        dataEpoch++
        voice.clear()
        slots.keys.toList().forEach(::retire)
    }
    override fun installVoiceReceiver(receiver: livekit.org.webrtc.RtpReceiver, identity: String) =
        VoiceReceiver(voice, identity).install(receiver)
    override fun installVoiceSender(sender: livekit.org.webrtc.RtpSender, identity: String) =
        VoiceSender(voice, identity) { index ->
            val epoch = dataEpoch
            index == (epoch and 1L).toInt() && gate.micAllowed && !gate.systemMuted && maySendData(epoch)
        }.install(sender)
    override fun getLatestKeyIndex(participantId: String): Int = sendIndex
    override fun setSifTrailer(trailer: ByteArray) = Unit
    override fun maySendData(epoch: Long): Boolean =
        epoch == authorizedEpoch && epoch == dataEpoch && gate.maySend(epoch)

    override fun receiveEncryptedData(index: Int, wireBytes: Int, deliver: (Long) -> Unit) =
        incoming.receive(index, wireBytes, deliver)

    override fun receiveDataEpoch(index: Int): Long? {
        if (index !in 0..1) return null
        val installed = installedEpochs.get(index) ?: return null
        return installed.takeIf { gate.receiveEpoch(index) == it }
    }

    fun mayDeliverData(epoch: Long): Boolean = receiveDataEpoch((epoch and 1).toInt()) == epoch
}

/** A routine rekey preserves this room and audience. Membership changes retire the whole media instance. */
internal suspend fun publishChatBatches(recipients: List<String>, authorizedEpoch: () -> Long?, publish: suspend (List<String>) -> Unit) {
    val batches = recipients.chunked(8).iterator()
    if (!batches.hasNext()) return
    val first = batches.next()
    val epoch = submitFirstChatBatch(authorizedEpoch) { publish(first) }
    for (batch in batches) {
        verify(authorizedEpoch() == epoch, "GROUP_CHANGED")
        publish(batch)
    }
}

/** Retry only an explicit pre-SCTP refusal. The caller bounds this wait and serializes packets. */
private suspend fun submitFirstChatBatch(authorizedEpoch: () -> Long?, publish: suspend () -> Unit): Long {
    while (true) {
        val epoch = authorizedEpoch()
        if (epoch != null) {
            try {
                publish()
                return epoch
            } catch (_: io.livekit.android.e2ee.ChirpDataKeyNotReady) {
                // The SDK rechecked the lease after waiting for the data channel. It did not send this batch.
            }
        }
        kotlinx.coroutines.delay(20)
    }
}
