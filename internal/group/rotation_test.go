package group

import (
	"errors"
	"testing"
	"time"
)

func rotationFixture(t *testing.T) (*Hub, []hubPeer, *time.Time, Snapshot) {
	t.Helper()
	h := NewHub("friends", DefaultPolicy())
	now := time.Now()
	h.now = func() time.Time { return now }
	h.policy.HeartbeatTimeout = time.Hour
	peers := []hubPeer{peer("a"), peer("b")}
	for _, p := range peers {
		apply(t, h, p, Request{Operation: "join", SmoothRotation: true})
	}
	s := complete(t, h, peers...)
	return h, peers, &now, s
}

func prepareRotation(t *testing.T, h *Hub, peers []hubPeer, s Snapshot) Snapshot {
	t.Helper()
	for _, p := range peers {
		r := roundRequest(s, "rotation_package")
		r.KeyEpoch = s.Rotation.Epoch
		r.KeyPackage = publicBlob(128)
		s = apply(t, h, p, r)
	}
	r := roundRequest(s, "rotation_publish")
	r.KeyEpoch = s.Rotation.Epoch
	r.Welcome = publicBlob(512)
	r.Confirmation = publicBlob(32)
	s = apply(t, h, peers[0], r)
	for i, p := range peers {
		r = roundRequest(s, "rotation_ack")
		r.KeyEpoch = s.Rotation.Epoch
		r.Confirmation = s.Rotation.Confirmation
		s = apply(t, h, p, r)
		if i == 0 && len(peers) > 1 {
			if s.Rotation.Phase != "confirming" {
				t.Fatal("candidate bypassed installer barrier")
			}
			early := roundRequest(s, "rotation_activate")
			early.KeyEpoch = s.Rotation.Epoch
			early.Confirmation = s.Rotation.Confirmation
			if _, err := h.Apply(p.member, p.key, randomID(), early); !errors.Is(err, ErrConflict) {
				t.Fatal("activated before every installer confirmed", err)
			}
		}
	}
	return s
}

func TestSmoothRotationKeepsAdmissionAndLeasesAndWaitsForEveryInstaller(t *testing.T) {
	h, peers, now, s := rotationFixture(t)
	generation, revision := s.Generation, s.Revision
	*now = now.Add(h.policy.Rotation - h.policy.TransitionTimeout)
	s = apply(t, h, peers[0], roundRequest(s, "snapshot"))
	if s.Rotation == nil || s.Phase != "ready" || s.LeaseMS <= 0 || s.Generation != generation || s.Revision != revision {
		t.Fatal("preparation interrupted the active round", s)
	}
	s = prepareRotation(t, h, peers, s)
	if s.Rotation.Phase != "ready" || s.KeyEpoch != 0 {
		t.Fatal("candidate switched before scheduled time", s)
	}
	*now = now.Add(h.policy.TransitionTimeout)
	s = apply(t, h, peers[0], roundRequest(s, "snapshot"))
	if s.Rotation.Phase != "switching" {
		t.Fatal("prepared keys did not switch")
	}
	for i, p := range peers {
		r := roundRequest(s, "rotation_activate")
		r.KeyEpoch = 1
		r.Confirmation = s.Rotation.Confirmation
		s = apply(t, h, p, r)
		lease := roundRequest(s, "lease")
		lease.Revision = s.Revision
		lease.Confirmation = s.Confirmation
		lease.KeyEpoch = 1
		if apply(t, h, p, lease).LeaseMS <= 0 {
			t.Fatal("switched participant lost permission")
		}
		lease.KeyEpoch = 0
		if _, err := h.Apply(p.member, p.key, randomID(), lease); !errors.Is(err, ErrStale) {
			t.Fatal("retired epoch granted a lease", err)
		}
		if i == 0 && s.Rotation == nil {
			t.Fatal("retired before all senders switched")
		}
	}
	if s.KeyEpoch != 1 || s.Rotation != nil || s.Generation != generation || s.Revision != revision {
		t.Fatal("smooth rotation changed membership", s)
	}
}

func TestSmoothRotationRevocationDiscardsPreparedKeys(t *testing.T) {
	h, peers, now, s := rotationFixture(t)
	*now = now.Add(h.policy.Rotation - h.policy.TransitionTimeout)
	s = apply(t, h, peers[0], roundRequest(s, "snapshot"))
	s = prepareRotation(t, h, peers, s)
	old := s
	h.Remove(peers[1].identity())
	s = apply(t, h, peers[0], roundRequest(s, "snapshot"))
	if s.Generation <= old.Generation || s.Rotation != nil || s.LeaseMS != 0 || s.KeyEpoch != 0 {
		t.Fatal("membership change retained candidate", s)
	}
	r := roundRequest(old, "rotation_activate")
	r.KeyEpoch = 1
	r.Confirmation = old.Rotation.Confirmation
	if _, err := h.Apply(peers[0].member, peers[0].key, randomID(), r); !errors.Is(err, ErrStale) {
		t.Fatal("stale candidate activated", err)
	}
}

func TestSmoothRotationDeadlineCannotExtendOldKeysIndefinitely(t *testing.T) {
	h, peers, now, s := rotationFixture(t)
	*now = now.Add(h.policy.Rotation + 2*time.Second)
	s = apply(t, h, peers[0], roundRequest(s, "snapshot"))
	if s.LeaseMS > 1000 {
		t.Fatal("old epoch lease exceeded cutoff", s.LeaseMS)
	}
	*now = now.Add(time.Second)
	s = apply(t, h, peers[0], roundRequest(s, "snapshot"))
	if s.Phase != "collecting" || s.Rotation != nil || s.LeaseMS != 0 {
		t.Fatal("stalled candidate did not fail closed", s)
	}
}
