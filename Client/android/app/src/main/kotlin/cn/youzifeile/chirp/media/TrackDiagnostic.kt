package cn.youzifeile.chirp.media

internal data class TrackDiagnostic(val identity: String, val subscribed: Boolean, val muted: Boolean,
    val quality: String, val jitterMS: Double?, val roundTripMS: Double?, val lost: Long?, val received: Long?,
    val lastDecryptedAt: Long?, val encrypted: Boolean, val trackID: String = identity,
    val decryptionFailure: VoiceFailure? = null, val measuredAt: Long = 0,
    val subscriptionFailed: Boolean = false, val firstDecryptedAt: Long? = null,
    val averageJitterBufferMS: Double? = null, val lastDecryptionEventAt: Long? = null) {
    val lastDecryptionMS get() = lastDecryptedAt?.let { (measuredAt - it).coerceAtLeast(0) }
}

internal enum class VoiceFailure { MissingKey, DecryptionFailed }

internal enum class MemberAudioStatus { NoTransport, NoTrack, Muted, NetworkLost, SubscriptionFailed, Unsubscribed, DecryptionFailed, Verified, Waiting }

internal fun memberAudioStatus(present: Boolean, tracks: List<TrackDiagnostic>): MemberAudioStatus {
    if (!present) return MemberAudioStatus.NoTransport
    if (tracks.isEmpty()) return MemberAudioStatus.NoTrack
    val audible = tracks.filterNot { it.muted }
    return when {
        audible.isEmpty() -> MemberAudioStatus.Muted
        audible.any { it.quality == "LOST" } -> MemberAudioStatus.NetworkLost
        audible.any { it.subscriptionFailed } -> MemberAudioStatus.SubscriptionFailed
        audible.any { !it.subscribed } -> MemberAudioStatus.Unsubscribed
        audible.any { it.decryptionFailure != null } -> MemberAudioStatus.DecryptionFailed
        audible.all { it.encrypted && it.subscribed && it.lastDecryptedAt != null } -> MemberAudioStatus.Verified
        else -> MemberAudioStatus.Waiting
    }
}

internal class DecryptionRecovery {
    enum class Action { Recover, Stop }
    private data class Issue(val since: Long, val packets: Long)
    private val issues = mutableMapOf<String, Issue>()
    private var lastRecovery: Long? = null
    private var attempts = 0

    fun observe(tracks: List<TrackDiagnostic>, now: Long): Action? {
        val failing = tracks.filter { it.subscribed && !it.muted && it.encrypted && it.decryptionFailure != null }
        issues.keys.retainAll(failing.map { it.trackID }.toSet())
        for (track in failing) {
            val packets = track.received ?: continue
            if (packets <= 0) continue
            val first = issues.getOrPut(track.trackID) { Issue(now, packets) }
            if (packets < first.packets || track.lastDecryptedAt?.let { it > first.since } == true) {
                issues[track.trackID] = Issue(now, packets)
                continue
            }
            if (packets == first.packets || now - first.since < 5_000) continue
            if (lastRecovery?.let { now - it >= 60_000 } == true) attempts = 0
            issues.clear()
            if (attempts >= 2) return Action.Stop
            attempts++
            lastRecovery = now
            return Action.Recover
        }
        return null
    }

    fun resetTracks() = issues.clear()
}
