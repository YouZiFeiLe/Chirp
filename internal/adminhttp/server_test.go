package adminhttp

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpapi"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testadmin"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testclient"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

type fakeMedia struct {
	err          error
	creates      int
	removes      []string
	ends         int
	room         string
	participants map[string][]room.Participant
}

func (m *fakeMedia) Participants(_ context.Context, id string) ([]room.Participant, error) {
	return m.participants[id], m.err
}
func (m *fakeMedia) EnsureRoom(context.Context, string) error { m.creates++; return m.err }
func (m *fakeMedia) RemoveParticipant(_ context.Context, name, id string) error {
	m.room = name
	m.removes = append(m.removes, id)
	return m.err
}
func (m *fakeMedia) EndRoom(_ context.Context, name string) error {
	m.room = name
	m.ends++
	return m.err
}

func newAdminTestServer(t *testing.T) (*store.Store, *fakeMedia, http.Handler) {
	t.Helper()
	dsn := testdb.Path(t)
	db, err := store.Open(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	testdb.SeedRooms(t, dsn)
	media := &fakeMedia{}
	return db, media, authenticatedAdmin(t, db, New(db, media, "wss://rtc.example.com", slog.New(slog.NewTextHandler(io.Discard, nil))), "https://rtc.example.com")
}

func adminRequest(t *testing.T, handler http.Handler, method, path, body string, status int) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		r.Header.Set("Content-Type", "application/json")
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != status {
		t.Fatalf("%s %s returned %d, want %d: %s", method, path, w.Code, status, w.Body.String())
	}
	if strings.HasPrefix(path, "/") && w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("administrator response can be cached")
	}
	return w
}

func decodeAdmin[T any](t *testing.T, w *httptest.ResponseRecorder) T {
	t.Helper()
	var value T
	if err := json.Unmarshal(w.Body.Bytes(), &value); err != nil {
		t.Fatal(err)
	}
	return value
}

func approvedLogin(t *testing.T, db *store.Store, handler http.Handler, nickname string) (store.Member, string) {
	t.Helper()
	ctx := context.Background()
	id, err := store.NewPasskeyID()
	if err != nil {
		t.Fatal(err)
	}
	account := store.PasskeyAccount{ID: id, Nickname: nickname, CredentialID: []byte(id), CredentialJSON: []byte(`{}`)}
	requestID, err := db.RegisterPasskey(ctx, account)
	if err != nil {
		t.Fatal(err)
	}
	adminRequest(t, handler, "POST", "/admin/api/registrations/"+requestID.RequestID+"/approve", `{}`, 200)
	verifier := strings.Repeat("v", 43)
	hash := sha256.Sum256([]byte(verifier))
	code, err := db.CreateClientAuthorization(ctx, account, []byte(`{}`), store.ClientAuthorization{
		ClientID: store.ClientID, RedirectURI: store.ClientRedirectURI, State: strings.Repeat("s", 32),
		CodeChallenge: base64.RawURLEncoding.EncodeToString(hash[:]), CodeChallengeMethod: "S256",
	})
	if err != nil {
		t.Fatal(err)
	}
	mac := testclient.MustLatest(t, db, "macos")
	login, err := db.ExchangeClientAuthorization(ctx, code, verifier, store.ClientID, store.ClientRedirectURI, mac, testidentity.New("existing-login-fixture").Login(store.ClientID, code, verifier))
	if err != nil {
		t.Fatal(err)
	}
	return login.Member, login.Credential
}

func TestAdminDeviceRoutesPermanentlyBanTheLastDevice(t *testing.T) {
	db, media, handler := newAdminTestServer(t)
	member, credential := approvedLogin(t, db, handler, "DeviceUser")
	path := "/admin/api/members/" + member.ID + "/devices"
	devices := decodeAdmin[[]store.RegisteredDevice](t, adminRequest(t, handler, "GET", path, "", 200))
	if len(devices) != 1 || devices[0].Revoked || devices[0].AccountID != member.ID {
		t.Fatal("device registry was not returned", devices)
	}
	lastLogin, err := time.Parse(time.RFC3339, member.LastLoginAt)
	if err != nil || devices[0].CreatedAt <= 0 || devices[0].LastLoginAt != lastLogin.Unix() {
		t.Fatal("admin device timestamps were not returned", devices, err)
	}
	client := httpapi.New(db, media, room.Issuer{}, "wss://rtc.example.com", "https://keys.example.test", slog.New(slog.NewTextHandler(io.Discard, nil)))
	r := httptest.NewRequest("GET", "/v1/identity/devices", nil)
	r.Header.Set("Authorization", "Bearer "+credential)
	response := httptest.NewRecorder()
	client.ServeHTTP(response, r)
	if response.Code != 200 {
		t.Fatal("client device list failed", response.Code, response.Body.String())
	}
	clientDevices := decodeAdmin[[]store.RegisteredDevice](t, response)
	if len(clientDevices) != 1 || clientDevices[0].CreatedAt != devices[0].CreatedAt || clientDevices[0].LastLoginAt != devices[0].LastLoginAt {
		t.Fatal("client and admin device timestamps differ", clientDevices, devices)
	}
	key, err := base64.StdEncoding.DecodeString(devices[0].DeviceKey)
	if err != nil {
		t.Fatal(err)
	}
	devicePath := "/" + base64.RawURLEncoding.EncodeToString(key)
	adminRequest(t, handler, "DELETE", "/admin/api/members/wrong-account/devices"+devicePath, "", 404)
	adminRequest(t, handler, "DELETE", path+devicePath, "", 204)
	current, err := db.MemberByCredential(t.Context(), credential)
	if err != nil || current.Enabled {
		t.Fatal("last device revocation did not ban the online account", err)
	}
	records := decodeAdmin[[]store.BlacklistEntry](t, adminRequest(t, handler, "GET", "/admin/api/blacklist", "", 200))
	if len(records) != 2 || records[0].AccountID != member.ID || records[1].AccountID != member.ID {
		t.Fatal("account and device blacklist records missing", records)
	}
	if len(media.removes) != 0 {
		t.Fatal("device action performed an unscoped member-wide media removal")
	}
	if _, err = db.UpdateMember(t.Context(), member.ID, member.DisplayName, true); !errors.Is(err, store.ErrBlacklisted) {
		t.Fatal("permanently revoked account was re-enabled", err)
	}
}

func TestAdminPasskeyMembersAndLoginRevocation(t *testing.T) {
	db, media, handler := newAdminTestServer(t)
	member, credential := approvedLogin(t, db, handler, "FriendA")
	id := member.ID
	identity := member.ParticipantIdentity()
	a, err := db.JoinRoom(context.Background(), member, "friends", 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	media.participants = map[string][]room.Participant{"friends": {{ID: a.Identity()}}}
	list := adminRequest(t, handler, "GET", "/admin/api/overview", "", 200)
	if strings.Contains(list.Body.String(), credential) || strings.Contains(list.Body.String(), "credential_hash") {
		t.Fatal("member list leaked credentials")
	}
	var overview struct {
		Members []struct {
			LoginActive bool   `json:"login_active"`
			Identity    string `json:"participant_identity"`
		} `json:"members"`
	}
	if err := json.Unmarshal(list.Body.Bytes(), &overview); err != nil {
		t.Fatal(err)
	}
	if len(overview.Members) != 2 || !strings.Contains(list.Body.String(), identity) {
		t.Fatal("current login not represented accurately", list.Body.String())
	}
	adminRequest(t, handler, "POST", "/admin/api/members", `{"display_name":"manual"}`, 404)
	adminRequest(t, handler, "POST", "/admin/api/members/"+id+"/reset-credential", `{}`, 404)
	revoked := adminRequest(t, handler, "POST", "/admin/api/members/"+id+"/revoke-login", `{"participant_identity":"`+identity+`"}`, 204)
	if revoked.Body.Len() != 0 {
		t.Fatal("revocation returned a new credential")
	}
	if _, err := db.MemberByCredential(context.Background(), credential); !errors.Is(err, store.ErrNotFound) {
		t.Fatal("old login still authorizes requests", err)
	}
	if len(media.removes) != 1 || media.removes[0] != a.Identity() {
		t.Fatal("revocation did not clean up exact media identity")
	}
	// A stale administrator snapshot must never revoke a newer login.
	newCredential, err := db.ResetCredential(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	adminRequest(t, handler, "POST", "/admin/api/members/"+id+"/revoke-login", `{"participant_identity":"`+identity+`"}`, 204)
	if _, err := db.MemberByCredential(context.Background(), newCredential); err != nil {
		t.Fatal("stale action revoked new login", err)
	}
	adminRequest(t, handler, "PUT", "/admin/api/members/"+id, `{"display_name":"朋友乙","enabled":false}`, 200)
	if member, err := db.MemberByCredential(context.Background(), newCredential); err != nil || member.Enabled || member.DisplayName != "朋友乙" {
		t.Fatal("member update failed", err)
	}
	adminRequest(t, handler, "PUT", "/admin/api/members/"+id, `{"display_name":"朋友乙","enabled":true}`, 403)
	if m, err := db.MemberByCredential(context.Background(), newCredential); err != nil || m.Enabled {
		t.Fatal("permanently banned member was enabled", err)
	}
	adminRequest(t, handler, "DELETE", "/admin/api/members/"+id, "", 204)
	adminRequest(t, handler, "DELETE", "/admin/api/members/"+id, "", 404)
	adminRequest(t, handler, "PUT", "/admin/api/members/"+id, `{"display_name":"朋友","enabled":true}`, 404)
	if requests, err := db.ListRegistrationRequests(context.Background()); err != nil || len(requests) != 1 || requests[0].Nickname != "Maintainer" {
		t.Fatal("deletion retained Passkey registration", err)
	}
}

func TestAdminRoomAndMediaFailure(t *testing.T) {
	db, media, handler := newAdminTestServer(t)
	type overviewResponse struct {
		Rooms         []room.Overview `json:"rooms"`
		Members       []store.Member  `json:"members"`
		MediaStatus   string          `json:"media_status"`
		SQLiteVersion string          `json:"sqlite_version"`
	}
	empty := decodeAdmin[overviewResponse](t, adminRequest(t, handler, "GET", "/admin/api/overview", "", 200))
	if len(empty.Rooms) != 5 || empty.Rooms[0].RoomID != "friends" || empty.Rooms[0].DisplayName != "公开大厅" || empty.MediaStatus != "available" || empty.SQLiteVersion != store.SQLiteVersion {
		t.Fatal("five-room metadata incomplete", empty)
	}
	saved := decodeAdmin[store.RoomConfig](t, adminRequest(t, handler, "PUT", "/admin/api/rooms/room-2", `{"display_name":"  周末大厅 😀  "}`, 200))
	if saved.RoomID != "room-2" || saved.DisplayName != "周末大厅 😀" || media.ends != 0 || media.creates != 0 {
		t.Fatal("rename changed routing", saved)
	}
	const description = "周六晚八点见！"
	adminRequest(t, handler, "PUT", "/admin/api/rooms/room-2/description", `{"description":"周六晚八点见！"}`, 200)
	_, credential := approvedLogin(t, db, handler, "FriendB")
	media.err = errors.New("private infrastructure failure")
	offlineHandler := authenticatedAdmin(t, db, New(db, media, "wss://rtc.example.com", slog.New(slog.NewTextHandler(io.Discard, nil))), "https://rtc.example.com")
	state := decodeAdmin[overviewResponse](t, adminRequest(t, offlineHandler, "GET", "/admin/api/overview", "", 200))
	if state.MediaStatus != "unavailable" || state.Rooms[1].Participants != nil || state.Rooms[1].DisplayName != saved.DisplayName || state.Rooms[1].Description != description {
		t.Fatal("invalid degraded overview")
	}
	adminRequest(t, offlineHandler, "PUT", "/admin/api/rooms/room-2", `{"display_name":"新的大厅"}`, 200)
	client := httpapi.New(db, media, room.Issuer{APIKey: "test", APISecret: strings.Repeat("x", 32), TTL: time.Minute}, "wss://rtc.example.com", "https://keys.example.test", slog.New(slog.NewTextHandler(io.Discard, nil)))
	for _, path := range []string{"/v1/rooms", "/v1/state"} {
		r := httptest.NewRequest("GET", path, nil)
		r.Header.Set("Authorization", "Bearer "+credential)
		response := httptest.NewRecorder()
		client.ServeHTTP(response, r)
		if response.Code != 200 || strings.Contains(response.Body.String(), media.err.Error()) {
			t.Fatal("directory unavailable during SFU outage", response.Body.String())
		}
		rooms := decodeAdmin[overviewResponse](t, response).Rooms
		if len(rooms) != 5 || rooms[1].RoomID != "room-2" || rooms[1].DisplayName != "新的大厅" || rooms[1].Description != description {
			t.Fatalf("%s lost room metadata after a name-only update: %+v", path, rooms)
		}
	}
	ending := adminRequest(t, handler, "POST", "/admin/api/rooms/room-2/end", `{}`, 503)
	if !strings.Contains(ending.Body.String(), "ROOM_END_INCOMPLETE") {
		t.Fatal(ending.Body.String())
	}
}

func TestRoomKickRevokesOnlyExactAdmissionBeforeControls(t *testing.T) {
	db, media, _ := newAdminTestServer(t)
	ctx := context.Background()
	member, credential, err := db.AddMember(ctx, "Group member")
	if err != nil {
		t.Fatal(err)
	}
	a, err := db.JoinRoom(ctx, member, "friends", 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	controls := make(chan string, 4)
	control := controlFunc(func(_ context.Context, operation, roomID, identity string) error {
		if allowed, err := db.AdmissionAllowed(ctx, "friends", a.Identity()); err != nil || allowed {
			t.Error("control preceded admission revocation", err)
		}
		controls <- operation
		return nil
	})
	handler := authenticatedAdmin(t, db, New(db, media, "wss://rtc.example.com", slog.New(slog.NewTextHandler(io.Discard, nil)), control), "https://rtc.example.com")
	adminRequest(t, handler, "DELETE", "/admin/api/rooms/friends/participants/"+a.Identity(), "", 204)
	if _, err := db.MemberByCredential(ctx, credential); err != nil {
		t.Fatal("room kick revoked account login", err)
	}
	if len(media.removes) != 1 || media.removes[0] != a.Identity() || media.room != "friends" || <-controls != "remove" {
		t.Fatal("kick missed exact room entry")
	}
	b, err := db.JoinRoom(ctx, member, "room-2", 2, 0)
	if err != nil {
		t.Fatal(err)
	}
	adminRequest(t, handler, "DELETE", "/admin/api/rooms/friends/participants/"+a.Identity(), "", 204)
	<-controls
	adminRequest(t, handler, "POST", "/admin/api/rooms/friends/end", `{}`, 204)
	<-controls
	if allowed, err := db.AdmissionAllowed(ctx, "room-2", b.Identity()); err != nil || !allowed {
		t.Fatal("stale kick or other room end revoked new room", err)
	}
	media.err = errors.New("offline")
	w := adminRequest(t, handler, "DELETE", "/admin/api/rooms/room-2/participants/"+b.Identity(), "", 503)
	<-controls
	if !strings.Contains(w.Body.String(), "ADMISSION_REVOKED_CLEANUP_PENDING") {
		t.Fatal(w.Body.String())
	}
}

func TestAdminValidationAndOrigins(t *testing.T) {
	_, media, handler := newAdminTestServer(t)
	for _, body := range []string{`{`, `null`, `[]`, `{}`, `{"display_name":" "}`, `{"display_name":12}`, `{"display_name":"test","secret":"no"}`, `{"display_name":"test"} {}`, `{"display_name":"x\ny"}`, `{"display_name":"` + strings.Repeat("字", 81) + `"}`, `{"key_id":"old-key"}`, `{"display_name":"` + strings.Repeat("x", 5000) + `"}`} {
		adminRequest(t, handler, "PUT", "/admin/api/rooms/friends", body, 400)
	}
	adminRequest(t, handler, "PUT", "/admin/api/members/unknown", `{"display_name":"test"}`, 400)
	adminRequest(t, handler, "POST", "/admin/api/members/unknown/revoke-login", `{"participant_identity":"someone-else.login_id"}`, 400)
	adminRequest(t, handler, "POST", "/admin/api/members/unknown/revoke-login", `{"participant_identity":"unknown.login_"}`, 400)
	adminRequest(t, handler, "POST", "/admin/api/rooms/friends/end", `{"extra":true}`, 400)
	if media.ends != 0 {
		t.Fatal("invalid request reached the media service")
	}
	for _, method := range []string{"POST", "PUT", "DELETE"} {
		path := "/admin/api/rooms/friends"
		if method == "POST" {
			path = "/admin/api/rooms/friends/end"
		}
		if method == "DELETE" {
			path = "/admin/api/members/unknown"
		}
		r := httptest.NewRequest(method, path, strings.NewReader(`{"display_name":"test"}`))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Origin", "https://unrelated.example")
		r.Header.Set("Sec-Fetch-Site", "cross-site")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != 403 {
			t.Fatalf("cross-origin %s accepted: %d", method, w.Code)
		}
	}
	r := httptest.NewRequest("PUT", "/admin/api/rooms/friends", strings.NewReader(`{"display_name":"test"}`))
	r.Header.Set("Content-Type", "text/plain")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 415 {
		t.Fatal("non-JSON room rename was accepted")
	}
}

func TestAdminEmbeddedPages(t *testing.T) {
	_, _, handler := newAdminTestServer(t)
	health := adminRequest(t, handler, "GET", "/admin/healthz", "", 200)
	if !strings.Contains(health.Body.String(), `"service":"admin"`) {
		t.Fatal("health check does not identify the independent administrator service")
	}
	for _, path := range []string{"/admin/", "/admin/assets/app.js", "/admin/assets/styles.css"} {
		w := adminRequest(t, handler, "GET", path, "", 200)
		if w.Body.Len() == 0 || !strings.Contains(w.Header().Get("Content-Security-Policy"), "frame-ancestors 'none'") {
			t.Fatal("page or static asset missing")
		}
	}
	for _, path := range []string{"/", "/api/overview", "/v1/me", "/v1/room", "/v1/room/join"} {
		adminRequest(t, handler, "GET", path, "", 404)
	}

	adminRequest(t, handler, "GET", "/admin/api/unknown", "", 404)
	adminRequest(t, handler, "GET", "/assets/missing.js", "", 404)
}

type controlFunc func(context.Context, string, string, string) error

func (f controlFunc) Send(ctx context.Context, operation, roomID, identity string) error {
	return f(ctx, operation, roomID, identity)
}

func authenticatedAdmin(t *testing.T, db *store.Store, next http.Handler, origin string) http.Handler {
	t.Helper()
	cookie := testadmin.Session(t, db)
	u, _ := url.Parse(origin)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Header.Set("Cookie", cookie.String())
		r.Host = u.Host
		if r.Header.Get("Origin") == "" {
			r.Header.Set("Origin", origin)
		}
		next.ServeHTTP(w, r)
	})
}
