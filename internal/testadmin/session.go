// Package testadmin supplies an authenticated administrator to isolated HTTP tests.
package testadmin

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"net/http"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/browserauth"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func Session(t *testing.T, db *store.Store) *http.Cookie {
	t.Helper()
	ctx := context.Background()
	account := store.PasskeyAccount{ID: "passkey_test_administrator", Nickname: "Maintainer", CredentialID: []byte("test-administrator-credential"), CredentialJSON: []byte(`{}`)}
	request, err := db.RegisterPasskey(ctx, account)
	if err == nil {
		_, err = db.BootstrapAdministrator(ctx, request.RequestID)
	} else if errors.Is(err, store.ErrRegistrationExists) {
		err = nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var data [32]byte
	if _, err := rand.Read(data[:]); err != nil {
		t.Fatal(err)
	}
	token := base64.RawURLEncoding.EncodeToString(data[:])
	if _, err := db.FinishPasskeyLogin(ctx, account, account.CredentialJSON, token, time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	return &http.Cookie{Name: browserauth.SessionCookie, Value: token}
}
