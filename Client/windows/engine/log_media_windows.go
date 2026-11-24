package main

import (
	"context"
	"errors"
	"maps"
	"slices"
	"time"

	"github.com/livekit/protocol/livekit"
)

const audioListening uint32 = 1 << 4
const defaultAudioPreset = 1 // Windows communications

func boolBit(v bool) uint32 {
	if v {
		return 1
	}
	return 0
}

func (l *clientLog) setAudioContext(a args) {
	preset := a.Preset
	if preset < 0 || preset > 2 {
		preset = defaultAudioPreset
	}
	l.audio.Store(uint32(preset) | boolBit(a.SelectedInput)<<2 | boolBit(a.SelectedOutput)<<3 | boolBit(a.Listening)*audioListening)
}

type logAudio struct {
	Muted  bool   `json:"microphoneMuted"`
	Listen bool   `json:"listening"`
	Preset string `json:"preset"`
	Route  string `json:"route"`
}

func (l *clientLog) audioDetails(muted bool) logAudio {
	bits := l.audio.Load()
	presets := [...]string{"communicationsDenoise", "communications", "software"}
	routes := [...]string{"default", "selectedInput", "selectedOutput", "selectedInputOutput"}
	return logAudio{muted, bits&audioListening != 0, presets[bits&3], routes[(bits>>2)&3]}
}

type logCallEvent struct {
	Event     string    `json:"event"`
	Phase     string    `json:"phase"`
	Sequence  uint64    `json:"sequence"`
	Elapsed   int64     `json:"elapsedMilliseconds"`
	Transport uint64    `json:"transportGeneration"`
	Keys      uint64    `json:"keyRevision"`
	Failure   string    `json:"failure,omitempty"`
	Audio     *logAudio `json:"audio,omitempty"`
}

// Called with m.mu when media already exists. The segment owns its monotonic
// call clock, including admission stages before a media session exists.
func (l *clientLog) lifecycle(g uint64, event, phase string, m *mediaSession, err error) {
	if g == 0 || g != l.epoch() {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if g != l.epoch() {
		return
	}
	now := time.Now()
	if l.callStart.IsZero() {
		l.callStart = now
	}
	l.callSequence++
	d := logCallEvent{Event: event, Phase: phase, Sequence: l.callSequence, Elapsed: now.Sub(l.callStart).Milliseconds()}
	if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, errJoinCancelled) {
		d.Failure = safeLogError(err)
	}
	if m != nil {
		a := l.audioDetails(m.muted)
		d.Audio, d.Transport, d.Keys = &a, m.transportRevision, m.logKeyRevision
	}
	l.appendLocked(logEntry{op: logOp{"call", "lifecycle"}, details: d})
}

func callLogPhase(status string) string {
	switch status {
	case "ready":
		return "active"
	case "verify":
		return "verifying"
	case "securing":
		return "securing"
	case "connecting":
		return "connecting"
	default:
		return "recovering"
	}
}

func (m *mediaSession) recordLocked(event string) {
	switch event {
	case "mediaConnected":
		m.logPhase = "connecting"
	case "keysInstalled":
		m.logKeyRevision++
		m.logPhase = "securing"
	case "activated":
		m.logPhase = "active"
	case "leaving":
		m.logPhase = "leaving"
	case "cleanedUp":
		m.logPhase = "idle"
	case "reconnecting", "mediaLeaseExpired", "audioInterrupted", "decryptionRecovery", "failed":
		m.logPhase = "recovering"
	}
	installationLog.lifecycle(installationLog.epoch(), event, m.logPhase, m, nil)
}

type logTrack struct {
	Number             int      `json:"number"`
	Muted              bool     `json:"muted"`
	Subscribed         bool     `json:"subscribed"`
	SubscriptionFailed bool     `json:"subscriptionFailed"`
	Encryption         string   `json:"encryption"`
	Quality            string   `json:"quality"`
	Received           *uint64  `json:"packetsReceived,omitempty"`
	Lost               *int32   `json:"packetsLost,omitempty"`
	Jitter             *float64 `json:"jitterMS,omitempty"`
	RTT                *float64 `json:"roundTripMS,omitempty"`
	DecryptionAge      *int64   `json:"lastDecryptionEventAgeMS,omitempty"`
}
type logTrackSample struct {
	logAudio
	Schema      int        `json:"schema"`
	Phase       string     `json:"phase"`
	Interrupted bool       `json:"audioInterrupted"`
	Valid       bool       `json:"mediaLeaseValid"`
	Remaining   *int64     `json:"mediaLeaseRemainingMS,omitempty"`
	Tracks      []logTrack `json:"tracks"`
}

func (m *mediaSession) trackSampleLocked(audio logAudio, now int64) logTrackSample {
	d := logTrackSample{logAudio: audio, Schema: 1, Phase: m.logPhase, Interrupted: m.audioSuspended, Valid: !m.closed && m.until > now, Tracks: []logTrack{}}
	if d.Phase == "" {
		d.Phase = "connecting"
	}
	if d.Valid {
		remaining := m.until - now
		d.Remaining = &remaining
	}
	for _, sid := range slices.Sorted(maps.Keys(m.tracks)) {
		t := m.tracks[sid]
		if !m.members[t.owner] || !t.microphone {
			continue
		}
		q := "unknown"
		if quality, ok := m.quality[t.owner]; ok {
			switch quality {
			case livekit.ConnectionQuality_EXCELLENT:
				q = "excellent"
			case livekit.ConnectionQuality_GOOD:
				q = "good"
			case livekit.ConnectionQuality_POOR:
				q = "poor"
			case livekit.ConnectionQuality_LOST:
				q = "lost"
			}
		}
		encryption := "waiting"
		switch t.encryption {
		case "verified", "missingKey", "decryptionFailed", "failed":
			encryption = t.encryption
		}
		v := logTrack{Number: len(d.Tracks) + 1, Muted: t.muted, Subscribed: t.subscribed, SubscriptionFailed: t.subscriptionFailed,
			Encryption: encryption, Quality: q, Received: t.packetsReceived, Lost: t.packetsLost, Jitter: t.jitter, RTT: m.rtt}
		if t.lastDecryption > 0 {
			age := max(int64(0), now-t.lastDecryption)
			v.DecryptionAge = &age
		}
		d.Tracks = append(d.Tracks, v)
	}
	return d
}

type decryptWindow struct {
	generation uint64
	Frames     uint64 `json:"frames"`
	Total      uint64 `json:"total_ns"`
	Max        uint64 `json:"max_ns"`
}

type voiceMeasurement struct {
	generation uint64
	elapsed    time.Duration
}

// The RTP path only updates counters under its existing media lock.
func (m *mediaSession) countDecryptionLocked(s voiceMeasurement) {
	if s.generation == 0 {
		return
	}
	if m.firstDecryptGeneration != s.generation {
		m.firstDecryptGeneration = s.generation
		installationLog.lifecycle(s.generation, "firstRemoteDecryption", m.logPhase, m, nil)
	}
	w := &m.decryptWindow
	if w.generation != s.generation {
		*w = decryptWindow{generation: s.generation}
	}
	w.Frames++
	ns := uint64(s.elapsed.Nanoseconds())
	w.Total += ns
	w.Max = max(w.Max, ns)
}

func (m *mediaSession) flushVoiceLocked() {
	w := m.decryptWindow
	m.decryptWindow = decryptWindow{}
	if w.Frames != 0 {
		installationLog.record(w.generation, logEntry{op: logOp{"crypto", "voiceDecrypt"}, details: w})
	}
}

func (m *mediaSession) logTracksLocked(changed bool) {
	g := installationLog.epoch()
	if g == 0 {
		return
	}
	now := ticks()
	audio := installationLog.audioDetails(m.muted)
	if !changed && g == m.sampleGeneration && now-m.lastLogSample < 5000 && audio == m.lastLogAudio {
		return
	}
	m.sampleGeneration, m.lastLogSample, m.lastLogAudio = g, now, audio
	installationLog.record(g, logEntry{op: logOp{"call", "trackSample"}, details: m.trackSampleLocked(audio, now)})
}

func (m *mediaSession) logMediaTick(status string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if now := ticks(); now-m.lastVoiceWindow >= 1000 {
		m.flushVoiceLocked()
		m.lastVoiceWindow = now
	}
	phase := callLogPhase(status)
	changed := phase != m.logPhase
	m.logPhase = phase
	if changed && phase == "verifying" {
		m.recordLocked("verificationPending")
	}
	m.logTracksLocked(changed)
}
