package store

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

func TestProfilePersistsAcrossPoolsWithoutChangingLoginOrAdmission(t *testing.T) {
	ctx := context.Background()
	dsn := testdb.Path(t)
	one, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer one.Close()
	m, token, err := one.AddMember(ctx, "Oliver")
	if err != nil {
		t.Fatal(err)
	}
	admission, err := one.JoinRoom(ctx, m, "friends", 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := one.UpdateOwnDisplayName(ctx, m, "朋友 😀"); err != nil {
		t.Fatal(err)
	}
	data := bytes.Repeat([]byte{0, 1, 127, 255}, 20000) // Exceeds ordinary BLOB capacity.
	p, err := one.SetOwnAvatar(ctx, m, data)
	if err != nil {
		t.Fatal(err)
	}
	two, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer two.Close()
	got, err := two.MemberProfile(ctx, m.ID)
	if err != nil || got != p || got.ProfileRevision != 2 || got.DisplayName != "朋友 😀" {
		t.Fatal("profile did not persist across pools", got, err)
	}
	image, err := two.MemberAvatar(ctx, m.ID, p.AvatarRevision)
	if err != nil || !bytes.Equal(data, image) {
		t.Fatal("MEDIUMBLOB bytes changed", err)
	}
	current, err := two.MemberByCredential(ctx, token)
	if err != nil || current.LoginID != m.LoginID || current.JoinSequence != 1 || current.CredentialExpiresAt != m.CredentialExpiresAt {
		t.Fatal("profile update changed login/admission state", err)
	}
	if allowed, err := two.AdmissionAllowed(ctx, "friends", admission.Identity()); err != nil || !allowed {
		t.Fatal("profile update interrupted admission", err)
	}
	if _, err := two.UpdateMember(ctx, m.ID, "管理员改名", true); err != nil {
		t.Fatal(err)
	}
	if got, _ := one.MemberProfile(ctx, m.ID); got.ProfileRevision != 3 || got.DisplayName != "管理员改名" {
		t.Fatal("admin rename did not advance public revision", got)
	}
	if err := one.DeleteMember(ctx, m.ID); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := two.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM member_avatars WHERE member_id = ?", m.ID).Scan(&count); err != nil || count != 0 {
		t.Fatal("member deletion did not cascade to avatar", err)
	}
}

func TestLateProfileWritesCannotUseReplacedDisabledOrRevokedLogin(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	m, _, err := s.AddMember(ctx, "Oliver")
	if err != nil {
		t.Fatal(err)
	}
	newToken, err := s.ResetCredential(ctx, m.ID)
	if err != nil {
		t.Fatal(err)
	}
	assertRejected := func(member Member) {
		t.Helper()
		_, renameErr := s.UpdateOwnDisplayName(ctx, member, "late request")
		_, uploadErr := s.SetOwnAvatar(ctx, member, []byte("normalized-pixels"))
		_, deleteErr := s.DeleteOwnAvatar(ctx, member)
		for _, err := range []error{renameErr, uploadErr, deleteErr} {
			if !errors.Is(err, ErrProfileSessionChanged) {
				t.Fatal("late profile write accepted", err)
			}
		}
	}
	assertRejected(m)
	current, err := s.MemberByCredential(ctx, newToken)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.RevokeClientCredential(ctx, newToken); err != nil {
		t.Fatal(err)
	}
	assertRejected(current)
	if err := s.DisableMember(ctx, m.ID); err != nil {
		t.Fatal(err)
	}
	assertRejected(current)
	if got, err := s.MemberProfiles(ctx); err != nil || len(got) != 0 {
		t.Fatal("disabled member exposed in public profiles", err)
	}
}
