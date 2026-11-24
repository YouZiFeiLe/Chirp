package main

import (
	"context"
	"encoding/json"
	"slices"
	"strconv"
	"strings"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

type trustStatement struct {
	Roster  string   `json:"roster"`
	Version int64    `json:"version"`
	Keys    []string `json:"trustedKeys"`
	expires int64
}
type verification struct {
	ID, Peer, Name, Step string
	Decimals             []int
	commitment           string
	deviceHash           string
	until                int64
}
type sasResult struct {
	Message             string
	Decimals            []int
	Complete, Cancelled bool
}

func (v *verification) active() bool {
	return v != nil && (v.Step == "sent" || v.Step == "incoming" || v.Step == "accepted" || v.Step == "compare" || v.Step == "confirmed")
}

func (v *verification) occupied() bool {
	return v.active() || v != nil && v.Step == "trustPending"
}

func (e *engine) canRetryVerification(r *activeRoom) bool {
	v := r.verification
	if v == nil {
		return false
	}
	switch v.Step {
	case "mismatch", "timedOut", "peerBusy", "peerCancelled", "roomChanged", "cancelled", "failed":
	default:
		return false
	}
	p := r.peer(v.Peer)
	return p != nil && p.Identity != r.join.Identity && p.Binding != nil &&
		p.Binding.Device.Hash() == v.deviceHash && e.authorized(memberID(p.Identity), p.Binding.Device)
}
func (r *activeRoom) verificationChanged() {
	if r.verification.occupied() {
		r.endLocalVerification("roomChanged")
	}
}

func (r *activeRoom) endLocalVerification(step string) {
	v := r.verification
	if r.n != nil && v.active() {
		_ = r.n.request(obj{"operation": "security", "security": obj{"action": "sas_cancel", "id": v.ID}}, nil)
	}
	v.Step = step
}

func (r *activeRoom) peer(id string) *group.Member {
	for i := range r.snap.Members {
		if r.snap.Members[i].Identity == id {
			return &r.snap.Members[i]
		}
	}
	return nil
}
func memberID(id string) string { s, _, _ := strings.Cut(id, "."); return s }
func (r *activeRoom) acceptSignal(id string) bool {
	if _, seen := r.seenSignals[id]; seen {
		return false
	}
	if r.seenSignals == nil || len(r.seenSignals) >= 8192 {
		r.seenSignals = make(map[string]struct{})
	}
	r.seenSignals[id] = struct{}{}
	return true
}
func (e *engine) signal(ctx context.Context, r *activeRoom, p *group.Member, kind string, body any) error {
	raw, err := json.Marshal(body)
	if err != nil {
		return err
	}
	s := identity.Signal{ID: b64(random(32)), Origin: e.conn.origin, RoomID: r.join.Room, Sender: e.session.Member.ID, Recipient: memberID(p.Identity), SenderEntry: r.join.Identity, RecipientEntry: p.Identity, Kind: kind, Payload: string(raw), ExpiresAt: time.Now().Unix() + 120, Device: e.session.Device}
	s.Signature = e.account.Active.sign(s.Message())
	return e.api(ctx, "POST", "v1/identity/signals", s, nil)
}
func (e *engine) mutual(r *activeRoom) bool {
	for _, p := range r.snap.Members {
		if !e.trusted(p) {
			return false
		}
		if p.Identity == r.join.Identity {
			continue
		}
		statement := r.statements[p.Identity]
		if statement.Roster != r.roster || statement.expires <= time.Now().Unix() {
			return false
		}
		for _, other := range r.snap.Members {
			if !slices.Contains(statement.Keys, other.Binding.Device.LeafKey()) {
				return false
			}
		}
	}
	return len(r.snap.Members) > 0
}
func (e *engine) trustStatement(r *activeRoom) trustStatement {
	var keys []string
	for _, p := range r.snap.Members {
		if e.trusted(p) {
			keys = append(keys, p.Binding.Device.LeafKey())
		}
	}
	slices.Sort(keys)
	version := e.account.SocialHead.Version
	if pending := e.account.Pending; pending != nil {
		version = pending.Version
	}
	return trustStatement{Roster: r.roster, Version: version, Keys: keys}
}

func (e *engine) signals(ctx context.Context, r *activeRoom) error {
	var hashes []string
	for _, p := range r.snap.Members {
		hashes = append(hashes, p.Binding.Hash())
	}
	slices.Sort(hashes)
	digest := identity.Hash(identity.Message("Chirp mutual trust roster v5", hashes...))
	if r.roster != digest {
		r.roster = digest
		r.statements = map[string]trustStatement{}
		r.verificationChanged()
		r.broadcastAt = 0
	}
	if v := r.verification; v.active() && ticks() >= v.until {
		_ = e.verify(ctx, "timedOut", v.Peer, v.ID)
	} else if v != nil && v.Step == "trustPending" {
		if p := r.peer(v.Peer); p != nil && p.Binding.Device.Hash() == v.deviceHash && e.trusted(*p) {
			v.Step = "completed"
		}
	}
	if len(r.snap.Members) == 1 {
		return nil
	}
	if ticks()-r.broadcastAt >= 9000 || r.broadcastAt == 0 {
		outgoing := e.trustStatement(r)
		for _, p := range r.snap.Members {
			if p.Identity != r.join.Identity {
				if err := e.signal(ctx, r, &p, "trust", outgoing); err != nil {
					return err
				}
			}
		}
		r.broadcastAt = ticks()
	}
	var incoming []store.RoutedSignal
	if err := e.api(ctx, "GET", "v1/identity/signals/"+strconv.FormatInt(r.signalSeq, 10), nil, &incoming); err != nil {
		return err
	}
	for _, event := range incoming {
		if event.Sequence <= r.signalSeq {
			continue
		}
		r.signalSeq = event.Sequence
		s := event.Signal
		p := r.peer(s.SenderEntry)
		now := time.Now()
		if p == nil || s.Recipient != e.session.Member.ID || s.RecipientEntry != r.join.Identity || s.Origin != e.conn.origin || s.RoomID != r.join.Room || s.Sender != memberID(p.Identity) || s.Device.Hash() != p.Binding.Device.Hash() || !e.authorized(s.Sender, s.Device) || s.Validate(now) != nil || !r.acceptSignal(s.ID) {
			continue
		}
		if s.Kind == "trust" {
			var v trustStatement
			previous, seen := r.statements[p.Identity]
			if json.Unmarshal([]byte(s.Payload), &v) == nil && v.Roster == digest && v.Version >= previous.Version {
				v.expires = s.ExpiresAt
				r.statements[p.Identity] = v
				// The peer may have consumed our first statement before learning
				// this roster. Its signed statement establishes when it can use ours.
				if !seen && e.trusted(*p) {
					if err := e.signal(ctx, r, p, "trust", e.trustStatement(r)); err != nil {
						r.broadcastAt = 0
						return err
					}
				}
			}
			continue
		}
		var envelope struct{ Transaction, Message string }
		var packet struct {
			Kind       string
			Commitment *string
		}
		if json.Unmarshal([]byte(s.Payload), &envelope) != nil || json.Unmarshal([]byte(envelope.Message), &packet) != nil {
			continue
		}
		if _, ok := identity.Bytes(envelope.Transaction, 32); !ok {
			continue
		}
		v := r.verification
		if packet.Kind == "Request" {
			if packet.Commitment == nil {
				continue
			}
			if v != nil && v.Peer == p.Identity && v.ID == envelope.Transaction {
				continue
			}
			if v.occupied() {
				if v.Peer != p.Identity || v.Step != "sent" {
					// The reply belongs to the new invitation. Keep the current exchange intact.
					err := e.signal(ctx, r, p, "sas", obj{"transaction": envelope.Transaction, "message": `{"kind":"Busy"}`})
					if signedOutError(err) {
						return err
					}
					continue
				}
				// For crossed invitations between the same two peers, keep the lower identity's request.
				if p.Identity >= r.join.Identity {
					continue
				}
				_ = e.verify(ctx, "cancel", p.Identity, v.ID)
			}
			r.verification = &verification{ID: envelope.Transaction, Peer: p.Identity, Name: p.Name, Step: "incoming", deviceHash: p.Binding.Device.Hash(), commitment: *packet.Commitment, until: ticks() + 120000}
			continue
		}
		if !v.active() || v.ID != envelope.Transaction || v.Peer != p.Identity {
			continue
		}
		if packet.Kind == "Busy" {
			if v.Step == "sent" {
				r.endLocalVerification("peerBusy")
			}
			continue
		}
		if packet.Kind == "Cancel" {
			r.endLocalVerification("peerCancelled")
			continue
		}
		if err := e.sas(ctx, r, p, obj{"action": "sas_receive", "id": envelope.Transaction, "message": envelope.Message}); err != nil {
			_ = e.verify(ctx, "failed", p.Identity, envelope.Transaction)
			if signedOutError(err) {
				return err
			}
		}
	}
	return nil
}
func (e *engine) verify(ctx context.Context, action, peer, id string) error {
	r := e.room
	if r == nil {
		return invalid
	}
	p := r.peer(peer)
	own := r.peer(r.join.Identity)
	v := r.verification
	if action != "start" && (v == nil || v.ID != id || v.Peer != peer) {
		return invalid
	}
	if action == "dismiss" && !v.active() {
		r.verification = nil
		return nil
	}
	if action == "cancel" || action == "mismatch" || action == "timedOut" || action == "failed" {
		if !v.active() {
			return invalid
		}
		v.Step = action
		if action == "cancel" {
			v.Step = "cancelled"
		}
		var res sasResult
		if r.n != nil && r.n.request(obj{"operation": "security", "security": obj{"action": "sas_cancel", "id": v.ID}}, &res) == nil && p != nil && res.Message != "" {
			_ = e.signal(ctx, r, p, "sas", obj{"transaction": v.ID, "message": res.Message})
		}
		return nil
	}
	if p == nil || p == own || own == nil || p.Binding == nil || own.Binding == nil {
		return invalid
	}
	if action == "retry" {
		if !e.canRetryVerification(r) {
			return invalid
		}
		action = "start"
	}
	if action == "start" {
		if v.occupied() || !e.authorized(memberID(peer), p.Binding.Device) {
			return invalid
		}
		v = &verification{ID: b64(random(32)), Peer: peer, Name: p.Name, Step: "sent", deviceHash: p.Binding.Device.Hash(), until: ticks() + 120000}
		r.verification = v
	} else if v.deviceHash != p.Binding.Device.Hash() {
		return invalid
	} else if action == "retryTrust" && v.Step == "trustPending" {
		return e.saveVerifiedTrust(ctx, r, p, true)
	}
	op := obj{"id": v.ID}
	switch action {
	case "start", "accept":
		first, last := own, p
		op["action"] = "sas_start"
		if action == "accept" {
			if v.Step != "incoming" {
				return invalid
			}
			first, last = p, own
			op["action"] = "sas_accept"
			op["commitment"] = v.commitment
			v.Step = "accepted"
		}
		op["context"] = b64(identity.Message("Chirp SAS session v5", v.ID, e.conn.origin, r.join.Room, first.Identity, first.Binding.Device.AccountKey, first.Binding.Device.LeafKey(), last.Identity, last.Binding.Device.AccountKey, last.Binding.Device.LeafKey()))
	case "confirm":
		if len(v.Decimals) != 3 || v.Step != "compare" {
			return invalid
		}
		op["action"] = "sas_confirm"
		v.Step = "confirmed"
	default:
		return invalid
	}
	err := e.sas(ctx, r, p, op)
	if err != nil {
		_ = e.verify(ctx, "failed", peer, v.ID)
	}
	return err
}
func (e *engine) sas(ctx context.Context, r *activeRoom, p *group.Member, op obj) error {
	var res sasResult
	if err := r.n.request(obj{"operation": "security", "security": op}, &res); err != nil {
		return err
	}
	v := r.verification
	if res.Message != "" {
		if err := e.signal(ctx, r, p, "sas", obj{"transaction": v.ID, "message": res.Message}); err != nil {
			return err
		}
	}
	if len(res.Decimals) == 3 && v.Step != "confirmed" {
		v.Decimals = res.Decimals
		v.Step = "compare"
	}
	if res.Complete {
		return e.saveVerifiedTrust(ctx, r, p, false)
	}
	return nil
}
func (e *engine) saveVerifiedTrust(ctx context.Context, r *activeRoom, p *group.Member, retry bool) error {
	v := r.verification
	v.Step = "trustPending"
	if retry {
		if err := e.refreshAuth(ctx, e.roomRoots(), true); err != nil {
			return err
		}
	}
	if !e.trusted(*p) {
		if err := e.social(ctx, "trust", memberID(p.Identity), p.Binding.Device.AccountKey, p.Binding.Device.LeafKey(), p.Name); err != nil {
			// The exchange completed. A failed trust write has its own retry path.
			if retry || signedOutError(err) {
				return err
			}
			return nil
		}
	}
	if e.trusted(*p) {
		v.Step = "completed"
	}
	r.broadcastAt = 0
	signalWorker(r.progress)
	return nil
}
