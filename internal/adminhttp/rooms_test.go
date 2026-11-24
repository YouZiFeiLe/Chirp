package adminhttp

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"strings"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

func TestAdminRoomDescriptionValidationAndReset(t *testing.T) {
	db, _, handler := newAdminTestServer(t)
	const path = "/admin/api/rooms/friends/description"
	saved := decodeAdmin[store.RoomConfig](t, adminRequest(t, handler, "PUT", path, `{"description":"  🎵 周末歌单\r\n<带上朋友>  "}`, 200))
	if saved.Description != "🎵 周末歌单\n<带上朋友>" || saved.DisplayName != store.DefaultRoomDisplayName {
		t.Fatal("unexpected room after saving description", saved)
	}
	for _, body := range []string{`{}`, `{"description":null}`, `{"description":42}`, `{"description":"a\u0000b"}`, `{"description":"` + strings.Repeat("😀", 281) + `"}`} {
		adminRequest(t, handler, "PUT", path, body, 400)
	}
	if cfg, err := db.Room(t.Context(), store.DefaultRoomID); err != nil || cfg != saved {
		t.Fatal("rejected edit changed the room", cfg, err)
	}
	adminRequest(t, handler, "PUT", path, `{"description":"`+strings.Repeat("😀", 280)+`"}`, 200)
	reset := decodeAdmin[store.RoomConfig](t, adminRequest(t, handler, "PUT", path, `{"description":" \n "}`, 200))
	if reset.Description != store.DefaultRoomDescription {
		t.Fatal("did not restore the default description", reset)
	}
	adminRequest(t, handler, "DELETE", "/admin/api/rooms/room-2", "", 204)
	adminRequest(t, handler, "PUT", "/admin/api/rooms/room-2/description", `{"description":"test"}`, 404)
}

func TestAdminCreatesBeyondFiveProtectsDefaultAndDeletesActiveRoom(t *testing.T) {
	ctx := context.Background()
	db, err := store.Open(ctx, testdb.Path(t))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	media := &fakeMedia{}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	control := group.New(db, group.DefaultPolicy(), logger)
	handler := authenticatedAdmin(t, db, New(db, media, "wss://rtc.example.test", logger, control), "https://rtc.example.test")
	type overviewResponse struct {
		Rooms      []room.Overview `json:"rooms"`
		MaxMembers int             `json:"max_members"`
	}
	initial := decodeAdmin[overviewResponse](t, adminRequest(t, handler, "GET", "/admin/api/overview", "", 200))
	if len(initial.Rooms) != 1 || initial.MaxMembers != 0 || !initial.Rooms[0].IsDefault {
		t.Fatal("incorrect fresh admin overview", initial)
	}
	adminRequest(t, handler, "DELETE", "/admin/api/rooms/friends", "", 409)
	var added store.RoomConfig
	for i := range 6 {
		added = decodeAdmin[store.RoomConfig](t, adminRequest(t, handler, "POST", "/admin/api/rooms", fmt.Sprintf(`{"display_name":"房间 %d"}`, i), 201))
	}
	m, credential, err := db.AddMember(ctx, "Oliver")
	if err != nil {
		t.Fatal(err)
	}
	entry, err := db.JoinRoom(ctx, m, added.RoomID, 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	adminRequest(t, handler, "DELETE", "/admin/api/rooms/"+added.RoomID, "", 204)
	if allowed, err := db.AdmissionAllowed(ctx, added.RoomID, entry.Identity()); err != nil || allowed {
		t.Fatal("deleted room still authorizes media", err)
	}
	if _, err := db.MemberByCredential(ctx, credential); err != nil {
		t.Fatal("room deletion signed member out", err)
	}
	if media.ends != 1 || media.room != added.RoomID {
		t.Fatal("media was not stopped")
	}
	adminRequest(t, handler, "DELETE", "/admin/api/rooms/"+added.RoomID, "", 404)
	media.err = errors.New("media offline")
	adminRequest(t, handler, "DELETE", "/admin/api/rooms/"+initial.Rooms[0].RoomID, "", 409)
	pending := decodeAdmin[store.RoomConfig](t, adminRequest(t, handler, "POST", "/admin/api/rooms", `{"display_name":"等待清理"}`, 201))
	adminRequest(t, handler, "DELETE", "/admin/api/rooms/"+pending.RoomID, "", 202)
	if _, err := db.Room(ctx, pending.RoomID); !errors.Is(err, store.ErrNotFound) {
		t.Fatal("cleanup failure restored room", err)
	}
}
