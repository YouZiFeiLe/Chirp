package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

// Start at a verified two-member snapshot with a live lease and both media
// slots installed, as during an ordinary same-roster key rotation.
func readyRosterRoom(t *testing.T) (*activeRoom, sendPermit) {
	t.Helper()
	requireNative(t)
	policy := identity.MutualRoom("https://room.test", "room")
	s := group.Snapshot{RoomID: policy.RoomID, Protocol: identity.Protocol, ServerID: "server", SessionID: "session", Generation: 3, Revision: 8, Phase: "ready", Leader: "alice", Confirmation: identity.Hash([]byte("confirmed round")), IdentityPolicy: &policy}
	bindings := []identity.EntryBinding{}
	for _, id := range []string{"alice", "bob"} {
		d := testidentity.New(id)
		b := d.Binding(policy, id, d.Device.LeafKey())
		bindings = append(bindings, b)
		s.Members = append(s.Members, group.Member{Identity: id, PublicKey: b.MLSKey, Binding: &b})
	}
	roster := identity.RosterHash(bindings)
	for i := range s.Members {
		p := &s.Members[i]
		proof := identity.ReadyProof{GroupID: groupID(s), PolicyHash: policy.Hash(), RosterHash: roster, Confirmation: s.Confirmation}
		proof.Signature = identity.Sign(testidentity.New(p.Identity).Key, proof.Message())
		p.Ready = &proof
	}
	n, err := newNative(s.Leader)
	ok(t, err)
	t.Cleanup(n.close)
	m := &mediaSession{entry: s.Leader, loginExpires: time.Now().Unix() + 60}
	t.Cleanup(m.close)
	r := &activeRoom{n: n, media: m, join: admission{Room: s.RoomID, Identity: s.Leader}, policy: policy, binding: bindings[0], snap: group.Snapshot{ServerID: s.ServerID}}
	ok(t, r.applySnapshot(s, ticks()))
	id := groupID(s)
	key, err := newSenderKey(random(32))
	ok(t, err)
	keys := map[string]*senderKey{"alice": key, "bob": key}
	if !m.stage(id, roster, 0, keys) || !m.stage(id+"/key/1", roster, 1, keys) {
		t.Fatal("could not install fixture keys")
	}
	q := r.action("lease")
	q.Revision, q.Confirmation = s.Revision, s.Confirmation
	r.pulses.setLease(leasePlan{request: q, group: id, roster: roster, version: m.version, hard: ticks() + 3000})
	r.current, r.candidate = round{group: id, activated: true}, round{group: id + "/key/1", staged: true}
	r.installed, r.previouslyReady = id, true
	r.watchLive, r.watchSeen, r.watchRev = true, ticks(), s.Revision
	m.mu.Lock()
	defer m.mu.Unlock()
	m.muted = false
	if m.grantLocked(id, "different roster", 0, ticks()+3000) || !m.grantLocked(id, roster, 0, ticks()+3000) {
		t.Fatal("lease must match the installed key's roster")
	}
	return r, m.sendPermitLocked()
}

func assertRosterRetired(t *testing.T, r *activeRoom, permit sendPermit) {
	t.Helper()
	r.pulses.mu.Lock()
	defer r.pulses.mu.Unlock()
	m := r.media
	m.mu.Lock()
	defer m.mu.Unlock()
	if r.pulses.lease != nil || m.until != 0 || m.group != "" || !m.muted || m.members != nil || permit.validLocked(m) {
		t.Fatal("obsolete lease, microphone or send permit survived the roster change")
	}
	if m.slots[0].keys != nil || m.slots[1].keys != nil || r.current != (round{}) || r.candidate != (round{}) || r.installed != "" || r.previouslyReady {
		t.Fatal("obsolete media keys or MLS round state survived the roster change")
	}
}

func TestSnapshotRetiresContradictoryRosters(t *testing.T) {
	for name, change := range map[string]func(*group.Snapshot){
		"same revision removes member":    func(s *group.Snapshot) { s.Phase = "collecting"; s.Members = s.Members[:1] },
		"later revision removes member":   func(s *group.Snapshot) { s.Revision++; s.Phase = "collecting"; s.Members = s.Members[:1] },
		"earlier revision changes roster": func(s *group.Snapshot) { s.Revision--; s.Phase = "collecting"; s.Members = s.Members[:1] },
		"same identity changes MLS binding": func(s *group.Snapshot) {
			d := testidentity.New("bob")
			b := d.Binding(*s.IdentityPolicy, "bob", testidentity.New("new MLS key").Device.LeafKey())
			s.Phase = "collecting"
			s.Members[1] = group.Member{Identity: b.Identity, PublicKey: b.MLSKey, Binding: &b}
		},
		"ready regresses":     func(s *group.Snapshot) { s.Revision++; s.Phase = "confirming" },
		"ready proof missing": func(s *group.Snapshot) { s.Members[1].Ready = nil },
		"rotation loses member": func(s *group.Snapshot) {
			s.Rotation = &group.RotationSnapshot{Epoch: 1, Phase: "collecting", Members: s.Members[:1]}
		},
		"rotation duplicates member": func(s *group.Snapshot) {
			s.Rotation = &group.RotationSnapshot{Epoch: 1, Phase: "collecting", Members: []group.Member{s.Members[0], s.Members[0]}}
		},
	} {
		t.Run(name, func(t *testing.T) {
			r, permit := readyRosterRoom(t)
			s := r.snap
			s.Members = slices.Clone(s.Members)
			change(&s)
			if err := r.applySnapshot(s, ticks()); err == nil || !terminalRoomError(err) {
				t.Fatalf("contradictory snapshot returned %v", err)
			}
			assertRosterRetired(t, r, permit)
			if len(r.snap.Members) != 2 || r.snap.Phase != "ready" || r.snap.Rotation != nil || r.snap.Revision != 8 {
				t.Fatal("unverified snapshot was published")
			}
		})
	}
}

func TestSnapshotKeepsLeaseOnDisplayChanges(t *testing.T) {
	r, permit := readyRosterRoom(t)
	s := r.snap
	s.Members = slices.Clone(s.Members)
	s.Members[0].Name = "renamed"
	slices.Reverse(s.Members)
	ok(t, r.applySnapshot(s, ticks()))
	r.media.mu.Lock()
	defer r.media.mu.Unlock()
	if r.snap.Members[1].Name != "renamed" || r.pulses.lease == nil || !permit.validLocked(r.media) {
		t.Fatal("cosmetic roster change interrupted a verified lease")
	}
}

func TestMemberLeaveRevokesInFlightLease(t *testing.T) {
	r, permit := readyRosterRoom(t)
	pending, respond := make(chan struct{}), make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		close(pending)
		<-respond
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(pulse{Room: "room", Server: "server", Session: "session", Protocol: identity.Protocol, Generation: 3, Revision: 8, Phase: "ready", Lease: 3000})
	}))
	defer server.Close()
	r.base = server.URL
	done := make(chan struct{})
	go func() { defer close(done); r.refreshLease(t.Context(), 1000) }()
	defer func() { close(respond); <-done; assertRosterRetired(t, r, permit) }()
	select {
	case <-pending:
	case <-time.After(3 * time.Second):
		t.Fatal("lease request did not start")
	}
	s := r.snap
	s.Generation++
	s.Revision++
	s.Members = slices.Clone(s.Members[:1])
	s.Members[0].Ready = nil
	s.Confirmation, s.Phase = "", "collecting"
	ok(t, r.applySnapshot(s, ticks()))
	assertRosterRetired(t, r, permit)
	err := r.media.publish(permit, "alice", []byte("queued"), []string{"bob"}, false, func([]byte) error {
		t.Fatal("queued data reached the write boundary after retirement")
		return nil
	})
	if err != errContentPaused {
		t.Fatalf("retired send permit returned %v", err)
	}
	if len(r.snap.Members) != 1 || r.generationRoster != identity.RosterHash([]identity.EntryBinding{r.binding}) {
		t.Fatal("new generation did not pin the remaining member")
	}
}
