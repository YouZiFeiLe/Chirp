package cn.youzifeile.chirp.media

import android.os.SystemClock
import androidx.core.telecom.CallEndpointCompat
import cn.youzifeile.chirp.data.CallStage
import cn.youzifeile.chirp.data.ClientLog
import cn.youzifeile.chirp.data.DiagnosticAudio
import cn.youzifeile.chirp.data.DiagnosticPhase
import cn.youzifeile.chirp.data.DiagnosticRoute
import cn.youzifeile.chirp.data.DiagnosticTrack
import cn.youzifeile.chirp.data.LogDetails
import cn.youzifeile.chirp.data.LogEvent
import cn.youzifeile.chirp.data.TrackEncryption
import cn.youzifeile.chirp.data.TrackQuality

internal class CallDiagnostics {
    var transport = 0L
    var keyRevision = 0L
    private var generation = 0L
    private var started = 0L
    private var sequence = 0L
    private var sampleGeneration = 0L
    private var verifiedTransport = -1L
    private var sampled = 0L
    private var lastState: SampleState? = null

    private data class TrackState(val id: String, val muted: Boolean, val subscribed: Boolean, val failed: Boolean,
        val encryption: TrackEncryption, val quality: TrackQuality)
    private data class SampleState(val phase: DiagnosticPhase, val audio: DiagnosticAudio, val held: Boolean,
        val leaseValid: Boolean, val tracks: List<TrackState>)

    fun lifecycle(stage: CallStage, state: CallState, preset: AudioPreset, failure: String? = null,
        phase: DiagnosticPhase = state.diagnosticPhase(), expected: Long = ClientLog.current?.generation ?: 0) {
        val log = ClientLog.current ?: return
        if (expected == 0L || expected != log.generation) return
        val now = SystemClock.elapsedRealtime()
        if (expected != generation) {
            generation = expected
            started = now
            sequence = 0
        }
        val details = LogDetails.Lifecycle(stage, phase, ++sequence, now - started,
            if (phase == DiagnosticPhase.authorizing) 0 else transport,
            if (phase == DiagnosticPhase.authorizing) 0 else keyRevision, state.audio(preset))
        log.record(LogEvent.lifecycle, error = failure, details = details, expected = expected)
    }

    fun sample(state: CallState, preset: AudioPreset, lease: Long?, tracks: List<TrackDiagnostic>, expected: Long) {
        val log = ClientLog.current ?: return
        if (expected == 0L || expected != log.generation) return
        val now = SystemClock.elapsedRealtime()
        val snapshot = SampleState(state.diagnosticPhase(), state.audio(preset), state.held, lease != null && lease > 0,
            tracks.map { TrackState(it.trackID, it.muted, it.subscribed, it.subscriptionFailed, it.encryption(), it.qualityCode()) })
        if (sampleGeneration == expected && snapshot == lastState && now - sampled < 5_000) return
        if (snapshot.tracks.any { it.encryption == TrackEncryption.verified } &&
            (sampleGeneration != expected || verifiedTransport != transport)) {
            verifiedTransport = transport
            lifecycle(CallStage.firstRemoteDecryption, state, preset, expected = expected)
        }
        lastState = snapshot
        sampleGeneration = expected
        sampled = now
        // IDs are used above only to detect track replacements. Numbers are assigned afresh inside each exported sample.
        val anonymous = tracks.mapIndexed { index, t ->
            val s = snapshot.tracks[index]
            DiagnosticTrack(t.muted, t.subscribed, t.subscriptionFailed, s.encryption, s.quality,
                t.received, t.lost, t.jitterMS, t.roundTripMS, t.lastDecryptionEventAt?.let { (t.measuredAt - it).coerceAtLeast(0) })
        }
        log.record(LogEvent.trackSample, details = LogDetails.Sample(snapshot.phase, snapshot.audio, state.held, lease, anonymous),
            expected = expected)
    }

    fun resetTransport() {
        transport = 0
        keyRevision = 0
        lastState = null
        verifiedTransport = -1L
    }
}

private fun TrackDiagnostic.encryption() = when {
    !encrypted -> TrackEncryption.failed
    decryptionFailure == VoiceFailure.MissingKey -> TrackEncryption.missingKey
    decryptionFailure == VoiceFailure.DecryptionFailed -> TrackEncryption.decryptionFailed
    lastDecryptedAt != null -> TrackEncryption.verified
    else -> TrackEncryption.waiting
}

private fun TrackDiagnostic.qualityCode() = when (quality) {
    "EXCELLENT" -> TrackQuality.excellent
    "GOOD" -> TrackQuality.good
    "POOR" -> TrackQuality.poor
    "LOST" -> TrackQuality.lost
    else -> TrackQuality.unknown
}

internal fun CallState.diagnosticPhase() = when (phase) {
    CallPhase.Idle -> DiagnosticPhase.idle
    CallPhase.Joining -> DiagnosticPhase.connecting
    CallPhase.Securing -> when {
        trust.pending -> DiagnosticPhase.verifying
        chatVisible -> DiagnosticPhase.recovering
        connectingMedia -> DiagnosticPhase.connecting
        else -> DiagnosticPhase.securing
    }
    CallPhase.Connected -> DiagnosticPhase.active
    CallPhase.Leaving -> DiagnosticPhase.leaving
}

private fun CallState.audio(preset: AudioPreset) = DiagnosticAudio(!micOn, listening, preset, when (endpoint?.type) {
    CallEndpointCompat.TYPE_SPEAKER -> DiagnosticRoute.speaker
    CallEndpointCompat.TYPE_EARPIECE -> DiagnosticRoute.earpiece
    CallEndpointCompat.TYPE_BLUETOOTH -> DiagnosticRoute.bluetooth
    CallEndpointCompat.TYPE_WIRED_HEADSET -> DiagnosticRoute.wired
    CallEndpointCompat.TYPE_STREAMING -> DiagnosticRoute.streaming
    else -> DiagnosticRoute.unknown
})
