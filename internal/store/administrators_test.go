package store

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

func administratorRegistration(t *testing.T, db *Store, nickname string) (PasskeyAccount, RegistrationRequest) {
	t.Helper()
	id, err := NewPasskeyID()
	if err != nil {
		t.Fatal(err)
	}
	a := PasskeyAccount{ID: id, Nickname: nickname, CredentialID: []byte(id), CredentialJSON: []byte(`{}`)}
	r, err := db.RegisterPasskey(context.Background(), a)
	if err != nil {
		t.Fatal(err)
	}
	return a, r
}

func TestBootstrapIsAtomicAndCannotBeRepeated(t *testing.T) {
	db := openTestStore(t)
	ctx := context.Background()
	if _, err := db.BootstrapAdministrator(ctx, "missing"); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
	_, a := administratorRegistration(t, db, "FirstAdmin")
	_, b := administratorRegistration(t, db, "OtherAdmin")
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for _, id := range []string{a.RequestID, b.RequestID} {
		wg.Add(1)
		go func(id string) { defer wg.Done(); _, err := db.BootstrapAdministrator(ctx, id); results <- err }(id)
	}
	wg.Wait()
	close(results)
	succeeded, rejected := 0, 0
	for err := range results {
		if err == nil {
			succeeded++
		} else if errors.Is(err, ErrAdminInitialized) {
			rejected++
		} else {
			t.Fatal(err)
		}
	}
	members, err := db.ListMembers(ctx)
	if err != nil || succeeded != 1 || rejected != 1 || len(members) != 1 || !members[0].IsAdmin {
		t.Fatal(members, succeeded, rejected, err)
	}
	if err := db.DeleteMember(ctx, members[0].ID); !errors.Is(err, ErrLastAdministrator) {
		t.Fatal(err)
	}
	if err := db.DisableMember(ctx, members[0].ID); !errors.Is(err, ErrLastAdministrator) {
		t.Fatal(err)
	}
	if _, err := db.UpdateMember(ctx, members[0].ID, "Disabled", false); !errors.Is(err, ErrLastAdministrator) {
		t.Fatal(err)
	}
	if err := db.SetAdministrator(ctx, members[0].ID, false); !errors.Is(err, ErrLastAdministrator) {
		t.Fatal(err)
	}
}

func TestAdministratorRoleAndDisableInvalidateBrowserSessions(t *testing.T) {
	db := openTestStore(t)
	ctx := context.Background()
	a, registration := administratorRegistration(t, db, "FirstAdmin")
	first, err := db.BootstrapAdministrator(ctx, registration.RequestID)
	if err != nil {
		t.Fatal(err)
	}
	b, registration := administratorRegistration(t, db, "SecondAdmin")
	second, err := db.ApproveRegistration(ctx, registration.RequestID)
	if err != nil {
		t.Fatal(err)
	}
	token := strings.Repeat("a", 43)
	if _, err := db.FinishPasskeyLogin(ctx, b, b.CredentialJSON, token, time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := db.SetAdministrator(ctx, second.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, _, err := db.PasskeySession(ctx, token); !errors.Is(err, ErrNotFound) {
		t.Fatal("grant reused a pre-grant browser session", err)
	}
	if member, err := db.FinishPasskeyLogin(ctx, b, b.CredentialJSON, token, time.Now().Add(time.Hour)); err != nil || !member.IsAdmin {
		t.Fatal(member, err)
	}
	if err := db.DisableMember(ctx, second.ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := db.PasskeySession(ctx, token); !errors.Is(err, ErrNotFound) {
		t.Fatal("disabled session remains usable", err)
	}
	if _, err := db.UpdateMember(ctx, second.ID, second.DisplayName, true); !errors.Is(err, ErrBlacklisted) {
		t.Fatal(err)
	}
	if _, _, err := db.PasskeySession(ctx, token); !errors.Is(err, ErrNotFound) {
		t.Fatal("re-enabling revived a session", err)
	}
	if err := db.SetAdministrator(ctx, second.ID, false); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
	if member, _, err := db.PasskeySession(ctx, token); err == nil && member.IsAdmin {
		t.Fatal("demoted account still administers")
	}
	if _, err := db.FinishPasskeyLogin(ctx, a, a.CredentialJSON, strings.Repeat("b", 43), time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := db.DeleteMember(ctx, first.ID); !errors.Is(err, ErrLastAdministrator) {
		t.Fatal(err)
	}
}

func TestLocalRecoveryApprovesAnAdditionalAdministrator(t *testing.T) {
	db := openTestStore(t)
	ctx := context.Background()
	_, first := administratorRegistration(t, db, "FirstAdmin")
	if _, err := db.GrantAdministratorRegistration(ctx, first.RequestID); !errors.Is(err, ErrAdminNotInitialized) {
		t.Fatal(err)
	}
	if _, err := db.BootstrapAdministrator(ctx, first.RequestID); err != nil {
		t.Fatal(err)
	}
	_, replacement := administratorRegistration(t, db, "Replacement")
	member, err := db.GrantAdministratorRegistration(ctx, replacement.RequestID)
	if err != nil || !member.IsAdmin {
		t.Fatal(member, err)
	}
	if _, err := db.GrantAdministratorRegistration(ctx, replacement.RequestID); !errors.Is(err, ErrAlreadyApproved) {
		t.Fatal(err)
	}
	if _, err := db.BootstrapAdministrator(ctx, replacement.RequestID); !errors.Is(err, ErrAdminInitialized) {
		t.Fatal(err)
	}
}
