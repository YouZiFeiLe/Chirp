package httpapi

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

// The current deployment has exactly one API process. Bound parallel chunk IO,
// serialize writes to the same object, and exclude GC from in-flight IO. Never
// hold a SQLite write transaction across disk/network IO.
type AttachmentStorage struct {
	db        *store.Store
	root      *os.Root
	mu        sync.RWMutex
	writers   [64]sync.Mutex
	transfers chan struct{}
	feed      *attachmentFeed
}

func NewAttachmentStorage(db *store.Store, directory string, protectedPaths ...string) (*AttachmentStorage, error) {
	if !filepath.IsAbs(directory) {
		return nil, errors.New("attachment storage must be an absolute directory")
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(directory)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("attachment storage must be a private directory")
	}
	// GC owns this entire tree. Reject database overlap before changing any
	// transfer state or removing files, including aliases through parent links.
	resolved, err := filepath.EvalSymlinks(directory)
	if err != nil {
		return nil, err
	}
	for _, path := range append([]string{db.Path()}, protectedPaths...) {
		protected, err := filepath.EvalSymlinks(path)
		if err != nil {
			return nil, err
		}
		relative, err := filepath.Rel(resolved, protected)
		if err != nil {
			return nil, err
		}
		if relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return nil, errors.New("attachment storage must not contain application databases or signing keys")
		}
	}
	if err = os.Chmod(directory, 0700); err != nil {
		return nil, err
	}
	root, err := os.OpenRoot(directory)
	if err != nil {
		return nil, err
	}
	f := &AttachmentStorage{db: db, root: root, transfers: make(chan struct{}, 16), feed: newAttachmentFeed()}
	if err = db.ResetAttachmentTransfers(context.Background()); err != nil {
		root.Close()
		return nil, err
	}
	if err = f.Reap(context.Background()); err != nil {
		root.Close()
		return nil, err
	}
	return f, nil
}
func (f *AttachmentStorage) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.root.Close()
}
func (f *AttachmentStorage) Monitor(ctx context.Context, logger *slog.Logger) {
	cleanup := logging.FailureTracker{Logger: logger.With("module", "attachments"), Event: "attachments.cleanup"}
	reconcile := logging.FailureTracker{Logger: logger.With("module", "attachments"), Event: "attachments.reconcile"}
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	gc := time.NewTicker(time.Minute)
	defer gc.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-gc.C:
			cleanup.Observe(ctx, f.Reap(ctx, logger))
		case <-ticker.C:
			checkCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
			reconcile.Observe(ctx, f.reconcile(checkCtx))
			cancel()
		}
	}
}
func (f *AttachmentStorage) Reap(ctx context.Context, loggers ...*slog.Logger) error {
	if err := f.reconcile(ctx); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	removed, err := f.db.ReapAttachments(ctx)
	if err != nil {
		return err
	}
	if len(removed) > 0 {
		f.feed.notifyAll()
	}
	ids, err := f.db.AttachmentIDs(ctx)
	if err != nil {
		return err
	}
	directory, err := f.root.Open(".")
	if err != nil {
		return err
	}
	defer directory.Close()
	entries, err := directory.ReadDir(-1)
	if err != nil {
		return err
	}
	orphans := 0
	for _, entry := range entries {
		if !ids[entry.Name()] {
			if err = f.root.RemoveAll(entry.Name()); err != nil {
				return err
			}
			orphans++
		}
	}
	if (len(removed) > 0 || orphans > 0) && len(loggers) > 0 {
		loggers[0].Info("Attachment cache reclaimed", "event", "attachment.reclaimed", "expired_attachments", len(removed), "removed_directories", orphans)
	}
	return nil
}

func (s *Server) createAttachment(w http.ResponseWriter, r *http.Request, m store.Member) {
	if s.attachments == nil {
		httpresponse.Error(w, 503, "ATTACHMENTS_UNAVAILABLE", "附件服务未启用")
		return
	}
	var request struct {
		ID         string   `json:"id"`
		EntryID    string   `json:"entry_id"`
		Size       int64    `json:"ciphertext_size"`
		Digest     string   `json:"ciphertext_sha256"`
		Recipients []string `json:"recipients"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 128*1024))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || decoder.Decode(new(any)) != io.EOF {
		s.attachmentError(w, r, store.ErrAttachmentInvalid)
		return
	}
	f := s.attachments
	if !f.mu.TryLock() {
		s.attachmentBusy(w)
		return
	}
	defer f.mu.Unlock()
	if r.Header.Get("X-Chirp-Entry") != request.EntryID {
		s.attachmentError(w, r, store.ErrAdmissionChanged)
		return
	}
	f.feed.mu.Lock()
	online := make(map[string]bool, len(request.Recipients))
	for _, identity := range request.Recipients {
		online[identity] = f.feed.onlineLocked(identity)
	}
	a, err := s.store.CreateAttachment(r.Context(), m, r.PathValue("room"), request.EntryID, request.ID, request.Size, request.Digest, request.Recipients, online)
	f.feed.mu.Unlock()
	if err != nil {
		s.attachmentError(w, r, err)
		return
	}
	logging.Annotate(r.Context(), "room_id", a.RoomID, "attachment_id", a.ID)
	if !a.State.Terminal() {
		err = f.root.Mkdir(a.ID, 0700)
	}
	if err != nil && !errors.Is(err, os.ErrExist) {
		s.internalError(w, r, fmt.Errorf("create attachment directory: %w", err))
		return
	}
	f.feed.notify(a.RoomID)
	logging.Request(r, s.logger).Info("Attachment created", "event", "attachment.created", "bytes", a.Size, "recipients", len(request.Recipients))
	httpresponse.JSON(w, 201, attachmentResponse{Attachment: a.PublicState(time.Now()), Protocol: store.AttachmentProtocol, ChunkBytes: store.AttachmentChunkBytes})
}

func (s *Server) attachment(w http.ResponseWriter, r *http.Request, m store.Member) {
	if s.attachments == nil {
		httpresponse.Error(w, 503, "ATTACHMENTS_UNAVAILABLE", "附件服务未启用")
		return
	}
	a, err := s.store.Attachment(r.Context(), m, r.PathValue("room"), r.Header.Get("X-Chirp-Entry"), r.PathValue("attachment"))
	if err != nil {
		s.attachmentError(w, r, err)
		return
	}
	logging.Annotate(r.Context(), "room_id", a.RoomID, "attachment_id", a.ID)
	digests, err := s.store.AttachmentDigests(r.Context(), a)
	if err != nil {
		s.attachmentError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, attachmentResponse{Attachment: a, Protocol: store.AttachmentProtocol, ChunkBytes: store.AttachmentChunkBytes, Digests: digests})
}

func (s *Server) attachmentChunk(w http.ResponseWriter, r *http.Request, m store.Member) {
	if s.attachments == nil {
		httpresponse.Error(w, 503, "ATTACHMENTS_UNAVAILABLE", "附件服务未启用")
		return
	}
	index, err := strconv.ParseInt(r.PathValue("chunk"), 10, 64)
	if err != nil || index < 0 {
		s.attachmentError(w, r, store.ErrAttachmentInvalid)
		return
	}
	f := s.attachments
	// Independent recipients can download in parallel, with a fixed memory/IO
	// budget. A slow transfer must not monopolize the whole room's file service.
	select {
	case f.transfers <- struct{}{}:
		defer func() { <-f.transfers }()
	default:
		s.attachmentBusy(w)
		return
	}
	if !f.mu.TryRLock() {
		s.attachmentBusy(w)
		return
	}
	defer f.mu.RUnlock()
	if r.Method == http.MethodPut {
		id := r.PathValue("attachment")
		if !store.ValidAttachmentID(id) {
			s.attachmentError(w, r, store.ErrNotFound)
			return
		}
		stripe, _ := strconv.ParseUint(id[:2], 16, 8)
		writer := &f.writers[stripe%uint64(len(f.writers))]
		if !writer.TryLock() {
			s.attachmentBusy(w)
			return
		}
		defer writer.Unlock()
	}
	a, err := s.store.Attachment(r.Context(), m, r.PathValue("room"), r.Header.Get("X-Chirp-Entry"), r.PathValue("attachment"))
	if err != nil {
		s.attachmentError(w, r, err)
		return
	}
	if a.State.Terminal() {
		s.attachmentTerminal(w, a.State)
		return
	}
	logging.Annotate(r.Context(), "room_id", a.RoomID, "attachment_id", a.ID, "chunk", index)
	length := a.ChunkSize(index)
	if length == 0 {
		s.attachmentError(w, r, store.ErrAttachmentInvalid)
		return
	}
	name := fmt.Sprintf("%s/ciphertext", a.ID)
	if r.Method == http.MethodGet {
		if !f.feed.online(store.AdmissionIdentity(m, r.Header.Get("X-Chirp-Entry"))) {
			s.attachmentError(w, r, store.ErrNotFound)
			return
		}
		if a.State != store.AttachmentCompleted {
			httpresponse.Error(w, 409, "ATTACHMENT_PENDING", "附件尚未上传完成")
			return
		}
		file, err := f.root.Open(name)
		if err != nil {
			logging.Request(r, s.logger).Warn("Attachment read failed", "event", "attachment.read_failed", "error", err)
			s.attachmentError(w, r, store.ErrNotFound)
			return
		}
		defer file.Close()
		info, err := file.Stat()
		if err != nil || info.Size() != a.Size {
			logging.Request(r, s.logger).Warn("Attachment file inconsistent", "event", "attachment.read_failed", "error", err, "expected_bytes", a.Size)
			s.attachmentError(w, r, store.ErrNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Length", strconv.FormatInt(length, 10))
		w.Header().Set("X-Content-Type-Options", "nosniff")
		reader := io.NewSectionReader(file, index*store.AttachmentChunkBytes, length)
		buffer := make([]byte, 64*1024)
		for {
			// Larger HTTP blocks do not enlarge the authorization check quantum.
			if !f.feed.online(store.AdmissionIdentity(m, r.Header.Get("X-Chirp-Entry"))) {
				return
			}
			current, err := s.store.Attachment(r.Context(), m, a.RoomID, r.Header.Get("X-Chirp-Entry"), a.ID)
			if err != nil || current.State != store.AttachmentCompleted {
				if err != nil && !errors.Is(err, store.ErrNotFound) && r.Context().Err() == nil {
					logging.Request(r, s.logger).Warn("Attachment download authorization failed", "event", "attachment.download_failed", "error", err)
				}
				return
			}
			_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(15 * time.Second))
			n, err := reader.Read(buffer)
			if n > 0 {
				if _, writeErr := w.Write(buffer[:n]); writeErr != nil {
					return
				}
			}
			if err != nil {
				if !errors.Is(err, io.EOF) {
					logging.Request(r, s.logger).Warn("Attachment download read failed", "event", "attachment.read_failed", "error", err)
				}
				return
			}
		}
	}
	if a.Owner != store.AdmissionIdentity(m, r.Header.Get("X-Chirp-Entry")) {
		s.attachmentError(w, r, store.ErrNotFound)
		return
	}
	if r.ContentLength != length || r.Header.Get("Content-Type") != "application/octet-stream" {
		s.attachmentError(w, r, store.ErrAttachmentInvalid)
		return
	}
	if index > a.Uploaded {
		s.attachmentError(w, r, store.ErrAttachmentConflict)
		return
	}
	// A retry can only acknowledge exactly the same immutable ciphertext.
	if index < a.Uploaded {
		file, err := f.root.Open(name)
		if err != nil {
			s.attachmentError(w, r, store.ErrNotFound)
			return
		}
		defer file.Close()
		oldHash, newHash := sha256.New(), sha256.New()
		_, e1 := io.Copy(oldHash, io.NewSectionReader(file, index*store.AttachmentChunkBytes, length))
		body := &attachmentUploadBody{Reader: http.MaxBytesReader(w, r.Body, length), controller: http.NewResponseController(w)}
		n, e2 := io.Copy(newHash, body)
		if e1 != nil || e2 != nil || n != length || string(oldHash.Sum(nil)) != string(newHash.Sum(nil)) {
			s.attachmentError(w, r, store.ErrAttachmentConflict)
			return
		}
		w.WriteHeader(204)
		return
	}
	file, err := f.root.OpenFile(name, os.O_RDWR|os.O_CREATE, 0600)
	if err != nil {
		s.internalError(w, r, fmt.Errorf("open attachment storage: %w", err))
		return
	}
	defer file.Close()
	offset := index * store.AttachmentChunkBytes
	preserveTail := false
	defer func() {
		if preserveTail {
			return
		}
		if offset == 0 {
			if err := f.root.Remove(name); err != nil && !errors.Is(err, os.ErrNotExist) {
				logging.Request(r, s.logger).Warn("Attachment rollback failed", "event", "attachment.rollback_failed", "error", err)
			}
			return
		}
		if tail, err := f.root.OpenFile(name, os.O_WRONLY, 0); err == nil {
			if err := errors.Join(tail.Truncate(offset), tail.Close()); err != nil {
				logging.Request(r, s.logger).Warn("Attachment rollback failed", "event", "attachment.rollback_failed", "error", err)
			}
		} else {
			logging.Request(r, s.logger).Warn("Attachment rollback open failed", "event", "attachment.rollback_failed", "error", err)
		}
	}()
	info, err := file.Stat()
	if err != nil || info.Size() < offset {
		if err == nil {
			err = errors.New("attachment prefix is shorter than durable progress")
		}
		s.internalError(w, r, fmt.Errorf("inspect attachment prefix: %w", err))
		return
	}
	if err = file.Truncate(offset); err != nil {
		s.internalError(w, r, err)
		return
	}
	if _, err = file.Seek(offset, io.SeekStart); err != nil {
		s.internalError(w, r, err)
		return
	}
	hash := sha256.New()
	body := &attachmentUploadBody{Reader: http.MaxBytesReader(w, r.Body, length), controller: http.NewResponseController(w)}
	n, copyErr := io.CopyBuffer(io.MultiWriter(file, hash), body, make([]byte, 32*1024))
	if copyErr == nil {
		copyErr = file.Sync()
	}
	closeErr := file.Close()
	if copyErr != nil || closeErr != nil || n != length {
		logging.Request(r, s.logger).Warn("Attachment chunk write failed", "event", "attachment.chunk_write_failed", "chunk", index, "expected_bytes", length, "received_bytes", n, "error", errors.Join(copyErr, closeErr))
		s.attachmentError(w, r, store.ErrAttachmentInvalid)
		return
	}
	// Recheck after reading: leaving/logging out while a chunk arrives must fail.
	current, err := s.store.Attachment(r.Context(), m, a.RoomID, r.Header.Get("X-Chirp-Entry"), a.ID)
	if err != nil {
		s.attachmentError(w, r, err)
		return
	}
	if current.State.Terminal() {
		s.attachmentTerminal(w, current.State)
		return
	}
	// A commit error can be ambiguous. Keep these synced bytes once commit is
	// attempted; the next PUT truncates any tail not covered by durable progress.
	preserveTail = true
	if err = s.store.AdvanceAttachment(r.Context(), a, hex.EncodeToString(hash.Sum(nil))); err != nil {
		s.attachmentError(w, r, err)
		return
	}
	// Local jobs already report byte progress. Notify other recipients only
	// when upload state changes, never once per network block and full catalog.
	if a.Uploaded == 0 || a.State != store.AttachmentUploading {
		f.feed.notify(a.RoomID)
	}
	w.WriteHeader(204)
}

// Refresh an idle deadline as bytes arrive rather than timing out a slow but
// progressing 1 MiB request against the ordinary API's total read deadline.
type attachmentUploadBody struct {
	io.Reader
	controller *http.ResponseController
}

func (b *attachmentUploadBody) Read(p []byte) (int, error) {
	_ = b.controller.SetReadDeadline(time.Now().Add(15 * time.Second))
	// The ordinary response deadline also starts before the body is read.
	// Keep the receipt writable while a slow upload continues making progress.
	_ = b.controller.SetWriteDeadline(time.Now().Add(15 * time.Second))
	return b.Reader.Read(p)
}

func (s *Server) attachmentError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound), errors.Is(err, store.ErrAdmissionChanged):
		httpresponse.Error(w, 404, "ATTACHMENT_UNAVAILABLE", "附件已失效或不属于本次入房")
	case errors.Is(err, store.ErrAttachmentInvalid):
		httpresponse.Error(w, 400, "ATTACHMENT_INVALID", "附件信息或分块无效")
	case errors.Is(err, store.ErrAttachmentQuota):
		httpresponse.Error(w, 413, "ATTACHMENT_QUOTA", "附件大小或存储配额已达上限")
	case errors.Is(err, store.ErrAttachmentConflict):
		httpresponse.Error(w, 409, "ATTACHMENT_CONFLICT", "附件上传状态已改变")
	default:
		s.internalError(w, r, err)
	}
}

func (s *Server) attachmentBusy(w http.ResponseWriter) {
	w.Header().Set("Retry-After", "1")
	httpresponse.Error(w, 429, "ATTACHMENT_BUSY", "附件传输繁忙，请稍后重试")
}
