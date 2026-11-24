package store

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

func TestRoomPasswordsDoNotRevokeExistingAdmissionsAndRejectStaleChecks(t *testing.T) {
	ctx := context.Background()
	s := openTestStore(t)
	m, token, err := s.AddMember(ctx, "Oliver")
	if err != nil {
		t.Fatal(err)
	}
	old, err := s.JoinRoom(ctx, m, "friends", 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	password := "朋友的 语音密码 😀"
	cfg, err := s.SetRoomPassword(ctx, "room-2", password)
	if err != nil || !cfg.PasswordRequired {
		t.Fatal("password not set", err)
	}
	for _, attempt := range []struct {
		text string
		want error
	}{{"", ErrRoomPasswordRequired}, {"incorrect-password", ErrRoomPasswordWrong}, {"short", ErrRoomPasswordWrong}} {
		if _, err := s.CheckRoomPassword(ctx, "room-2", attempt.text); !errors.Is(err, attempt.want) {
			t.Fatal("password bypass", err)
		}
	}
	checked, err := s.CheckRoomPassword(ctx, "room-2", password)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetRoomPassword(ctx, "room-2", "Replacement 123"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.JoinRoom(ctx, m, "room-2", 2, checked); !errors.Is(err, ErrRoomPasswordChanged) {
		t.Fatal("unused old check admitted", err)
	}
	if allowed, err := s.AdmissionAllowed(ctx, "friends", old.Identity()); err != nil || !allowed {
		t.Fatal("rejected switch changed old admission", err)
	}
	current, err := s.MemberByCredential(ctx, token)
	if err != nil || current.JoinSequence != 1 {
		t.Fatal("preflight changed sequence", err)
	}
	checked, err = s.CheckRoomPassword(ctx, "room-2", "Replacement 123")
	if err != nil {
		t.Fatal(err)
	}
	joined, err := s.JoinRoom(ctx, m, "room-2", 2, checked)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetRoomPassword(ctx, "room-2", "Another password"); err != nil {
		t.Fatal(err)
	}
	if err := s.TouchAdmission(ctx, "room-2", joined.Identity()); err != nil {
		t.Fatal("password change revoked admitted member", err)
	}
	retry, err := s.JoinRoom(ctx, m, "room-2", 2, checked)
	if err != nil || retry.EntryID != joined.EntryID {
		t.Fatal("exact admitted retry stopped working", err)
	}
	if _, err := s.JoinRoom(ctx, m, "room-2", 3, checked); !errors.Is(err, ErrRoomPasswordChanged) {
		t.Fatal("used check admitted a new entry", err)
	}
	if _, err := s.RenameRoom(ctx, "room-2", "周末房间"); err != nil {
		t.Fatal(err)
	}
	cfg, err = s.Room(ctx, "room-2")
	if err != nil || !cfg.PasswordRequired || cfg.DisplayName != "周末房间" {
		t.Fatal("rename cleared password", err)
	}
	if _, err := s.ClearRoomPassword(ctx, "room-2"); err != nil {
		t.Fatal(err)
	}
	if allowed, err := s.AdmissionAllowed(ctx, "room-2", joined.Identity()); err != nil || !allowed {
		t.Fatal("clearing password revoked member", err)
	}
	if _, err := s.JoinRoom(ctx, m, "room-2", 3, checked); !errors.Is(err, ErrRoomPasswordChanged) {
		t.Fatal("clear did not invalidate unused check", err)
	}
	noPassword, err := s.CheckRoomPassword(ctx, "room-2", "")
	if err != nil || noPassword <= checked {
		t.Fatal("password removal revision", err)
	}
	if _, err := s.JoinRoom(ctx, m, "room-2", 3, noPassword); err != nil {
		t.Fatal(err)
	}
	if _, err := s.JoinRoom(ctx, m, "room-3", 4, 0); err != nil {
		t.Fatal("other room password affected", err)
	}
}

func TestRoomPasswordStorageAndIndependentPool(t *testing.T) {
	ctx := context.Background()
	dsn := testdb.Path(t)
	s, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	testdb.SeedRooms(t, dsn)
	const password = " exact password 😀 "
	for _, id := range []string{"friends", "room-2"} {
		if _, err := s.SetRoomPassword(ctx, id, password); err != nil {
			t.Fatal(err)
		}
	}
	var firstSalt, firstHash, nextSalt, nextHash []byte
	if err := s.db.QueryRow("SELECT password_salt,password_hash FROM room_settings WHERE room_id='friends'").Scan(&firstSalt, &firstHash); err != nil {
		t.Fatal(err)
	}
	if err := s.db.QueryRow("SELECT password_salt,password_hash FROM room_settings WHERE room_id='room-2'").Scan(&nextSalt, &nextHash); err != nil {
		t.Fatal(err)
	}
	if len(firstSalt) != 16 || len(firstHash) != 32 || bytes.Equal(firstSalt, nextSalt) || bytes.Equal(firstHash, nextHash) || bytes.Contains(firstHash, []byte(password)) {
		t.Fatal("password verifier or salt invalid")
	}
	// A second Store with a separate pool observes the same saved configuration.
	two, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer two.Close()
	if _, err := two.CheckRoomPassword(ctx, "friends", password); err != nil {
		t.Fatal(err)
	}
	if _, err := two.CheckRoomPassword(ctx, "friends", strings.TrimSpace(password)); !errors.Is(err, ErrRoomPasswordWrong) {
		t.Fatal("password was silently trimmed", err)
	}
	rooms, err := s.Rooms(ctx)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(rooms)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{password, "password_salt", "password_hash", "password_revision"} {
		if strings.Contains(string(encoded), secret) {
			t.Fatal("room metadata leaked verifier material")
		}
	}
	for _, bad := range []string{"", "short", "bad\npassword", strings.Repeat("a", 129), string([]byte{0xff})} {
		if _, err := s.SetRoomPassword(ctx, "friends", bad); !errors.Is(err, ErrInvalidRoomPassword) {
			t.Fatal("invalid password accepted", err)
		}
	}
	if _, err := s.CheckRoomPassword(ctx, "friends", password); err != nil {
		t.Fatal("invalid writes changed password", err)
	}
}
