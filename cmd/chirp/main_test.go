package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"path/filepath"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func TestLocalBootstrapDoesNotRequireMediaOrPublicConfiguration(t *testing.T) {
	t.Chdir(t.TempDir())
	path := filepath.Join(t.TempDir(), "chirp.db")
	t.Setenv("CHIRP_DATABASE_PATH", path)
	t.Setenv("CHIRP_PUBLIC_ORIGIN", "invalid")
	t.Setenv("LIVEKIT_API_SECRET", "")
	db, err := store.Open(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	id, _ := store.NewPasskeyID()
	r, err := db.RegisterPasskey(context.Background(), store.PasskeyAccount{ID: id, Nickname: "Maintainer", CredentialID: []byte(id), CredentialJSON: []byte(`{}`)})
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := run([]string{"admin", "bootstrap", "--request-id", r.RequestID}, &out); err != nil {
		t.Fatal(err)
	}
	var member store.Member
	if err := json.Unmarshal(out.Bytes(), &member); err != nil || !member.IsAdmin {
		t.Fatal(out.String(), err)
	}
	if err := run([]string{"admin", "bootstrap", "--request-id", r.RequestID}, &out); err == nil {
		t.Fatal("bootstrap repeated")
	}
	if err := run([]string{"admin", "revoke", "--id", member.ID}, &out); err == nil {
		t.Fatal("last administrator demoted")
	}
	for _, args := range [][]string{{"admin"}, {"admin", "grant"}, {"admin", "bootstrap", "--id", member.ID}, {"member", "list", "extra"}, {"unknown"}} {
		if err := run(args, &out); err == nil {
			t.Fatal("invalid command accepted", args)
		}
	}
	if err := run([]string{"version"}, &out); err != nil {
		t.Fatal(err)
	}
}

func TestLocalAdminCanReopenRegistration(t *testing.T) {
	t.Chdir(t.TempDir())
	path := filepath.Join(t.TempDir(), "chirp.db")
	t.Setenv("CHIRP_DATABASE_PATH", path)
	t.Setenv("CHIRP_PUBLIC_ORIGIN", "invalid")
	db, err := store.Open(t.Context(), path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := db.SetRegistrationClosed(t.Context(), true); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"admin", "reopen-registration"}, io.Discard); err != nil {
		t.Fatal(err)
	}
	if closed, err := db.RegistrationClosed(t.Context()); err != nil || closed {
		t.Fatalf("registration should be open: closed=%t, err=%v", closed, err)
	}
}
