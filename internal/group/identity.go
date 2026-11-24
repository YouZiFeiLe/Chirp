package group

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	v5 "gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

type identityAuthorityStore interface {
	LoginDevice(context.Context, string, string) (v5.Device, error)
	RoomPolicy(context.Context, string) (v5.RoomPolicy, error)
}

func (s *Server) roomPolicy(ctx context.Context, db identityAuthorityStore, roomID string) (v5.RoomPolicy, error) {
	if s.origin != "" {
		return v5.MutualRoom(s.origin, roomID), nil
	}
	return db.RoomPolicy(ctx, roomID)
}

func (h *Hub) setIdentityPolicy(policy v5.RoomPolicy) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.identityPolicy != nil && h.identityPolicy.Hash() != policy.Hash() {
		h.members = make(map[string]*participant)
		h.restartLocked(h.now(), "identity_policy_changed")
	}
	h.identityPolicy = &policy
}

func (h *Hub) validateIdentityRequest(m store.Member, device v5.Device, key string, r Request) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.identityPolicy == nil {
		return false
	}
	policy := *h.identityPolicy
	identity := store.AdmissionIdentity(m, r.EntryID)
	if r.Operation == "join" {
		return r.Binding != nil && r.Binding.Identity == identity && r.Binding.MLSKey == key && r.Binding.Device.Hash() == device.Hash() && r.Binding.Validate(policy, time.Now()) == nil
	}
	if r.ServerID != h.serverID {
		return true // Apply returns GROUP_CHANGED, including after a server restart.
	}
	p := h.members[identity]
	if p == nil || p.Binding == nil || p.Binding.Device.Hash() != device.Hash() || p.Binding.Validate(policy, time.Now()) != nil {
		return false
	}
	// A legitimate membership change can overtake a signed package in flight.
	// Let Apply reject its stale round with 409 so clients resynchronize; checking
	// that signature against the new roster would misreport an identity attack.
	if r.ServerID != h.serverID || r.SessionID != h.sessionID || r.Generation != h.generation {
		return true
	}
	if r.Operation != "package" && r.Operation != "ack" && r.Operation != "rotation_package" && r.Operation != "rotation_ack" {
		return true
	}
	bindings := make([]v5.EntryBinding, 0, len(h.members))
	for _, peer := range h.members {
		if peer.Binding == nil {
			return false
		}
		bindings = append(bindings, *peer.Binding)
	}
	roster := v5.RosterHash(bindings)
	groupID := fmt.Sprintf("%s/%s/%s/%d", h.roomID, h.serverID, h.sessionID, h.generation)
	if r.KeyEpoch > 0 {
		groupID += fmt.Sprintf("/key/%d", r.KeyEpoch)
	}
	if r.Operation == "package" || r.Operation == "rotation_package" {
		proof := r.Offer
		packet, err := base64.StdEncoding.Strict().DecodeString(r.KeyPackage)
		return err == nil && proof != nil && proof.GroupID == groupID && proof.KeyEpoch == r.KeyEpoch && proof.PolicyHash == policy.Hash() && proof.RosterHash == roster && proof.KeyPackageHash == v5.Hash(packet) && v5.Verify(key, proof.Signature, proof.Message())
	}
	proof := r.Ready
	return proof != nil && proof.GroupID == groupID && proof.KeyEpoch == r.KeyEpoch && proof.PolicyHash == policy.Hash() && proof.RosterHash == roster && proof.Confirmation == r.Confirmation && v5.Verify(key, proof.Signature, proof.Message())
}

func (s *Server) verifyIdentity(w http.ResponseWriter, r *http.Request, hub *Hub, member store.Member, key string, request Request) bool {
	db, ok := s.db.(identityAuthorityStore)
	if !ok {
		httpresponse.Error(w, 503, "V5_IDENTITY_UNAVAILABLE", "客户端身份授权不可用")
		return false
	}
	policy, err := s.roomPolicy(r.Context(), db, hub.roomID)
	if err != nil || policy.Validate(time.Now()) != nil {
		httpresponse.Error(w, 409, "ROOM_IDENTITY_REQUIRED", "请先核验房间签名授权")
		return false
	}
	device, err := db.LoginDevice(r.Context(), member.ID, member.LoginID)
	if err != nil || policy.Allows(device, time.Now()) != nil {
		httpresponse.Error(w, 403, "DEVICE_IDENTITY_REQUIRED", "本设备没有有效的房间身份授权")
		return false
	}
	hub.setIdentityPolicy(policy)
	if !hub.validateIdentityRequest(member, device, key, request) {
		httpresponse.Error(w, 403, "V5_IDENTITY_INVALID", "身份绑定或配钥证明无效")
		return false
	}
	return true
}
