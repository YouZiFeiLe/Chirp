package httpapi

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/config"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

type attachmentAPIFixture struct {
	db          *store.Store
	files       *AttachmentStorage
	handler     http.Handler
	root        string
	members     []store.Member
	entries     []store.RoomAdmission
	tokens      []string
	disconnects []func()
}

func newAttachmentAPIFixture(t *testing.T) *attachmentAPIFixture {
	t.Helper()
	ctx := context.Background()
	db, err := store.Open(ctx, testdb.Path(t))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	f := &attachmentAPIFixture{db: db, root: t.TempDir()}
	f.files, err = NewAttachmentStorage(db, f.root)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.files.Close() })
	for _, name := range []string{"owner", "peer", "late"} {
		m, token, err := db.AddMember(ctx, name)
		if err != nil {
			t.Fatal(err)
		}
		a, err := db.JoinRoom(ctx, m, store.DefaultRoomID, 1, 0)
		if err != nil {
			t.Fatal(err)
		}
		f.members = append(f.members, m)
		f.entries = append(f.entries, a)
		f.tokens = append(f.tokens, token)
		_, disconnect := f.files.feed.register(a.Identity())
		f.disconnects = append(f.disconnects, disconnect)
		t.Cleanup(disconnect)
	}
	f.handler = NewWithAttachments(db, nil, room.Issuer{}, "wss://example.test", "https://example.test", slog.New(slog.NewTextHandler(io.Discard, nil)), config.DefaultClientEndpoints("https://example.test"), f.files, nil)
	return f
}
func (f *attachmentAPIFixture) base(id string) string {
	return "/v1/rooms/" + store.DefaultRoomID + "/attachments/" + id
}
func (f *attachmentAPIFixture) request(t *testing.T, index int, method, path string, body []byte, want int) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, path, bytes.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+f.tokens[index])
	r.Header.Set("X-Chirp-Entry", f.entries[index].EntryID)
	if method == "PUT" {
		r.Header.Set("Content-Type", "application/octet-stream")
	}
	w := httptest.NewRecorder()
	f.handler.ServeHTTP(w, r)
	if w.Code != want {
		t.Fatalf("%s %s: %d want %d %s", method, path, w.Code, want, w.Body.String())
	}
	return w
}
func (f *attachmentAPIFixture) create(t *testing.T, id string, data []byte) {
	t.Helper()
	digest := sha256.Sum256(data)
	body, _ := json.Marshal(map[string]any{"id": id, "entry_id": f.entries[0].EntryID, "ciphertext_size": len(data), "ciphertext_sha256": hex.EncodeToString(digest[:]), "recipients": []string{f.entries[0].Identity(), f.entries[1].Identity()}})
	f.request(t, 0, "POST", strings.TrimSuffix(f.base(""), "/"), body, 201)
}

func TestAttachmentCancellationDuringChunkCannotPublishOrResurrect(t *testing.T) {
	f := newAttachmentAPIFixture(t)
	id := strings.Repeat("a", 32)
	data := bytes.Repeat([]byte{7}, 32)
	f.create(t, id, data)
	body := &attachmentRevokingReader{data: bytes.NewReader(data), revoke: func() { f.request(t, 0, "POST", f.base(id)+"/cancel", nil, 200) }}
	r := httptest.NewRequest("PUT", f.base(id)+"/chunks/0", body)
	r.ContentLength = 32
	r.Header.Set("Authorization", "Bearer "+f.tokens[0])
	r.Header.Set("X-Chirp-Entry", f.entries[0].EntryID)
	r.Header.Set("Content-Type", "application/octet-stream")
	w := httptest.NewRecorder()
	f.handler.ServeHTTP(w, r)
	if w.Code != 410 {
		t.Fatal("cancelled chunk did not stop", w.Code, w.Body.String())
	}
	f.request(t, 0, "PUT", f.base(id)+"/chunks/0", data, 410)
	f.request(t, 0, "POST", f.base(id)+"/complete", nil, 410)
	response := f.request(t, 1, "GET", f.base(id), nil, 200)
	var state attachmentResponse
	if err := json.Unmarshal(response.Body.Bytes(), &state); err != nil || state.State != store.AttachmentCancelled || state.Uploaded != 0 {
		t.Fatal(state, err)
	}
	if _, err := os.Stat(filepath.Join(f.root, id)); !os.IsNotExist(err) {
		t.Fatal("cancel left ciphertext", err)
	}
	f.request(t, 2, "GET", f.base(id), nil, 404)
	f.request(t, 1, "POST", f.base(id)+"/cancel", nil, 404)
}

func TestAttachmentCompleteVerifiesCiphertextAndCancelKeepsCompletedContent(t *testing.T) {
	f := newAttachmentAPIFixture(t)
	for _, digit := range []string{"a", "b"} {
		id := strings.Repeat(digit, 32)
		data := bytes.Repeat([]byte{9}, 32)
		f.create(t, id, data)
		f.request(t, 0, "PUT", f.base(id)+"/chunks/0", data, 204)
		f.request(t, 1, "GET", f.base(id)+"/chunks/0", nil, 409)
		if digit == "a" {
			if err := os.WriteFile(filepath.Join(f.root, id, "ciphertext"), bytes.Repeat([]byte{8}, 32), 0600); err != nil {
				t.Fatal(err)
			}
			response := f.request(t, 0, "POST", f.base(id)+"/complete", nil, 409)
			if !strings.Contains(response.Body.String(), "ATTACHMENT_INTEGRITY") {
				t.Fatal(response.Body.String())
			}
			f.request(t, 0, "POST", f.base(id)+"/cancel", nil, 200)
		} else {
			f.request(t, 0, "POST", f.base(id)+"/complete", nil, 200)
			response := f.request(t, 0, "POST", f.base(id)+"/cancel", nil, 200)
			var state attachmentResponse
			if err := json.Unmarshal(response.Body.Bytes(), &state); err != nil || state.State != store.AttachmentCompleted {
				t.Fatal(state, err)
			}
			f.request(t, 1, "GET", f.base(id)+"/chunks/0", nil, 200)
		}
	}
}

func TestAttachmentEventsNotifyOriginalRecipientAndCloseOnReentry(t *testing.T) {
	f := newAttachmentAPIFixture(t)
	server := httptest.NewServer(f.handler)
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	request, _ := http.NewRequestWithContext(ctx, "GET", server.URL+f.base("events"), nil)
	request.Header.Set("Authorization", "Bearer "+f.tokens[1])
	request.Header.Set("X-Chirp-Entry", f.entries[1].EntryID)
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	scanner := bufio.NewScanner(response.Body)
	readHint := func() uint64 {
		t.Helper()
		for scanner.Scan() {
			if strings.HasPrefix(scanner.Text(), "data: ") {
				var hint struct {
					Revision uint64 `json:"revision"`
					ServerID string `json:"server_id"`
				}
				if err := json.Unmarshal([]byte(strings.TrimPrefix(scanner.Text(), "data: ")), &hint); err != nil || hint.Revision == 0 || hint.ServerID == "" {
					t.Fatal(hint, err)
				}
				return hint.Revision
			}
		}
		t.Fatal("missing event", scanner.Err())
		return 0
	}
	first := readHint()
	id := strings.Repeat("d", 32)
	f.create(t, id, make([]byte, 32))
	next := readHint()
	if next <= first {
		t.Fatal("creation did not advance room revision")
	}
	f.request(t, 0, "POST", f.base(id)+"/cancel", nil, 200)
	if readHint() <= next {
		t.Fatal("cancellation did not advance revision")
	}
	body := f.request(t, 1, "GET", strings.TrimSuffix(f.base(""), "/"), nil, 200).Body.Bytes()
	if !bytes.Contains(body, []byte(`"state":"cancelled"`)) || bytes.Contains(body, []byte("owner_identity")) {
		t.Fatal(string(body))
	}
	body = f.request(t, 2, "GET", strings.TrimSuffix(f.base(""), "/"), nil, 200).Body.Bytes()
	if bytes.Contains(body, []byte(id)) {
		t.Fatal("catalog exposed another audience's object")
	}
	if err = f.db.LeaveRoom(ctx, f.members[1], store.DefaultRoomID, f.entries[1].EntryID); err != nil {
		t.Fatal(err)
	}
	revoked := false
	for scanner.Scan() {
		if scanner.Text() == "event: revoked" {
			revoked = true
			break
		}
	}
	if !revoked {
		t.Fatal("stream survived admission revocation", scanner.Err())
	}
	cancel()
	fresh, err := f.db.JoinRoom(context.Background(), f.members[1], store.DefaultRoomID, 2, 0)
	if err != nil {
		t.Fatal(err)
	}
	f.entries[1] = fresh
	f.request(t, 1, "GET", f.base(id), nil, 404)
}

func TestAttachmentChunkProgressCoalescesCatalogNotifications(t *testing.T) {
	f := newAttachmentAPIFixture(t)
	id := strings.Repeat("e", 32)
	data := bytes.Repeat([]byte{0xab}, int(store.AttachmentChunkBytes*4+16))
	f.create(t, id, data)
	reserved, _ := f.files.feed.snapshot(store.DefaultRoomID)
	for index := 0; index < 5; index++ {
		start := int64(index) * store.AttachmentChunkBytes
		end := min(start+store.AttachmentChunkBytes, int64(len(data)))
		f.request(t, 0, "PUT", f.base(id)+"/chunks/"+string('0'+rune(index)), data[start:end], 204)
		revision, _ := f.files.feed.snapshot(store.DefaultRoomID)
		if revision != reserved+1 {
			t.Fatal("bulk progress flooded the full-catalog feed", index, revision, reserved)
		}
	}
	f.request(t, 0, "POST", f.base(id)+"/complete", nil, 200)
	completed, _ := f.files.feed.snapshot(store.DefaultRoomID)
	if completed != reserved+2 {
		t.Fatal("completion did not notify receivers", completed, reserved)
	}
	if err := f.files.Reap(context.Background()); err != nil {
		t.Fatal(err)
	}
	afterGC, _ := f.files.feed.snapshot(store.DefaultRoomID)
	if afterGC != completed {
		t.Fatal("idle GC emitted a spurious change", afterGC, completed)
	}
}

func TestInvalidAttachmentCatalogRequestsDoNotRetainRoomFeeds(t *testing.T) {
	f := newAttachmentAPIFixture(t)
	for index := range 100 {
		path := "/v1/rooms/missing-" + strconv.Itoa(index) + "/attachments"
		f.request(t, 0, "GET", path, nil, 404)
	}
	f.files.feed.mu.Lock()
	defer f.files.feed.mu.Unlock()
	if len(f.files.feed.rooms) != 0 {
		t.Fatalf("rejected catalog requests retained %d room feeds", len(f.files.feed.rooms))
	}
}

func TestSlowAttachmentUploadCanReturnReceiptAfterOrdinaryWriteTimeout(t *testing.T) {
	f := newAttachmentAPIFixture(t)
	id := strings.Repeat("f", 32)
	data := bytes.Repeat([]byte{0x42}, 32)
	f.create(t, id, data)
	server := httptest.NewUnstartedServer(f.handler)
	server.Config.ReadTimeout = 100 * time.Millisecond
	server.Config.WriteTimeout = 100 * time.Millisecond
	server.Start()
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// The second request retries the same bytes after a lost receipt. Both
	// paths must support a progressing body beyond the ordinary HTTP timeout.
	for _, operation := range []string{"upload", "retry"} {
		t.Run(operation, func(t *testing.T) {
			reader, writer := io.Pipe()
			defer reader.Close()
			written := make(chan error, 1)
			go func() {
				_, err := writer.Write(data[:16])
				if err == nil {
					time.Sleep(250 * time.Millisecond)
					_, err = writer.Write(data[16:])
				}
				writer.CloseWithError(err)
				written <- err
			}()
			r, err := http.NewRequestWithContext(ctx, "PUT", server.URL+f.base(id)+"/chunks/0", reader)
			if err != nil {
				t.Fatal(err)
			}
			r.ContentLength = int64(len(data))
			r.Header.Set("Authorization", "Bearer "+f.tokens[0])
			r.Header.Set("X-Chirp-Entry", f.entries[0].EntryID)
			r.Header.Set("Content-Type", "application/octet-stream")
			response, err := server.Client().Do(r)
			if err != nil {
				t.Fatal("progressing body lost its receipt to the ordinary HTTP timeout", err)
			}
			defer response.Body.Close()
			if response.StatusCode != http.StatusNoContent {
				body, _ := io.ReadAll(response.Body)
				t.Fatalf("receipt: %d %s", response.StatusCode, body)
			}
			if err := <-written; err != nil {
				t.Fatal(err)
			}
			a, err := f.db.Attachment(ctx, f.members[0], store.DefaultRoomID, f.entries[0].EntryID, id)
			if err != nil || a.Uploaded != 1 {
				t.Fatal("receipt did not match durable progress", a, err)
			}
		})
	}
}
