package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	lk "github.com/livekit/server-sdk-go/v2"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

type admission struct {
	Room      string `json:"room_id"`
	Name      string `json:"display_name"`
	Entry     string `json:"entry_id"`
	Identity  string `json:"participant_identity"`
	Sequence  int64  `json:"join_sequence"`
	Expires   int64  `json:"admission_expires_at"`
	Token     string
	URL       string `json:"livekit_url"`
	Protocol  string `json:"key_protocol"`
	Transport string `json:"media_transport"`
	Encrypted bool   `json:"e2ee_required"`
}
type round struct {
	epoch                             uint64
	group, pkg, confirmation, welcome string
	started, born, nativeDeadline     int64
	ack, staged, activated            bool
}
type activeRoom struct {
	join                    admission
	n                       *native
	media                   *mediaSession
	listening               *bool // The playback switch reported by the local mixer for this entry.
	listeningRetryAt        time.Time
	base, public            string
	credential, attemptKey  string
	policy                  identity.RoomPolicy
	binding                 identity.EntryBinding
	snap                    group.Snapshot
	generationRoster        string // hash of signed entry bindings, fixed for this generation
	information             roomInformation
	current, candidate      round
	epoch                   uint64
	installed               string
	authorityPaused         int64
	previouslyReady         bool
	snapshotAt, broadcastAt int64
	progress                chan struct{}
	progressDue             <-chan time.Time // owned by the protocol actor
	pulses                  roomPulses
	cancelWatch             context.CancelFunc
	cancelAttachments       context.CancelFunc
	watchMu                 sync.Mutex
	watchRev                uint64
	watchRotationRev        uint64
	watchLive, watchEnded   bool
	watchSeen               int64
	watchNumber             uint64
	signalSeq               int64
	seenSignals             map[string]struct{}
	roster                  string
	statements              map[string]trustStatement
	verification            *verification
	status                  string
}

const listeningAttribute = "chirp.listening"

func (r *activeRoom) publishListening(changed bool) {
	if r.listening == nil || r.media.room.ConnectionState() != lk.ConnectionStateConnected {
		return
	}
	local := r.media.room.LocalParticipant
	value := strconv.FormatBool(*r.listening)
	if !changed && (time.Now().Before(r.listeningRetryAt) || local.Attributes()[listeningAttribute] == value) {
		return
	}
	if local.Permissions().GetCanUpdateMetadata() {
		// SetAttributes has no error result. Retry until the server echoes the desired value.
		local.SetAttributes(map[string]string{listeningAttribute: value})
		r.listeningRetryAt = time.Now().Add(3 * time.Second)
	}
}

func (r *activeRoom) peerAudio(id string) (microphone, listening any, speaking bool) {
	room := r.media.room
	self := id == r.join.Identity
	if self && r.listening != nil {
		listening = *r.listening
	}
	if room.ConnectionState() != lk.ConnectionStateConnected {
		return nil, listening, false
	}
	var participant lk.Participant = room.LocalParticipant
	if !self {
		remote := room.GetParticipantByIdentity(id)
		if remote == nil {
			return nil, nil, false
		}
		participant = remote
		if value := remote.Attributes()[listeningAttribute]; value == "true" || value == "false" {
			listening = value == "true"
		}
	}
	enabled := participant.IsMicrophoneEnabled()
	return enabled, listening, enabled && participant.IsSpeaking()
}

func (e *engine) roomRoots() []string {
	var out []string
	if e.room != nil {
		for _, p := range e.room.snap.Members {
			if p.Binding != nil {
				out = append(out, p.Binding.Device.AccountKey)
			}
		}
	}
	return out
}
func (e *engine) api(ctx context.Context, method, path string, body, out any) error {
	if e.session == nil || e.session.Expires <= time.Now().Unix() {
		return errSessionExpired
	}
	_, err := request(ctx, apiLogName(method, path), method, e.conn.api(path), body, e.session.Credential, nil, out, 2<<20)
	return err
}
func (e *engine) joinRoom(ctx context.Context, id, password string) error {
	return e.prepareRoom(ctx, ctx, id, password, "")
}
func (e *engine) prepareRoom(ctx, lifetime context.Context, id, password, attemptKey string) (resultErr error) {
	epoch := installationLog.epoch()
	installationLog.lifecycle(epoch, "authorizationStarted", "authorizing", nil, nil)
	defer func() {
		if resultErr != nil {
			event := "authorizationRejected"
			if errors.Is(resultErr, errJoinCancelled) || errors.Is(resultErr, context.Canceled) {
				event = "authorizationCancelled"
			}
			installationLog.lifecycle(epoch, event, "idle", nil, resultErr)
		}
	}()
	if ctx.Err() != nil {
		return errJoinCancelled
	}
	if !store.ValidRoomID(id) {
		return invalid
	}
	if len(password) > 512 {
		return errors.New("ROOM_PASSWORD_TOO_LONG")
	}
	if e.room != nil && e.room.join.Room == id {
		return nil
	}
	if e.session == nil || e.account == nil || e.account.Active == nil {
		return errSessionExpired
	}
	d := e.account.Active
	r := &activeRoom{attemptKey: attemptKey, credential: e.session.Credential, base: strings.TrimRight(e.conn.endpoints.GroupBaseURL, "/") + "/rooms/" + id, policy: identity.MutualRoom(e.conn.origin, id), statements: map[string]trustStatement{}, status: "connecting", progress: make(chan struct{}, 1)}
	if d.Device.Hash() != e.session.Device.Hash() || r.policy.Allows(d.Device, time.Now()) != nil {
		return identity.ErrInvalid
	}
	sequence, err := e.session.joinSequence(ctx, e.conn.api("v1/session"))
	if err != nil {
		return err
	}
	seq, err := e.joins.next(e.session.Identity, sequence)
	if err != nil {
		return err
	}
	path := "v1/rooms/" + id + "/"
	var pre struct {
		Room    string `json:"room_id"`
		Proof   string `json:"preflight_proof"`
		Seq     int64  `json:"join_sequence"`
		Expires int64  `json:"expires_at"`
	}
	if err := e.api(ctx, "POST", path+"preflight", obj{"join_sequence": seq, "password": password}, &pre); err != nil {
		return err
	}
	if pre.Room != id || pre.Seq != seq || !validAdmissionProof(pre.Proof) || pre.Expires <= time.Now().Unix() || pre.Expires > e.session.Expires {
		return invalid
	}
	var cfg struct {
		Room           string `json:"room_id"`
		Server         string `json:"server_id"`
		Protocol       string
		Policy         identity.RoomPolicy `json:"identity_policy"`
		Lease          int                 `json:"max_lease_ms"`
		Heartbeat      int                 `json:"heartbeat_ms"`
		Refresh        int                 `json:"lease_refresh_ms"`
		SmoothRotation bool                `json:"smooth_rotation"`
	}
	if _, err = request(ctx, "groupConfig", "GET", r.base+"/config", nil, r.credential, nil, &cfg, 65536); err != nil {
		return err
	}
	if cfg.Room != id || cfg.Protocol != identity.Protocol || cfg.Server == "" || cfg.Lease != 3000 || cfg.Heartbeat != 2000 || cfg.Refresh != 1000 || cfg.Policy.Hash() != r.policy.Hash() || !cfg.Policy.IsMutual() {
		return invalid
	}
	if err = e.refreshAuth(ctx, e.roomRoots(), true); err != nil {
		return err
	}
	// Once submitted, read the admission even if preparation is cancelled.
	// Its exact entry is needed to release it without touching a newer one.
	if ctx.Err() != nil {
		return errJoinCancelled
	}
	j, err := claimAdmission(ctx, lifetime, e.conn.api(path), e.session.Credential, id, seq, pre.Proof)
	if err != nil {
		return err
	}
	if j.Room != id || !store.ValidEntryID(j.Entry) || j.Identity != e.session.Identity+"."+j.Entry || j.Sequence != seq {
		return invalid
	}
	success := false
	defer func() {
		if !success {
			cleanup, cancel := context.WithTimeout(context.WithoutCancel(lifetime), 3*time.Second)
			defer cancel()
			_ = e.api(cleanup, "POST", path+"leave", obj{"entry_id": j.Entry}, nil)
		}
	}()
	u, err := url.Parse(j.URL)
	if err != nil || u.Scheme != "wss" && !(e.local && u.Scheme == "ws") {
		return invalid
	}
	test := *u
	if u.Scheme == "ws" {
		test.Scheme = "http"
	} else {
		test.Scheme = "https"
	}
	if _, err = validateURL(test.String(), e.local); err != nil || !validName(j.Name) || j.Expires <= time.Now().Unix() || j.Expires > e.session.Expires || !j.Encrypted || j.Protocol != identity.Protocol || j.Transport != "udp" || j.Token == "" {
		return invalid
	}
	if ctx.Err() != nil {
		return errJoinCancelled
	}
	e.leaveRoom(lifetime)
	r.join = j
	installationLog.lifecycle(epoch, "admissionAccepted", "connecting", nil, nil)
	if r.n, err = newNative(j.Identity); err != nil {
		return err
	}
	defer func() {
		if !success {
			r.stop()
		}
	}()
	if err = r.n.request(obj{"operation": "authorize", "policy": r.policy, "origin": e.conn.origin, "room_id": id}, nil); err != nil {
		return err
	}
	var public struct {
		Key string `json:"public_key"`
	}
	if err = r.n.request(obj{"operation": "identity"}, &public); err != nil {
		return err
	}
	r.public = public.Key
	r.binding = identity.EntryBinding{Device: d.Device, Origin: e.conn.origin, RoomID: id, TrustID: r.policy.TrustID, PolicyHash: r.policy.Hash(), Identity: j.Identity, MLSKey: r.public, Nonce: b64(random(32)), NotBefore: time.Now().Unix(), NotAfter: min(e.session.Expires, d.Device.Certificates[len(d.Device.Certificates)-1].NotAfter)}
	r.binding.Signature = d.sign(r.binding.Message())
	r.snap.ServerID = cfg.Server
	// The group considers an entry live as soon as it accepts join. Finish
	// RTC negotiation before starting that heartbeat obligation.
	installationLog.lifecycle(epoch, "mediaConnectStarted", "connecting", nil, nil)
	if r.media, err = connectMedia(ctx, lifetime, j, e.notify); err != nil {
		return err
	}
	r.media.loginExpires = e.session.Expires
	installationLog.lifecycle(epoch, "groupStarted", "securing", nil, nil)
	first := r.action("join")
	first.Binding = &r.binding
	first.SmoothRotation = cfg.SmoothRotation
	previousDeadline := ticks() + 8000
	for {
		err = e.fetchSnapshot(ctx, r, first)
		if err == nil {
			break
		}
		var conflict *apiError
		if !errors.As(err, &conflict) || conflict.status != 409 || conflict.code != "IDENTITY_KEY_CHANGED" {
			return err
		}
		if ticks() >= previousDeadline {
			return errors.New("PREVIOUS_GROUP_ACTIVE")
		}
		select {
		case <-ctx.Done():
			return errJoinCancelled
		case <-time.After(500 * time.Millisecond):
		}
	}
	if !e.joins.commit(ctx) {
		return errJoinCancelled
	}
	r.startPulses(lifetime, cfg.Heartbeat, cfg.Refresh)
	e.room = r
	e.audio.Store(r.media)
	e.beginFiles(r)
	success = true
	e.notify("joined", obj{"room": id, "identity": j.Identity, "cacheRevision": e.fileScope.Load().revision})
	signalWorker(r.progress)
	return nil
}
func (r *activeRoom) stop() {
	if r.pulses.cancel != nil {
		r.pulses.cancel()
	}
	if r.cancelAttachments != nil {
		r.cancelAttachments()
	}
	if r.cancelWatch != nil {
		r.cancelWatch()
	}
	r.media.close()
	r.pulses.stop()
	r.n.close()
}
func (e *engine) leaveRoom(ctx context.Context) {
	r := e.room
	if r == nil {
		return
	}
	e.room = nil
	e.audio.Store(nil)
	r.media.mu.Lock()
	r.media.recordLocked("leaving")
	r.media.mu.Unlock()
	r.stop()
	r.media.mu.Lock()
	r.media.recordLocked("cleanedUp")
	r.media.flushVoiceLocked()
	r.media.mu.Unlock()
	_ = e.clearFiles()
	e.notify("left", obj{"room": r.join.Room})
	_ = e.api(ctx, "POST", "v1/rooms/"+r.join.Room+"/leave", obj{"entry_id": r.join.Entry}, nil)
}
func (r *activeRoom) action(op string) group.Request {
	return group.Request{RoomID: r.join.Room, EntryID: r.join.Entry, ServerID: r.snap.ServerID, SessionID: r.snap.SessionID, Generation: r.snap.Generation, Operation: op}
}
func (r *activeRoom) sign(msg []byte) (string, error) {
	var res struct{ Signature string }
	err := r.n.request(obj{"operation": "sign", "message": b64(msg)}, &res)
	return res.Signature, err
}
func (r *activeRoom) signed(q group.Request, endpoint string) (json.RawMessage, http.Header, error) {
	body, err := json.Marshal(q)
	if err != nil {
		return nil, nil, err
	}
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	nonce := rawURL(random(24))
	hash := sha256.Sum256(body)
	msg := strings.Join([]string{"Chirp group request v5", r.join.Identity, "POST", "/v1/group/rooms/" + r.join.Room + "/" + endpoint, ts, nonce, hex.EncodeToString(hash[:])}, "\n")
	sig, err := r.sign([]byte(msg))
	return body, http.Header{"X-Chirp-Time": {ts}, "X-Chirp-Nonce": {nonce}, "X-Chirp-Key": {r.public}, "X-Chirp-Signature": {sig}}, err
}
func (r *activeRoom) post(ctx context.Context, q group.Request, out any) error {
	body, h, err := r.signed(q, "action")
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	_, err = request(ctx, groupLogName(q.Operation), "POST", r.base+"/action", body, r.credential, h, out, 256<<10)
	return err
}
func groupID(s group.Snapshot) string {
	return fmt.Sprintf("%s/%s/%s/%d", s.RoomID, s.ServerID, s.SessionID, s.Generation)
}
func (r *activeRoom) validateMembers(members []group.Member, id string, epoch uint64, phase, confirmation string) (string, error) {
	if len(members) == 0 {
		return "", invalid
	}
	ready := phase == "ready" || phase == "switching"
	if ready && confirmation == "" {
		return "", invalid
	}
	bindings := make([]identity.EntryBinding, 0, len(members))
	seen := map[string]bool{}
	own := false
	now := time.Now()
	for _, p := range members {
		b := p.Binding
		if b == nil || p.Identity != b.Identity || p.PublicKey != b.MLSKey || b.Validate(r.policy, now) != nil || seen[p.Identity] || seen["key:"+p.PublicKey] {
			return "", identity.ErrInvalid
		}
		seen[p.Identity] = true
		seen["key:"+p.PublicKey] = true
		bindings = append(bindings, *b)
		if p.Identity == r.join.Identity {
			own = b.Hash() == r.binding.Hash()
		}
	}
	if !own {
		return "", identity.ErrInvalid
	}
	digest := identity.RosterHash(bindings)
	for _, p := range members {
		if p.KeyPackage != "" && p.Offer == nil {
			return "", invalid
		}
		if o := p.Offer; o != nil {
			if o.GroupID != id || o.KeyEpoch != epoch || o.PolicyHash != r.policy.Hash() || o.RosterHash != digest || !identity.Verify(p.PublicKey, o.Signature, o.Message()) {
				return "", invalid
			}
			if p.KeyPackage != "" {
				b, err := base64.StdEncoding.Strict().DecodeString(p.KeyPackage)
				if err != nil || identity.Hash(b) != o.KeyPackageHash {
					return "", invalid
				}
			}
		}
		if ready {
			v := p.Ready
			if v == nil || v.GroupID != id || v.KeyEpoch != epoch || v.PolicyHash != r.policy.Hash() || v.RosterHash != digest || v.Confirmation != confirmation || !identity.Verify(p.PublicKey, v.Signature, v.Message()) {
				return "", invalid
			}
		}
	}
	return digest, nil
}
func (e *engine) fetchSnapshot(ctx context.Context, r *activeRoom, q group.Request) error {
	var s group.Snapshot
	started := ticks()
	if err := r.post(ctx, q, &s); err != nil {
		return err
	}
	return r.applySnapshot(s, started)
}

func (r *activeRoom) applySnapshot(s group.Snapshot, started int64) error {
	if s.Protocol != identity.Protocol || s.RoomID != r.join.Room || s.ServerID != r.snap.ServerID || s.SessionID == "" || r.snap.SessionID != "" && s.SessionID != r.snap.SessionID || s.Generation == 0 || s.Revision == 0 || s.IdentityPolicy == nil || s.IdentityPolicy.Hash() != r.policy.Hash() || !slices.ContainsFunc(s.Members, func(p group.Member) bool { return p.Identity == s.Leader }) {
		return r.rejectSnapshot(invalid)
	}
	stale := s.Revision < r.snap.Revision || s.Revision == r.snap.Revision && s.RotationRevision < r.snap.RotationRevision
	if s.Generation < r.snap.Generation && stale {
		r.pulses.changed.Store(true)
		return nil
	}
	if s.Generation < r.snap.Generation || s.Generation > r.snap.Generation && s.Revision <= r.snap.Revision {
		return r.rejectSnapshot(invalid)
	}
	phases := []string{"collecting", "welcoming", "confirming", "ready"}
	phase := slices.Index(phases, s.Phase)
	if phase < 0 {
		return r.rejectSnapshot(invalid)
	}
	id := groupID(s)
	roster, err := r.validateMembers(s.Members, id, 0, s.Phase, s.Confirmation)
	if err != nil {
		return r.rejectSnapshot(err)
	}
	if s.Generation == r.snap.Generation {
		if roster != r.generationRoster || s.Leader != r.snap.Leader {
			return r.rejectSnapshot(invalid)
		}
		sameRevisionConflict := s.Revision == r.snap.Revision && (s.Phase != r.snap.Phase || s.Suspended != r.snap.Suspended)
		rollback := phase < slices.Index(phases, r.snap.Phase) || r.snap.Confirmation != "" && s.Confirmation != r.snap.Confirmation
		if sameRevisionConflict || !stale && rollback {
			return r.rejectSnapshot(invalid)
		}
	} else {
		if err := r.retireRound(roster != r.generationRoster); err != nil {
			return err
		}
	}
	if rot := s.Rotation; rot != nil {
		if s.Phase != "ready" || rot.Epoch == 0 || rot.Phase != "switching" && !slices.Contains(phases, rot.Phase) {
			return r.rejectSnapshot(invalid)
		}
		candidate, err := r.validateMembers(rot.Members, fmt.Sprintf("%s/key/%d", id, rot.Epoch), rot.Epoch, rot.Phase, rot.Confirmation)
		if err != nil {
			return r.rejectSnapshot(err)
		}
		if candidate != roster {
			return r.rejectSnapshot(invalid)
		}
	}
	if stale {
		r.pulses.changed.Store(true)
		return nil
	}
	r.generationRoster = roster
	r.snap = s
	r.snapshotAt = started
	r.information.snapshot(s, started)
	r.pulses.setHeartbeat(r.action("heartbeat"), s.Revision)
	return nil
}
func (r *activeRoom) rejectSnapshot(reason error) error {
	return errors.Join(reason, r.retireRound(true))
}

// Close the lease worker and the final media write gate together, before
// exposing a different roster or touching the native MLS state.
func (r *activeRoom) retireRound(mute bool) error {
	m := r.media
	r.pulses.mu.Lock()
	m.mu.Lock()
	r.pulses.lease = nil
	if r.snap.Generation != 0 {
		m.blockedGroup = groupID(r.snap)
	}
	m.muted = m.muted || mute
	m.retireLocked()
	m.refresh.Store(false)
	m.mu.Unlock()
	r.pulses.mu.Unlock()

	r.current, r.candidate = round{}, round{}
	r.epoch, r.broadcastAt = 0, 0
	r.installed, r.previouslyReady = "", false
	if err := r.n.request(obj{"operation": "clear"}, nil); err != nil {
		r.n.close()
		return errors.Join(invalid, err)
	}
	if mute {
		r.verificationChanged()
		clear(r.statements)
		m.applyMicrophone()
	}
	return nil
}
func (e *engine) watch(ctx context.Context, r *activeRoom) error {
	if r.cancelWatch != nil {
		r.cancelWatch()
	}
	body, h, err := r.signed(r.action("watch"), "events")
	if err != nil {
		return err
	}
	watchCtx, cancel := context.WithCancel(ctx)
	r.cancelWatch = cancel
	req, err := http.NewRequestWithContext(watchCtx, "POST", r.base+"/events", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header = h
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Authorization", "Bearer "+e.session.Credential)
	r.watchMu.Lock()
	r.watchNumber++
	number := r.watchNumber
	r.watchEnded = false
	r.watchSeen = ticks()
	r.watchMu.Unlock()
	roomID, server := r.join.Room, r.snap.ServerID
	go func() {
		defer func() {
			r.watchMu.Lock()
			if number == r.watchNumber {
				r.watchEnded = true
				r.watchLive = false
				r.media.pause()
			}
			r.watchMu.Unlock()
		}()
		span := installationLog.begin()
		resp, err := client.Do(req)
		defer streamLog(span, "groupEventStreamEnded", watchCtx, resp, err)()
		if err != nil {
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
			return
		}
		sc := bufio.NewScanner(resp.Body)
		typ := ""
		for sc.Scan() {
			line := sc.Text()
			r.watchMu.Lock()
			if r.watchNumber != number {
				r.watchMu.Unlock()
				return
			}
			r.watchSeen = ticks()
			r.watchMu.Unlock()
			if strings.HasPrefix(line, "event:") {
				typ = strings.TrimSpace(line[6:])
				if typ == "revoked" {
					return
				}
			}
			if typ == "state" && strings.HasPrefix(line, "data:") {
				var v struct {
					Room             string `json:"room_id"`
					Server           string `json:"server_id"`
					Revision         uint64
					RotationRevision uint64 `json:"rotation_revision"`
				}
				if json.Unmarshal([]byte(line[5:]), &v) != nil || v.Room != roomID || v.Server != server || v.Revision == 0 {
					return
				}
				r.watchMu.Lock()
				if r.watchNumber != number {
					r.watchMu.Unlock()
					return
				}
				changed := !r.watchLive || v.Revision > r.watchRev || v.RotationRevision > r.watchRotationRev
				if v.Revision > r.watchRev {
					r.media.pause()
				}
				r.watchRev = max(r.watchRev, v.Revision)
				r.watchRotationRev = max(r.watchRotationRev, v.RotationRevision)
				r.watchLive = true
				r.watchMu.Unlock()
				if changed {
					signalWorker(r.progress)
				}
			}
		}
	}()
	return nil
}
func (e *engine) tickRoom(ctx context.Context) error {
	r := e.room
	r.media.mu.Lock()
	trackFailure, interrupted := r.media.subscriptionFailure, r.media.audioSuspended
	transport, transportRevision := r.media.transport, r.media.transportRevision
	r.media.mu.Unlock()
	if trackFailure != nil {
		return trackFailure
	}
	if err := r.pulses.takeFailure(); err != nil {
		return err
	}
	if transport == transportDisconnected {
		return errors.New("MEDIA_DISCONNECTED")
	}
	r.publishListening(false)
	if interrupted {
		r.status = "audioInterrupted"
		return nil
	}
	if transport == transportReconnecting {
		r.status = "reconnecting"
		return nil
	}
	if r.media.refresh.Swap(false) || transport == transportNeedsRefresh {
		oldGeneration := r.snap.Generation
		if err := e.fetchSnapshot(ctx, r, r.action("refresh")); err != nil {
			r.media.refresh.Store(true)
			return err
		}
		if r.snap.Generation == oldGeneration {
			r.media.refresh.Store(true)
			return nil
		}
		if transport == transportNeedsRefresh && !r.media.transportRestored(transportRevision) {
			return nil
		}
	}
	r.media.listen()
	r.media.updateTrackStatistics()
	if recover, err := r.media.decryptionRecovery(ticks()); err != nil {
		return err
	} else if recover {
		r.media.pause()
		return e.fetchSnapshot(ctx, r, r.action("refresh"))
	}
	r.watchMu.Lock()
	live, ended, rev, rotationRev, seen := r.watchLive, r.watchEnded, r.watchRev, r.watchRotationRev, r.watchSeen
	r.watchMu.Unlock()
	if r.cancelWatch == nil || ended {
		if err := e.watch(ctx, r); err != nil {
			return err
		}
	}
	if r.cancelWatch != nil && !ended && seen > 0 && ticks()-seen > 15000 {
		r.cancelWatch()
		r.media.pause()
		return nil
	}
	maxAge := int64(1800)
	if r.snap.Phase != "ready" || r.snap.Rotation != nil {
		maxAge = roomTickInterval.Milliseconds()
	}
	if r.pulses.changed.Swap(false) || !live || rev > r.snap.Revision || rotationRev > r.snap.RotationRevision || ticks()-r.snapshotAt >= maxAge {
		if err := e.fetchSnapshot(ctx, r, r.action("snapshot")); err != nil {
			return err
		}
	}
	if r.snap.Suspended {
		if r.authorityPaused == 0 {
			r.authorityPaused = ticks()
			r.media.invalidate()
		}
		if ticks()-r.authorityPaused >= 25000 {
			return errGroupAuthorization
		}
		r.status = "paused"
		return nil
	}
	if r.authorityPaused != 0 {
		if err := e.fetchSnapshot(ctx, r, r.action("refresh")); err != nil {
			return err
		}
		r.authorityPaused = 0
		return nil
	}
	roots := e.roomRoots()
	missing := slices.ContainsFunc(roots, func(s string) bool { return e.auth.states[s] == nil })
	if missing || ticks()-e.auth.updated >= 20000 {
		if err := e.refreshAuth(ctx, roots, true); err != nil {
			return err
		}
	}
	if err := e.signals(ctx, r); err != nil {
		return err
	}
	if !e.mutual(r) {
		r.media.pause()
		if e.identityMuteNeeded(r) {
			r.media.forceMute()
		}
		r.status = "verify"
		return nil
	}
	if !r.previouslyReady && r.current.started != 0 && ticks()-r.current.started > 25000 {
		return errGroupUpdate
	}
	if !r.current.activated {
		if err := e.advance(ctx, r, &r.current, r.snap.Members, r.snap.Phase, r.snap.Welcome, r.snap.Confirmation, 0); err != nil {
			return e.resyncRound(ctx, r, err)
		}
		if !r.current.activated {
			r.status = "securing"
			return nil
		}
	}
	if r.candidate.activated && (r.snap.Rotation == nil || r.snap.Rotation.Epoch > r.candidate.epoch) {
		r.media.retirePrevious()
		r.current = r.candidate
		r.candidate = round{}
	}
	if r.current.born != 0 && ticks()-r.current.born >= 90000 && r.candidate.started == 0 {
		r.media.pause()
		return e.fetchSnapshot(ctx, r, r.action("refresh"))
	}
	if rot := r.snap.Rotation; rot != nil {
		if rot.Epoch < r.epoch || rot.Epoch > r.epoch+1 {
			return r.rejectSnapshot(invalid)
		}
		if !r.candidate.activated && r.candidate.started != 0 && ticks()-r.candidate.started >= 15000 {
			return errGroupUpdate
		}
		if !r.candidate.activated {
			if err := e.advance(ctx, r, &r.candidate, rot.Members, rot.Phase, rot.Welcome, rot.Confirmation, rot.Epoch); err != nil {
				return e.resyncRound(ctx, r, err)
			}
		}
	}
	if r.snap.Suspended || r.snap.Phase != "ready" {
		return nil
	}
	q := r.action("lease")
	q.Revision = r.snap.Revision
	q.Confirmation = r.snap.Confirmation
	q.KeyEpoch = r.epoch
	active := r.current
	if r.candidate.activated {
		active = r.candidate
	}
	absolute := e.session.Expires
	for _, member := range r.snap.Members {
		absolute = min(absolute, member.Binding.NotAfter)
		for _, cert := range member.Binding.Device.Certificates {
			absolute = min(absolute, cert.NotAfter)
		}
		if member.Identity != r.join.Identity {
			absolute = min(absolute, r.statements[member.Identity].expires)
		}
	}
	deadline := min(e.auth.until, active.born+120000, active.nativeDeadline, ticks()+absolute*1000-time.Now().UnixMilli())
	if active.nativeDeadline <= ticks() {
		return errGroupUpdate
	}
	r.media.mu.Lock()
	version := r.media.version
	r.media.mu.Unlock()
	r.pulses.setLease(leasePlan{request: q, group: groupID(r.snap), roster: r.generationRoster, version: version, hard: deadline})
	if r.media.ready() {
		r.previouslyReady = true
		r.status = "ready"
	} else {
		r.status = "securing"
	}
	return nil
}

// A member can join or leave between our verified snapshot and a round write.
// Discard that write and let the next turn evaluate the complete new roster.
func (e *engine) resyncRound(ctx context.Context, r *activeRoom, err error) error {
	var remote *apiError
	if !errors.As(err, &remote) || remote.status != http.StatusConflict || remote.code != "GROUP_CHANGED" {
		return err
	}
	r.media.pause()
	revision, rotation := r.snap.Revision, r.snap.RotationRevision
	if err := e.fetchSnapshot(ctx, r, r.action("snapshot")); err != nil {
		return err
	}
	if r.snap.Revision == revision && r.snap.RotationRevision == rotation {
		return err
	}
	r.status = "securing"
	signalWorker(r.progress)
	return nil
}

func (e *engine) identityMuteNeeded(r *activeRoom) bool {
	now := time.Now().Unix()
	for _, p := range r.snap.Members {
		if ticks() < e.auth.until && !e.trusted(p) {
			return true
		}
		statement := r.statements[p.Identity]
		if statement.Roster != r.roster || statement.expires <= now {
			continue
		}
		for _, other := range r.snap.Members {
			if !slices.Contains(statement.Keys, other.Binding.Device.LeafKey()) {
				return true
			}
		}
	}
	return false
}

type pulse struct {
	Room                 string `json:"room_id"`
	Server               string `json:"server_id"`
	Session              string `json:"session_id"`
	Protocol, Phase      string
	Revision, Generation uint64
	RotationRevision     uint64                 `json:"rotation_revision"`
	Information          *group.RoomInformation `json:"room_information"`
	Suspended            bool
	Epoch                uint64 `json:"key_epoch"`
	Lease                int64  `json:"lease_ms"`
}

var errGroupUpdate = errors.New("GROUP_UPDATE_TIMED_OUT")
var errGroupAuthorization = errors.New("GROUP_AUTHORIZATION_LOST")

func terminalRoomError(err error) bool {
	var status *apiError
	if errors.As(err, &status) && (status.status == 401 || status.status == 403) {
		return true
	}
	return errors.Is(err, invalid) || errors.Is(err, identity.ErrInvalid) || errors.Is(err, errDecryptionRecovery) ||
		errors.Is(err, errUnencryptedMicrophone) || errors.Is(err, errSubscription) || errors.Is(err, errGroupUpdate) ||
		errors.Is(err, errGroupAuthorization) || err.Error() == "MEDIA_DISCONNECTED"
}

func (e *engine) advance(ctx context.Context, r *activeRoom, v *round, members []group.Member, phase, welcome, conf string, epoch uint64) error {
	id := groupID(r.snap)
	prefix, op := "", ""
	if epoch > 0 {
		id += fmt.Sprintf("/key/%d", epoch)
		prefix = "staged_"
		op = "rotation_"
	}
	roster, err := r.validateMembers(members, id, epoch, phase, conf)
	if err != nil {
		return r.rejectSnapshot(err)
	}
	if roster != r.generationRoster {
		return r.rejectSnapshot(invalid)
	}
	send := func(q group.Request) error { q.KeyEpoch = epoch; return e.fetchSnapshot(ctx, r, q) }
	if v.pkg == "" {
		var p struct {
			Package string `json:"key_package"`
		}
		if err = r.n.request(obj{"operation": prefix + "key_package"}, &p); err != nil {
			return err
		}
		v.group = id
		v.epoch = epoch
		v.pkg = p.Package
		v.started = ticks()
	}
	own := slices.IndexFunc(members, func(m group.Member) bool { return m.Identity == r.join.Identity })
	if phase == "collecting" && members[own].KeyPackage == "" {
		raw, err := base64.StdEncoding.DecodeString(v.pkg)
		if err != nil {
			return err
		}
		o := identity.RoundProof{GroupID: id, KeyEpoch: epoch, PolicyHash: r.policy.Hash(), RosterHash: roster, KeyPackageHash: identity.Hash(raw)}
		if o.Signature, err = r.sign(o.Message()); err != nil {
			return err
		}
		q := r.action(op + "package")
		q.Offer = &o
		q.KeyPackage = v.pkg
		return send(q)
	}
	if phase == "collecting" {
		return nil
	}
	params := obj{"operation": "approve", "group_id": id, "members": members, "authorization_hash": e.authHash(e.roomRoots())}
	if err = r.n.request(params, nil); err != nil {
		return err
	}
	delete(params, "authorization_hash")
	params["key_epoch"] = epoch
	if phase == "welcoming" && r.snap.Leader == r.join.Identity {
		if v.confirmation == "" {
			v.born = ticks()
			params["operation"] = prefix + "create"
			var out struct{ Welcome, Confirmation string }
			if err = r.n.request(params, &out); err != nil {
				return err
			}
			v.welcome = out.Welcome
			v.confirmation = out.Confirmation
		}
		q := r.action(op + "publish")
		q.Welcome = v.welcome
		q.Confirmation = v.confirmation
		return send(q)
	}
	if phase == "welcoming" {
		return nil
	}
	if v.confirmation == "" {
		v.born = ticks()
		params["operation"] = prefix + "join"
		params["welcome"] = welcome
		var out struct{ Confirmation string }
		if err = r.n.request(params, &out); err != nil {
			return err
		}
		v.confirmation = out.Confirmation
	}
	if conf == "" || conf != v.confirmation {
		return invalid
	}
	if !v.staged {
		if v.nativeDeadline, err = r.n.keyDeadline(epoch > 0); err != nil {
			return err
		}
		if err = r.media.install(r.n, id, roster, byte(epoch%2), memberIDs(members), epoch > 0); err != nil {
			return err
		}
		v.staged = true
		if epoch == 0 {
			r.installed = id
		}
	}
	if !v.ack && members[own].Ready == nil {
		p := identity.ReadyProof{GroupID: id, KeyEpoch: epoch, PolicyHash: r.policy.Hash(), RosterHash: roster, Confirmation: conf}
		if p.Signature, err = r.sign(p.Message()); err != nil {
			return err
		}
		q := r.action(op + "ack")
		q.Confirmation = conf
		q.Ready = &p
		if err = send(q); err != nil {
			return err
		}
		if r.snap.Generation == q.Generation {
			v.ack = true
		}
		return nil
	}
	if epoch == 0 && phase != "ready" || epoch != 0 && phase != "switching" {
		return nil
	}
	if epoch > 0 && r.installed != id {
		if err = r.media.beginSwitch(byte(epoch % 2)); err != nil {
			return err
		}
		if err = r.n.request(obj{"operation": "activate_staged", "group_id": id}, nil); err != nil {
			r.media.refresh.Store(true)
			return err
		}
	}
	if r.installed != id {
		r.installed = id
	}
	if epoch > 0 {
		q := r.action("rotation_activate")
		q.Confirmation = conf
		if err = send(q); err != nil {
			r.media.refresh.Store(true)
			return err
		}
		if r.snap.Generation != q.Generation {
			return nil
		}
		r.media.mu.Lock()
		r.media.switching = false
		r.media.mu.Unlock()
	}
	r.epoch = epoch
	v.activated = true
	return nil
}
func memberIDs(members []group.Member) []string {
	ids := make([]string, 0, len(members))
	for _, p := range members {
		ids = append(ids, p.Identity)
	}
	return ids
}
