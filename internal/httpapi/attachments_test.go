package httpapi

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/config"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testfs"
)

func TestAttachmentCiphertextTransportAdmissionAndReentry(t *testing.T) {
	ctx := context.Background()
	db, err := store.Open(ctx, testdb.Path(t))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	a, at, _ := db.AddMember(ctx, "a")
	b, bt, _ := db.AddMember(ctx, "b")
	c, ct, _ := db.AddMember(ctx, "late")
	aa, _ := db.JoinRoom(ctx, a, "friends", 1, 0)
	ba, _ := db.JoinRoom(ctx, b, "friends", 1, 0)
	root := t.TempDir()
	files, err := NewAttachmentStorage(db, root)
	if err != nil {
		t.Fatal(err)
	}
	defer files.Close()
	_, disconnect := files.feed.register(ba.Identity())
	defer disconnect()
	h := NewWithAttachments(db, &fakeMedia{}, room.Issuer{}, "wss://example.test", "https://example.test", slog.New(slog.NewTextHandler(io.Discard, nil)), config.DefaultClientEndpoints("https://example.test"), files, nil)
	request := func(method, path, token, entry string, body []byte, want int) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(method, path, bytes.NewReader(body))
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("X-Chirp-Entry", entry)
		if method == "PUT" {
			r.Header.Set("Content-Type", "application/octet-stream")
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("%s %s: %d want %d: %s", method, path, w.Code, want, w.Body.String())
		}
		if w.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("ciphertext response can be cached")
		}
		return w
	}
	id := strings.Repeat("a", 32)
	base := "/v1/rooms/friends/attachments/" + id
	chunk := bytes.Repeat([]byte{0xab}, int(store.AttachmentChunkBytes))
	digest := sha256.Sum256(append(append([]byte{}, chunk...), make([]byte, 32)...))
	body, _ := json.Marshal(map[string]any{"ciphertext_sha256": hex.EncodeToString(digest[:]), "id": id, "entry_id": aa.EntryID, "ciphertext_size": store.AttachmentChunkBytes + 32, "recipients": []string{aa.Identity(), ba.Identity()}})
	request("POST", "/v1/rooms/friends/attachments", at, aa.EntryID, body, 201)
	request("GET", base+"/chunks/0", bt, ba.EntryID, nil, 409)
	request("PUT", base+"/chunks/1", at, aa.EntryID, make([]byte, 32), 409)
	request("PUT", base+"/chunks/0", bt, ba.EntryID, make([]byte, store.AttachmentChunkBytes), 404)
	request("PUT", base+"/chunks/0", at, aa.EntryID, make([]byte, 31), 400)
	request("PUT", base+"/chunks/0", at, aa.EntryID, chunk, 204)
	request("PUT", base+"/chunks/0", at, aa.EntryID, chunk, 204)
	request("PUT", base+"/chunks/0", at, aa.EntryID, make([]byte, len(chunk)), 409)
	request("PUT", base+"/chunks/1", at, aa.EntryID, make([]byte, 32), 204)
	request("GET", base+"/chunks/0", bt, ba.EntryID, nil, 409)
	request("POST", base+"/complete", at, aa.EntryID, nil, 200)
	if got := request("GET", base+"/chunks/0", bt, ba.EntryID, nil, 200).Body.Bytes(); !bytes.Equal(got, chunk) {
		t.Fatal("ciphertext changed")
	}
	var concurrent sync.WaitGroup
	for range 8 {
		concurrent.Go(func() {
			r := httptest.NewRequest("GET", base+"/chunks/0", nil)
			r.Header.Set("Authorization", "Bearer "+bt)
			r.Header.Set("X-Chirp-Entry", ba.EntryID)
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != 200 || !bytes.Equal(w.Body.Bytes(), chunk) {
				t.Errorf("parallel download rejected or corrupted: %d", w.Code)
			}
		})
	}
	concurrent.Wait()
	ca, _ := db.JoinRoom(ctx, c, "friends", 1, 0)
	request("GET", base, ct, ca.EntryID, nil, 404)
	request("GET", "/v1/rooms/other/attachments/"+id, bt, ba.EntryID, nil, 404)
	if err = db.LeaveRoom(ctx, a, "friends", aa.EntryID); err != nil {
		t.Fatal(err)
	}
	if err = files.Reap(ctx); err != nil {
		t.Fatal(err)
	}
	request("GET", base+"/chunks/0", bt, ba.EntryID, nil, 200)
	request("GET", base, at, aa.EntryID, nil, 404)
	if err = db.LeaveRoom(ctx, b, "friends", ba.EntryID); err != nil {
		t.Fatal(err)
	}
	newB, _ := db.JoinRoom(ctx, b, "friends", 2, 0)
	request("GET", base, bt, newB.EntryID, nil, 404)
	if err = files.Reap(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(filepath.Join(root, id)); !os.IsNotExist(err) {
		t.Fatal("orphan ciphertext not removed", err)
	}
}

type attachmentRevokingReader struct {
	data   *bytes.Reader
	revoke func()
	once   bool
}

func (r *attachmentRevokingReader) Read(p []byte) (int, error) {
	if !r.once {
		r.once = true
		r.revoke()
	}
	return r.data.Read(p)
}

func TestAttachmentRevocationDuringChunkAndOrphanRecovery(t *testing.T) {
	ctx := context.Background()
	db, err := store.Open(ctx, testdb.Path(t))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	m, token, _ := db.AddMember(ctx, "owner")
	a, _ := db.JoinRoom(ctx, m, "friends", 1, 0)
	root := t.TempDir()
	files, err := NewAttachmentStorage(db, root)
	if err != nil {
		t.Fatal(err)
	}
	h := NewWithAttachments(db, &fakeMedia{}, room.Issuer{}, "wss://example.test", "https://example.test", slog.New(slog.NewTextHandler(io.Discard, nil)), config.DefaultClientEndpoints("https://example.test"), files, nil)
	id := strings.Repeat("b", 32)
	_, err = db.CreateAttachment(ctx, m, "friends", a.EntryID, id, 32, strings.Repeat("0", 64), nil)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.Mkdir(filepath.Join(root, id), 0700); err != nil {
		t.Fatal(err)
	}
	body := &attachmentRevokingReader{data: bytes.NewReader(make([]byte, 32)), revoke: func() {
		if err := db.LeaveRoom(ctx, m, "friends", a.EntryID); err != nil {
			t.Error(err)
		}
	}}
	r := httptest.NewRequest("PUT", "/v1/rooms/friends/attachments/"+id+"/chunks/0", body)
	r.ContentLength = 32
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Content-Type", "application/octet-stream")
	r.Header.Set("X-Chirp-Entry", a.EntryID)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 404 {
		t.Fatal("upload committed after leave", w.Code, w.Body.String())
	}
	if _, err = os.Stat(filepath.Join(root, id, "ciphertext")); !os.IsNotExist(err) {
		t.Fatal("revoked upload finalized", err)
	}
	files.Close()
	if err = os.Mkdir(filepath.Join(root, "crashed-upload"), 0700); err != nil {
		t.Fatal(err)
	}
	files, err = NewAttachmentStorage(db, root)
	if err != nil {
		t.Fatal(err)
	}
	defer files.Close()
	entries, _ := os.ReadDir(root)
	if len(entries) != 0 {
		t.Fatal("startup left orphan files", entries)
	}
}

func TestAttachmentStoragePreservesProtectedAuthorizationFiles(t *testing.T) {
	for _, name := range []string{"authorization.db", "authorization-key"} {
		for _, alias := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/alias=%t", name, alias), func(t *testing.T) {
				db, err := store.Open(t.Context(), testdb.Path(t))
				if err != nil {
					t.Fatal(err)
				}
				defer db.Close()
				directory := t.TempDir()
				path := filepath.Join(directory, name)
				original := []byte("protected authorization state")
				if err := os.WriteFile(path, original, 0600); err != nil {
					t.Fatal(err)
				}
				if alias {
					link := filepath.Join(t.TempDir(), "alias")
					testfs.Symlink(t, directory, link)
					path = filepath.Join(link, name)
				}
				files, err := NewAttachmentStorage(db, directory, path)
				if err == nil {
					files.Close()
					t.Fatal("attachment GC accepted authorization state")
				}
				preserved, err := os.ReadFile(path)
				if err != nil || !bytes.Equal(preserved, original) {
					t.Fatal("attachment GC damaged authorization state", err)
				}
			})
		}
	}
}

func TestAttachmentStorageRejectsDirectoryContainingDatabase(t *testing.T) {
	for _, alias := range []bool{false, true} {
		t.Run(map[bool]string{false: "direct", true: "parent symlink"}[alias], func(t *testing.T) {
			ctx := context.Background()
			root := t.TempDir()
			path := filepath.Join(root, "database", "chirp.db")
			db, err := store.Open(ctx, path)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			member, credential, err := db.AddMember(ctx, "preserved")
			if err != nil {
				t.Fatal(err)
			}
			admission, err := db.JoinRoom(ctx, member, store.DefaultRoomID, 1, 0)
			if err != nil {
				t.Fatal(err)
			}
			attachment, err := db.CreateAttachment(ctx, member, admission.RoomID, admission.EntryID, strings.Repeat("c", 32), 32, strings.Repeat("0", 64), nil)
			if err != nil {
				t.Fatal(err)
			}
			directory := root
			if alias {
				link := filepath.Join(t.TempDir(), "alias")
				testfs.Symlink(t, root, link)
				// The final component is a directory, with a symlink in its parent.
				directory = filepath.Join(link, "database")
			}
			files, err := NewAttachmentStorage(db, directory)
			if err == nil {
				files.Close()
				t.Fatal("attachment GC accepted a directory containing the SQLite database")
			}
			if _, err := os.Stat(path); err != nil {
				t.Fatal("storage validation removed the database", err)
			}
			if got, err := db.MemberByCredential(ctx, credential); err != nil || got.ID != member.ID {
				t.Fatal("storage validation damaged the database", got, err)
			}
			if got, err := db.Attachment(ctx, member, admission.RoomID, admission.EntryID, attachment.ID); err != nil || got.State != store.AttachmentReserved {
				t.Fatal("storage validation changed an existing transfer", got, err)
			}
		})
	}
}
