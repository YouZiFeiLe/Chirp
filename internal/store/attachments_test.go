package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestAttachmentQuotaExpiryAndRecipientIsolation(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	m, _, _ := s.AddMember(ctx, "sender")
	a, _ := s.JoinRoom(ctx, m, "friends", 1, 0)
	for _, id := range []string{"../escape", strings.Repeat("A", 32), strings.Repeat("x", 32)} {
		if _, err := s.CreateAttachment(ctx, m, "friends", a.EntryID, id, 32, strings.Repeat("0", 64), nil); !errors.Is(err, ErrAttachmentInvalid) {
			t.Fatal("unsafe ID accepted", id, err)
		}
	}
	if _, err := s.CreateAttachment(ctx, m, "friends", a.EntryID, strings.Repeat("a", 32), MaxAttachmentBytes+1, strings.Repeat("0", 64), nil); !errors.Is(err, ErrAttachmentInvalid) {
		t.Fatal(err)
	}
	for _, digit := range []string{"1", "2", "3", "4", "5"} {
		if _, err := s.CreateAttachment(ctx, m, "friends", a.EntryID, strings.Repeat(digit, 32), MaxAttachmentBytes, strings.Repeat("0", 64), nil); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.CreateAttachment(ctx, m, "friends", a.EntryID, strings.Repeat("6", 32), MaxAttachmentBytes, strings.Repeat("0", 64), nil); !errors.Is(err, ErrAttachmentQuota) {
		t.Fatal("quota not reserved", err)
	}
	if _, err := s.db.ExecContext(ctx, "UPDATE room_attachments SET expires_at=?", time.Now().Add(-16*time.Minute).Unix()); err != nil {
		t.Fatal(err)
	}
	changed, err := s.ReconcileAttachments(ctx)
	if err != nil || len(changed) != 5 {
		t.Fatal("pending uploads did not enter expired state", changed, err)
	}
	if _, err := s.db.ExecContext(ctx, "UPDATE room_attachments SET terminal_at=?", time.Now().Add(-6*time.Minute).Unix()); err != nil {
		t.Fatal(err)
	}
	ids, err := s.ReapAttachments(ctx)
	if err != nil || len(ids) != 5 {
		t.Fatal("pending uploads did not expire", ids, err)
	}
	var recipients int
	if err = s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM attachment_recipients").Scan(&recipients); err != nil || recipients != 0 {
		t.Fatal("recipient cascade failed", err)
	}
	f, err := s.CreateAttachment(ctx, m, "friends", a.EntryID, strings.Repeat("7", 32), 32, strings.Repeat("0", 64), nil)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.AdvanceAttachment(ctx, f, strings.Repeat("1", 64)); err != nil {
		t.Fatal(err)
	}
	if _, err = s.db.ExecContext(ctx, "UPDATE room_attachments SET expires_at=?", time.Now().Add(-time.Second).Unix()); err != nil {
		t.Fatal(err)
	}
	if a, err := s.Attachment(ctx, m, "friends", a.EntryID, f.ID); err != nil || a.State != AttachmentExpired {
		t.Fatal("expired status unavailable", a, err)
	}
	if _, err := s.ReconcileAttachments(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.ExecContext(ctx, "UPDATE room_attachments SET terminal_at=?", time.Now().Add(-6*time.Minute).Unix()); err != nil {
		t.Fatal(err)
	}
	ids, err = s.ReapAttachments(ctx)
	if err != nil || len(ids) != 1 {
		t.Fatal("completed upload did not expire", ids, err)
	}
}
