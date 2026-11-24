package group

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	v5 "gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

var httpV5Owner = testidentity.New("group-http-owner")
var httpV5Policy = httpV5Owner.Policy("https://fixture.test", "friends")

func testHTTPPolicy(room string) v5.RoomPolicy {
	policy := httpV5Policy
	policy.RoomID = room
	policy.Signature = v5.Sign(httpV5Owner.Key, policy.Message())
	return policy
}
func (*identityStore) LoginDevice(context.Context, string, string) (v5.Device, error) {
	return httpV5Owner.Device, nil
}
func (*identityStore) RoomPolicy(_ context.Context, room string) (v5.RoomPolicy, error) {
	return testHTTPPolicy(room), nil
}
func (*eventAuthority) LoginDevice(context.Context, string, string) (v5.Device, error) {
	return httpV5Owner.Device, nil
}
func (*eventAuthority) RoomPolicy(_ context.Context, room string) (v5.RoomPolicy, error) {
	return testHTTPPolicy(room), nil
}
func bindHTTPPeer(h *Hub, peer hubPeer) {
	policy := testHTTPPolicy(h.roomID)
	h.setIdentityPolicy(policy)
	binding := httpV5Owner.Binding(policy, peer.identity(), base64.StdEncoding.EncodeToString(peer.key))
	h.mu.Lock()
	h.members[peer.identity()].Binding = &binding
	h.mu.Unlock()
}

type identityStore struct {
	member         store.Member
	unavailable    bool
	authorityError bool
	touches        int
}

func (s *identityStore) MemberByCredential(_ context.Context, token string) (store.Member, error) {
	if token != "current-credential" {
		return store.Member{}, store.ErrNotFound
	}
	return s.member, nil
}
func (s *identityStore) AdmissionAllowed(context.Context, string, string) (bool, error) {
	if s.authorityError {
		return false, errors.New("authority offline")
	}
	return !s.unavailable, nil
}
func (s *identityStore) ActiveAdmissions(context.Context) (map[string]string, error) {
	if s.authorityError {
		return nil, errors.New("authority offline")
	}
	result := map[string]string{}
	if !s.unavailable {
		result[store.AdmissionIdentity(s.member, testEntryID)] = "friends"
	}
	return result, nil
}
func (s *identityStore) TouchAdmission(context.Context, string, string) error {
	s.touches++
	return nil
}
func (s *identityStore) Room(_ context.Context, id string) (store.RoomConfig, error) {
	if !store.ValidRoomID(id) || id == "unknown" {
		return store.RoomConfig{}, store.ErrNotFound
	}
	return store.RoomConfig{RoomID: id}, nil
}
func (s *identityStore) Ping(context.Context) error { return nil }

type policyCountingStore struct {
	identityStore
	reads int
}

func (s *policyCountingStore) RoomPolicy(ctx context.Context, room string) (v5.RoomPolicy, error) {
	s.reads++
	return s.identityStore.RoomPolicy(ctx, room)
}

func TestGroupUsesCurrentPolicySourceForConfigAndJoin(t *testing.T) {
	for _, tc := range []struct {
		name, origin string
		wantReads    int
	}{{"mutual", "https://fixture.test", 0}, {"owner", "", 2}} {
		t.Run(tc.name, func(t *testing.T) {
			db := &policyCountingStore{}
			db.member = store.Member{ID: "a", LoginID: "login_current", Enabled: true}
			server := New(db, DefaultPolicy(), slog.New(slog.NewTextHandler(io.Discard, nil)), tc.origin)
			request := httptest.NewRequest("GET", "/v1/group/rooms/friends/config", nil)
			request.Header.Set("Authorization", "Bearer current-credential")
			config := httptest.NewRecorder()
			server.ServeHTTP(config, request)
			var response struct {
				Policy v5.RoomPolicy `json:"identity_policy"`
			}
			if config.Code != 200 || json.Unmarshal(config.Body.Bytes(), &response) != nil {
				t.Fatal("configuration unavailable", config.Code)
			}
			key := httpV5Owner.Device.LeafKey()
			binding := httpV5Owner.Binding(response.Policy, store.AdmissionIdentity(db.member, testEntryID), key)
			join := Request{Operation: "join", RoomID: "friends", EntryID: testEntryID, Binding: &binding}
			if !server.verifyIdentity(httptest.NewRecorder(), request, server.hubs["friends"], db.member, key, join) {
				t.Fatal("valid binding rejected")
			}
			if db.reads != tc.wantReads {
				t.Errorf("room policy lookups = %d, want %d", db.reads, tc.wantReads)
			}
		})
	}
}

func TestHTTPProofAndPublicOnlyContract(t *testing.T) {
	db := &identityStore{member: store.Member{ID: "a", LoginID: "login_current", Enabled: true}}
	server := New(db, DefaultPolicy(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	server.hubs["room-2"] = NewHub("room-2", DefaultPolicy())
	key, private, _ := ed25519.GenerateKey(rand.Reader)
	binding := httpV5Owner.Binding(testHTTPPolicy("friends"), store.AdmissionIdentity(db.member, testEntryID), base64.StdEncoding.EncodeToString(key))
	body, _ := json.Marshal(Request{RoomID: store.DefaultRoomID, EntryID: testEntryID, ServerID: server.hubs[store.DefaultRoomID].ServerID(), Operation: "join", Binding: &binding})
	stamp, nonce := strconv.FormatInt(time.Now().Unix(), 10), randomID()
	signature := base64.StdEncoding.EncodeToString(ed25519.Sign(private, ProofMessage(store.AdmissionIdentity(db.member, testEntryID), store.DefaultRoomID, stamp, nonce, body)))
	request := func(token, proof string, payload []byte) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "/v1/group/rooms/friends/action", bytes.NewReader(payload))
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("X-Chirp-Time", stamp)
		r.Header.Set("X-Chirp-Nonce", nonce)
		r.Header.Set("X-Chirp-Key", base64.StdEncoding.EncodeToString(key))
		r.Header.Set("X-Chirp-Signature", proof)
		w := httptest.NewRecorder()
		server.ServeHTTP(w, r)
		return w
	}
	if w := request("old-credential", signature, body); w.Code != 401 {
		t.Fatal("old login accepted")
	}
	if w := request("current-credential", "", body); w.Code != 403 {
		t.Fatal("missing proof accepted")
	}
	tampered := bytes.ReplaceAll(body, []byte("join"), []byte("leave"))
	if w := request("current-credential", signature, tampered); w.Code != 403 {
		t.Fatal("tampered message accepted")
	}
	w := request("current-credential", signature, body)
	if w.Code != 200 || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("valid join failed: %d %s", w.Code, w.Body.String())
	}
	for _, secret := range []string{"current-credential", "private_key", "media_key", "epoch_secret"} {
		if strings.Contains(w.Body.String(), secret) {
			t.Fatal("secret in public response")
		}
	}
	touches := db.touches
	if request("current-credential", signature, body).Code != 409 {
		t.Fatal("HTTP replay accepted")
	}
	if db.touches != touches {
		t.Fatal("replay renewed an abandoned admission")
	}
	// Even a correctly signed request cannot introduce secret-bearing fields.
	body = []byte(`{"room_id":"friends","entry_id":"` + testEntryID + `","server_id":"` + server.hubs[store.DefaultRoomID].ServerID() + `","operation":"join","media_key":"forbidden"}`)
	nonce = randomID()
	signature = base64.StdEncoding.EncodeToString(ed25519.Sign(private, ProofMessage(store.AdmissionIdentity(db.member, testEntryID), store.DefaultRoomID, stamp, nonce, body)))
	if request("current-credential", signature, body).Code != 400 {
		t.Fatal("unknown secret field accepted")
	}
	for _, path := range []string{"/internal/group/end", "/internal/group/remove"} {
		r := httptest.NewRequest("POST", path, strings.NewReader(`{"room_id":"friends"}`))
		w := httptest.NewRecorder()
		server.ServeHTTP(w, r)
		if w.Code != 404 {
			t.Fatal("internal HTTP control route remains exposed")
		}
	}
	if err := server.Send(context.Background(), "remove", "", db.member.ParticipantIdentity()); err != nil || len(server.hubs[store.DefaultRoomID].Identities()) != 0 {
		t.Fatal("in-process removal failed", err)
	}
	joined := apply(t, server.hubs[store.DefaultRoomID], hubPeer{db.member, key}, Request{Operation: "join"})
	if err := server.Send(context.Background(), "end", "friends", ""); err != nil || len(server.hubs[store.DefaultRoomID].Identities()) != 0 {
		t.Fatal("in-process end failed", err)
	}
	newCall := apply(t, server.hubs[store.DefaultRoomID], hubPeer{db.member, key}, Request{Operation: "join"})
	if joined.SessionID == newCall.SessionID {
		t.Fatal("control end reused the prior cryptographic session")
	}
}

func TestAuthorityFailureReturnsOnlyPausedBoundStateAndRoomProofsCannotCross(t *testing.T) {
	db := &identityStore{member: store.Member{ID: "a", LoginID: "login_current", Enabled: true}}
	server := New(db, DefaultPolicy(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	server.hubs["room-2"] = NewHub("room-2", DefaultPolicy())
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	hub := server.hubs["friends"]
	peer := hubPeer{db.member, public}
	ready := complete(t, hub, peer)
	bindHTTPPeer(hub, peer)
	send := func(pathRoom string, req Request, signRoom string) *httptest.ResponseRecorder {
		t.Helper()
		body, _ := json.Marshal(req)
		stamp := strconv.FormatInt(time.Now().Unix(), 10)
		nonce := randomID()
		signature := ed25519.Sign(private, ProofMessage(peer.identity(), signRoom, stamp, nonce, body))
		r := httptest.NewRequest("POST", "/v1/group/rooms/"+pathRoom+"/action", bytes.NewReader(body))
		r.Header.Set("Authorization", "Bearer current-credential")
		r.Header.Set("X-Chirp-Time", stamp)
		r.Header.Set("X-Chirp-Nonce", nonce)
		r.Header.Set("X-Chirp-Key", base64.StdEncoding.EncodeToString(public))
		r.Header.Set("X-Chirp-Signature", base64.StdEncoding.EncodeToString(signature))
		w := httptest.NewRecorder()
		server.ServeHTTP(w, r)
		return w
	}
	wrong := Request{RoomID: "room-2", EntryID: testEntryID, ServerID: server.hubs["room-2"].ServerID(), Operation: "join"}
	if w := send("room-2", wrong, "friends"); w.Code != 403 {
		t.Fatal("signature for another room accepted", w.Body.String())
	}
	db.authorityError = true
	paused := send("friends", roundRequest(ready, "snapshot"), "friends")
	var snapshot Snapshot
	if paused.Code != 200 || json.Unmarshal(paused.Body.Bytes(), &snapshot) != nil || snapshot.LeaseMS != 0 || db.touches != 0 {
		t.Fatal("authority failure renewed entry or media", paused.Body.String())
	}
	if w := send("room-2", wrong, "room-2"); w.Code != 503 || len(server.hubs["room-2"].Identities()) != 0 {
		t.Fatal("unknown admission joined while authority offline")
	}
	db.authorityError = false
	hub.Reconcile(map[string]bool{peer.identity(): true}, true)
	recovered := send("friends", roundRequest(ready, "snapshot"), "friends")
	if recovered.Code != 200 || json.Unmarshal(recovered.Body.Bytes(), &snapshot) != nil || snapshot.Generation <= ready.Generation || snapshot.LeaseMS != 0 || snapshot.Phase != "collecting" {
		t.Fatal("recovery reused a retired round", recovered.Body.String())
	}
	db.unavailable = true
	if w := send("friends", roundRequest(snapshot, "snapshot"), "friends"); w.Code != 409 || !strings.Contains(w.Body.String(), "ADMISSION_EXPIRED") {
		t.Fatal("revocation was treated as transient authority outage")
	}
}
