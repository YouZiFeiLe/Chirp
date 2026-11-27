package main

import (
	"context"
	"errors"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/authorization"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

type friend struct {
	ID      string   `json:"id"`
	Root    string   `json:"root"`
	Name    string   `json:"name"`
	Devices []string `json:"devices"`
}
type verified struct {
	*authorization.State
	issued int64
	full   bool
}
type authority struct {
	states         map[string]*verified
	until, updated int64
	friends        []friend
}

func verifyHistory(origin string, a authorization.Account, issued int64, previous checkpoint) (*verified, error) {
	// A peer's private social records are redacted. The outer device signature
	// still authenticates the social digest and the complete prefix.
	if _, ok := identity.Bytes(a.Root, 32); !ok || len(a.Records) > authorization.MaxRecords || int64(len(a.Records)) < previous.Version || issued <= 0 {
		return nil, invalid
	}
	st := &authorization.State{Root: a.Root, Devices: map[string]identity.Device{}, Revoked: map[string]bool{}}
	v := &verified{st, issued, true}
	var last int64
	for _, record := range a.Records {
		ev := record.Event
		at := time.Unix(record.AcceptedAt, 0)
		if ev.Origin != origin || record.AcceptedAt < last || record.AcceptedAt > issued {
			return nil, invalid
		}
		if ev.Operation == "social" && ev.Social == nil {
			_, ok := identity.Bytes(ev.SocialHash, 32)
			if !ok || ev.TargetKey != "" || ev.Version != st.Version+1 || ev.Version > authorization.MaxOrdinaryRecords || ev.PreviousHash != st.Head || !st.Active(ev.Signer, at) || !identity.Verify(ev.Signer.LeafKey(), ev.Signature, ev.Message()) {
				return nil, invalid
			}
			st.Version, st.Head = ev.Version, ev.Hash()
			v.full = false
		} else if err := st.Apply(ev, at); err != nil {
			return nil, err
		}
		if st.Version == previous.Version && st.Head != previous.Hash {
			return nil, invalid
		}
		last = record.AcceptedAt
	}
	return v, nil
}
func (e *engine) refreshAuth(ctx context.Context, roots []string, enroll bool) error {
	err := e.refreshAuthSnapshot(ctx, roots, enroll)
	if r := e.room; r != nil && r.media != nil {
		switch {
		case signedOutError(err):
			r.media.pause()
			r.media.forceMute()
		case ticks() >= e.auth.until:
			r.media.pause()
		case slices.ContainsFunc(r.snap.Members, func(p group.Member) bool { return !e.trusted(p) }):
			r.media.pause()
			r.media.forceMute()
		}
	}
	return err
}
func (e *engine) refreshAuthSnapshot(ctx context.Context, roots []string, enroll bool) error {
	e.auth.until = 0
	if e.account == nil || e.session == nil || e.account.Active == nil {
		return errSessionExpired
	}
	d := e.account.Active
	if p := e.account.Pending; p != nil {
		roots = append(slices.Clone(roots), p.FriendKey)
	}
	roots = append(slices.Clone(roots), d.Device.AccountKey)
	slices.Sort(roots)
	roots = slices.Compact(roots)
	start := ticks()
	states := map[string]*verified{}
	if e.account.Heads == nil {
		e.account.Heads = map[string]checkpoint{}
	}
	for batch := range slices.Chunk(roots, 2) {
		req := authorization.SnapshotRequest{Origin: e.conn.origin, Nonce: b64(random(32)), Roots: batch, Device: &d.Device, SignedAt: time.Now().Unix()}
		req.Signature = d.sign(req.Message())
		var envelope authorization.Envelope
		status, err := request(ctx, "authorizationSnapshot", "POST", e.conn.authorizationEndpoint("snapshot"), req, "", nil, &envelope, 9<<20)
		if err != nil {
			return err
		}
		if status != 200 {
			return invalid
		}
		snap, err := verifiedSnapshot(envelope, e.trustKey, req)
		if err != nil {
			return err
		}
		for _, a := range snap.Accounts {
			if !slices.Contains(batch, a.Root) || states[a.Root] != nil {
				return invalid
			}
			head, err := e.vault.knownHead(req.Origin, a.Root)
			if err != nil {
				return err
			}
			v, err := verifyHistory(req.Origin, a, snap.IssuedAt, head)
			if err != nil {
				return err
			}
			states[a.Root] = v
		}
	}
	own := states[d.Device.AccountKey]
	if own == nil || ticks() >= start+60000 {
		return invalid
	}
	if !own.Active(d.Device, time.Now()) || !own.Active(d.Device, time.Unix(own.issued, 0)) {
		if key := d.Device.LeafKey(); own.Revoked[key] && !e.account.Denied[key] {
			if e.account.Denied == nil {
				e.account.Denied = map[string]bool{}
			}
			e.account.Denied[key] = true
			_ = e.vault.save()
		}
		if !enroll || own.Revoked[d.Device.LeafKey()] || e.account.Denied[d.Device.LeafKey()] || own.Devices[d.Device.LeafKey()].LeafKey() != "" {
			return errDeviceRevoked
		}
		if err := e.appendEvent(ctx, own, "enroll", "", nil); err != nil {
			return err
		}
		return e.refreshAuthSnapshot(ctx, roots, false)
	}
	if !own.full {
		return invalid
	}
	var blocked []store.BlacklistEntry
	changed := false
	if err := e.api(ctx, "GET", "v1/identity/blacklist", nil, &blocked); err == nil {
		changed = e.vault.acceptBlacklist(e.conn.origin, blocked)
	} else if signedOutError(err) {
		return err
	}
	for root, v := range states {
		next := checkpoint{v.Version, v.Head}
		if next != e.account.Heads[root] {
			e.account.Heads[root] = next
			changed = true
		}
	}
	for _, social := range own.Social {
		if social.AccountID != e.session.Member.ID {
			return invalid
		}
	}
	if p := e.account.Pending; p != nil {
		if slices.ContainsFunc(own.Social, func(ev identity.SocialEvent) bool { return ev.Hash() == p.Hash() }) {
			e.account.Pending = nil
			changed = true
		}
	}
	head := checkpoint{Version: int64(len(own.Social))}
	if head.Version != 0 {
		head.Hash = own.Social[head.Version-1].Hash()
	}
	friends := friendsOf(own.Social, e.account.Pending)
	if head != e.account.SocialHead || !reflect.DeepEqual(friends, e.account.Friends) {
		e.account.SocialHead, e.account.Friends = head, friends
		changed = true
	}
	confirmedRevoke := e.account.PendingRevocation
	if confirmedRevoke != "" && own.Revoked[confirmedRevoke] {
		e.account.PendingRevocation = ""
		changed = true
	} else {
		confirmedRevoke = ""
	}
	if changed || e.vault.dirty {
		if err := e.vault.save(); err != nil {
			return err
		}
	}
	e.auth = authority{states: states, until: start + 60000, updated: start, friends: friends}
	if !e.authorized(e.session.Member.ID, d.Device) {
		e.auth.until = 0
		return errDeviceRevoked
	}
	if confirmedRevoke != "" {
		if key, err := routeKey(confirmedRevoke); err == nil {
			_ = e.api(ctx, "DELETE", "v1/identity/devices/"+key, nil, nil)
		}
	}
	if target := e.account.PendingRevocation; target != "" {
		if err := e.appendEvent(ctx, own, "revoke", target, nil); err != nil {
			return err
		}
		return e.refreshAuthSnapshot(ctx, roots, false)
	}
	if p := e.account.Pending; p != nil {
		p.Version, p.PreviousHash, p.Signer = head.Version+1, head.Hash, d.Device
		p.Signature = d.sign(p.Message())
		if err := e.vault.save(); err != nil {
			return err
		}
		if err := e.appendEvent(ctx, own, "social", "", p); err != nil {
			return err
		}
		return e.refreshAuthSnapshot(ctx, roots, false)
	}
	return nil
}
func friendsOf(events []identity.SocialEvent, pending *identity.SocialEvent) []friend {
	result := []friend{}
	if pending != nil && (pending.Operation == "untrust" || pending.Operation == "remove_friend") {
		events = append(slices.Clone(events), *pending)
	}
	return applySocial(result, events)
}
func applySocial(result []friend, events []identity.SocialEvent) []friend {
	for _, v := range events {
		i := slices.IndexFunc(result, func(f friend) bool { return f.ID == v.FriendID && f.Root == v.FriendKey })
		switch v.Operation {
		case "remove_friend":
			if i >= 0 {
				result = slices.Delete(result, i, i+1)
			}
		case "untrust":
			if i >= 0 {
				result[i].Devices = slices.DeleteFunc(result[i].Devices, func(s string) bool { return s == v.DeviceKey })
			}
		case "friend", "trust":
			if i < 0 {
				result = append(result, friend{v.FriendID, v.FriendKey, v.Name, []string{}})
				i = len(result) - 1
			} else if v.Operation == "friend" {
				result[i].Name = v.Name
			}
			if v.Operation == "trust" && !slices.Contains(result[i].Devices, v.DeviceKey) {
				result[i].Devices = append(result[i].Devices, v.DeviceKey)
			}
		}
	}
	return result
}
func (e *engine) appendEvent(ctx context.Context, v *verified, op, target string, social *identity.SocialEvent) error {
	d := e.account.Active
	ev := authorization.Event{Origin: e.conn.origin, Version: v.Version + 1, PreviousHash: v.Head, Operation: op, Signer: d.Device, TargetKey: target, Social: social}
	ev.Signature = d.sign(ev.Message())
	status, err := request(ctx, "authorizationAppend", "POST", e.conn.authorizationEndpoint("append"), ev, "", nil, nil, 65536)
	if err == nil && status != 204 {
		return invalid
	}
	return err
}
func (e *engine) authorized(id string, d identity.Device) bool {
	a := e.auth.states[d.AccountKey]
	if a == nil || ticks() >= e.auth.until || !a.Active(d, time.Unix(max(a.issued, time.Now().Unix()), 0)) {
		return false
	}
	return !e.blocked(id, d.AccountKey, d.LeafKey())
}
func (e *engine) blocked(id, root, key string) bool {
	state := e.auth.states[root]
	return e.account.Denied[key] || state != nil && state.Revoked[key] || e.vault.blacklisted(e.conn.origin, id, root, key)
}

func (v *vault) blacklisted(origin, id, root, key string) bool {
	return slices.ContainsFunc(v.Blacklists[origin], func(b store.BlacklistEntry) bool {
		return b.Kind == "account" && (b.Subject == id || b.AccountKey == root) || b.Kind == "device" && b.Subject == key
	})
}
func (e *engine) trusted(p group.Member) bool {
	if p.Binding == nil {
		return false
	}
	id, _, _ := strings.Cut(p.Identity, ".")
	d := p.Binding.Device
	if !e.authorized(id, d) {
		return false
	}
	if p.Identity == e.room.join.Identity {
		return true
	}
	return slices.ContainsFunc(e.auth.friends, func(f friend) bool {
		return f.ID == id && f.Root == d.AccountKey && slices.Contains(f.Devices, d.LeafKey())
	})
}
func (e *engine) authHash(roots []string) string {
	slices.Sort(roots)
	var fields []string
	for _, root := range slices.Compact(roots) {
		v := e.auth.states[root]
		fields = append(fields, root, strconv.FormatInt(v.Version, 10), v.Head)
	}
	return identity.Hash(identity.Message("Chirp approved authorization v5", fields...))
}
func (e *engine) social(ctx context.Context, op, id, root, key, name string) error {
	if e.account.Pending != nil {
		return errors.New("SOCIAL_SYNC_PENDING")
	}
	if (op == "friend" || op == "trust") && e.blocked(id, root, key) {
		return errors.New("PEER_IDENTITY_BLOCKED")
	}
	head := e.account.SocialHead
	ev := identity.SocialEvent{Origin: e.conn.origin, AccountID: e.session.Member.ID, Version: head.Version + 1, PreviousHash: head.Hash, Operation: op, FriendID: id, FriendKey: root, DeviceKey: key, Name: name, Signer: e.session.Device}
	ev.Signature = e.account.Active.sign(ev.Message())
	if err := ev.Validate(time.Now()); err != nil {
		return err
	}
	e.account.Pending = &ev
	removal := op == "untrust" || op == "remove_friend"
	if removal {
		e.account.Friends = applySocial(e.account.Friends, []identity.SocialEvent{ev})
		e.auth.friends = e.account.Friends
	}
	if e.room != nil {
		e.room.media.pause()
		if removal && slices.ContainsFunc(e.room.snap.Members, func(p group.Member) bool {
			return memberID(p.Identity) == id && p.Binding != nil && p.Binding.Device.AccountKey == root && (key == "" || key == p.Binding.Device.LeafKey())
		}) {
			e.room.media.forceMute()
		}
		e.room.broadcastAt = 0
	}
	if err := e.vault.save(); err != nil {
		return err
	}
	err := e.refreshAuth(ctx, e.roomRoots(), true)
	if removal && temporarilyUnavailable(err) {
		return nil
	}
	return err
}
func (e *engine) refreshAmbient(ctx context.Context) error {
	if e.session == nil {
		return nil
	}
	return e.refreshAuth(ctx, e.roomRoots(), true)
}
func (e *engine) registeredDevices(ctx context.Context) (obj, error) {
	err := e.refreshAuth(ctx, e.roomRoots(), true)
	own := e.auth.states[e.session.Device.AccountKey]
	if err != nil && (own == nil || !temporarilyUnavailable(err)) {
		return nil, err
	}
	var labels []store.RegisteredDevice
	_ = e.api(ctx, "GET", "v1/identity/devices", nil, &labels)
	devices := make([]store.RegisteredDevice, 0, len(own.Devices))
	for key, d := range own.Devices {
		record := store.RegisteredDevice{DeviceKey: key, AccountID: e.session.Member.ID, AccountKey: own.Root, Device: d, Revoked: own.Revoked[key]}
		for _, label := range labels {
			if label.Device.Hash() == d.Hash() && label.AccountID == record.AccountID {
				record.Name, record.Platform, record.CreatedAt, record.LastLoginAt = label.Name, label.Platform, label.CreatedAt, label.LastLoginAt
				break
			}
		}
		devices = append(devices, record)
	}
	slices.SortFunc(devices, func(a, b store.RegisteredDevice) int { return strings.Compare(a.DeviceKey, b.DeviceKey) })
	return obj{"current": e.session.Device.LeafKey(), "root": own.Root, "canEnroll": e.canEnroll(), "devices": devices, "pendingRevocation": e.account.PendingRevocation}, nil
}
