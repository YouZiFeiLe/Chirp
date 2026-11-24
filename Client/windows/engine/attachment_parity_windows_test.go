package main

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func attachmentFixture(t *testing.T) *attachmentSession {
	t.Helper()
	ctx, cancel := context.WithCancel(t.Context())
	s := &attachmentSession{ctx: ctx, cancel: cancel, entry: "member_xyz.login_1.entry_a", room: "room_one", revision: "first",
		cache: t.TempDir(), media: &mediaSession{group: "initial", until: ticks() + 120000}, files: map[string]*transfer{}, notify: func(string, any) {},
		catalogWake: make(chan struct{}, 1), scheduleWake: make(chan struct{}, 1)}
	t.Cleanup(func() { cancel(); s.workers.Wait() })
	return s
}
func fixtureFile(s *attachmentSession, id int, size int64) *transfer {
	i := fileInfo{Version: 1, Room: s.room, Sender: s.entry, Name: "sample.jpg", MIME: "image/jpeg", ID: fmt.Sprintf("%032x", id), Size: size, Digest: strings.Repeat("0", 64)}
	return &transfer{session: s, entry: s.entry, base: s.base, credential: s.credential, media: s.media, d: descriptor{Info: i, Key: bytes.Repeat([]byte{3}, 32)}, group: "initial", cache: filepath.Join(s.cache, i.ID+".cipher")}
}
func fixtureRemote(v *transfer, state string, revision uint64) remoteFile {
	i := v.d.Info
	r := remoteFile{ID: i.ID, Room: i.Room, Size: i.cipherSize(), Digest: i.Digest, State: state, Revision: revision, Updated: time.Now().Unix(), Expires: time.Now().Add(time.Hour).Unix(), Protocol: 3, Chunk: fileChunk}
	if r.uploaded() {
		r.Uploaded = int((r.Size + fileChunk - 1) / fileChunk)
		r.Completed = r.Updated
	}
	return r
}

// Read a real outgoing descriptor independently of the Windows thumbnail
// functions. CryptoKit's combined box is nonce || ciphertext || tag.
func openReferenceThumbnail(t *testing.T, d descriptor) []byte {
	t.Helper()
	extract := hmac.New(sha256.New, []byte(d.Info.ID))
	extract.Write(d.Key)
	expand := hmac.New(sha256.New, extract.Sum(nil))
	expand.Write([]byte("Chirp attachment thumbnail v1"))
	expand.Write([]byte{1})
	block, err := aes.NewCipher(expand.Sum(nil))
	ok(t, err)
	gcm, err := cipher.NewGCM(block)
	ok(t, err)
	records := max(int64(1), (d.Info.Size+262143)/262144)
	aad := fmt.Sprintf("Chirp attachment AES256GCM v1\n%s\n%s\n%s\n%d\n%d\n-1\n", d.Info.Room, d.Info.Sender, d.Info.ID, d.Info.Size, records)
	if len(d.Thumbnail) < 28 {
		t.Fatal("short combined box")
	}
	plain, err := gcm.Open(nil, d.Thumbnail[:12], d.Thumbnail[12:], []byte(aad))
	ok(t, err)
	return plain
}

func TestAttachment17MacThumbnailVector(t *testing.T) {
	// Generated independently with OpenSSL via Node HKDF/AES-GCM. The literal
	// associated data matches AttachmentCrypto.aad(info,index:-1) byte for byte.
	d := descriptor{Info: fileInfo{ID: "0123456789abcdef0123456789abcdef", Room: "room_one", Sender: "member_xyz.login_1.entry_a", Size: 17}, Key: make([]byte, 32)}
	for i := range d.Key {
		d.Key[i] = byte(i)
	}
	vector, err := hex.DecodeString("000102030405060708090a0bb50b50af8565e8b9f46d2fa79e35068e7d2344bc49b742bcf71ee65574ff6100")
	ok(t, err)
	plain, err := d.thumbnail(vector, true)
	ok(t, err)
	if string(plain) != "thumbnail-vector" {
		t.Fatal("different Mac-format plaintext")
	}
	sealed, err := d.thumbnail(plain, false)
	ok(t, err)
	if len(sealed) != len(plain)+28 || bytes.Equal(sealed, vector) {
		t.Fatal("nonce or combined format")
	}
	d.Info.Size++
	if _, err = d.thumbnail(vector, true); err == nil {
		t.Fatal("accepted a thumbnail bound to another object")
	}
	if _, err = d.thumbnail(make([]byte, 6144-27), false); err == nil {
		t.Fatal("ignored encrypted thumbnail limit")
	}
}

func TestAttachment18To20LocalPreviewExportAndScope(t *testing.T) {
	s := attachmentFixture(t)
	payload := []byte("authenticated original bytes")
	v := fixtureFile(s, 1, int64(len(payload)))
	v.source = filepath.Join(t.TempDir(), "original")
	ok(t, os.WriteFile(v.source, payload, 0600))
	ok(t, s.register(v))
	ok(t, v.prepare(t.Context()))
	// Roster replacement or an expired media lease cannot erase ownership of a
	// verified local copy. The sender's own image must remain exportable.
	s.media.group = "replacement"
	s.media.until = 0
	a := args{ID: v.d.Info.ID, Entry: s.entry, Revision: s.revision, Path: filepath.Join(t.TempDir(), "saved.jpg")}
	for _, wrong := range []args{{ID: a.ID, Entry: "another", Revision: a.Revision}, {ID: a.ID, Entry: a.Entry, Revision: "cleared"}} {
		if _, err := s.command(t.Context(), "previewFile", wrong); err == nil {
			t.Fatal("stale preview")
		}
	}
	preview, err := s.command(t.Context(), "previewFile", a)
	ok(t, err)
	if !bytes.Equal(preview.(obj)["file"].([]byte), payload) {
		t.Fatal("preview changed original")
	}
	ok(t, v.download(t.Context(), a.Path))
	got, err := os.ReadFile(a.Path)
	ok(t, err)
	if !bytes.Equal(got, payload) {
		t.Fatal("exported content changed")
	}
	if err = v.download(t.Context(), a.Path); err == nil {
		t.Fatal("overwrote previous export")
	}
	s.mu.Lock()
	s.downloads = 2
	s.mu.Unlock()
	second := a
	second.Path = filepath.Join(t.TempDir(), "local.jpg")
	_, err = s.command(t.Context(), "download", second)
	ok(t, err)
	s.mu.Lock()
	done := v.jobDone
	s.mu.Unlock()
	<-done
	copy, err := os.ReadFile(second.Path)
	ok(t, err)
	if !bytes.Equal(copy, payload) || s.downloads != 2 {
		t.Fatal("exporting a local copy used a network download slot")
	}
	before, err := os.ReadDir(s.cache)
	ok(t, err)
	if len(before) != 1 || !strings.HasSuffix(before[0].Name(), ".cipher") {
		t.Fatal("plaintext in app cache")
	}
	e := engine{room: &activeRoom{}, session: &session{}}
	e.fileScope.Store(s)
	for _, wrong := range []args{{Entry: "earlier", Revision: s.revision}, {Entry: s.entry, Revision: "retired"}, {Entry: s.entry, Revision: s.revision, Group: "wrong"}} {
		if _, err = e.handle(t.Context(), command{Op: "upload", Args: wrong}); err == nil || err.Error() != "ATTACHMENT_UNAVAILABLE" {
			t.Fatalf("picker scope %v", err)
		}
	}
	v.d.Info.Size++
	if _, err = v.preview(t.Context()); err == nil {
		t.Fatal("corrupt body returned for preview")
	}
	v.d.Info.Size--
}

func TestPrepareExportRestoresMissingCacheAndKeepsIncomingActionsLocal(t *testing.T) {
	s := attachmentFixture(t)
	body := []byte("previously authenticated attachment")
	transfer := fixtureFile(s, 403, int64(len(body)))
	var sealed bytes.Buffer
	ok(t, transfer.d.transform(t.Context(), bytes.NewReader(body), &sealed, true, func() error { return nil }))
	hash := fmt.Sprintf("%x", sha256.Sum256(sealed.Bytes()))
	transfer.d.Info.Digest = hash
	var reads atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "/chunks/") {
			reads.Add(1)
			w.Header().Set("Content-Type", "application/octet-stream")
			_, _ = w.Write(sealed.Bytes())
			return
		}
		remote := fixtureRemote(transfer, "completed", 2)
		remote.Hashes = []string{hash}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(remote)
	}))
	defer server.Close()
	transfer.base = server.URL
	transfer.cached = true
	ok(t, s.register(transfer))
	a := args{ID: transfer.d.Info.ID, Entry: s.entry, Revision: s.revision}
	if _, err := s.command(t.Context(), "cancelFile", a); err == nil {
		t.Fatal("incoming file exposed sender cancellation")
	}
	if _, err := s.command(t.Context(), "pauseFile", a); err == nil {
		t.Fatal("idle download exposed pause")
	}
	e := engine{session: &session{}}
	e.fileScope.Store(s)
	for i := 0; i < 2; i++ {
		res, err := e.handle(t.Context(), command{Op: "prepareExport", Args: a})
		ok(t, err)
		if res.(obj)["revision"] != s.revision || res.(obj)["name"] != transfer.d.Info.Name {
			t.Fatal("folder picker preparation lost its admission")
		}
	}
	if reads.Load() != 1 {
		t.Fatal("missing cache was not restored exactly once", reads.Load())
	}
	got, err := os.ReadFile(transfer.cache)
	ok(t, err)
	if !bytes.Equal(got, sealed.Bytes()) {
		t.Fatal("export picker opened without authenticated ciphertext")
	}
	bad := a
	bad.Revision = "old"
	if _, err = e.handle(t.Context(), command{Op: "prepareExport", Args: bad}); err == nil {
		t.Fatal("stale picker authorized")
	}
	s.apply(fixtureRemote(transfer, "delivered", 3))
	ok(t, os.Remove(transfer.cache))
	if _, err = e.handle(t.Context(), command{Op: "prepareExport", Args: a}); err == nil || err.Error() != "ATTACHMENT_EXPIRED" || reads.Load() != 1 {
		t.Fatal("requested a discarded remote copy", err)
	}
}

func TestAttachmentExportWindowsNames(t *testing.T) {
	v := fixtureFile(attachmentFixture(t), 404, 4)
	for _, name := range []string{"line\u0085break", "line\u2028break", "line\u2029break", "two\nlines"} {
		v.d.Info.Name = name
		if v.d.valid(v.d.Info.Room, v.d.Info.Sender) {
			t.Fatalf("accepted a name containing a line break: %q", name)
		}
	}
	v.d.Info.Name = "photo:\u0081.jpeg"
	if !v.d.valid(v.d.Info.Room, v.d.Info.Sender) {
		t.Fatal("rejected a macOS-permitted attachment name")
	}
	for name, want := range map[string]string{"风景.jpeg": "风景.jpeg", "a:b?.gif ": "a_b_.gif", "CON": "_CON", " ...": "attachment", "lpt³": "_lpt³"} {
		if got := exportFilename(name); got != want || !filepath.IsLocal(got) {
			t.Fatalf("export name %q produced %q, want %q", name, got, want)
		}
	}
	for _, name := range []string{"CoN.txt", "AUX." + strings.Repeat("a", 251)} {
		got := exportFilename(name)
		if !filepath.IsLocal(got) || len(got) > 255 || filepath.IsLocal(name) && got != name {
			t.Fatalf("invalid device filename transformation %q => %q", name, got)
		}
	}
}

func TestAttachment21ReservationsAndScheduler(t *testing.T) {
	s := attachmentFixture(t)
	// Ciphertext overhead, including that of empty files, counts from admission.
	for i := 0; i < 5; i++ {
		v := fixtureFile(s, i, 100<<20)
		ok(t, s.register(v))
	}
	if err := s.register(fixtureFile(s, 5, 12<<20)); err == nil {
		t.Fatal("overcommitted cache")
	}
	v := s.file(fmt.Sprintf("%032x", 0))
	s.discard(v)
	ok(t, s.register(fixtureFile(s, 6, 12<<20)))
	for i := 0; i < 16; i++ {
		v := fixtureFile(s, 20+i, 0)
		v.source = "source"
		ok(t, s.register(v))
	}
	spare := fixtureFile(s, 40, 0)
	spare.source = "source"
	if err := s.register(spare); err == nil {
		t.Fatal("too many outstanding uploads")
	}
	v = s.file(fmt.Sprintf("%032x", 20))
	s.mu.Lock()
	s.uploading = true
	s.mu.Unlock()
	if err := s.start(v, "", false); err == nil {
		t.Fatal("second upload allowed")
	}
	incoming := s.file(fmt.Sprintf("%032x", 1))
	s.mu.Lock()
	s.downloads = 2
	s.mu.Unlock()
	if err := s.start(incoming, "", false); err == nil {
		t.Fatal("third download allowed")
	}
	s.mu.Lock()
	s.downloads = 1
	s.automatic = true
	s.enqueueLocked(incoming)
	s.enqueueLocked(incoming)
	queued := len(s.queue)
	s.mu.Unlock()
	if err := s.start(incoming, "", true); err == nil || queued != 1 {
		t.Fatal("auto-download duplicated")
	}
}

func TestAttachment21SerialAutoAndParallelManualDownload(t *testing.T) {
	s := attachmentFixture(t)
	started := make(chan string, 4)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started <- strings.TrimPrefix(r.URL.Path, "/")
		<-r.Context().Done()
	}))
	defer func() { s.cancel(); s.workers.Wait(); server.Close() }()
	s.base = server.URL
	var items []*transfer
	for n := 1; n <= 3; n++ {
		v := fixtureFile(s, n, 4)
		ok(t, s.register(v))
		items = append(items, v)
	}
	s.workers.Go(s.downloadLoop)
	for _, v := range items {
		s.apply(fixtureRemote(v, "completed", 2))
	}
	expectStart := func(id string) {
		t.Helper()
		select {
		case value := <-started:
			if value != id {
				t.Fatalf("unexpected active download %s", value)
			}
		case <-time.After(time.Second):
			t.Fatal("missing active download", id)
		}
	}
	expectStart(items[0].d.Info.ID)
	ok(t, s.start(items[2], "", false))
	expectStart(items[2].d.Info.ID)
	if err := s.start(items[1], "", false); !errors.Is(err, errTransferBusy) {
		t.Fatal("third simultaneous download allowed", err)
	}
	s.mu.Lock()
	if !s.automatic || s.downloads != 2 || items[1].running {
		s.mu.Unlock()
		t.Fatal("automatic download bypassed queue")
	}
	s.mu.Unlock()
}

func TestAttachment22TerminalCatalogAndUncertainCancel(t *testing.T) {
	s := attachmentFixture(t)
	var succeed atomic.Bool
	var v *transfer
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || !strings.HasSuffix(r.URL.Path, "/cancel") || r.Header.Get("X-Chirp-Entry") != "entry_a" {
			http.Error(w, "wrong entry", 400)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if !succeed.Load() {
			w.WriteHeader(409)
			return
		}
		_ = json.NewEncoder(w).Encode(fixtureRemote(v, "cancelled", 5))
	}))
	defer server.Close()
	s.base = server.URL
	v = fixtureFile(s, 51, 0)
	v.source = "source"
	v.reservationAttempted = true
	ok(t, s.register(v))
	a := args{Entry: s.entry, Revision: s.revision, ID: v.d.Info.ID}
	if _, err := s.command(t.Context(), "cancelFile", a); err == nil {
		t.Fatal("lost cancel reported success")
	}
	if _, err := s.command(t.Context(), "resumeFile", a); err == nil {
		t.Fatal("pending cancel allowed upload")
	}
	succeed.Store(true)
	_, err := s.command(t.Context(), "cancelFile", a)
	ok(t, err)
	s.workers.Wait()
	if s.file(a.ID) != nil {
		t.Fatal("cancelled descriptor retained")
	}
	v = fixtureFile(s, 52, 2)
	v.cached = true
	ok(t, s.register(v))
	s.apply(fixtureRemote(v, "completed", 4))
	s.apply(fixtureRemote(v, "uploading", 3))
	s.apply(fixtureRemote(v, "reserved", 5))
	if v.remoteState != "completed" || v.remoteRevision != 4 {
		t.Fatal("rolled back completed catalog")
	}
	s.apply(fixtureRemote(v, "delivered", 5))
	s.apply(fixtureRemote(v, "completed", 6))
	if !v.cached || v.remoteState != "delivered" {
		t.Fatal("delivery removed verified local copy")
	}
}

func TestAttachment22CleanupAndReceipt(t *testing.T) {
	s := attachmentFixture(t)
	var calls, bodyReads, cancels atomic.Int32
	var incoming *transfer
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Header.Get("X-Chirp-Entry") != "entry_a" {
			w.WriteHeader(400)
			return
		}
		switch {
		case strings.HasSuffix(r.URL.Path, "/received"):
			if calls.Add(1) <= 4 {
				w.WriteHeader(503)
				return
			}
			_ = json.NewEncoder(w).Encode(fixtureRemote(incoming, "delivered", 8))
		case strings.HasSuffix(r.URL.Path, "/cancel"):
			cancels.Add(1)
			w.WriteHeader(204)
		default:
			bodyReads.Add(1)
			w.WriteHeader(500)
		}
	}))
	defer server.Close()
	s.base = server.URL
	incoming = fixtureFile(s, 61, 1)
	incoming.cached = true
	ok(t, s.register(incoming))
	incoming.receipt()
	s.mu.Lock()
	done := incoming.receiptDone
	s.mu.Unlock()
	select {
	case <-done:
	case <-time.After(9 * time.Second):
		t.Fatal("receipt scheduler did not retry")
	}
	if !incoming.acknowledged || calls.Load() != 5 || bodyReads.Load() != 0 {
		t.Fatal("receipt caused redownload or was lost")
	}
	outgoing := fixtureFile(s, 62, 0)
	outgoing.source = "source"
	outgoing.reservationAttempted = true
	ok(t, s.register(outgoing))
	ok(t, os.WriteFile(outgoing.cache, []byte("sealed"), 0600))
	e := engine{}
	e.fileScope.Store(s)
	ok(t, e.closeFiles())
	if cancels.Load() != 1 || !bytes.Equal(outgoing.d.Key, make([]byte, 32)) || incoming.ctx.Err() == nil {
		t.Fatal("cleanup missed reservation or key")
	}
	if _, err := os.Stat(outgoing.cache); !os.IsNotExist(err) {
		t.Fatal("cache survived clear")
	}
}

func TestAttachment22ClearOrphanedCacheOutsideRoom(t *testing.T) {
	e := engine{cache: t.TempDir(), session: &session{}}
	path := filepath.Join(e.cache, "leftover.cipher")
	ok(t, os.WriteFile(path, []byte("ciphertext"), 0600))
	if _, err := e.handle(t.Context(), command{Op: "clearCache", Args: args{Entry: "previous", Revision: "retired"}}); err == nil {
		t.Fatal("stale room cleared cache")
	}
	_, err := e.handle(t.Context(), command{Op: "clearCache"})
	ok(t, err)
	if _, err = os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("orphaned ciphertext retained")
	}
}

func TestAttachment22CatalogEventsRevokeAndReconnect(t *testing.T) {
	s := attachmentFixture(t)
	v := fixtureFile(s, 66, 1)
	ok(t, s.register(v))
	var streams atomic.Int32
	hints := make(chan string, 2)
	state := make(chan string, 8)
	s.notify = func(name string, data any) {
		if name == "transfer" {
			select {
			case state <- data.(obj)["state"].(string):
			default:
			}
		}
	}
	var revision atomic.Uint64
	revision.Store(1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Chirp-Entry") != "entry_a" {
			w.WriteHeader(400)
			return
		}
		if r.URL.Path == "/events" {
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprint(w, "event: state\ndata: {\"room_id\":\"room_one\",\"server_id\":\"server\",\"revision\":1}\n\n")
			w.(http.Flusher).Flush()
			if streams.Add(1) == 1 {
				return
			}
			for {
				select {
				case <-r.Context().Done():
					return
				case event := <-hints:
					fmt.Fprint(w, event)
					w.(http.Flusher).Flush()
				}
			}
		}
		rev := revision.Load()
		phase := "reserved"
		if rev > 1 {
			phase = "completed"
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(fileCatalog{fileHint: fileHint{"server", s.room, rev}, Files: []remoteFile{fixtureRemote(v, phase, rev)}})
	}))
	defer func() { s.cancel(); s.workers.Wait(); server.Close() }()
	s.base = server.URL
	s.workers.Go(s.watch)
	s.workers.Go(s.catalogLoop)
	next := func(expect string) {
		t.Helper()
		timeout := time.After(3 * time.Second)
		for {
			select {
			case got := <-state:
				if got == expect {
					return
				}
			case <-timeout:
				t.Fatalf("catalog did not reach %s", expect)
			}
		}
	}
	next("reserved")
	revision.Store(2)
	hints <- "event: state\ndata: {\"room_id\":\"room_one\",\"server_id\":\"server\",\"revision\":2}\n\n"
	next("completed")
	hints <- "event: revoked\ndata: {}\n\n"
	select {
	case <-s.ctx.Done():
	case <-time.After(3 * time.Second):
		t.Fatal("SSE revocation retained entry")
	}
	if streams.Load() < 2 {
		t.Fatal("event stream did not reconnect")
	}
}

func TestAttachment23ImmutableSealing(t *testing.T) {
	s := attachmentFixture(t)
	v := fixtureFile(s, 70, 4)
	v.source = filepath.Join(t.TempDir(), "input")
	ok(t, s.register(v))
	ok(t, os.WriteFile(v.source, []byte("old!"), 0600))
	ok(t, v.prepare(t.Context()))
	digest := v.d.Info.Digest
	ok(t, os.WriteFile(v.source, []byte("new!"), 0600))
	ok(t, v.prepare(t.Context()))
	var out bytes.Buffer
	ok(t, v.decrypt(t.Context(), &out))
	if out.String() != "old!" || v.d.Info.Digest != digest {
		t.Fatal("sealed source reopened")
	}
	bad := fixtureFile(s, 71, 4)
	bad.source = filepath.Join(t.TempDir(), "short")
	ok(t, s.register(bad))
	ok(t, os.WriteFile(bad.source, []byte("x"), 0600))
	if err := bad.prepare(t.Context()); err == nil {
		t.Fatal("short source accepted")
	}
	ok(t, os.WriteFile(bad.source, []byte("new!"), 0600))
	if err := bad.prepare(t.Context()); err == nil {
		t.Fatal("key reused after failed preparation")
	}
}

func TestAttachment24RetryAfterAndCancellation(t *testing.T) {
	begin := time.Now()
	attempts := 0
	err := retryAttachment(t.Context(), func(context.Context) error {
		attempts++
		if attempts == 1 {
			return &apiError{code: "RATE_LIMITED", status: 429, retryAfter: 450 * time.Millisecond}
		}
		return nil
	})
	ok(t, err)
	if attempts != 2 || time.Since(begin) < 450*time.Millisecond {
		t.Fatal("Retry-After ignored")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 80*time.Millisecond)
	defer cancel()
	attempts = 0
	err = retryAttachment(ctx, func(context.Context) error {
		attempts++
		return &apiError{code: "BUSY", status: 503, retryAfter: time.Second}
	})
	if err == nil || attempts != 1 {
		t.Fatal("retry exceeded deadline")
	}
	if retryableAttachment(errors.New("ATTACHMENT_INTEGRITY")) {
		t.Fatal("retried integrity error")
	}
}

func TestAttachment24InterruptedHTTPBodyRetries(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if calls.Add(1) == 1 {
			w.Header().Set("Content-Length", "200")
			fmt.Fprint(w, "{")
			return
		}
		fmt.Fprint(w, `{"ok":true}`)
	}))
	defer server.Close()
	var out struct{ OK bool }
	err := retryAttachment(t.Context(), func(ctx context.Context) error {
		_, err := request(ctx, "request", "GET", server.URL, nil, "", nil, &out, 400)
		return err
	})
	ok(t, err)
	if !out.OK || calls.Load() != 2 {
		t.Fatal("truncated response did not recover")
	}
}

func TestAttachment21AdmissionBounds(t *testing.T) {
	s := attachmentFixture(t)
	for i := 0; i < 1000; i++ {
		ok(t, s.register(fixtureFile(s, i, 0)))
	}
	if err := s.register(fixtureFile(s, 1001, 0)); err == nil {
		t.Fatal("retained more than 1000 file keys")
	}
	first := s.file(fmt.Sprintf("%032x", 0))
	s.discard(first)
	if err := s.register(fixtureFile(s, 0, 0)); !errors.Is(err, errDuplicateFile) {
		t.Fatal("retired descriptor resurrected")
	}
	if err := s.register(fixtureFile(s, 1001, 0)); err == nil {
		t.Fatal("terminal metadata bypassed entry limit")
	}
	if s.reserved != 999*int64(16) {
		t.Fatal("incorrect charge for empty records")
	}
}

func TestAttachment18FileIntegrityBeforePublication(t *testing.T) {
	s := attachmentFixture(t)
	v := fixtureFile(s, 82, 6)
	v.source = filepath.Join(t.TempDir(), "original")
	ok(t, s.register(v))
	ok(t, os.WriteFile(v.source, []byte("source"), 0600))
	ok(t, v.prepare(t.Context()))
	sealed, err := os.ReadFile(v.cache)
	ok(t, err)
	sealed[2] ^= 1
	ok(t, os.WriteFile(v.cache, sealed, 0600))
	v.d.Info.Digest = fmt.Sprintf("%x", sha256.Sum256(sealed))
	path := filepath.Join(t.TempDir(), "corrupt.jpg")
	if err = v.download(t.Context(), path); !errors.Is(err, errAttachmentIntegrity) || retryableAttachment(err) {
		t.Fatal("damaged record did not report an integrity failure", err)
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	ok(t, err)
	if len(entries) != 0 {
		t.Fatal("plaintext left after failed export")
	}
}

func TestAttachmentIntegrityResponseClassification(t *testing.T) {
	s := attachmentFixture(t)
	v := fixtureFile(s, 405, 8)
	ok(t, s.register(v))
	body := bytes.Repeat([]byte{1}, int(v.d.Info.cipherSize()))
	v.d.Info.Digest = fmt.Sprintf("%x", sha256.Sum256(body))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mode := strings.Split(r.URL.Path, "/")[1]
		w.Header().Set("Content-Type", "application/octet-stream")
		switch mode {
		case "short":
			_, _ = w.Write(body[:2])
		case "long":
			_, _ = w.Write(body)
		case "body-ended":
			w.Header().Set("Content-Length", "3")
			_, _ = w.Write(body[:2])
		case "wrong-type":
			w.Header().Set("Content-Type", "text/plain")
			_, _ = w.Write(body[:3])
		case "forbidden":
			w.WriteHeader(http.StatusForbidden)
		case "wrong-key":
			if strings.Contains(r.URL.Path, "/chunks/") {
				_, _ = w.Write(body)
				return
			}
			remote := fixtureRemote(v, "completed", 1)
			remote.Hashes = []string{v.d.Info.Digest}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(remote)
		}
	}))
	defer server.Close()
	for path, want := range map[string]error{"short": errAttachmentIntegrity, "long": errAttachmentIntegrity, "body-ended": io.ErrUnexpectedEOF, "wrong-type": invalid} {
		v.base = server.URL + "/" + path
		_, err := v.chunk(t.Context(), 0, 3)
		if !errors.Is(err, want) || retryableAttachment(err) != (path == "body-ended") {
			t.Fatalf("%s: got %v, want %v", path, err, want)
		}
	}
	v.base = server.URL + "/forbidden"
	_, err := v.chunk(t.Context(), 0, 3)
	var status *apiError
	if !errors.As(err, &status) || status.status != 403 {
		t.Fatal("lost authorization failure", err)
	}
	v.base = server.URL + "/wrong-key"
	e := engine{session: &session{}}
	e.fileScope.Store(s)
	_, err = e.handle(t.Context(), command{Op: "prepareExport", Args: args{ID: v.d.Info.ID, Entry: s.entry, Revision: s.revision}})
	if err == nil || err.Error() != "ATTACHMENT_INTEGRITY" || retryableAttachment(err) {
		t.Fatal("transfer accepted an invalid AEAD record with a matching file and chunk hash", err)
	}
	if _, err := os.Stat(v.cache); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("unauthenticated ciphertext was retained", err)
	}
}
