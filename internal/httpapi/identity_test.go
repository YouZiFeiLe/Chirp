package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http/httptest"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

func TestIdentityEndpointsAreAccountScopedAndOldOwnerRoutesAreGone(t *testing.T) {
	db, err := store.Open(context.Background(), testdb.Path(t))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	m, token, err := db.AddMember(t.Context(), "Fixture")
	if err != nil {
		t.Fatal(err)
	}
	handler := New(db, &fakeMedia{}, room.Issuer{}, "wss://fixture.test", "https://fixture.test", slog.New(slog.NewTextHandler(io.Discard, nil)))
	send := func(path, credential string, want int) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest("GET", path, nil)
		if credential != "" {
			r.Header.Set("Authorization", "Bearer "+credential)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("%s got %d want %d: %s", path, w.Code, want, w.Body.String())
		}
		return w
	}
	for _, path := range []string{"/v1/identity/devices", "/v1/identity/blacklist", "/v1/identity/social/0", "/v1/identity/signals/0"} {
		send(path, "", 401)
		send(path, token, 200)
	}
	send("/v1/identity/social/-1", token, 400)
	send("/v1/rooms/friends/identity-policy", token, 404)
	if err = db.DisableMember(t.Context(), m.ID); err != nil {
		t.Fatal(err)
	}
	send("/v1/identity/blacklist", token, 403)
	records, err := db.Blacklist(t.Context())
	if err != nil || len(records) != 1 || records[0].AccountID != m.ID {
		t.Fatal("blacklist not persistent", records, err)
	}
	data, err := json.Marshal(records)
	if err != nil || len(data) == 0 {
		t.Fatal(err)
	}
}
