package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/livekit/protocol/auth"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

type fakeMedia struct {
	err     error
	creates int
}

func (m *fakeMedia) Participants(context.Context, string) ([]room.Participant, error) {
	return []room.Participant{}, m.err
}
func (m *fakeMedia) EnsureRoom(context.Context, string) error { m.creates++; return m.err }
func TestAuthorizationAndRoomContracts(t *testing.T) {
	ctx := context.Background()
	dsn := testdb.Path(t)
	db, err := store.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	testdb.SeedRooms(t, dsn)
	member, credential, err := db.AddMember(ctx, "朋友甲")
	if err != nil {
		t.Fatal(err)
	}
	media := &fakeMedia{}
	secret := strings.Repeat("test-secret-", 4)
	handler := New(db, media, room.Issuer{APIKey: "test-key", APISecret: secret, TTL: 5 * time.Minute}, "wss://rtc.example.com", "https://auth.example.com", slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := func(method, path, token, body string, status int) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != status {
			t.Fatalf("%s %s: %d want %d: %s", method, path, w.Code, status, w.Body.String())
		}
		return w
	}
	for _, path := range []string{"/", "/admin", "/api/overview", "/v1/room", "/v1/room/config"} {
		request("GET", path, credential, "", 404)
	}
	request("POST", "/api/members", credential, `{}`, 404)
	request("GET", "/v1/rooms", "", "", 401)
	request("GET", "/v1/rooms", "bad-token", "", 401)
	directory := request("GET", "/v1/rooms", credential, "", 200)
	var listing struct {
		Rooms []room.Overview `json:"rooms"`
	}
	if err := json.Unmarshal(directory.Body.Bytes(), &listing); err != nil {
		t.Fatal(err)
	}
	if len(listing.Rooms) != 5 || listing.Rooms[0].RoomID != "friends" || len(listing.Rooms[0].Participants) != 0 || media.creates != 0 {
		t.Fatal("browsing joined a room or omitted empty rooms")
	}
	for _, body := range []string{`{`, `null`, `{}`, `{"key_id":"old"}`, `{"join_sequence":1} {}`, `{"join_sequence":1,"entry_id":"forged"}`, strings.Repeat("x", 2048)} {
		status := 400
		if body == `{}` {
			status = 409
		}
		request("POST", "/v1/rooms/friends/join", credential, body, status)
	}
	if media.creates != 0 {
		t.Fatal("invalid request reached LiveKit")
	}
	joinBody := func(roomID string, sequence int64) string {
		t.Helper()
		body, _ := json.Marshal(map[string]any{"join_sequence": sequence})
		response := request("POST", "/v1/rooms/"+roomID+"/preflight", credential, string(body), 200)
		var proof struct {
			Proof string `json:"preflight_proof"`
		}
		if err := json.Unmarshal(response.Body.Bytes(), &proof); err != nil {
			t.Fatal(err)
		}
		body, _ = json.Marshal(map[string]any{"join_sequence": sequence, "preflight_proof": proof.Proof})
		return string(body)
	}
	request("POST", "/v1/rooms/friends/join", credential, `{"join_sequence":1}`, 403)
	joined := request("POST", "/v1/rooms/room-2/join", credential, joinBody("room-2", 1), 200)
	var result struct {
		store.RoomAdmission
		Token    string `json:"token"`
		Identity string `json:"participant_identity"`
		Protocol string `json:"key_protocol"`
		E2EE     bool   `json:"e2ee_required"`
	}
	if err := json.Unmarshal(joined.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.RoomID != "room-2" || !store.ValidEntryID(result.EntryID) || result.Identity != store.AdmissionIdentity(member, result.EntryID) || !result.E2EE || result.Protocol != "chirp-mls-authenticated-v5" {
		t.Fatal("join omitted room/entry/security binding", joined.Body.String())
	}
	if joined.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("join can be cached")
	}
	verifier, err := auth.ParseAPIToken(result.Token)
	if err != nil {
		t.Fatal(err)
	}
	registered, claims, err := verifier.Verify(secret)
	if err != nil {
		t.Fatal(err)
	}
	grant := claims.Video
	if claims.Identity != result.Identity || grant == nil || grant.Room != "room-2" || !grant.RoomJoin || !grant.GetCanPublish() || !grant.GetCanSubscribe() || !grant.GetCanPublishData() || grant.RoomAdmin || grant.RoomCreate || grant.RoomList || len(grant.CanPublishSources) != 1 || grant.CanPublishSources[0] != "microphone" {
		t.Fatal("JWT privilege or room binding incorrect")
	}
	if !grant.GetCanUpdateOwnMetadata() {
		t.Fatal("join token must allow publishing the participant's playback state")
	}
	if registered.ExpiresAt == nil || time.Until(registered.ExpiresAt.Time) < 4*time.Minute || time.Until(registered.ExpiresAt.Time) > 5*time.Minute {
		t.Fatal("wrong JWT lifetime")
	}
	entryBody := `{"entry_id":"` + result.EntryID + `"}`
	refreshed := request("POST", "/v1/rooms/room-2/media-token", credential, entryBody, 200)
	var fresh struct {
		RoomID   string `json:"room_id"`
		EntryID  string `json:"entry_id"`
		Identity string `json:"participant_identity"`
		Token    string `json:"token"`
	}
	if err := json.Unmarshal(refreshed.Body.Bytes(), &fresh); err != nil {
		t.Fatal(err)
	}
	refreshVerifier, err := auth.ParseAPIToken(fresh.Token)
	if err != nil {
		t.Fatal(err)
	}
	_, refreshClaims, err := refreshVerifier.Verify(secret)
	if err != nil || fresh.RoomID != result.RoomID || fresh.EntryID != result.EntryID ||
		fresh.Identity != result.Identity || refreshClaims.Identity != result.Identity ||
		refreshClaims.Video == nil || refreshClaims.Video.Room != result.RoomID || !refreshClaims.Video.GetCanUpdateOwnMetadata() {
		t.Fatal("token refresh changed admission or grant", err)
	}
	request("POST", "/v1/rooms/friends/media-token", credential, entryBody, 409)
	request("POST", "/v1/rooms/room-2/media-token", "", entryBody, 401)
	retry := request("POST", "/v1/rooms/room-2/join", credential, joinBody("room-2", 1), 200)
	if !strings.Contains(retry.Body.String(), result.EntryID) {
		t.Fatal("idempotent retry replaced admission")
	}
	request("POST", "/v1/rooms/friends/join", credential, joinBody("friends", 1), 409)
	request("POST", "/v1/rooms/friends/join", credential, joinBody("friends", 2), 200)
	request("POST", "/v1/rooms/room-2/media-token", credential, entryBody, 409)
	request("POST", "/v1/rooms/room-2/leave", credential, `{"entry_id":"`+result.EntryID+`"}`, 204)
	request("POST", "/v1/rooms/room-2/join", credential, joinBody("room-2", 1), 409)
	request("POST", "/v1/rooms/nonexistent/join", credential, `{"join_sequence":3}`, 404)
	media.err = errors.New("offline")
	request("POST", "/v1/rooms/room-3/join", credential, joinBody("room-3", 3), 503)
	if err := db.DisableMember(ctx, member.ID); err != nil {
		t.Fatal(err)
	}
	request("GET", "/v1/rooms", credential, "", 403)
	request("POST", "/v1/rooms/friends/join", credential, `{"join_sequence":4}`, 403)
}
