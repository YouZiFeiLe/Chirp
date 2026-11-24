package main

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"image/jpeg"
	"io"
	"mime"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/windows"
)

const fileRecord = 256 * 1024
const fileChunk = 1024 * 1024

var fileID = regexp.MustCompile(`^[0-9a-f]{32}$`)
var hashID = regexp.MustCompile(`^[0-9a-f]{64}$`)
var errAttachmentInvalid = errors.New("ATTACHMENT_INVALID")
var errAttachmentIntegrity = errors.New("ATTACHMENT_INTEGRITY")

type fileInfo struct {
	Version   int    `json:"version"`
	ID        string `json:"id"`
	Room      string `json:"roomID"`
	Sender    string `json:"sender"`
	Name      string `json:"name"`
	MIME      string `json:"mimeType"`
	Size      int64  `json:"size"`
	Digest    string `json:"digest"`
	Thumbnail bool   `json:"hasThumbnail"`
}
type descriptor struct {
	Info      fileInfo `json:"info"`
	Key       []byte   `json:"key"`
	Thumbnail []byte   `json:"thumbnail,omitempty"`
}

func (i fileInfo) records() int64    { return max(1, (i.Size+fileRecord-1)/fileRecord) }
func (i fileInfo) cipherSize() int64 { return i.Size + 16*i.records() }
func (d *descriptor) valid(room, sender string) bool {
	i := d.Info
	nameInvalid := strings.ContainsFunc(i.Name, func(r rune) bool {
		return r < ' ' || r == '\x7f' || r == '/' || r == '\\' || r == '\u0085' || r == '\u2028' || r == '\u2029'
	})
	return i.Version == 1 && fileID.MatchString(i.ID) &&
		i.Room == room && len(room) > 0 && len(room) <= 80 && i.Sender == sender && len(sender) <= 256 &&
		len(strings.FieldsFunc(sender, func(r rune) bool { return r == '.' })) == 3 &&
		len(i.Name) > 0 && len(i.Name) <= 255 && i.Name != "." && i.Name != ".." && !nameInvalid &&
		len(i.MIME) <= 100 && i.Size >= 0 && i.Size <= 100<<20 && (!i.isImage() || i.Size <= 20<<20) &&
		hashID.MatchString(i.Digest) && len(d.Key) == 32 && len(d.Thumbnail) <= 6144 && i.Thumbnail == (d.Thumbnail != nil)
}
func (d *descriptor) transform(ctx context.Context, in io.Reader, out io.Writer, encrypt bool, check func() error) (resultErr error) {
	span := installationLog.begin()
	defer func() {
		name := "attachmentDecrypt"
		if encrypt {
			name = "attachmentEncrypt"
		}
		installationLog.finish(span, logOp{"crypto", name}, resultErr, 0)
	}()
	block, err := aes.NewCipher(d.Key)
	if err != nil {
		return err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return err
	}
	i := d.Info
	for n := int64(0); n < i.records(); n++ {
		if err = ctx.Err(); err != nil {
			return err
		}
		if err = check(); err != nil {
			return err
		}
		count := min(int64(fileRecord), i.Size-n*fileRecord)
		if !encrypt {
			count += 16
		}
		buf := make([]byte, count)
		if _, err = io.ReadFull(in, buf); err != nil {
			clear(buf)
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				if encrypt {
					return errAttachmentInvalid
				}
				return errAttachmentIntegrity
			}
			return err
		}
		var nonce [12]byte
		binary.BigEndian.PutUint64(nonce[4:], uint64(n))
		aad := i.aad(n)
		var result []byte
		if encrypt {
			result = aead.Seal(nil, nonce[:], buf, aad)
		} else {
			result, err = aead.Open(nil, nonce[:], buf, aad)
			if err != nil {
				clear(buf)
				return errAttachmentIntegrity
			}
		}
		clear(buf)
		_, err = out.Write(result)
		clear(result)
		if err != nil {
			return err
		}
	}
	var extra [1]byte
	n, err := in.Read(extra[:])
	if err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	if n != 0 || err == nil {
		if encrypt {
			return errAttachmentInvalid
		}
		return errAttachmentIntegrity
	}
	return nil
}

func (i fileInfo) aad(index int64) []byte {
	return fmt.Appendf(nil, "Chirp attachment AES256GCM v1\n%s\n%s\n%s\n%d\n%d\n%d\n", i.Room, i.Sender, i.ID, i.Size, i.records(), index)
}

func (i fileInfo) isImage() bool {
	switch i.MIME {
	case "image/jpeg", "image/png", "image/webp", "image/gif", "image/heic", "image/heif":
		return true
	}
	return false
}

func (d descriptor) thumbnail(data []byte, decrypt bool) (result []byte, resultErr error) {
	span := installationLog.begin()
	defer func() {
		name := "thumbnailEncrypt"
		if decrypt {
			name = "thumbnailDecrypt"
		}
		installationLog.finish(span, logOp{"crypto", name}, resultErr, 0)
	}()
	key, err := hkdf.Key(sha256.New, d.Key, []byte(d.Info.ID), "Chirp attachment thumbnail v1", 32)
	if err != nil {
		return nil, err
	}
	defer clear(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	overhead := aead.NonceSize() + aead.Overhead()
	if decrypt {
		if len(data) < overhead || len(data) > 6144 {
			return nil, errAttachmentIntegrity
		}
		plain, err := aead.Open(nil, data[:aead.NonceSize()], data[aead.NonceSize():], d.Info.aad(-1))
		if err != nil {
			return nil, errAttachmentIntegrity
		}
		return plain, nil
	}
	if len(data) == 0 || len(data) > 6144-overhead {
		return nil, errAttachmentInvalid
	}
	nonce := random(aead.NonceSize())
	return aead.Seal(nonce, nonce, data, d.Info.aad(-1)), nil
}

type transfer struct {
	eventNumber                                                                         uint64
	progressPercent                                                                     int
	lastError, operation                                                                string
	retryable                                                                           bool
	networkPolicy                                                                       string
	session                                                                             *attachmentSession
	d                                                                                   descriptor
	group, base, entry, credential, cache, source                                       string
	media                                                                               *mediaSession
	recipients                                                                          []string
	ctx                                                                                 context.Context
	retire                                                                              context.CancelFunc
	keyMu, controlMu                                                                    sync.Mutex
	exportPending                                                                       bool
	cancel                                                                              context.CancelFunc
	jobDone, receiptDone                                                                chan struct{}
	running, completed, terminal, cancelling, paused, discarding, cached, acknowledged  bool
	preparationStarted, prepared, reservationAttempted, announced, publicationAttempted bool
	remoteRevision                                                                      uint64
	remoteState                                                                         string
}

func (t *transfer) currentGroup() error {
	if err := t.ctx.Err(); err != nil {
		return err
	}
	m := t.media
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed || m.group != t.group || ticks() >= m.until {
		return errors.New("CONTENT_PAUSED")
	}
	keys := m.slots[m.index].keys
	if keys[t.entry] == nil || len(keys) != len(t.recipients)+1 {
		return errors.New("GROUP_STATE_CHANGED")
	}
	for _, peer := range t.recipients {
		if keys[peer] == nil {
			return errors.New("GROUP_STATE_CHANGED")
		}
	}
	return nil
}

func attachmentMIME(path string) string {
	ext := strings.ToLower(filepath.Ext(path))
	switch ext {
	case ".jpeg", ".jpg", ".jpe", ".jfif", ".pjpeg", ".pjp":
		return "image/jpeg"
	case ".hif":
		return "image/heif"
	case ".png", ".gif", ".webp", ".heif", ".heic":
		return "image/" + ext[1:]
	}
	if typ := strings.Split(mime.TypeByExtension(ext), ";")[0]; typ != "" {
		return typ
	}
	return "application/octet-stream"
}

// Preserve the sender's filename unless it cannot be saved on this Windows system.
func exportFilename(name string) string {
	name = strings.Map(func(r rune) rune {
		if r < 32 || strings.ContainsRune("<>:\"/\\|?*", r) {
			return '_'
		}
		return r
	}, name)
	name = strings.TrimRight(name, " .")
	if name == "" {
		return "attachment"
	}
	if !filepath.IsLocal(name) {
		// Reserved DOS device names start with an ASCII letter. Keep the
		// protocol's maximum filename length if an extension filled it.
		if len(name) == 255 {
			name = name[1:]
		}
		return "_" + name
	}
	return name
}

func (e *engine) upload(ctx context.Context, path string, thumbnail []byte) (any, error) {
	r, s := e.room, e.fileScope.Load()
	if r == nil || s == nil || !r.media.ready() || ctx.Err() != nil {
		return nil, invalid
	}
	stat, err := os.Stat(path)
	if err != nil || !stat.Mode().IsRegular() || stat.Size() > 100<<20 {
		return nil, invalid
	}
	id := hex.EncodeToString(random(16))
	d := descriptor{Info: fileInfo{Version: 1, ID: id, Room: r.join.Room, Sender: r.join.Identity, Name: filepath.Base(path), MIME: attachmentMIME(path), Size: stat.Size(), Digest: strings.Repeat("0", 64)}, Key: random(32)}
	if d.Info.isImage() {
		config, err := jpeg.DecodeConfig(bytes.NewReader(thumbnail))
		if err != nil || config.Width <= 0 || config.Height <= 0 || max(config.Width, config.Height) > 256 {
			return nil, errAttachmentInvalid
		}
		d.Thumbnail, err = d.thumbnail(thumbnail, false)
		if err != nil {
			return nil, err
		}
		d.Info.Thumbnail = true
	}
	if !d.valid(r.join.Room, r.join.Identity) {
		return nil, errAttachmentInvalid
	}
	d.Info.Digest = ""
	t := e.transferFor(r, d)
	t.source = path
	for _, p := range r.snap.Members {
		if p.Identity != r.join.Identity {
			t.recipients = append(t.recipients, p.Identity)
		}
	}
	slices.Sort(t.recipients)
	if len(t.recipients) == 0 {
		return nil, errors.New("ATTACHMENT_NO_RECIPIENTS")
	}
	if err = s.register(t); err != nil {
		clear(d.Key)
		return nil, err
	}
	if err = s.start(t, "", false); err != nil {
		s.discard(t)
		return nil, err
	}
	return obj{"id": id, "entry": s.entry, "revision": s.revision}, nil
}

// Seal a newly selected file at most once. Network retries below only read the
// sealed file whose digest and recipient list were fixed on the first attempt.
func (t *transfer) prepare(ctx context.Context) error {
	s := t.session
	s.mu.Lock()
	if t.prepared {
		s.mu.Unlock()
		return nil
	}
	if t.preparationStarted {
		s.mu.Unlock()
		return errors.New("ATTACHMENT_PREPARATION_FAILED")
	}
	t.preparationStarted = true
	d := t.d
	s.mu.Unlock()
	src, err := os.Open(t.source)
	if err != nil {
		return err
	}
	defer src.Close()
	f, err := os.OpenFile(t.cache, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	hash := sha256.New()
	if err = d.transform(ctx, src, io.MultiWriter(f, hash), true, t.ctx.Err); err != nil {
		return err
	}
	if err = f.Sync(); err != nil {
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	d.Info.Digest = hex.EncodeToString(hash.Sum(nil))
	if !d.valid(d.Info.Room, t.entry) {
		return errAttachmentInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err = t.ctx.Err(); err != nil {
		return err
	}
	t.d.Info.Digest = d.Info.Digest
	t.prepared, t.cached = true, true
	return nil
}

func (t *transfer) publish(ctx context.Context, d descriptor) error {
	s := t.session
	s.mu.Lock()
	if t.announced {
		s.mu.Unlock()
		return nil
	}
	if t.publicationAttempted {
		s.mu.Unlock()
		return errors.New("ATTACHMENT_PUBLICATION_UNKNOWN")
	}
	t.reservationAttempted = true
	s.mu.Unlock()
	var remote remoteFile
	err := retryAttachment(ctx, func(ctx context.Context) error {
		if err := t.currentGroup(); err != nil {
			return err
		}
		return t.request(ctx, "POST", "", obj{"id": d.Info.ID, "entry_id": admissionEntry(t.entry), "ciphertext_size": d.Info.cipherSize(), "ciphertext_sha256": d.Info.Digest, "recipients": t.recipients}, &remote)
	})
	if err != nil {
		return err
	}
	if !t.matches(remote) {
		return invalid
	}
	for {
		if err = ctx.Err(); err != nil {
			return err
		}
		if err = t.currentGroup(); err != nil {
			return err
		}
		s.mu.Lock()
		t.publicationAttempted = true
		s.mu.Unlock()
		err = t.media.sendFileContext(ctx, t.group, &d)
		if err == nil {
			s.mu.Lock()
			t.announced = true
			s.mu.Unlock()
			return nil
		}
		if !errors.Is(err, errChatBusy) {
			return err
		}
		// sendFile reports busy only before any recipient batch is submitted.
		s.mu.Lock()
		t.publicationAttempted = false
		s.mu.Unlock()
		if err = waitAttachment(ctx, 30*time.Millisecond); err != nil {
			return err
		}
	}
}

func (t *transfer) upload(ctx context.Context) error {
	if err := t.prepare(ctx); err != nil {
		return err
	}
	d := t.d
	if err := t.publish(ctx, d); err != nil {
		return err
	}
	id := "/" + d.Info.ID
	var remote remoteFile
	if err := t.api(ctx, "GET", id, nil, &remote); err != nil {
		return err
	}
	if !t.matches(remote) {
		return invalid
	}
	if remote.uploaded() {
		return nil
	}
	f, err := os.Open(t.cache)
	if err != nil {
		return err
	}
	defer f.Close()
	count := int((d.Info.cipherSize() + fileChunk - 1) / fileChunk)
	if remote.Uploaded < 0 || remote.Uploaded > count || len(remote.Hashes) != remote.Uploaded {
		return invalid
	}
	hash := sha256.New()
	for n := 0; n < count; n++ {
		size := min(int64(fileChunk), d.Info.cipherSize()-int64(n)*fileChunk)
		buf := make([]byte, size)
		if _, err = io.ReadFull(f, buf); err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return errAttachmentIntegrity
			}
			return err
		}
		hash.Write(buf)
		if n < remote.Uploaded {
			if fmt.Sprintf("%x", sha256.Sum256(buf)) != remote.Hashes[n] {
				return errAttachmentIntegrity
			}
			continue
		}
		if err = retryAttachment(ctx, func(ctx context.Context) error {
			if err := t.budget(ctx, size, 0); err != nil {
				return err
			}
			return t.request(ctx, "PUT", fmt.Sprintf("%s/chunks/%d", id, n), buf, nil)
		}); err != nil {
			return err
		}
		t.progress(n+1, count)
	}
	if hex.EncodeToString(hash.Sum(nil)) != d.Info.Digest {
		return errAttachmentIntegrity
	}
	if err = t.api(ctx, "POST", id+"/complete", nil, &remote); err != nil {
		return err
	}
	if !t.matches(remote) || !remote.uploaded() {
		return invalid
	}
	t.session.apply(remote)
	return nil
}

func (t *transfer) progress(n, count int) {
	s := t.session
	s.mu.Lock()
	if t.terminal || t.cancelling || t.paused {
		s.mu.Unlock()
		return
	}
	t.progressPercent = n * 100 / count
	data := t.eventLocked()
	s.mu.Unlock()
	s.report("transfer", data)
}

func (t *transfer) hasCachedFile() bool {
	s := t.session
	s.mu.Lock()
	cached := t.cached
	size := t.d.Info.cipherSize()
	s.mu.Unlock()
	if !cached {
		return false
	}
	stat, err := os.Stat(t.cache)
	if err == nil && stat.Mode().IsRegular() && stat.Size() == size {
		return true
	}
	s.mu.Lock()
	if !t.cached {
		s.mu.Unlock()
		return false
	}
	t.cached = false
	data := t.eventLocked()
	s.mu.Unlock()
	s.report("transfer", data)
	return false
}
func (t *transfer) download(ctx context.Context, dest string) error {
	s := t.session
	if !t.hasCachedFile() {
		s.mu.Lock()
		pending := t.source != "" && !t.completed
		expired := t.remoteState == "delivered" || t.remoteState == "expired" || t.terminal
		s.mu.Unlock()
		if expired {
			return errors.New("ATTACHMENT_EXPIRED")
		}
		if pending {
			return errors.New("ATTACHMENT_PENDING")
		}
		if err := t.fetch(ctx); err != nil {
			return err
		}
		if err := t.decrypt(ctx, io.Discard); err != nil {
			if errors.Is(err, errAttachmentIntegrity) {
				_ = os.Remove(t.cache)
			}
			return err
		}
		s.mu.Lock()
		t.cached = true
		s.mu.Unlock()
	}
	t.receipt()
	if dest == "" {
		return nil
	}
	tmp, err := os.CreateTemp(filepath.Dir(dest), ".chirp-export-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	defer tmp.Close()
	if err = t.decrypt(ctx, tmp); err != nil {
		return err
	}
	if err = tmp.Sync(); err != nil {
		return err
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err = ctx.Err(); err != nil {
		return err
	}
	if err = t.ctx.Err(); err != nil {
		return err
	}
	// MoveFile on Windows fails if the destination already exists. The temp
	// file lives on the chosen volume, including volumes without hard links.
	sourceName, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return err
	}
	destinationName, err := windows.UTF16PtrFromString(dest)
	if err != nil {
		return err
	}
	return windows.MoveFile(sourceName, destinationName)
}

func (t *transfer) fetch(ctx context.Context) error {
	d := t.d
	if !d.valid(d.Info.Room, d.Info.Sender) {
		return errAttachmentInvalid
	}
	id := "/" + d.Info.ID
	var remote remoteFile
	for {
		if err := t.api(ctx, "GET", id, nil, &remote); err != nil {
			return err
		}
		if !t.identifies(remote) {
			return invalid
		}
		t.session.apply(remote)
		if remote.State == "cancelled" {
			return errors.New("ATTACHMENT_CANCELLED")
		}
		if remote.State == "expired" || remote.State == "delivered" {
			return errors.New("ATTACHMENT_EXPIRED")
		}
		if remote.State == "completed" {
			break
		}
		if err := waitAttachment(ctx, time.Second); err != nil {
			return err
		}
	}
	count := int((d.Info.cipherSize() + fileChunk - 1) / fileChunk)
	if len(remote.Hashes) != count {
		return invalid
	}
	f, err := os.OpenFile(t.cache, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	for n := 0; n < count; n++ {
		size := min(int64(fileChunk), d.Info.cipherSize()-int64(n)*fileChunk)
		off := int64(n) * fileChunk
		buf := make([]byte, size)
		got, _ := f.ReadAt(buf, off)
		if int64(got) != size || fmt.Sprintf("%x", sha256.Sum256(buf)) != remote.Hashes[n] {
			err = retryAttachment(ctx, func(ctx context.Context) error {
				if err := t.budget(ctx, size, 1); err != nil {
					return err
				}
				var err error
				buf, err = t.chunk(ctx, n, size)
				return err
			})
			if err != nil {
				return err
			}
			if fmt.Sprintf("%x", sha256.Sum256(buf)) != remote.Hashes[n] {
				return errAttachmentIntegrity
			}
			if _, err = f.WriteAt(buf, off); err != nil {
				return err
			}
		}
		t.progress(n+1, count)
	}
	if err = f.Truncate(d.Info.cipherSize()); err != nil {
		return err
	}
	return f.Sync()
}

func (t *transfer) decrypt(ctx context.Context, w io.Writer) error {
	t.keyMu.Lock()
	defer t.keyMu.Unlock()
	if err := t.ctx.Err(); err != nil {
		return err
	}
	f, err := os.Open(t.cache)
	if err != nil {
		return err
	}
	defer f.Close()
	hash := sha256.New()
	if err = t.d.transform(ctx, io.TeeReader(f, hash), w, false, t.ctx.Err); err != nil {
		return err
	}
	if hex.EncodeToString(hash.Sum(nil)) != t.d.Info.Digest {
		return errAttachmentIntegrity
	}
	return t.ctx.Err()
}

func (t *transfer) ensureCached(ctx context.Context) error {
	s := t.session
	s.mu.Lock()
	done, running := t.jobDone, t.running
	pending := t.source != "" && !t.completed
	unavailable := s.closed || t.terminal || t.cancelling
	s.mu.Unlock()
	if unavailable || t.ctx.Err() != nil {
		return errors.New("ATTACHMENT_UNAVAILABLE")
	}
	if t.hasCachedFile() {
		t.receipt()
		return nil
	}
	s.mu.Lock()
	expired := t.remoteState == "delivered" || t.remoteState == "expired"
	s.mu.Unlock()
	if expired {
		return errors.New("ATTACHMENT_EXPIRED")
	}
	if pending && !running {
		return errors.New("ATTACHMENT_PENDING")
	}
	if !running {
		err := s.start(t, "", false)
		s.mu.Lock()
		done, running = t.jobDone, t.running
		s.mu.Unlock()
		if err != nil && !(errors.Is(err, errTransferBusy) && running) {
			return err
		}
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.ctx.Done():
		return t.ctx.Err()
	case <-done:
	}
	if t.hasCachedFile() {
		return nil
	}
	s.mu.Lock()
	reason := t.lastError
	s.mu.Unlock()
	if reason != "" {
		return errors.New(reason)
	}
	return errors.New("ATTACHMENT_UNAVAILABLE")
}
func (t *transfer) preview(ctx context.Context) (any, error) {
	s := t.session
	s.mu.Lock()
	isImage := t.d.Info.isImage()
	s.mu.Unlock()
	if !isImage {
		return nil, errAttachmentInvalid
	}
	if err := t.ensureCached(ctx); err != nil {
		return nil, err
	}
	var out bytes.Buffer
	if err := t.decrypt(ctx, &out); err != nil {
		clear(out.Bytes())
		return nil, err
	}
	return obj{"file": out.Bytes(), "entry": s.entry, "revision": s.revision}, nil
}
