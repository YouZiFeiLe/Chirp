package store

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

func TestAttachmentRetryKeepsOriginalCiphertextAudienceAndAdmission(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	owner, _, _ := s.AddMember(ctx, "owner")
	peer, _, _ := s.AddMember(ctx, "peer")
	late, _, _ := s.AddMember(ctx, "late")
	a, _ := s.JoinRoom(ctx, owner, "friends", 1, 0)
	b, _ := s.JoinRoom(ctx, peer, "friends", 1, 0)
	c, _ := s.JoinRoom(ctx, late, "friends", 1, 0)
	id, hash := strings.Repeat("a", 32), strings.Repeat("1", 64)
	original, err := s.CreateAttachment(ctx, owner, "friends", a.EntryID, id, AttachmentChunkBytes+16, hash, []string{b.Identity()})
	if err != nil {
		t.Fatal(err)
	}
	if err = s.AdvanceAttachment(ctx, original, strings.Repeat("2", 64)); err != nil {
		t.Fatal(err)
	}
	paused, err := s.SetAttachmentState(ctx, owner, "friends", a.EntryID, id, AttachmentPaused)
	if err != nil || paused.Uploaded != 1 || paused.State != AttachmentPaused || paused.Revision != 3 {
		t.Fatal(paused, err)
	}
	if err = s.LeaveRoom(ctx, peer, "friends", b.EntryID); err != nil {
		t.Fatal(err)
	}
	// An unchanged retry is allowed even when an original recipient has left.
	retry, err := s.CreateAttachment(ctx, owner, "friends", a.EntryID, id, original.Size, hash, []string{b.Identity(), a.Identity(), b.Identity()})
	if err != nil || retry != paused {
		t.Fatal("retry changed immutable state", retry, err)
	}
	for _, change := range []struct {
		size       int64
		hash       string
		recipients []string
	}{
		{original.Size + 1, hash, []string{b.Identity()}},
		{original.Size, strings.Repeat("3", 64), []string{b.Identity()}},
		{original.Size, hash, []string{c.Identity()}},
		{original.Size, hash, []string{b.Identity(), c.Identity()}},
	} {
		if _, err = s.CreateAttachment(ctx, owner, "friends", a.EntryID, id, change.size, change.hash, change.recipients); !errors.Is(err, ErrAttachmentConflict) {
			t.Fatal("mutable retry accepted", err)
		}
	}
	if err = s.AdvanceAttachment(ctx, paused, strings.Repeat("4", 64)); err != nil {
		t.Fatal(err)
	}
	full, _ := s.Attachment(ctx, owner, "friends", a.EntryID, id)
	hashes, err := s.AttachmentDigests(ctx, full)
	if err != nil || len(hashes) != 2 || hashes[0] != strings.Repeat("2", 64) || hashes[1] != strings.Repeat("4", 64) {
		t.Fatal(hashes, err)
	}
	// A late prefix query sees exactly its captured progress, not a later chunk.
	prefix, err := s.AttachmentDigests(ctx, paused)
	if err != nil || len(prefix) != 1 {
		t.Fatal(prefix, err)
	}
	if err = s.AdvanceAttachment(ctx, paused, strings.Repeat("4", 64)); !errors.Is(err, ErrAttachmentConflict) {
		t.Fatal("stale chunk advanced twice", err)
	}
	completed, err := s.SetAttachmentState(ctx, owner, "friends", a.EntryID, id, AttachmentCompleted)
	if err != nil || completed.Revision != 5 || completed.CompletedAt == 0 {
		t.Fatal(completed, err)
	}
	cancel, err := s.SetAttachmentState(ctx, owner, "friends", a.EntryID, id, AttachmentCancelled)
	if err != nil || cancel != completed {
		t.Fatal("cancel withdrew completed file", cancel, err)
	}
	if err = s.LeaveRoom(ctx, owner, "friends", a.EntryID); err != nil {
		t.Fatal(err)
	}
	fresh, _ := s.JoinRoom(ctx, owner, "friends", 2, 0)
	if _, err = s.Attachment(ctx, owner, "friends", fresh.EntryID, id); !errors.Is(err, ErrNotFound) {
		t.Fatal("reentry inherited old file", err)
	}
	if _, err = s.CreateAttachment(ctx, owner, "friends", fresh.EntryID, id, original.Size, hash, nil); !errors.Is(err, ErrAttachmentConflict) {
		t.Fatal("reentry reused old ID", err)
	}
}

func TestAttachmentCompleteCancelRaceAcrossSQLitePools(t *testing.T) {
	ctx := context.Background()
	path := testdb.Path(t)
	a, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	b, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	testdb.SeedRooms(t, path)
	owner, _, _ := a.AddMember(ctx, "owner")
	entry, _ := a.JoinRoom(ctx, owner, "friends", 1, 0)
	for i := range 24 {
		id := strings.Repeat("0", 30) + string("0123456789abcdef"[i/16]) + string("0123456789abcdef"[i%16])
		f, err := a.CreateAttachment(ctx, owner, "friends", entry.EntryID, id, 16, strings.Repeat("0", 64), nil)
		if err != nil {
			t.Fatal(err)
		}
		if err = a.AdvanceAttachment(ctx, f, strings.Repeat("1", 64)); err != nil {
			t.Fatal(err)
		}
		start := make(chan struct{})
		var wg sync.WaitGroup
		results := make(chan Attachment, 2)
		for index, db := range []*Store{a, b} {
			state := AttachmentCompleted
			if index == 1 {
				state = AttachmentCancelled
			}
			wg.Go(func() {
				<-start
				value, err := db.SetAttachmentState(ctx, owner, "friends", entry.EntryID, id, state)
				if err != nil && !errors.Is(err, ErrAttachmentConflict) {
					t.Error(err)
				}
				if err == nil {
					results <- value
				}
			})
		}
		close(start)
		wg.Wait()
		close(results)
		current, err := a.Attachment(ctx, owner, "friends", entry.EntryID, id)
		if err != nil || (current.State != AttachmentDelivered && current.State != AttachmentCancelled) || (current.State == AttachmentCancelled && current.Revision != 3) || (current.State == AttachmentDelivered && current.Revision != 4) {
			t.Fatal(current, err)
		}
		for result := range results {
			if result.State != current.State {
				t.Fatal("conflicting terminal successes", result, current)
			}
		}
		if err = a.AdvanceAttachment(ctx, f, strings.Repeat("1", 64)); !errors.Is(err, ErrAttachmentConflict) {
			t.Fatal("terminal upload resurrected", err)
		}
	}
}

func TestAttachmentReconciliationAndTerminalRetention(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	owner, _, _ := s.AddMember(ctx, "owner")
	peer, _, _ := s.AddMember(ctx, "peer")
	a, _ := s.JoinRoom(ctx, owner, "friends", 1, 0)
	b, _ := s.JoinRoom(ctx, peer, "friends", 1, 0)
	create := func(digit string) Attachment {
		t.Helper()
		f, err := s.CreateAttachment(ctx, owner, "friends", a.EntryID, strings.Repeat(digit, 32), 16, strings.Repeat("0", 64), []string{b.Identity()})
		if err != nil {
			t.Fatal(err)
		}
		return f
	}
	complete := create("1")
	abandoned := create("2")
	expired := create("3")
	idle := create("4")
	if err := s.AdvanceAttachment(ctx, complete, strings.Repeat("0", 64)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetAttachmentState(ctx, owner, "friends", a.EntryID, complete.ID, AttachmentCompleted); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.ExecContext(ctx, "UPDATE room_attachments SET updated_at=? WHERE id=?", time.Now().Add(-time.Minute).Unix(), idle.ID); err != nil {
		t.Fatal(err)
	}
	changed, err := s.ReconcileAttachments(ctx)
	if err != nil || len(changed) != 1 || changed[0].ID != idle.ID || changed[0].State != AttachmentPaused {
		t.Fatal(changed, err)
	}
	changed, err = s.ReconcileAttachments(ctx)
	if err != nil || len(changed) != 0 {
		t.Fatal("idle reconcile wrote unchanged states", changed, err)
	}
	if _, err = s.db.ExecContext(ctx, "UPDATE room_attachments SET expires_at=? WHERE id=?", time.Now().Add(-time.Second).Unix(), expired.ID); err != nil {
		t.Fatal(err)
	}
	if err = s.LeaveRoom(ctx, owner, "friends", a.EntryID); err != nil {
		t.Fatal(err)
	}
	changed, err = s.ReconcileAttachments(ctx)
	if err != nil || len(changed) != 3 {
		t.Fatal(changed, err)
	}
	for _, f := range []Attachment{complete, abandoned, expired, idle} {
		got, err := s.Attachment(ctx, peer, "friends", b.EntryID, f.ID)
		expected := AttachmentCancelled
		if f.ID == complete.ID {
			expected = AttachmentCompleted
		}
		if f.ID == expired.ID {
			expected = AttachmentExpired
		}
		if err != nil || got.State != expected {
			t.Fatal("recipient cannot observe terminal state", got, expected, err)
		}
	}
	ids, err := s.ReapAttachments(ctx)
	if err != nil || len(ids) != 0 {
		t.Fatal("tombstones removed too early", ids, err)
	}
	if _, err = s.db.ExecContext(ctx, "UPDATE room_attachments SET terminal_at=? WHERE state IN ('cancelled','expired')", time.Now().Add(-6*time.Minute).Unix()); err != nil {
		t.Fatal(err)
	}
	ids, err = s.ReapAttachments(ctx)
	if err != nil || len(ids) != 3 {
		t.Fatal(ids, err)
	}
	remaining, err := s.Attachments(ctx, peer, "friends", b.EntryID)
	if err != nil || len(remaining) != 1 || remaining[0].ID != complete.ID {
		t.Fatal(remaining, err)
	}
}
