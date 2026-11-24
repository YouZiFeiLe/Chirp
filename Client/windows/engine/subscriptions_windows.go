package main

import (
	"context"
	"errors"

	"github.com/livekit/protocol/livekit"
	lk "github.com/livekit/server-sdk-go/v2"
)

var errUnencryptedMicrophone = errors.New("REMOTE_TRACK_UNENCRYPTED")
var errSubscription = errors.New("VOICE_CONNECTION_FAILED")

// The server may announce a publication before the room's signed roster or
// its first lease arrives. Only the activated roster can request a receiver.
func (m *mediaSession) wantMicrophone(owner string, kind lk.TrackKind, source livekit.TrackSource, encryption livekit.Encryption_Type) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed || m.audioSuspended || ticks() >= m.until || !m.members[owner] || kind != lk.TrackKindAudio || source != livekit.TrackSource_MICROPHONE {
		return false, nil
	}
	if encryption != livekit.Encryption_GCM {
		return false, errUnencryptedMicrophone
	}
	return true, nil
}

func (m *mediaSession) watchSubscriptions(ctx context.Context) {
	var revision uint64
	for {
		select {
		case <-ctx.Done():
			return
		case <-m.subscriptionWake:
		}
		m.mu.Lock()
		current := m.transportRevision
		m.mu.Unlock()
		if revision != current {
			clear(m.subscriptions)
			revision = current
		}
		seen := map[*lk.RemoteTrackPublication]bool{}
		for _, p := range m.room.GetRemoteParticipants() {
			for _, track := range p.TrackPublications() {
				pub, ok := track.(*lk.RemoteTrackPublication)
				if !ok {
					continue
				}
				seen[pub] = true
				want, err := m.wantMicrophone(p.Identity(), pub.Kind(), pub.Source(), pub.TrackInfo().GetEncryption())
				if err != nil {
					m.mu.Lock()
					m.subscriptionFailure = err
					m.pauseLocked()
					m.mu.Unlock()
					return
				}
				requested, known := m.subscriptions[pub]
				if !known {
					requested = pub.IsSubscribed()
				}
				if requested == want {
					continue
				}
				if err := pub.SetSubscribed(want); err != nil {
					m.mu.Lock()
					m.trackLocked(pub.SID(), p.Identity()).subscriptionFailed = true
					if want && m.transport == transportConnected && ticks() < m.until && m.members[p.Identity()] {
						m.subscriptionFailure = errSubscription
						m.pauseLocked()
					}
					m.mu.Unlock()
					continue
				}
				m.subscriptions[pub] = want
			}
		}
		for pub := range m.subscriptions {
			if !seen[pub] {
				delete(m.subscriptions, pub)
			}
		}
	}
}
