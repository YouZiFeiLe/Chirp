package cn.youzifeile.chirp.data

import android.os.Build
import cn.youzifeile.chirp.BuildConfig
import cn.youzifeile.chirp.media.AudioPreset
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal enum class CallStage {
    authorizationStarted, authorizationCancelled, authorizationRejected, admissionAccepted, groupStarted,
    mediaConnectStarted, mediaConnected, keysInstalled, mediaLeaseGranted, activated, recoveryStarted,
    verificationPending, decryptionRecovery, firstRemoteDecryption, microphoneRequested, microphoneChanged,
    listeningChanged, memberVolumeChanged, audioRouteChanged, audioInterrupted, audioResumed, leaving, cleanedUp, failed
}
internal enum class DiagnosticPhase { idle, authorizing, connecting, securing, verifying, active, recovering, leaving }
internal enum class DiagnosticRoute { unknown, speaker, earpiece, wired, bluetooth, streaming }
internal enum class TrackEncryption { waiting, verified, missingKey, decryptionFailed, failed }
internal enum class TrackQuality { unknown, excellent, good, poor, lost }

internal data class DiagnosticAudio(val muted: Boolean, val listening: Boolean, val preset: AudioPreset, val route: DiagnosticRoute)
internal data class DiagnosticTrack(val muted: Boolean, val subscribed: Boolean, val subscriptionFailed: Boolean,
    val encryption: TrackEncryption, val quality: TrackQuality, val received: Long?, val lost: Long?,
    val jitterMS: Double?, val roundTripMS: Double?, val decryptionAgeMS: Long?)

/** Each payload is explicitly projected onto v1 columns/JSON on the writer thread. */
internal sealed interface LogDetails {
    fun json(errorCode: String? = null): JsonObject

    data object Version : LogDetails {
        override fun json(errorCode: String?) = buildJsonObject {
            put("platform", "android")
            put("app_version", BuildConfig.VERSION_NAME)
            put("app_build", BuildConfig.CLIENT_BUILD)
            put("os_version", Build.VERSION.RELEASE.takeIf { it.matches(Regex("""\d+(\.\d+)*""")) } ?: Build.VERSION.SDK_INT.toString())
        }
    }
    data class Screen(val visible: Boolean) : LogDetails {
        override fun json(errorCode: String?) = buildJsonObject { put("visible", visible) }
    }
    data class Dropped(val count: Long) : LogDetails {
        override fun json(errorCode: String?) = buildJsonObject { put("count", count) }
    }
    data class Capture(val rate: Int, val channels: Int, val denoising: Boolean) : LogDetails {
        override fun json(errorCode: String?) = buildJsonObject {
            put("sample_rate_hz", rate); put("channels", channels); put("rnnoise", if (denoising) 1 else 0)
        }
    }
    data class Voice(val frames: Long, val total: Long, val maximum: Long) : LogDetails {
        override fun json(errorCode: String?) = buildJsonObject { put("frames", frames); put("total_ns", total); put("max_ns", maximum) }
    }
    data class Lifecycle(val stage: CallStage, val phase: DiagnosticPhase, val sequence: Long, val elapsed: Long,
        val transport: Long, val keys: Long, val audio: DiagnosticAudio) : LogDetails {
        override fun json(errorCode: String?) = buildJsonObject {
            put("event", stage.name); put("phase", phase.name); put("sequence", sequence)
            put("elapsedMilliseconds", elapsed); put("transportGeneration", transport); put("keyRevision", keys)
            errorCode?.let { put("failure", it) }
            put("audio", buildJsonObject {
                put("microphoneMuted", audio.muted); put("listening", audio.listening)
                put("preset", audio.preset.name); put("route", audio.route.name)
            })
        }
    }
    data class Sample(val phase: DiagnosticPhase, val audio: DiagnosticAudio, val interrupted: Boolean,
        val lease: Long?, val tracks: List<DiagnosticTrack>) : LogDetails {
        override fun json(errorCode: String?) = buildJsonObject {
            put("schema", 1); put("phase", phase.name); put("microphoneMuted", audio.muted); put("listening", audio.listening)
            put("audioInterrupted", interrupted); put("route", audio.route.name); put("preset", audio.preset.name)
            put("mediaLeaseValid", lease != null && lease > 0); lease?.let { put("mediaLeaseRemainingMS", it) }
            put("tracks", buildJsonArray { tracks.forEachIndexed { index, t ->
                add(buildJsonObject {
                    put("number", index + 1); put("muted", t.muted); put("subscribed", t.subscribed)
                    put("subscriptionFailed", t.subscriptionFailed); put("encryption", t.encryption.name); put("quality", t.quality.name)
                    t.received?.takeIf { it >= 0 }?.let { put("packetsReceived", it) }
                    t.lost?.takeIf { it >= 0 }?.let { put("packetsLost", it) }
                    metric(t.jitterMS)?.let { put("jitterMS", it) }; metric(t.roundTripMS)?.let { put("roundTripMS", it) }
                    t.decryptionAgeMS?.takeIf { it >= 0 }?.let { put("lastDecryptionEventAgeMS", it) }
                })
            } })
        }
        private fun metric(value: Double?) = value?.takeIf { it.isFinite() && it >= 0 }?.coerceAtMost(600_000.0)
    }
}
