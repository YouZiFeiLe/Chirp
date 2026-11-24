package adminhttp

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/browserauth"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testadmin"
)

func TestAdminChecksSessionRoleOriginAndRevocation(t *testing.T) {
	db, media, _ := newAdminTestServer(t)
	h := New(db, media, "wss://chirp.youzifeile.cn", slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := func(method, path string, cookie *http.Cookie, origin string, want int) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(method, "https://chirp.youzifeile.cn"+path, strings.NewReader(`{}`))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Origin", origin)
		// A native credential or a forged role header never authorizes the admin UI.
		r.Header.Set("Authorization", "Bearer chirp_native_credential")
		r.Header.Set("X-Admin", "true")
		if cookie != nil {
			r.AddCookie(cookie)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("%s %s: %d want %d: %s", method, path, w.Code, want, w.Body.String())
		}
		return w
	}
	for _, path := range []string{"/admin/api/overview", "/admin/assets/app.js", "/admin/healthz"} {
		request("GET", path, nil, "", 401)
	}
	if w := request("GET", "/admin/", nil, "", 303); w.Header().Get("Location") != "/?admin=1" {
		t.Fatal(w.Header())
	}
	request("POST", "/admin/api/rooms", nil, "https://chirp.youzifeile.cn", 401)
	request("PUT", "/admin/api/rooms/friends/description", nil, "https://chirp.youzifeile.cn", 401)
	request("PUT", "/admin/api/registration-settings", nil, "https://chirp.youzifeile.cn", 401)
	admin := testadmin.Session(t, db)
	request("GET", "/admin/", admin, "", 200)
	request("GET", "/admin/assets/app.js", admin, "", 200)
	request("POST", "/admin/api/rooms", admin, "https://attacker.test", 403)
	request("POST", "/admin/api/rooms", admin, "", 403)
	request("PUT", "/admin/api/registration-settings", admin, "https://attacker.test", 403)
	request("POST", "/admin/api/bootstrap", admin, "https://chirp.youzifeile.cn", 404)
	ctx := context.Background()
	a := store.PasskeyAccount{ID: "regular_account", Nickname: "Regular", CredentialID: []byte("regular_credential"), CredentialJSON: []byte(`{}`)}
	registration, err := db.RegisterPasskey(ctx, a)
	if err != nil {
		t.Fatal(err)
	}
	member, err := db.ApproveRegistration(ctx, registration.RequestID)
	if err != nil {
		t.Fatal(err)
	}
	token := strings.Repeat("r", 43)
	cookie := &http.Cookie{Name: browserauth.SessionCookie, Value: token}
	login := func(expires time.Time) {
		t.Helper()
		if _, err := db.FinishPasskeyLogin(ctx, a, a.CredentialJSON, token, expires); err != nil {
			t.Fatal(err)
		}
	}
	login(time.Now().Add(time.Hour))
	request("GET", "/admin/api/overview", cookie, "", 403)
	request("PUT", "/admin/api/rooms/friends/description", cookie, "https://chirp.youzifeile.cn", 403)
	request("PUT", "/admin/api/registration-settings", cookie, "https://chirp.youzifeile.cn", 403)
	if err := db.SetAdministrator(ctx, member.ID, true); err != nil {
		t.Fatal(err)
	}
	request("GET", "/admin/api/overview", cookie, "", 401)
	login(time.Now().Add(time.Hour))
	request("GET", "/admin/api/overview", cookie, "", 200)
	if err := db.SetAdministrator(ctx, member.ID, false); err != nil {
		t.Fatal(err)
	}
	request("GET", "/admin/api/overview", cookie, "", 401)
	login(time.Now().Add(-time.Second))
	request("GET", "/admin/api/overview", cookie, "", 401)
}
