package main

import (
	"errors"
	"maps"
	"math"
	"slices"
	"strings"

	"github.com/livekit/protocol/livekit"
	lk "github.com/livekit/server-sdk-go/v2"
	"github.com/pion/webrtc/v4"
)

type voiceTrack struct {
	sid, owner                              string
	ssrc                                    webrtc.SSRC
	muted, subscribed, subscriptionFailed   bool
	microphone                              bool
	encryption                              string
	received, issuePackets                  uint64
	packetsReceived                         *uint64
	packetsLost                             *int32
	jitter                                  *float64
	lastDecryption, issueSince, lastFailure int64
}

func (m *mediaSession) trackLocked(sid, owner string) *voiceTrack {
	if m.tracks == nil {
		m.tracks = map[string]*voiceTrack{}
	}
	t := m.tracks[sid]
	if t == nil || t.owner != owner {
		t = &voiceTrack{sid: sid, owner: owner, encryption: "waiting"}
		m.tracks[sid] = t
	}
	return t
}

func (m *mediaSession) observeTracks(cb *lk.RoomCallback) {
	cb.OnTrackPublished = func(pub *lk.RemoteTrackPublication, p *lk.RemoteParticipant) {
		if pub.Kind() != lk.TrackKindAudio || pub.Source() != livekit.TrackSource_MICROPHONE {
			return
		}
		m.mu.Lock()
		t := m.trackLocked(pub.SID(), p.Identity())
		t.microphone = true
		t.muted = pub.IsMuted()
		m.logTracksLocked(true)
		m.mu.Unlock()
		signalWorker(m.subscriptionWake)
	}
	cb.OnTrackSubscriptionFailed = func(sid string, p *lk.RemoteParticipant) {
		m.mu.Lock()
		t := m.trackLocked(sid, p.Identity())
		t.subscriptionFailed = true
		t.subscribed = false
		m.logTracksLocked(true)
		m.mu.Unlock()
	}
	cb.OnTrackUnsubscribed = func(_ *webrtc.TrackRemote, pub *lk.RemoteTrackPublication, p *lk.RemoteParticipant) {
		m.mu.Lock()
		if t := m.tracks[pub.SID()]; t != nil && t.owner == p.Identity() {
			t.subscribed = false
			t.issueSince = 0
			t.encryption = "waiting"
			m.logTracksLocked(true)
		}
		m.mu.Unlock()
	}
	cb.OnTrackUnpublished = func(pub *lk.RemoteTrackPublication, _ *lk.RemoteParticipant) {
		m.mu.Lock()
		delete(m.tracks, pub.SID())
		m.logTracksLocked(true)
		m.mu.Unlock()
		signalWorker(m.subscriptionWake)
	}
	changeMute := func(pub lk.TrackPublication, p lk.Participant) {
		if _, remote := p.(*lk.RemoteParticipant); !remote || pub.Kind() != lk.TrackKindAudio || pub.Source() != livekit.TrackSource_MICROPHONE {
			return
		}
		m.mu.Lock()
		t := m.trackLocked(pub.SID(), p.Identity())
		t.muted = pub.IsMuted()
		if t.muted {
			t.issueSince = 0
		}
		m.logTracksLocked(true)
		m.mu.Unlock()
	}
	cb.OnTrackMuted = changeMute
	cb.OnTrackUnmuted = changeMute
}

func (m *mediaSession) subscribed(pub *lk.RemoteTrackPublication, owner string, ssrc webrtc.SSRC) *voiceTrack {
	m.mu.Lock()
	defer m.mu.Unlock()
	t := &voiceTrack{sid: pub.SID(), owner: owner, ssrc: ssrc, microphone: true, muted: pub.IsMuted(), subscribed: true, encryption: "waiting"}
	if m.tracks == nil {
		m.tracks = map[string]*voiceTrack{}
	}
	m.tracks[t.sid] = t
	m.logTracksLocked(true)
	return t
}

func (t *voiceTrack) observeDecryption(state string, now int64) {
	if state == "" {
		return
	}
	changed := t.encryption != state
	t.encryption = state
	if state == "verified" {
		if changed {
			t.lastDecryption = now
		}
		t.issueSince = 0
	} else {
		if t.issueSince == 0 {
			t.issueSince = now
			t.issuePackets = t.received
		}
		t.lastFailure = now
	}
}

func metric(ms float64) *float64 {
	if math.IsNaN(ms) || math.IsInf(ms, 0) || ms < 0 {
		return nil
	}
	ms = min(ms, 600000)
	return &ms
}

// Query Pion once per second. Each inbound RTP stream is matched by its SSRC;
// all streams on the subscriber transport share the selected ICE pair RTT.
func (m *mediaSession) updateTrackStatistics() {
	if m.room == nil || ticks()-m.sampledAt < 1000 {
		return
	}
	m.sampledAt = ticks()
	pc := m.room.LocalParticipant.GetSubscriberPeerConnection()
	if pc == nil {
		return
	}
	stats := pc.GetStats()
	var rtt *float64
	if s := pc.SCTP(); s != nil && s.Transport() != nil && s.Transport().ICETransport() != nil {
		if pair, ok := s.Transport().ICETransport().GetSelectedCandidatePairStats(); ok && pair.ResponsesReceived > 0 {
			rtt = metric(pair.CurrentRoundTripTime * 1000)
		}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.rtt = rtt
	for _, v := range stats {
		s, ok := v.(webrtc.InboundRTPStreamStats)
		if !ok || s.Kind != "audio" || s.PacketsReceived == 0 {
			continue
		}
		for _, t := range m.tracks {
			if t.subscribed && t.ssrc == s.SSRC {
				received := uint64(s.PacketsReceived)
				t.packetsReceived = &received
				t.packetsLost = &s.PacketsLost
				t.jitter = metric(s.Jitter * 1000)
			}
		}
	}
}

var errDecryptionRecovery = errors.New("AUDIO_DECRYPTION_RECOVERY_FAILED")

func (m *mediaSession) decryptionRecovery(now int64) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed || now >= m.until {
		return false, nil
	}
	for _, t := range m.tracks {
		if !m.members[t.owner] || !t.microphone || t.muted || !t.subscribed || t.issueSince == 0 || (t.encryption != "decryptionFailed" && t.encryption != "missingKey") || t.received <= t.issuePackets || t.lastFailure-t.issueSince < 5000 {
			continue
		}
		if now-m.recoveryAt >= 60000 {
			m.recoveries = 0
		}
		if m.recoveries >= 2 {
			m.recordLocked("failed")
			return false, errDecryptionRecovery
		}
		m.recoveries++
		m.recoveryAt = now
		for _, v := range m.tracks {
			v.issueSince = 0
			v.encryption = "waiting"
		}
		m.recordLocked("decryptionRecovery")
		return true, nil
	}
	return false, nil
}

func (m *mediaSession) fileRateLocked() int64 {
	if m.closed || ticks() >= m.until || m.lost.Load() {
		return 0
	}
	rate := int64(8 << 20)
	for _, t := range m.tracks {
		if !m.members[t.owner] || !t.microphone || !t.subscribed || t.muted {
			continue
		}
		quality, known := m.quality[t.owner]
		if known && quality == livekit.ConnectionQuality_LOST {
			return 0
		}
		if known && quality == livekit.ConnectionQuality_POOR || t.jitter != nil && *t.jitter >= 40 {
			rate = 512 << 10
		}
	}
	return rate
}

func (m *mediaSession) trackViewLocked(t *voiceTrack) obj {
	var age any
	if t.lastDecryption > 0 {
		age = min(int64(86400000), max(int64(0), ticks()-t.lastDecryption))
	}
	q := "unknown"
	if v, ok := m.quality[t.owner]; ok {
		q = strings.ToLower(v.String())
	}
	return obj{"muted": t.muted, "subscribed": t.subscribed, "subscriptionFailed": t.subscriptionFailed, "encryption": t.encryption,
		"quality": q, "lastDecryptionEventAgeMs": age, "packetsReceived": t.received, "packetsLost": t.packetsLost, "jitterMs": t.jitter, "roundTripMs": m.rtt}
}

func (m *mediaSession) peerDiagnostic(id string) obj {
	m.mu.Lock()
	defer m.mu.Unlock()
	var tracks []obj
	var focus *voiceTrack
	priority := func(t *voiceTrack) int {
		switch {
		case t.muted:
			return 0
		case t.subscriptionFailed:
			return 5
		case !t.subscribed:
			return 4
		case t.encryption == "decryptionFailed" || t.encryption == "missingKey":
			return 3
		case t.encryption != "verified":
			return 2
		default:
			return 1
		}
	}
	for _, sid := range slices.Sorted(maps.Keys(m.tracks)) {
		t := m.tracks[sid]
		if t.owner != id || !m.members[t.owner] || !t.microphone {
			continue
		}
		tracks = append(tracks, m.trackViewLocked(t))
		if focus == nil || priority(t) > priority(focus) {
			focus = t
		}
	}
	if focus == nil {
		return obj{"encryption": "noTrack", "subscribed": false, "tracks": []obj{}}
	}
	view := m.trackViewLocked(focus)
	view["tracks"] = tracks
	return view
}
