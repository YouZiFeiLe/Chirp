package httpapi

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func completeDeliveryFixture(t *testing.T, f *attachmentAPIFixture, id string, data []byte, recipients []string) {
	t.Helper()
	digest := sha256.Sum256(data)
	body, _ := json.Marshal(map[string]any{"id": id, "entry_id": f.entries[0].EntryID, "ciphertext_size": len(data), "ciphertext_sha256": hex.EncodeToString(digest[:]), "recipients": recipients})
	f.request(t, 0, "POST", strings.TrimSuffix(f.base(""), "/"), body, 201)
	for offset, index := 0, 0; offset < len(data); index++ {
		end := min(offset+int(store.AttachmentChunkBytes), len(data))
		f.request(t, 0, "PUT", f.base(id)+"/chunks/"+strconv.Itoa(index), data[offset:end], 204)
		offset = end
	}
	f.request(t, 0, "POST", f.base(id)+"/complete", nil, 200)
}

func TestAttachmentReceiptsDeleteOnlyAfterEveryOriginalRecipient(t *testing.T) {
	f := newAttachmentAPIFixture(t)
	id := strings.Repeat("9", 32)
	data := bytes.Repeat([]byte{0x8c}, int(store.AttachmentChunkBytes)+37)
	completeDeliveryFixture(t, f, id, data, []string{f.entries[1].Identity(), f.entries[2].Identity()})
	digest := sha256.Sum256(data)
	receipt, _ := json.Marshal(map[string]string{"ciphertext_sha256": hex.EncodeToString(digest[:])})
	f.request(t, 1, "POST", f.base(id)+"/received", []byte(`{"ciphertext_sha256":"`+strings.Repeat("0", 64)+`"}`), 400)
	// The owner already has a local copy and cannot acknowledge for a peer.
	f.request(t, 0, "POST", f.base(id)+"/received", receipt, 200)
	f.request(t, 1, "POST", f.base(id)+"/received", receipt, 200)
	f.request(t, 1, "POST", f.base(id)+"/received", receipt, 200)
	if _, err := os.Stat(filepath.Join(f.root, id, "ciphertext")); err != nil {
		t.Fatal("deleted before last recipient", err)
	}
	f.request(t, 2, "GET", f.base(id)+"/chunks/0", nil, 200)
	response := f.request(t, 2, "POST", f.base(id)+"/received", receipt, 200)
	var state attachmentResponse
	if err := json.Unmarshal(response.Body.Bytes(), &state); err != nil || state.State != store.AttachmentDelivered {
		t.Fatal(state, err)
	}
	if _, err := os.Stat(filepath.Join(f.root, id)); !os.IsNotExist(err) {
		t.Fatal("ciphertext retained after all receipts", err)
	}
	// A lost last receipt response and a lost complete response remain retryable.
	f.request(t, 2, "POST", f.base(id)+"/received", receipt, 200)
	f.request(t, 0, "POST", f.base(id)+"/complete", nil, 200)
	f.request(t, 1, "GET", f.base(id)+"/chunks/0", nil, 410)
}

func TestAttachmentConfirmedDisconnectCannotRejoinOldDelivery(t *testing.T) {
	f := newAttachmentAPIFixture(t)
	id := strings.Repeat("8", 32)
	data := bytes.Repeat([]byte{1}, 32)
	completeDeliveryFixture(t, f, id, data, []string{f.entries[1].Identity()})
	f.disconnects[1]()
	f.files.feed.mu.Lock()
	f.files.feed.disconnected[f.entries[1].Identity()] = time.Now().Add(-attachmentDisconnectGrace - time.Second)
	f.files.feed.mu.Unlock()
	_, disconnect, err := f.files.connect(context.Background(), f.entries[1].Identity())
	if err != nil {
		t.Fatal(err)
	}
	defer disconnect()
	f.request(t, 1, "GET", f.base(id), nil, 404)
	if _, err := os.Stat(filepath.Join(f.root, id)); !os.IsNotExist(err) {
		t.Fatal("disconnected recipient retained server copy", err)
	}
	// A new file may target the new online interval; the previous one stays lost.
	next := strings.Repeat("7", 32)
	completeDeliveryFixture(t, f, next, data, []string{f.entries[1].Identity()})
	f.request(t, 1, "GET", f.base(next)+"/chunks/0", nil, 200)
	f.request(t, 1, "GET", f.base(id), nil, 404)
}

func TestAttachmentNotOnlineAtReservationCannotDownloadAfterConnecting(t *testing.T) {
	f := newAttachmentAPIFixture(t)
	f.disconnects[1]()
	f.files.feed.mu.Lock()
	delete(f.files.feed.disconnected, f.entries[1].Identity())
	f.files.feed.mu.Unlock()
	id := strings.Repeat("6", 32)
	completeDeliveryFixture(t, f, id, make([]byte, 32), []string{f.entries[1].Identity()})
	_, disconnect, err := f.files.connect(context.Background(), f.entries[1].Identity())
	if err != nil {
		t.Fatal(err)
	}
	defer disconnect()
	f.request(t, 1, "GET", f.base(id), nil, 404)
	if _, err := os.Stat(filepath.Join(f.root, id)); !os.IsNotExist(err) {
		t.Fatal("empty audience retained ciphertext", err)
	}
}

func TestAttachmentDisconnectDuringUploadEndsEligibilityBeforeCompletion(t *testing.T) {
	f := newAttachmentAPIFixture(t)
	id := strings.Repeat("4", 32)
	data := make([]byte, 32)
	f.create(t, id, data)
	f.disconnects[1]()
	f.files.feed.mu.Lock()
	f.files.feed.disconnected[f.entries[1].Identity()] = time.Now().Add(-attachmentDisconnectGrace - time.Second)
	f.files.feed.mu.Unlock()
	if err := f.files.reconcile(context.Background()); err != nil {
		t.Fatal(err)
	}
	f.request(t, 0, "PUT", f.base(id)+"/chunks/0", data, 204)
	response := f.request(t, 0, "POST", f.base(id)+"/complete", nil, 200)
	var state attachmentResponse
	if err := json.Unmarshal(response.Body.Bytes(), &state); err != nil || state.State != store.AttachmentDelivered {
		t.Fatal(state, err)
	}
	_, disconnect, err := f.files.connect(context.Background(), f.entries[1].Identity())
	if err != nil {
		t.Fatal(err)
	}
	defer disconnect()
	f.request(t, 1, "GET", f.base(id), nil, 404)
	if _, err := os.Stat(filepath.Join(f.root, id)); !os.IsNotExist(err) {
		t.Fatal("abandoned upload retained ciphertext", err)
	}
}

func TestAttachmentRestartRetiresOldDeliveryAndReapsCiphertext(t *testing.T) {
	f := newAttachmentAPIFixture(t)
	completeID, partialID := strings.Repeat("2", 32), strings.Repeat("3", 32)
	data := make([]byte, 32)
	completeDeliveryFixture(t, f, completeID, data, []string{f.entries[1].Identity()})
	f.create(t, partialID, data)
	f.request(t, 0, "PUT", f.base(partialID)+"/chunks/0", data, 204)
	if err := f.files.Close(); err != nil {
		t.Fatal(err)
	}
	fresh, err := NewAttachmentStorage(f.db, f.root)
	if err != nil {
		t.Fatal(err)
	}
	f.files = fresh // Existing fixture cleanup now owns the reopened storage.
	for _, id := range []string{completeID, partialID} {
		a, err := f.db.Attachment(context.Background(), f.members[0], store.DefaultRoomID, f.entries[0].EntryID, id)
		if err != nil {
			t.Fatal(err)
		}
		expected := store.AttachmentCancelled
		if id == completeID {
			expected = store.AttachmentDelivered
		}
		if a.State != expected {
			t.Fatal("restart retained old transfer", a)
		}
	}
	_, disconnect, err := fresh.connect(context.Background(), f.entries[1].Identity())
	if err != nil {
		t.Fatal(err)
	}
	defer disconnect()
	if _, err := f.db.Attachment(context.Background(), f.members[1], store.DefaultRoomID, f.entries[1].EntryID, completeID); err == nil {
		t.Fatal("reconnect restored old delivery")
	}
	entries, err := os.ReadDir(f.root)
	if err != nil || len(entries) != 0 {
		t.Fatal("restart left ciphertext", entries, err)
	}
}

type revokingAttachmentResponse struct {
	*httptest.ResponseRecorder
	revoke func()
}

func (w *revokingAttachmentResponse) Write(p []byte) (int, error) {
	n, err := w.ResponseRecorder.Write(p)
	if w.revoke != nil {
		revoke := w.revoke
		w.revoke = nil
		revoke()
	}
	return n, err
}

func TestLargeAttachmentDownloadStillChecksAuthorizationEvery64KiB(t *testing.T) {
	f := newAttachmentAPIFixture(t)
	id := strings.Repeat("5", 32)
	data := make([]byte, store.AttachmentChunkBytes)
	completeDeliveryFixture(t, f, id, data, []string{f.entries[1].Identity()})
	r := httptest.NewRequest("GET", f.base(id)+"/chunks/0", nil)
	r.Header.Set("Authorization", "Bearer "+f.tokens[1])
	r.Header.Set("X-Chirp-Entry", f.entries[1].EntryID)
	w := &revokingAttachmentResponse{ResponseRecorder: httptest.NewRecorder(), revoke: func() {
		if err := f.db.LeaveRoom(context.Background(), f.members[1], store.DefaultRoomID, f.entries[1].EntryID); err != nil {
			t.Fatal(err)
		}
	}}
	f.handler.ServeHTTP(w, r)
	if w.Body.Len() != 64*1024 {
		t.Fatal("revocation leaked remaining large block", w.Body.Len())
	}
}
