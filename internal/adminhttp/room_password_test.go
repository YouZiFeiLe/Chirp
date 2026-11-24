package adminhttp

import (
	"context"
	"strings"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func TestAdminRoomPasswordIsWriteOnlyAndKeepsCurrentCall(t *testing.T) {
	db, media, handler := newAdminTestServer(t)
	ctx := context.Background()
	m, _, err := db.AddMember(ctx, "Oliver")
	if err != nil {
		t.Fatal(err)
	}
	a, err := db.JoinRoom(ctx, m, "room-2", 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	path := "/admin/api/rooms/room-2/password"
	for _, bad := range []string{`{}`, `{"password":"short"}`, `{"password":"bad\npassword"}`, `{"password":"valid password","enabled":true}`} {
		adminRequest(t, handler, "PUT", path, bad, 400)
	}
	for _, password := range []string{"First password", "Replacement password"} {
		w := adminRequest(t, handler, "PUT", path, `{"password":"`+password+`"}`, 200)
		cfg := decodeAdmin[store.RoomConfig](t, w)
		if !cfg.PasswordRequired || strings.Contains(w.Body.String(), password) {
			t.Fatal("password was not write-only")
		}
		if ok, err := db.AdmissionAllowed(ctx, "room-2", a.Identity()); err != nil || !ok {
			t.Fatal("password update revoked current call", err)
		}
	}
	adminRequest(t, handler, "PUT", "/admin/api/rooms/room-2", `{"display_name":"保护的房间"}`, 200)
	if _, err := db.CheckRoomPassword(ctx, "room-2", "Replacement password"); err != nil {
		t.Fatal("rename cleared password", err)
	}
	overview := adminRequest(t, handler, "GET", "/admin/api/overview", "", 200)
	for _, secret := range []string{"Replacement password", "password_hash", "password_salt", "password_revision"} {
		if strings.Contains(overview.Body.String(), secret) {
			t.Fatal("admin leaked password verifier")
		}
	}
	adminRequest(t, handler, "GET", path, "", 405)
	adminRequest(t, handler, "PUT", "/admin/api/rooms/room-6/password", `{"password":"test password"}`, 404)
	adminRequest(t, handler, "DELETE", path, "", 200)
	cfg, err := db.Room(ctx, "room-2")
	if err != nil || cfg.PasswordRequired {
		t.Fatal("password not removed", err)
	}
	if ok, err := db.AdmissionAllowed(ctx, "room-2", a.Identity()); err != nil || !ok {
		t.Fatal("password removal revoked entry", err)
	}
	if media.ends != 0 || len(media.removes) != 0 {
		t.Fatal("password settings changed media membership")
	}
}
