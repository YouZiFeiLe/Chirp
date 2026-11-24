package group

import (
	"sort"
	"time"

	v5 "gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

// A key epoch is independent of the admission generation. Only an unchanged,
// unanimously capable roster may overlap keys; revocation always restarts Hub.
type RotationSnapshot struct {
	Epoch        uint64   `json:"epoch"`
	Phase        string   `json:"phase"`
	Members      []Member `json:"members"`
	Welcome      string   `json:"welcome"`
	Confirmation string   `json:"confirmation"`
}

type rotationRound struct {
	epoch                 uint64
	phase                 string
	packages              map[string]string
	offers                map[string]*v5.RoundProof
	readies               map[string]*v5.ReadyProof
	confirmed             map[string]bool
	activated             map[string]bool
	welcome, confirmation string
	switchAt, deadline    time.Time
}

func (h *Hub) rotationChangedLocked() {
	h.rotationRevision++
	close(h.changed)
	h.changed = make(chan struct{})
}

func (h *Hub) smoothRotationLocked(now time.Time) bool {
	for _, p := range h.members {
		if !p.smoothRotation {
			return false
		}
	}
	if h.rotation == nil {
		switchAt := h.readyAt.Add(h.policy.Rotation)
		window := min(h.policy.TransitionTimeout, h.policy.Rotation/2)
		if now.Before(switchAt.Add(-window)) {
			return true
		}
		h.rotation = &rotationRound{epoch: h.keyEpoch + 1, phase: "collecting", packages: make(map[string]string),
			confirmed: make(map[string]bool), activated: make(map[string]bool), offers: make(map[string]*v5.RoundProof), readies: make(map[string]*v5.ReadyProof), switchAt: switchAt, deadline: switchAt.Add(h.policy.Lease)}
		h.rotationChangedLocked()
		h.logState("rotation_preparing")
	}
	r := h.rotation
	if !now.Before(r.deadline) {
		h.restartLocked(now, "rotation_timeout")
		return true
	}
	if r.phase == "ready" && !now.Before(r.switchAt) {
		r.phase = "switching"
		h.rotationChangedLocked()
		h.logState("rotation_switching")
	}
	return true
}

func (h *Hub) rotationSnapshotLocked(identity string) *RotationSnapshot {
	r := h.rotation
	if r == nil {
		return nil
	}
	s := &RotationSnapshot{Epoch: r.epoch, Phase: r.phase, Confirmation: r.confirmation, Members: []Member{}}
	// Reuse the canonical admission ordering of the ordinary snapshot.
	for _, p := range h.members {
		m := p.Member
		m.KeyPackage = ""
		m.Offer = r.offers[m.Identity]
		m.Ready = r.readies[m.Identity]
		if r.phase == "collecting" || r.phase == "welcoming" {
			m.KeyPackage = r.packages[m.Identity]
		}
		s.Members = append(s.Members, m)
	}
	sort.Slice(s.Members, func(i, j int) bool { return s.Members[i].Identity < s.Members[j].Identity })
	if identity != h.leader && !r.confirmed[identity] && (r.phase == "confirming" || r.phase == "ready" || r.phase == "switching") {
		s.Welcome = r.welcome
	}
	return s
}

func (h *Hub) applyRotationLocked(identity string, request Request, now time.Time) error {
	r := h.rotation
	if h.suspended || h.phase != "ready" || r == nil || request.KeyEpoch != r.epoch {
		return ErrStale
	}
	switch request.Operation {
	case "rotation_package":
		if r.phase != "collecting" || !validBase64(request.KeyPackage, 32, 16384) {
			return ErrConflict
		}
		if previous := r.packages[identity]; previous != "" && previous != request.KeyPackage {
			return ErrConflict
		}
		if r.packages[identity] == request.KeyPackage {
			return nil
		}
		r.packages[identity] = request.KeyPackage
		r.offers[identity] = request.Offer
		if len(r.packages) == len(h.members) {
			r.phase = "welcoming"
		}
	case "rotation_publish":
		if identity != h.leader || r.phase != "welcoming" || !validBase64(request.Confirmation, 32, 32) {
			return ErrConflict
		}
		if len(h.members) > 1 && !validBase64(request.Welcome, 32, 131072) || len(h.members) == 1 && request.Welcome != "" {
			return ErrConflict
		}
		r.welcome, r.confirmation, r.phase = request.Welcome, request.Confirmation, "confirming"
	case "rotation_ack":
		if r.phase != "confirming" && r.phase != "ready" && r.phase != "switching" || request.Confirmation != r.confirmation {
			return ErrConflict
		}
		if r.confirmed[identity] {
			return nil
		}
		r.confirmed[identity] = true
		r.readies[identity] = request.Ready
		if len(r.confirmed) == len(h.members) {
			r.phase = "ready"
		}
	case "rotation_activate":
		if r.phase != "switching" || request.Confirmation != r.confirmation || !r.confirmed[identity] {
			return ErrConflict
		}
		if r.activated[identity] {
			return nil
		}
		r.activated[identity] = true
		h.members[identity].keyEpoch = r.epoch
		if len(r.activated) == len(h.members) {
			h.keyEpoch = r.epoch
			h.rotation = nil
			h.readyAt = now
			h.lastRotationAt = now
			h.updateReason = "scheduled_rotation"
			h.logState("rotation_completed")
		}
	default:
		return ErrConflict
	}
	h.rotationChangedLocked()
	// A slow final acknowledgement can arrive after the nominal switch time.
	if h.rotation != nil && h.rotation.phase == "ready" {
		h.smoothRotationLocked(now)
	}
	return nil
}
