package main

import (
	"math"
	"slices"
	"sync"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
)

// The actor and both pulse workers can complete out of order. This cache is
// only for the room information sheet and never supplies key or lease limits.
type roomInformation struct {
	mu                                                           sync.Mutex
	generation, revision, rotationRevision, epoch, rotationEpoch uint64
	count                                                        int
	phase                                                        string
	suspended, unavailable                                       bool
	value                                                        *group.RoomInformation
	observed, checked                                            int64
}

func validInformation(i *group.RoomInformation) bool {
	if i == nil || i.ServerTimeMS <= 0 || i.ServerTimeMS >= 253402300799000 ||
		i.KeyEpoch == math.MaxUint64 || i.RotationIntervalMS < 1 || i.RotationIntervalMS > 86400000 ||
		i.MemberCount <= 0 || i.ActivatedMembers < 0 || i.ConfirmedMembers < i.ActivatedMembers || i.MemberCount < i.ConfirmedMembers ||
		!slices.Contains([]string{"initial_connection", "members_changed", "scheduled_rotation", "connection_recovery"}, i.UpdateReason) {
		return false
	}
	if i.EstablishedAtMS < 0 || i.EstablishedAtMS > i.ServerTimeMS ||
		i.LastRotationAtMS < 0 || i.LastRotationAtMS > i.ServerTimeMS ||
		i.LastRotationAtMS != 0 && (i.KeyEpoch == 0 || i.EstablishedAtMS == 0 || i.LastRotationAtMS < i.EstablishedAtMS) ||
		i.NextRotationAtMS < 0 || i.NextRotationAtMS > i.ServerTimeMS+i.RotationIntervalMS || i.NextRotationAtMS != 0 && i.EstablishedAtMS == 0 {
		return false
	}
	if i.RotationPhase == "" {
		return i.RotationEpoch == 0 && i.ConfirmedMembers == 0 && i.ActivatedMembers == 0
	}
	return i.RotationEpoch == i.KeyEpoch+1 && slices.Contains([]string{"collecting", "welcoming", "confirming", "ready", "switching"}, i.RotationPhase)
}

func (v *roomInformation) snapshot(s group.Snapshot, started int64) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.generation != s.Generation {
		v.checked = 0
	}
	v.generation, v.revision, v.rotationRevision = s.Generation, s.Revision, s.RotationRevision
	v.epoch, v.count, v.suspended = s.KeyEpoch, len(s.Members), s.Suspended
	v.phase, v.rotationEpoch = "", 0
	if s.Rotation != nil {
		v.phase, v.rotationEpoch = s.Rotation.Phase, s.Rotation.Epoch
	}
	v.updateLocked(s.RoomInformation, started)
}

func (v *roomInformation) pulse(p pulse, started int64) (rotationChanged bool) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if p.Generation != v.generation || p.Revision != v.revision {
		return false
	}
	if p.RotationRevision != v.rotationRevision {
		return p.RotationRevision > v.rotationRevision
	}
	v.updateLocked(p.Information, started)
	return false
}

func (v *roomInformation) updateLocked(i *group.RoomInformation, started int64) {
	if started < v.checked {
		return
	}
	v.checked = started
	if !validInformation(i) || i.MemberCount != v.count || i.KeyEpoch != v.epoch || i.RotationPhase != v.phase || i.RotationEpoch != v.rotationEpoch {
		v.unavailable = true
		return
	}
	v.value, v.observed, v.unavailable = i, started, v.suspended
}

func (v *roomInformation) view() (*group.RoomInformation, int64, bool) {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.value, v.observed, v.unavailable
}
