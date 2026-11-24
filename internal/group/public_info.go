package group

import "time"

// RoomInformation is display-only metadata for the snapshot's exact admission
// generation. It grants no lease and contains no identities or key material.
type RoomInformation struct {
	ServerTimeMS       int64  `json:"server_time_ms"`
	EstablishedAtMS    int64  `json:"established_at_ms,omitempty"`
	LastRotationAtMS   int64  `json:"last_rotation_at_ms,omitempty"`
	NextRotationAtMS   int64  `json:"next_rotation_at_ms,omitempty"`
	RotationIntervalMS int64  `json:"rotation_interval_ms"`
	KeyEpoch           uint64 `json:"key_epoch"`
	MemberCount        int    `json:"member_count"`
	UpdateReason       string `json:"update_reason"`
	RotationPhase      string `json:"rotation_phase,omitempty"`
	RotationEpoch      uint64 `json:"rotation_epoch,omitempty"`
	ConfirmedMembers   int    `json:"confirmed_members"`
	ActivatedMembers   int    `json:"activated_members"`
}

func (h *Hub) roomInformationLocked(now time.Time) *RoomInformation {
	info := &RoomInformation{ServerTimeMS: now.UnixMilli(), RotationIntervalMS: h.policy.Rotation.Milliseconds(),
		KeyEpoch: h.keyEpoch, MemberCount: len(h.members), UpdateReason: h.updateReason}
	if !h.establishedAt.IsZero() {
		info.EstablishedAtMS = h.establishedAt.UnixMilli()
	}
	if !h.lastRotationAt.IsZero() {
		info.LastRotationAtMS = h.lastRotationAt.UnixMilli()
	}
	if h.phase == "ready" && !h.suspended {
		info.NextRotationAtMS = h.readyAt.Add(h.policy.Rotation).UnixMilli()
	}
	if r := h.rotation; r != nil {
		info.RotationPhase, info.RotationEpoch = r.phase, r.epoch
		info.ConfirmedMembers, info.ActivatedMembers = len(r.confirmed), len(r.activated)
	}
	return info
}

func publicUpdateReason(reason string, initial bool) string {
	if initial {
		return "initial_connection"
	}
	switch reason {
	case "member_joined", "member_left", "admission_removed", "login_removed", "heartbeat_timeout":
		return "members_changed"
	case "scheduled_rotation":
		return "scheduled_rotation"
	default:
		return "connection_recovery"
	}
}
