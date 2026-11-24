// Package group coordinates public MLS material. It never generates or accepts
// group secrets, client private keys, or media keys.
package group

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"log/slog"
	"sort"
	"strings"
	"sync"
	"time"

	v5 "gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

const Protocol = v5.Protocol

var (
	ErrStale    = errors.New("group state changed; rejoin or synchronize")
	ErrBinding  = errors.New("client identity is already bound to another signing key")
	ErrConflict = errors.New("group operation is not valid in the current phase")
	ErrReplay   = errors.New("request was already consumed")
	ErrBudget   = errors.New("member request budget exhausted")
)

type Policy struct {
	Lease             time.Duration
	HeartbeatTimeout  time.Duration
	TransitionTimeout time.Duration
	Rotation          time.Duration
}

func DefaultPolicy() Policy {
	return Policy{Lease: 3 * time.Second, HeartbeatTimeout: 6 * time.Second, TransitionTimeout: 12 * time.Second, Rotation: 2 * time.Minute}
}

type Member struct {
	Identity   string           `json:"identity"`
	Name       string           `json:"name"`
	PublicKey  string           `json:"public_key"`
	KeyPackage string           `json:"key_package"`
	Binding    *v5.EntryBinding `json:"binding,omitempty"`
	Offer      *v5.RoundProof   `json:"offer,omitempty"`
	Ready      *v5.ReadyProof   `json:"ready,omitempty"`
}

type participant struct {
	Member
	lastSeen       time.Time
	confirmation   string
	smoothRotation bool
	keyEpoch       uint64
}

type Request struct {
	RoomID         string           `json:"room_id"`
	EntryID        string           `json:"entry_id"`
	ServerID       string           `json:"server_id"`
	SessionID      string           `json:"session_id"`
	Generation     uint64           `json:"generation"`
	Operation      string           `json:"operation"`
	KeyPackage     string           `json:"key_package,omitempty"`
	Welcome        string           `json:"welcome,omitempty"`
	Confirmation   string           `json:"confirmation,omitempty"`
	Revision       uint64           `json:"revision,omitempty"`
	SmoothRotation bool             `json:"smooth_rotation,omitempty"`
	KeyEpoch       uint64           `json:"key_epoch,omitempty"`
	Binding        *v5.EntryBinding `json:"binding,omitempty"`
	Offer          *v5.RoundProof   `json:"offer,omitempty"`
	Ready          *v5.ReadyProof   `json:"ready,omitempty"`
}

type Snapshot struct {
	RoomID           string            `json:"room_id"`
	Protocol         string            `json:"protocol"`
	ServerID         string            `json:"server_id"`
	SessionID        string            `json:"session_id"`
	Generation       uint64            `json:"generation"`
	Revision         uint64            `json:"revision"`
	Suspended        bool              `json:"suspended"`
	Phase            string            `json:"phase"`
	Leader           string            `json:"leader"`
	Members          []Member          `json:"members"`
	Welcome          string            `json:"welcome"`
	Confirmation     string            `json:"confirmation"`
	KeyEpoch         uint64            `json:"key_epoch,omitempty"`
	RotationRevision uint64            `json:"rotation_revision,omitempty"`
	Rotation         *RotationSnapshot `json:"rotation,omitempty"`
	IdentityPolicy   *v5.RoomPolicy    `json:"identity_policy,omitempty"`
	RoomInformation  *RoomInformation  `json:"room_information,omitempty"`
	// Internal barrier result only. Full snapshots never issue a media lease.
	LeaseMS int64 `json:"-"`
}

type Hub struct {
	mu               sync.Mutex
	roomID           string
	serverID         string
	sessionID        string
	generation       uint64
	phase            string
	leader           string
	members          map[string]*participant
	used             map[string]map[string]time.Time
	usedCount        int
	lastPruned       time.Time
	revision         uint64
	changed          chan struct{}
	streams          map[string]chan struct{}
	welcome          string
	confirmation     string
	started          time.Time
	readyAt          time.Time
	establishedAt    time.Time
	lastRotationAt   time.Time
	updateReason     string
	keyEpoch         uint64
	rotationRevision uint64
	rotation         *rotationRound
	policy           Policy
	identityPolicy   *v5.RoomPolicy
	now              func() time.Time
	suspended        bool
	logger           *slog.Logger
}

func randomID() string {
	var id [24]byte
	if _, err := rand.Read(id[:]); err != nil {
		panic("system random source unavailable")
	}
	return base64.RawURLEncoding.EncodeToString(id[:])
}

func NewHub(roomID string, policy Policy, loggers ...*slog.Logger) *Hub {
	h := &Hub{roomID: roomID, serverID: randomID(), members: make(map[string]*participant), used: make(map[string]map[string]time.Time), policy: policy, now: time.Now, phase: "empty", revision: 1, changed: make(chan struct{}), streams: make(map[string]chan struct{})}
	if len(loggers) > 0 {
		h.logger = loggers[0].With("room_id", roomID, "group_server_id", h.serverID)
	}
	return h
}

func (h *Hub) ServerID() string { return h.serverID }

// Apply consumes a signed request nonce even if its operation subsequently fails.
// The HTTP layer authenticates the current login and verifies proof of possession.
func (h *Hub) Apply(m store.Member, key ed25519.PublicKey, nonce string, r Request) (Snapshot, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.now()
	h.expireLocked(now)
	if r.ServerID != h.serverID || r.RoomID != h.roomID || !store.ValidEntryID(r.EntryID) {
		return Snapshot{}, ErrStale
	}
	if err := h.consumeNonceLocked(m.ID, nonce, now); err != nil {
		return Snapshot{}, err
	}
	identity := store.AdmissionIdentity(m, r.EntryID)
	public := base64.StdEncoding.EncodeToString(key)
	p := h.members[identity]
	if p != nil && p.PublicKey != public {
		return Snapshot{}, ErrBinding
	}
	if r.Operation == "join" {
		if p == nil {
			// A new login cannot retain the old login's place in the crypto group.
			for id := range h.members {
				if id != identity && memberID(id) == m.ID {
					delete(h.members, id)
				}
			}

			if h.sessionID == "" {
				h.sessionID = randomID()
			}
			p = &participant{Member: Member{Identity: identity, Name: m.DisplayName, PublicKey: public, Binding: r.Binding}, lastSeen: now, smoothRotation: r.SmoothRotation}
			h.members[identity] = p
			h.restartLocked(now, "member_joined")
		}
		p.lastSeen = now
		return h.snapshotLocked(identity, now), nil
	}
	if p == nil || r.SessionID != h.sessionID {
		return Snapshot{}, ErrStale
	}
	if r.Operation == "leave" {
		delete(h.members, identity)
		h.restartLocked(now, "member_left")
		return h.snapshotLocked(identity, now), nil
	}
	if r.Operation == "heartbeat" {
		p.lastSeen = now
	}
	if r.Operation == "snapshot" || r.Operation == "heartbeat" || r.Operation == "watch" {
		return h.snapshotLocked(identity, now), nil
	}
	if r.Generation != h.generation {
		return Snapshot{}, ErrStale
	}
	if strings.HasPrefix(r.Operation, "rotation_") {
		if err := h.applyRotationLocked(identity, r, now); err != nil {
			return Snapshot{}, err
		}
		return h.snapshotLocked(identity, now), nil
	}
	switch r.Operation {
	case "lease":
		if r.Revision != h.revision || r.Confirmation != h.confirmation {
			return Snapshot{}, ErrStale
		}
		if r.KeyEpoch != p.keyEpoch {
			return Snapshot{}, ErrStale
		}
	case "refresh":
		h.restartLocked(now, "client_refresh")
	case "package":
		if h.phase != "collecting" || !validBase64(r.KeyPackage, 32, 16384) {
			return Snapshot{}, ErrConflict
		}
		if p.KeyPackage != "" && p.KeyPackage != r.KeyPackage {
			return Snapshot{}, ErrConflict
		}
		changed := p.KeyPackage != r.KeyPackage
		p.KeyPackage = r.KeyPackage
		p.Offer = r.Offer
		complete := true
		for _, peer := range h.members {
			complete = complete && peer.KeyPackage != ""
		}
		if complete {
			h.phase = "welcoming"
			// Human identity verification may precede package collection.
			// Start the mutual room's MLS timer once every peer is ready.
			if h.identityPolicy != nil && h.identityPolicy.IsMutual() {
				h.started = now
			}
		}
		if changed {
			h.changedLocked()
		}
		if complete {
			h.logState("packages_collected")
		}
	case "publish":
		if identity != h.leader || h.phase != "welcoming" || !validBase64(r.Confirmation, 32, 32) {
			return Snapshot{}, ErrConflict
		}
		if len(h.members) > 1 && !validBase64(r.Welcome, 32, 131072) {
			return Snapshot{}, ErrConflict
		}
		if len(h.members) == 1 && r.Welcome != "" {
			return Snapshot{}, ErrConflict
		}
		h.welcome, h.confirmation = r.Welcome, r.Confirmation
		h.phase = "confirming"
		h.changedLocked()
		h.logState("welcome_published")
	case "ack":
		if (h.phase != "confirming" && h.phase != "ready") || r.Confirmation != h.confirmation {
			return Snapshot{}, ErrConflict
		}
		changed := p.confirmation != r.Confirmation
		p.confirmation = r.Confirmation
		p.Ready = r.Ready
		if changed {
			h.changedLocked()
		}
		h.maybeReadyLocked(now)
	default:
		return Snapshot{}, ErrConflict
	}
	return h.snapshotLocked(identity, now), nil
}

func memberID(identity string) string {
	for i, c := range identity {
		if c == '.' {
			return identity[:i]
		}
	}
	return ""
}

func validBase64(s string, min, max int) bool {
	if len(s) > (max+2)/3*4 {
		return false
	}
	b, err := base64.StdEncoding.Strict().DecodeString(s)
	return err == nil && len(b) >= min && len(b) <= max
}

func (h *Hub) restartLocked(now time.Time, reason string) {
	defer h.logState(reason)
	h.updateReason = publicUpdateReason(reason, h.phase == "empty")
	h.establishedAt, h.lastRotationAt = time.Time{}, time.Time{}
	h.changedLocked()
	h.rotation = nil
	h.keyEpoch = 0
	h.rotationRevision++
	h.generation++
	h.welcome, h.confirmation, h.leader = "", "", ""
	h.started, h.readyAt = now, time.Time{}
	if len(h.members) == 0 {
		h.sessionID, h.phase = "", "empty"
		return
	}
	h.phase = "collecting"
	for id, p := range h.members {
		p.keyEpoch = 0
		p.KeyPackage, p.confirmation = "", ""
		p.Offer, p.Ready = nil, nil
		if h.leader == "" || id < h.leader {
			h.leader = id
		}
	}
}

func (h *Hub) maybeReadyLocked(now time.Time) {
	for _, p := range h.members {
		if p.confirmation != h.confirmation {
			return
		}
	}
	if h.phase != "ready" {
		h.readyAt = now
		h.establishedAt = now
		h.phase = "ready"
		h.logState("members_confirmed")
	}
}

func (h *Hub) snapshotLocked(identity string, now time.Time) Snapshot {
	s := Snapshot{RoomID: h.roomID, Protocol: Protocol, ServerID: h.serverID, SessionID: h.sessionID, Generation: h.generation, Revision: h.revision, Suspended: h.suspended, Phase: h.phase, Leader: h.leader, Members: []Member{}}
	s.KeyEpoch = h.keyEpoch
	s.IdentityPolicy = h.identityPolicy
	s.RoomInformation = h.roomInformationLocked(now)
	if p := h.members[identity]; p != nil && p.smoothRotation {
		s.RotationRevision = h.rotationRevision
	}
	s.Rotation = h.rotationSnapshotLocked(identity)
	for _, p := range h.members {
		member := p.Member
		if h.phase != "collecting" && h.phase != "welcoming" {
			member.KeyPackage = ""
		}
		s.Members = append(s.Members, member)
	}
	sort.Slice(s.Members, func(i, j int) bool { return s.Members[i].Identity < s.Members[j].Identity })
	if p := h.members[identity]; p != nil && identity != h.leader && p.confirmation != h.confirmation && (h.phase == "confirming" || h.phase == "ready") {
		s.Welcome = h.welcome
	}
	s.Confirmation = h.confirmation
	if p := h.members[identity]; p != nil && h.phase == "ready" && p.confirmation == h.confirmation && !h.suspended {
		s.LeaseMS = h.policy.Lease.Milliseconds()
		if h.rotation != nil {
			remaining := h.rotation.deadline.Sub(now).Milliseconds()
			if remaining < s.LeaseMS {
				s.LeaseMS = max(0, remaining)
			}
		}
	}
	return s
}

func (h *Hub) expireLocked(now time.Time) {
	changed := false
	for id, p := range h.members {
		if now.Sub(p.lastSeen) >= h.policy.HeartbeatTimeout {
			delete(h.members, id)
			changed = true
		}
	}
	if changed {
		h.restartLocked(now, "heartbeat_timeout")
		return
	}
	if len(h.members) == 0 {
		return
	}
	if h.phase == "ready" {
		if !h.suspended && h.smoothRotationLocked(now) {
			return
		}
		if now.Sub(h.readyAt) >= h.policy.Rotation {
			h.restartLocked(now, "scheduled_rotation")
		}
		return
	}
	// Mutual-trust clients withhold packages until their users have verified
	// every device. Keep that control-only wait separate from MLS timeouts;
	// absent members still expire through the heartbeat check above.
	if h.phase == "collecting" && h.identityPolicy != nil && h.identityPolicy.IsMutual() {
		return
	}
	if now.Sub(h.started) < h.policy.TransitionTimeout {
		return
	}
	for id, p := range h.members {
		missing := (h.phase == "collecting" && p.KeyPackage == "") || (h.phase == "welcoming" && id == h.leader) || (h.phase == "confirming" && p.confirmation != h.confirmation)
		if missing {
			delete(h.members, id)
		}
	}
	h.restartLocked(now, "transition_timeout")
}

func (h *Hub) Identities() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	ids := make([]string, 0, len(h.members))
	for id := range h.members {
		ids = append(ids, id)
	}
	return ids
}

// Reconcile also suspends lease issuance when the membership authority is down.
func (h *Hub) Reconcile(allowed map[string]bool, authorityAvailable bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	// Authority recovery must never renew a round whose native media keys
	// may already have been retired by paused clients.
	changed := h.suspended && authorityAvailable && len(h.members) > 0
	if h.suspended != !authorityAvailable {
		h.suspended = !authorityAvailable
		h.changedLocked()
		h.logState("authority_changed")
	}
	for id, ok := range allowed {
		if !ok {
			if _, exists := h.members[id]; exists {
				delete(h.members, id)
				changed = true
			}
		}
	}
	if changed {
		h.restartLocked(h.now(), "admissions_reconciled")
	}
	h.expireLocked(h.now())
}

func (h *Hub) End() {
	h.mu.Lock()
	defer h.mu.Unlock()
	clear(h.members)
	h.restartLocked(h.now(), "room_ended")
}

func (h *Hub) Remove(identity string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.members[identity]; ok {
		delete(h.members, identity)
		h.restartLocked(h.now(), "admission_removed")
	}
}

// Login revocation is deliberately separate from removing one room entry.
func (h *Hub) RemoveLogin(identity string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	changed := false
	for id := range h.members {
		if id == identity || strings.HasPrefix(id, identity+".") {
			delete(h.members, id)
			changed = true
		}
	}
	if changed {
		h.restartLocked(h.now(), "login_removed")
	}
}

// A previously bound peer may receive only a paused public snapshot while the
// authority is unavailable. Recovery always rebuilds the round in Reconcile.
func (h *Hub) suspendSnapshot(identity string) (Snapshot, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if !h.suspended {
		h.suspended = true
		h.changedLocked()
		h.logState("authority_unavailable")
	}
	if h.members[identity] == nil {
		return Snapshot{}, false
	}
	return h.snapshotLocked(identity, h.now()), true
}

func (h *Hub) changedLocked() {
	h.revision++
	close(h.changed)
	h.changed = make(chan struct{})
}

// Only phase metadata is logged; MLS packages, confirmations and keys stay out
// of operational logs. All callers hold mu.
func (h *Hub) logState(reason string) {
	if h.logger == nil {
		return
	}
	attrs := []any{"event", "group.state_changed", "reason", reason, "phase", h.phase, "generation", h.generation, "revision", h.revision, "participants", len(h.members), "suspended", h.suspended}
	attrs = append(attrs, "key_epoch", h.keyEpoch, "rotation_revision", h.rotationRevision)
	if h.rotation != nil {
		attrs = append(attrs, "rotation_epoch", h.rotation.epoch, "rotation_phase", h.rotation.phase)
	}
	if reason == "heartbeat_timeout" || reason == "transition_timeout" || h.suspended {
		h.logger.Warn("Group coordination changed", attrs...)
	} else {
		h.logger.Info("Group coordination changed", attrs...)
	}
}

// A stable member budget spans logins/entries. One member cannot occupy the
// room's complete replay ledger by flooding requests or repeatedly rejoining.
func (h *Hub) consumeNonceLocked(member, nonce string, now time.Time) error {
	if h.lastPruned.IsZero() || now.Sub(h.lastPruned) >= time.Second || h.usedCount >= 16384 {
		for id, values := range h.used {
			for n, deadline := range values {
				if !now.Before(deadline) {
					delete(values, n)
					h.usedCount--
				}
			}
			if len(values) == 0 {
				delete(h.used, id)
			}
		}
		h.lastPruned = now
	}
	values := h.used[member]
	if _, exists := values[nonce]; exists {
		return ErrReplay
	}
	if len(values) >= 512 || h.usedCount >= 16384 {
		return ErrBudget
	}
	if values == nil {
		values = make(map[string]time.Time)
		h.used[member] = values
	}
	values[nonce] = now.Add(2 * time.Minute)
	h.usedCount++
	return nil
}

// Watchers retain one wake-up channel, never a queue of snapshots. Replacing
// a stream closes its predecessor without extending the heartbeat or lease.
func (h *Hub) watch(identity, publicKey, session string) (Snapshot, <-chan struct{}, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.expireLocked(h.now())
	p := h.members[identity]
	if p == nil || p.PublicKey != publicKey || session != h.sessionID {
		return Snapshot{}, nil, false
	}
	return h.snapshotLocked(identity, h.now()), h.changed, true
}

func (h *Hub) registerStream(identity string) (<-chan struct{}, func()) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if previous := h.streams[identity]; previous != nil {
		close(previous)
	}
	stop := make(chan struct{})
	h.streams[identity] = stop
	return stop, func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		if h.streams[identity] == stop {
			delete(h.streams, identity)
		}
	}
}
