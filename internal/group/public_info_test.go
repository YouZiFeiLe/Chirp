package group

import (
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"
)

func TestRoomInformationWaitsForAllActivationsAndResetsWithMembership(t *testing.T) {
	h, peers, now, s := rotationFixture(t)
	established := now.UnixMilli()
	if s.RoomInformation.EstablishedAtMS != established || s.RoomInformation.LastRotationAtMS != 0 {
		t.Fatal("initial establishment was reported as a rotation", s.RoomInformation)
	}
	if s.RoomInformation.NextRotationAtMS != now.Add(h.policy.Rotation).UnixMilli() {
		t.Fatal("schedule differs from the hub policy", s.RoomInformation)
	}
	*now = now.Add(h.policy.Rotation - h.policy.TransitionTimeout)
	s = apply(t, h, peers[0], roundRequest(s, "snapshot"))
	s = prepareRotation(t, h, peers, s)
	if s.RoomInformation.ConfirmedMembers != len(peers) || s.RoomInformation.LastRotationAtMS != 0 {
		t.Fatal("preparation was reported as completed", s.RoomInformation)
	}
	*now = now.Add(h.policy.TransitionTimeout)
	s = apply(t, h, peers[0], roundRequest(s, "snapshot"))
	for i, p := range peers {
		r := roundRequest(s, "rotation_activate")
		r.KeyEpoch, r.Confirmation = 1, s.Rotation.Confirmation
		s = apply(t, h, p, r)
		if i == 0 && (s.RoomInformation.LastRotationAtMS != 0 || s.RoomInformation.ActivatedMembers != 1) {
			t.Fatal("one sender's switch was reported as full-room completion", s.RoomInformation)
		}
	}
	info := s.RoomInformation
	if info.LastRotationAtMS != now.UnixMilli() || info.EstablishedAtMS != established || info.KeyEpoch != 1 || info.RotationPhase != "" {
		t.Fatal("completed rotation metadata is inconsistent", info)
	}
	finished := info.LastRotationAtMS
	*now = now.Add(time.Second)
	s = apply(t, h, peers[0], roundRequest(s, "heartbeat"))
	if s.RoomInformation.LastRotationAtMS != finished || s.RoomInformation.ServerTimeMS != now.UnixMilli() {
		t.Fatal("heartbeat restarted the completed event's timestamp", s.RoomInformation)
	}
	h.Remove(peers[1].identity())
	s = apply(t, h, peers[0], roundRequest(s, "snapshot"))
	info = s.RoomInformation
	if info.EstablishedAtMS != 0 || info.LastRotationAtMS != 0 || info.NextRotationAtMS != 0 || info.MemberCount != 1 || info.UpdateReason != "members_changed" {
		t.Fatal("new roster inherited another roster's security history", info)
	}
}

func TestRoomInformationSuppressesScheduleWhileSuspended(t *testing.T) {
	h, peers, _, s := rotationFixture(t)
	h.Reconcile(nil, false)
	s = apply(t, h, peers[0], roundRequest(s, "snapshot"))
	if !s.Suspended || s.RoomInformation.NextRotationAtMS != 0 || s.LeaseMS != 0 {
		t.Fatal("paused room retained a live schedule or lease", s)
	}
	h.Reconcile(nil, true)
	s = apply(t, h, peers[0], roundRequest(s, "snapshot"))
	if s.RoomInformation.EstablishedAtMS != 0 || s.RoomInformation.NextRotationAtMS != 0 {
		t.Fatal("authority recovery retained previous connection timestamps", s.RoomInformation)
	}
}

func TestRoomInformationInFullAndCompactRepliesNeverGrantsPermission(t *testing.T) {
	h, _, _, state := rotationFixture(t)
	for _, operation := range []string{"snapshot", "heartbeat", "lease"} {
		t.Run(operation, func(t *testing.T) {
			response := httptest.NewRecorder()
			new(Server).reply(response, operation, state)
			var body struct {
				Information RoomInformation `json:"room_information"`
				LeaseMS     int64           `json:"lease_ms"`
			}
			if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			if body.Information.RotationIntervalMS != h.policy.Rotation.Milliseconds() || body.Information.ServerTimeMS == 0 {
				t.Fatal("reply omitted public schedule metadata", response.Body.String())
			}
			if operation != "lease" && body.LeaseMS != 0 {
				t.Fatal("public information granted media permission")
			}
		})
	}
	encoded, err := json.Marshal(state.RoomInformation)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err := json.Unmarshal(encoded, &fields); err != nil {
		t.Fatal(err)
	}
	allowed := map[string]bool{"server_time_ms": true, "established_at_ms": true, "last_rotation_at_ms": true,
		"next_rotation_at_ms": true, "rotation_interval_ms": true, "key_epoch": true, "member_count": true,
		"update_reason": true, "rotation_phase": true, "rotation_epoch": true, "confirmed_members": true, "activated_members": true}
	for key := range fields {
		if !allowed[key] {
			t.Errorf("public information exposed unexpected field %q", key)
		}
	}
}
