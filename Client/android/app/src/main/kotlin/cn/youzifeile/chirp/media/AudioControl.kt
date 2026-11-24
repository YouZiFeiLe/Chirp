package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.LogEvent
import cn.youzifeile.chirp.data.LogOutcome
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import cn.youzifeile.chirp.data.ChirpException
import cn.youzifeile.chirp.data.verify
import io.livekit.android.AudioOptions
import io.livekit.android.LiveKit
import io.livekit.android.LiveKitOverrides
import io.livekit.android.RoomOptions
import io.livekit.android.audio.AudioProcessorOptions
import io.livekit.android.audio.NoAudioHandler
import io.livekit.android.room.track.LocalAudioTrackOptions
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import livekit.org.webrtc.*
import livekit.org.webrtc.audio.JavaAudioDeviceModule
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal data class AudioDevice(val id: Int, val name: String, val type: Int)
internal enum class MicrophoneTestPhase { Idle, Starting, Measuring, Stopping, Playing }
internal data class AudioState(
    val preset: AudioPreset = AudioPreset.RNNoise,
    val activation: Boolean = false,
    val threshold: Float = -45f,
    val reading: CaptureReading = CaptureReading(),
    val inputs: List<AudioDevice> = emptyList(),
    val input: Int = 0,
    val outputs: List<AudioDevice> = emptyList(),
    val output: Int = 0,
    val test: MicrophoneTestPhase = MicrophoneTestPhase.Idle,
    val progress: Float = 0f,
    val error: String? = null,
    val applied: Boolean = false,
    val fellBack: Boolean = false,
)

internal fun AudioPreset.options() = LocalAudioTrackOptions(noiseSuppression = webRtcNoise,
    echoCancellation = true, autoGainControl = true, typingNoiseDetection = false)

internal class AudioControl(private val context: Context, private val busy: () -> Boolean, private val unrecoverable: () -> Unit = {}) {
    val settings = CaptureSettings()
    private val mutable = MutableStateFlow(AudioState())
    val state = mutable.asStateFlow()
    private val jobs = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val manager = context.getSystemService(AudioManager::class.java)
    private var processor: RNNoiseProcessor? = null
    private var inputTarget: ((AudioDeviceInfo?) -> Unit)? = null
    private var presetTarget: ((AudioPreset) -> Unit)? = null
    private var settingsOwner: String? = null
    private var modeBefore: Int? = null
    private var testJob: Job? = null
    private var testOwner: String? = null
    private var playback: Job? = null
    private val callback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = refreshDevices()
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = refreshDevices()
    }

    init {
        manager.registerAudioDeviceCallback(callback, Handler(Looper.getMainLooper()))
        refreshDevices()
        jobs.launch {
            while (isActive) {
                val reading = processor?.reading ?: CaptureReading()
                mutable.update { it.copy(reading = reading, applied = reading.processing && !reading.failed && reading.preset == it.preset) }
                if (reading.failed && busy()) { mutable.update { it.copy(error = "MICROPHONE_UNAVAILABLE") }; unrecoverable() }
                delay(100)
            }
        }
    }

    fun reportError(code: String) = mutable.update { it.copy(error = code) }

    fun configure(preset: AudioPreset, activation: Boolean, threshold: Float) {
        val old = settings.preset
        try {
            presetTarget?.invoke(preset)
            settings.preset = preset; settings.activation = activation; settings.threshold = threshold.coerceIn(-80f, -10f)
            mutable.update { it.copy(preset = preset, activation = activation, threshold = settings.threshold,
                applied = it.applied && it.preset == preset, error = null) }
        } catch (_: Exception) {
            try { presetTarget?.invoke(old) } catch (_: Exception) { mutable.update { it.copy(error = "CLIENT_AUDIO_PRESET_RECOVERY_FAILED") }; unrecoverable(); throw ChirpException("CLIENT_AUDIO_PRESET_RECOVERY_FAILED") }
            throw ChirpException("AUDIO_PRESET_FAILED")
        }
    }

    fun attach(value: RNNoiseProcessor, module: JavaAudioDeviceModule?, apply: (AudioPreset) -> Unit) {
        processor = value
        inputTarget = { device -> module?.let { livekit.org.webrtc.audio.ChirpAudioDeviceRoutes.setInput(it, device) } }
        presetTarget = apply
        inputTarget?.invoke(inputInfo(state.value.input)); apply(settings.preset)
    }

    fun detach(value: RNNoiseProcessor) {
        if (processor !== value) return
        processor = null; inputTarget = null; presetTarget = null
        mutable.update { it.copy(reading = CaptureReading(), applied = false) }
    }

    fun openSettings(owner: String) {
        settingsOwner = owner
        if (!busy() && modeBefore == null) { modeBefore = manager.mode; manager.mode = AudioManager.MODE_IN_COMMUNICATION }
        refreshDevices()
    }

    fun closeSettings(owner: String) {
        if (settingsOwner != owner) return
        settingsOwner = null
        stopTest(owner = owner)
        if (!busy()) releaseIdleRoute()
    }

    fun resumeSettingsIfIdle() { settingsOwner?.let { if (!busy()) openSettings(it) } }

    suspend fun prepareForCall() {
        val capture = testJob
        val player = playback
        capture?.cancel()
        player?.cancel()
        capture?.join()
        player?.join()
        mutable.update { it.copy(test = MicrophoneTestPhase.Idle, progress = 0f) }
        releaseIdleRoute()
    }

    private fun releaseIdleRoute() {
        val previous = modeBefore ?: return
        modeBefore = null
        manager.clearCommunicationDevice()
        manager.mode = previous
    }

    private fun inputInfo(id: Int): AudioDeviceInfo? = manager.getDevices(AudioManager.GET_DEVICES_INPUTS).find { it.id == id }
    fun chooseInput(id: Int) {
        val info = inputInfo(id)
        if (id != 0 && info == null) { LogEvent.selectInput.record(LogOutcome.failed, "AUDIO_ROUTE_UNAVAILABLE"); mutable.update { it.copy(error = "AUDIO_ROUTE_UNAVAILABLE") }; return }
        LogEvent.selectInput.measure(started = true) { inputTarget?.invoke(info) }
        mutable.update { it.copy(input = id, error = null, fellBack = false) }
    }

    fun chooseIdleOutput(id: Int) {
        if (busy()) return
        val ok = if (id == 0) { manager.clearCommunicationDevice(); true }
            else manager.availableCommunicationDevices.find { it.id == id }?.let(manager::setCommunicationDevice) == true
        LogEvent.preferOutput.record(if (ok) LogOutcome.succeeded else LogOutcome.failed, if (ok) null else "AUDIO_ROUTE_UNAVAILABLE")
        mutable.update { it.copy(error = if (ok) null else "AUDIO_ROUTE_UNAVAILABLE") }
        refreshDevices()
    }

    private fun refreshDevices() {
        fun AudioDeviceInfo.display() = AudioDevice(id, productName.toString(), type)
        val inputTypes = setOf(
            AudioDeviceInfo.TYPE_BUILTIN_MIC, AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_ACCESSORY, AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_BLE_HEADSET)
        val inputs = manager.getDevices(AudioManager.GET_DEVICES_INPUTS).filter { it.type in inputTypes }.map { it.display() }
        val outputs = manager.availableCommunicationDevices.map { it.display() }
        val lost = state.value.input != 0 && inputs.none { it.id == state.value.input }
        if (lost) inputTarget?.invoke(null)
        val output = manager.communicationDevice?.id ?: 0
        mutable.update { it.copy(inputs = inputs, outputs = outputs, output = output,
            input = if (lost) 0 else it.input, fellBack = lost || it.fellBack) }
    }

    fun startTest(owner: String) {
        LogEvent.microphoneTestStarted.record()
        if (busy() || testJob?.isActive == true || playback?.isActive == true || settingsOwner != owner) return
        testOwner = owner
        mutable.update { it.copy(test = MicrophoneTestPhase.Starting, error = null) }
        testJob = jobs.launch {
            val capture = RNNoiseProcessor(MediaGate("local-test"), settings).apply { testing = true }
            var room: io.livekit.android.room.Room? = null
            var track: io.livekit.android.room.track.LocalAudioTrack? = null
            var peer: PeerConnection? = null
            var sinkPeer: PeerConnection? = null
            var module: JavaAudioDeviceModule? = null
            try {
                verify(!busy(), "AUDIO_TEST_BUSY")
                LiveKit.init(context)
                room = LiveKit.create(context, RoomOptions(audioTrackCaptureDefaults = settings.preset.options()), LiveKitOverrides(
                    audioOptions = AudioOptions(audioHandler = NoAudioHandler(), disableCommunicationModeWorkaround = true,
                        audioProcessorOptions = AudioProcessorOptions(capturePostProcessor = capture),
                        javaAudioDeviceModuleCustomizer = { it.setUseHardwareAcousticEchoCanceler(false); it.setUseHardwareNoiseSuppressor(false); it.setUseStereoInput(false) })))
                val local = room.localParticipant.createAudioTrack()
                track = local
                peer = room.localParticipant.chirpLocalCapturePeer(LocalPeerObserver()) ?: throw ChirpException("MICROPHONE_UNAVAILABLE")
                peer.addTrack(local.rtcTrack, listOf("local-test"))
                val sink = room.localParticipant.chirpLocalCapturePeer(LocalPeerObserver()) ?: throw ChirpException("MICROPHONE_UNAVAILABLE")
                sinkPeer = sink
                // Negotiate only between these in-memory peers so WebRTC creates
                // its send stream and APM. ICE is NONE: no candidates or transport.
                withTimeout(3000) {
                    val offer = localDescription(peer, offer = true)
                    setDescription(peer, offer, local = true); setDescription(sink, offer, local = false)
                    val answer = localDescription(sink, offer = false)
                    setDescription(sink, answer, local = true); setDescription(peer, answer, local = false)
                }
                val deviceModule = room.lkObjects.audioDeviceModule as? JavaAudioDeviceModule ?: throw ChirpException("MICROPHONE_UNAVAILABLE")
                module = deviceModule
                attach(capture, deviceModule) { local.applyOptions(it.options()).getOrThrow() }
                // Prewarming deliberately withholds frames from native processing.
                // Start the local ADM explicitly after the capture holder exists.
                verify(deviceModule.requestStartRecording(livekit.org.webrtc.audio.AudioProcessingOptions(true,
                    settings.preset.webRtcNoise, true, true)), "MICROPHONE_UNAVAILABLE")
                withTimeout(3000) { while (!capture.reading.processing) { verify(!capture.reading.failed, "MICROPHONE_UNAVAILABLE"); delay(25) } }
                mutable.update { it.copy(test = MicrophoneTestPhase.Measuring) }
                repeat(100) { delay(100); verify(!capture.reading.failed, "MICROPHONE_UNAVAILABLE") }
            } catch (_: TimeoutCancellationException) { mutable.update { it.copy(error = "MICROPHONE_UNAVAILABLE") } }
            catch (e: CancellationException) { throw e }
            catch (error: Exception) {
                LogEvent.captureFailed.record(LogOutcome.failed, "MICROPHONE_UNAVAILABLE")
                mutable.update { it.copy(error = "MICROPHONE_UNAVAILABLE") }
            }
            finally {
                detach(capture)
                val cleaned = withContext(NonCancellable + Dispatchers.IO) {
                    var ok = true
                    fun release(action: () -> Unit) {
                        try { action() } catch (_: RuntimeException) { ok = false }
                    }
                    release { module?.requestStopRecording() }
                    release { track?.stopPrewarm() }
                    release { peer?.close() }
                    release { sinkPeer?.close() }
                    release { peer?.dispose() }
                    release { sinkPeer?.dispose() }
                    release { track?.dispose() }
                    release { room?.release() }
                    release { capture.close() }
                    ok
                }
                if (!cleaned) mutable.update { it.copy(error = "MICROPHONE_UNAVAILABLE") }
                if (state.value.test != MicrophoneTestPhase.Stopping) mutable.update { it.copy(test = MicrophoneTestPhase.Idle) }
            }
        }
    }

    fun stopTest(play: Boolean = false, owner: String? = null) {
        if (state.value.test != MicrophoneTestPhase.Idle) (if (play) LogEvent.microphoneTestPlayback else LogEvent.microphoneTestStopped).record()
        if (owner != null && testOwner != owner) return
        val pending = testJob
        val previous = playback
        if (pending?.isActive != true && previous?.isActive != true) return
        val sample = if (play && state.value.test == MicrophoneTestPhase.Measuring) processor?.sampleCopy() else null
        pending?.cancel()
        previous?.cancel()
        mutable.update { it.copy(test = MicrophoneTestPhase.Stopping) }
        playback = jobs.launch(start = CoroutineStart.UNDISPATCHED) {
            var output: AudioTrack? = null
            try {
                previous?.join()
                pending?.join()
                if (sample == null || sample.second.isEmpty()) {
                    if (play) mutable.update { it.copy(error = "MICROPHONE_NO_SAMPLE") }
                    return@launch
                }
                val (rate, pcm) = sample
                verify(!busy(), "AUDIO_TEST_BUSY")
                val player = AudioTrack.Builder().setAudioAttributes(voiceAttributes()).setAudioFormat(AudioFormat.Builder()
                    .setSampleRate(rate).setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                    .setBufferSizeInBytes(pcm.size * 2).setTransferMode(AudioTrack.MODE_STATIC).build()
                output = player
                verify(player.write(pcm, 0, pcm.size) == pcm.size, "MICROPHONE_NO_SAMPLE")
                player.play()
                mutable.update { it.copy(test = MicrophoneTestPhase.Playing, progress = 0f) }
                withTimeout(5000) {
                    while (player.playbackHeadPosition < pcm.size) {
                        mutable.update { it.copy(progress = player.playbackHeadPosition.toFloat() / pcm.size) }; delay(50)
                    }
                }
            } catch (_: TimeoutCancellationException) { mutable.update { it.copy(error = "MICROPHONE_NO_SAMPLE") } }
            catch (e: CancellationException) { throw e }
            catch (_: Exception) { mutable.update { it.copy(error = "MICROPHONE_NO_SAMPLE") } }
            finally {
                try { output?.stop() } catch (_: IllegalStateException) { }
                try { output?.release() } finally {
                    sample?.second?.fill(0)
                    mutable.update { it.copy(test = MicrophoneTestPhase.Idle, progress = 0f) }
                }
            }
        }
    }
}

internal fun voiceAttributes(): AudioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()

internal open class LocalPeerObserver : PeerConnection.Observer {
    override fun onSignalingChange(value: PeerConnection.SignalingState?) {}
    override fun onIceConnectionChange(value: PeerConnection.IceConnectionState?) {}
    override fun onIceConnectionReceivingChange(value: Boolean) {}
    override fun onIceGatheringChange(value: PeerConnection.IceGatheringState?) {}
    override fun onIceCandidate(value: IceCandidate?) {}
    override fun onIceCandidatesRemoved(value: Array<out IceCandidate>?) {}
    override fun onAddStream(value: MediaStream?) {}
    override fun onRemoveStream(value: MediaStream?) {}
    override fun onDataChannel(value: DataChannel?) {}
    override fun onRenegotiationNeeded() {}
}

internal suspend fun localDescription(peer: PeerConnection, offer: Boolean): SessionDescription = suspendCancellableCoroutine { continuation ->
    val observer = object : SdpObserver {
        override fun onCreateSuccess(description: SessionDescription) { if (continuation.isActive) continuation.resume(description) }
        override fun onCreateFailure(error: String?) { if (continuation.isActive) continuation.resumeWithException(ChirpException("MICROPHONE_UNAVAILABLE")) }
        override fun onSetSuccess() {}
        override fun onSetFailure(error: String?) {}
    }
    if (offer) peer.createOffer(observer, MediaConstraints()) else peer.createAnswer(observer, MediaConstraints())
}

internal suspend fun setDescription(peer: PeerConnection, description: SessionDescription, local: Boolean): Unit = suspendCancellableCoroutine { continuation ->
    val observer = object : SdpObserver {
        override fun onSetSuccess() { if (continuation.isActive) continuation.resume(Unit) }
        override fun onSetFailure(error: String?) { if (continuation.isActive) continuation.resumeWithException(ChirpException("MICROPHONE_UNAVAILABLE")) }
        override fun onCreateSuccess(description: SessionDescription?) {}
        override fun onCreateFailure(error: String?) {}
    }
    if (local) peer.setLocalDescription(observer, description) else peer.setRemoteDescription(observer, description)
}
