package authorization

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

func TestSignedSnapshotsBindChallengeOriginCompleteHistoryAndPersist(t *testing.T) {
	t.Parallel()
	key := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{9}, 32)) // Public test fixture only.
	path := filepath.Join(t.TempDir(), "authorization.db")
	s, err := Open(path, testOrigin, key)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	call := func(path string, body any, status int) []byte {
		t.Helper()
		data, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, httptest.NewRequest(http.MethodPost, path, bytes.NewReader(data)))
		if w.Code != status {
			t.Fatalf("%s: status %d, want %d", path, w.Code, status)
		}
		return w.Body.Bytes()
	}
	owner := testidentity.New("authority-http-owner")
	state := emptyState(owner.Device.AccountKey)
	event := signedEvent(state, owner, "enroll", "", nil)
	call("/v5/append", event, 204)
	call("/v5/append", event, 204)
	nonce := identity.Hash([]byte("request one"))
	data := call("/v5/snapshot", SnapshotRequest{Origin: testOrigin, Nonce: nonce, Roots: []string{owner.Device.AccountKey}}, 200)
	var envelope Envelope
	if json.Unmarshal(data, &envelope) != nil {
		t.Fatal("invalid response")
	}
	payload, err := base64.StdEncoding.DecodeString(envelope.Payload)
	if err != nil {
		t.Fatal(err)
	}
	public := base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))
	if !identity.Verify(public, envelope.Signature, SnapshotMessage(testOrigin, nonce, payload)) {
		t.Fatal("signature rejected")
	}
	for _, tc := range []struct{ name, origin, nonce string }{
		{"wrong challenge", testOrigin, identity.Hash([]byte("request two"))},
		{"wrong origin", "https://other.test:443", nonce},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if identity.Verify(public, envelope.Signature, SnapshotMessage(tc.origin, tc.nonce, payload)) {
				t.Fatal("replay accepted")
			}
		})
	}
	var snapshot Snapshot
	if json.Unmarshal(payload, &snapshot) != nil || len(snapshot.Accounts) != 1 || len(snapshot.Accounts[0].Records) != 1 {
		t.Fatal("incomplete or duplicate history")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(path, testOrigin, key)
	if err != nil {
		t.Fatal(err)
	}
	stored, err := s.account(t.Context(), owner.Device.AccountKey)
	if err != nil || len(stored.Records) != 1 || stored.Records[0].Event.Hash() != event.Hash() {
		t.Fatal("committed history was not durable")
	}
	call("/v5/snapshot", SnapshotRequest{Origin: testOrigin, Nonce: nonce, Roots: []string{owner.Device.AccountKey, owner.Device.AccountKey}}, 400)
	event.Origin = "https://other.test:443"
	call("/v5/append", event, 403)
}

func TestPrivateSocialBodiesRequireActiveOwnerProof(t *testing.T) {
	t.Parallel()
	key := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{11}, 32))
	s, err := Open(filepath.Join(t.TempDir(), "db"), testOrigin, key)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	owner := testidentity.New("private-history")
	if appendStatus(t, s, signedEvent(emptyState(owner.Device.AccountKey), owner, "enroll", "", nil)) != 204 {
		t.Fatal("enroll")
	}
	account, _ := s.account(t.Context(), owner.Device.AccountKey)
	state, _ := Replay(testOrigin, account)
	social := identity.SocialEvent{Origin: testOrigin, AccountID: "private-owner", Version: 1, Operation: "friend", FriendID: "private-friend", FriendKey: owner.Device.AccountKey, Name: "Private contact name", Signer: owner.Device}
	social.Signature = identity.Sign(owner.Key, social.Message())
	event := signedEvent(state, owner, "social", "", &social)
	if appendStatus(t, s, event) != 204 {
		t.Fatal("social")
	}
	snapshot := func(request SnapshotRequest, status int) Snapshot {
		t.Helper()
		body, _ := json.Marshal(request)
		response := httptest.NewRecorder()
		s.Handler().ServeHTTP(response, httptest.NewRequest("POST", "/v5/snapshot", bytes.NewReader(body)))
		if response.Code != status {
			t.Fatalf("snapshot: %d want %d", response.Code, status)
		}
		if status != 200 {
			return Snapshot{}
		}
		var envelope Envelope
		if err := json.Unmarshal(response.Body.Bytes(), &envelope); err != nil {
			t.Fatal(err)
		}
		payload, _ := base64.StdEncoding.DecodeString(envelope.Payload)
		var value Snapshot
		if err := json.Unmarshal(payload, &value); err != nil {
			t.Fatal(err)
		}
		return value
	}
	request := SnapshotRequest{Origin: testOrigin, Nonce: identity.Hash([]byte("privacy nonce")), Roots: []string{owner.Device.AccountKey}}
	peer := snapshot(request, 200).Accounts[0].Records[1].Event
	if peer.Social != nil || peer.SocialHash != social.Hash() || peer.Hash() != event.Hash() || !identity.Verify(owner.Device.LeafKey(), peer.Signature, peer.Message()) {
		t.Fatal("peer view leaked contacts or broke proof")
	}
	request.Device = &owner.Device
	request.SignedAt = time.Now().Unix()
	request.Signature = identity.Sign(owner.Key, request.Message())
	full := snapshot(request, 200).Accounts[0].Records[1].Event
	if full.Social == nil || full.SocialHash != "" || full.Hash() != peer.Hash() {
		t.Fatal("owner full history unavailable")
	}
	changed := request
	changed.Nonce = identity.Hash([]byte("other challenge"))
	snapshot(changed, 403)
	wrongRoots := request
	wrongRoots.Roots = []string{identity.Hash([]byte("another root"))}
	snapshot(wrongRoots, 403)
	wrongTime := request
	wrongTime.SignedAt++
	snapshot(wrongTime, 403)
	other := testidentity.New("other-reader")
	wrongDevice := request
	wrongDevice.Device = &other.Device
	snapshot(wrongDevice, 403)
	wrongDevice.Signature = identity.Sign(other.Key, wrongDevice.Message())
	if snapshot(wrongDevice, 200).Accounts[0].Records[1].Event.Social != nil {
		t.Fatal("another account read private contacts")
	}
	stale := request
	stale.SignedAt -= 121
	stale.Signature = identity.Sign(owner.Key, stale.Message())
	snapshot(stale, 403)
	account, _ = s.account(t.Context(), owner.Device.AccountKey)
	state, _ = Replay(testOrigin, account)
	if appendStatus(t, s, signedEvent(state, owner, "revoke", owner.Device.LeafKey(), nil)) != 204 {
		t.Fatal("revoke")
	}
	if snapshot(request, 200).Accounts[0].Records[1].Event.Social != nil {
		t.Fatal("revoked reader obtained contact list")
	}
}
