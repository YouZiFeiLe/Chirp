package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test

class CallFlowParityTest {
    @Test fun previousUnconfirmedAdmissionCannotReuseItsSequenceAfterAStaleSessionRead() {
        val url = "https://example.test/".toHttpUrl()
        val session = SessionRepository(ServerConnection(url, url, url, null, url, url, url, url, "room", null),
            Login("test", "member.login", "Name", 30), ChirpHttp())
        assertEquals(4L, session.reserveJoinSequence(3))
        assertEquals(5L, session.reserveJoinSequence(3))
        assertEquals(11L, session.reserveJoinSequence(10))
        assertThrows(ChirpException::class.java) { session.reserveJoinSequence(Long.MAX_VALUE) }
    }

    @Test fun memberAudioSeparatesTransportSubscriptionEncryptionAndMuteStates() {
        val fresh = TrackDiagnostic("alice", true, false, "GOOD", null, null, null, 20, null, true)
        fun status(vararg tracks: TrackDiagnostic) = memberAudioStatus(true, tracks.toList())
        assertEquals(MemberAudioStatus.NoTransport, memberAudioStatus(false, emptyList()))
        assertEquals(MemberAudioStatus.NoTrack, status())
        assertEquals(MemberAudioStatus.Muted, status(fresh.copy(muted = true)))
        assertEquals(MemberAudioStatus.NetworkLost, status(fresh.copy(quality = "LOST", subscriptionFailed = true)))
        assertEquals(MemberAudioStatus.SubscriptionFailed, status(fresh.copy(subscribed = false, subscriptionFailed = true)))
        assertEquals(MemberAudioStatus.Unsubscribed, status(fresh.copy(subscribed = false)))
        assertEquals(MemberAudioStatus.Unsubscribed, status(fresh.copy(lastDecryptedAt = 120), fresh.copy(subscribed = false)))
        assertEquals(MemberAudioStatus.Waiting, status(fresh))
        assertEquals(MemberAudioStatus.DecryptionFailed, status(fresh.copy(decryptionFailure = VoiceFailure.MissingKey)))
        assertEquals(MemberAudioStatus.Verified, status(fresh.copy(lastDecryptedAt = 120), fresh.copy(muted = true)))
    }
}
