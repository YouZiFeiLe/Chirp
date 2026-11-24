package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

func TestRoomPasswordPreflightKeepsOldRoomAndProtectsEveryJoin(t *testing.T) {
	ctx := context.Background()
	dsn := testdb.Path(t)
	db, err := store.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	testdb.SeedRooms(t, dsn)
	m, token, err := db.AddMember(ctx, "Oliver")
	if err != nil {
		t.Fatal(err)
	}
	old, err := db.JoinRoom(ctx, m, "friends", 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.SetRoomPassword(ctx, "room-2", "First password"); err != nil {
		t.Fatal(err)
	}
	media := &fakeMedia{}
	handler := New(db, media, room.Issuer{APIKey: "test", APISecret: strings.Repeat("s", 32), TTL: 5 * time.Minute}, "wss://rtc.example.com", "https://auth.example.com", slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := func(path string, body any, status int) *httptest.ResponseRecorder {
		t.Helper()
		raw, _ := json.Marshal(body)
		r := httptest.NewRequest("POST", path, strings.NewReader(string(raw)))
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != status {
			t.Fatalf("%s: %d want %d: %s", path, w.Code, status, w.Body.String())
		}
		return w
	}
	preflight := func(sequence int64, password string, status int) string {
		t.Helper()
		w := request("/v1/rooms/room-2/preflight", map[string]any{"join_sequence": sequence, "password": password}, status)
		var result struct {
			Proof string `json:"preflight_proof"`
		}
		if status == 200 {
			if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
				t.Fatal(err)
			}
		}
		return result.Proof
	}
	join := func(id string, sequence int64, proof string, status int) *httptest.ResponseRecorder {
		return request("/v1/rooms/"+id+"/join", map[string]any{"join_sequence": sequence, "preflight_proof": proof}, status)
	}
	preflight(2, "", 403)
	preflight(2, "bad password", 403)
	proof := preflight(2, "First password", 200)
	if media.creates != 0 {
		t.Fatal("preflight created media room")
	}
	if ok, err := db.AdmissionAllowed(ctx, "friends", old.Identity()); err != nil || !ok {
		t.Fatal("preflight revoked current call", err)
	}
	current, err := db.MemberByCredential(ctx, token)
	if err != nil || current.JoinSequence != 1 {
		t.Fatal("preflight advanced sequence", err)
	}
	join("room-2", 2, "", 403)
	join("room-2", 2, proof+"x", 403)
	join("room-3", 2, proof, 403)
	join("room-2", 3, proof, 403)
	if media.creates != 0 {
		t.Fatal("unverified join reached media")
	}
	if _, err := db.SetRoomPassword(ctx, "room-2", "Second password"); err != nil {
		t.Fatal(err)
	}
	join("room-2", 2, proof, 409)
	if ok, _ := db.AdmissionAllowed(ctx, "friends", old.Identity()); !ok {
		t.Fatal("changed password displaced current room")
	}
	proof = preflight(2, "Second password", 200)
	joined := join("room-2", 2, proof, 200)
	var result struct {
		Entry    string `json:"entry_id"`
		Identity string `json:"participant_identity"`
	}
	if err := json.Unmarshal(joined.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if _, err := db.SetRoomPassword(ctx, "room-2", "Third password"); err != nil {
		t.Fatal(err)
	}
	if err := db.TouchAdmission(ctx, "room-2", result.Identity); err != nil {
		t.Fatal("password update revoked established entry", err)
	}
	if retry := join("room-2", 2, proof, 200); !strings.Contains(retry.Body.String(), result.Entry) {
		t.Fatal("exact retry issued a new entry")
	}
	if err := db.LeaveRoom(ctx, m, "room-2", result.Entry); err != nil {
		t.Fatal(err)
	}
	join("room-2", 2, proof, 409)
	join("room-2", 3, proof, 403)
	for range 5 {
		preflight(3, "wrong password", 403)
	}
	w := request("/v1/rooms/room-2/preflight", map[string]any{"join_sequence": 3, "password": "Third password"}, 429)
	if w.Header().Get("Retry-After") == "" {
		t.Fatal("missing retry guidance")
	}
	request("/v1/rooms/room-3/preflight", map[string]any{"join_sequence": 3}, 200)
	listing := httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/v1/rooms", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	handler.ServeHTTP(listing, r)
	if listing.Code != 200 || !strings.Contains(listing.Body.String(), `"password_required":true`) {
		t.Fatal("directory omitted password flag")
	}
	for _, secret := range []string{"Third password", "password_hash", "password_salt", "password_revision"} {
		if strings.Contains(listing.Body.String(), secret) {
			t.Fatal("directory leaked password material")
		}
	}
}
