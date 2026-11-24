package httpapi

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpstream"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

type attachmentResponse struct {
	store.Attachment
	Protocol   int      `json:"protocol_version"`
	ChunkBytes int64    `json:"chunk_bytes"`
	Digests    []string `json:"chunk_sha256,omitempty"`
}
type attachmentRevision struct {
	revision uint64
	changed  chan struct{}
}
type attachmentFeed struct {
	mu           sync.Mutex
	serverID     string
	rooms        map[string]*attachmentRevision
	streams      map[string]chan struct{}
	disconnected map[string]time.Time
}

const attachmentDisconnectGrace = 6 * time.Second

func newAttachmentFeed() *attachmentFeed {
	var id [24]byte
	if _, err := rand.Read(id[:]); err != nil {
		panic("system random source unavailable")
	}
	return &attachmentFeed{serverID: hex.EncodeToString(id[:]), rooms: map[string]*attachmentRevision{}, streams: map[string]chan struct{}{}, disconnected: map[string]time.Time{}}
}
func (f *attachmentFeed) roomLocked(room string) *attachmentRevision {
	if f.rooms[room] == nil {
		f.rooms[room] = &attachmentRevision{revision: 1, changed: make(chan struct{})}
	}
	return f.rooms[room]
}
func (f *attachmentFeed) snapshot(room string) (uint64, <-chan struct{}) {
	f.mu.Lock()
	defer f.mu.Unlock()
	r := f.roomLocked(room)
	return r.revision, r.changed
}

// Catalog requests can fail authorization. Reading their revision must not
// allocate a persistent feed for an arbitrary room supplied by the requester.
func (f *attachmentFeed) currentRevision(room string) uint64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r := f.rooms[room]; r != nil {
		return r.revision
	}
	return 1
}
func (f *attachmentFeed) notify(room string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	r := f.roomLocked(room)
	r.revision++
	close(r.changed)
	r.changed = make(chan struct{})
}
func (f *attachmentFeed) notifyAll() {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, r := range f.rooms {
		r.revision++
		close(r.changed)
		r.changed = make(chan struct{})
	}
}
func (f *attachmentFeed) register(identity string) (<-chan struct{}, func()) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.registerLocked(identity)
}
func (f *attachmentFeed) registerLocked(identity string) (<-chan struct{}, func()) {
	if previous := f.streams[identity]; previous != nil {
		close(previous)
	}
	stop := make(chan struct{})
	f.streams[identity] = stop
	delete(f.disconnected, identity)
	return stop, func() {
		f.mu.Lock()
		defer f.mu.Unlock()
		if f.streams[identity] == stop {
			delete(f.streams, identity)
			f.disconnected[identity] = time.Now()
		}
	}
}

func (f *attachmentFeed) onlineLocked(identity string) bool {
	if f.streams[identity] != nil {
		return true
	}
	when, ok := f.disconnected[identity]
	return ok && time.Since(when) < attachmentDisconnectGrace
}
func (f *attachmentFeed) online(identity string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.onlineLocked(identity)
}

// Serialize reconnect with expiry and audience capture. A connection returning
// after the grace period cannot reclaim pending deliveries from its old entry.
func (f *AttachmentStorage) connect(ctx context.Context, identity string) (<-chan struct{}, func(), error) {
	f.feed.mu.Lock()
	var changed []store.Attachment
	if when, ok := f.feed.disconnected[identity]; ok && time.Since(when) >= attachmentDisconnectGrace {
		var err error
		changed, err = f.db.SkipAttachmentRecipients(ctx, []string{identity})
		if err != nil {
			f.feed.mu.Unlock()
			return nil, nil, err
		}
	}
	stop, unregister := f.feed.registerLocked(identity)
	f.feed.mu.Unlock()
	if err := f.applyDeliveryChanges(changed); err != nil {
		unregister()
		return nil, nil, err
	}
	return stop, unregister, nil
}

func (f *AttachmentStorage) applyDeliveryChanges(changed []store.Attachment) error {
	for _, a := range changed {
		f.feed.notify(a.RoomID)
		if a.State.Terminal() {
			f.mu.RLock()
			err := f.root.RemoveAll(a.ID)
			f.mu.RUnlock()
			if err != nil {
				return err
			}
		}
	}
	return nil
}
func (f *AttachmentStorage) reconcile(ctx context.Context) error {
	f.feed.mu.Lock()
	var offline []string
	for identity, when := range f.feed.disconnected {
		if time.Since(when) >= attachmentDisconnectGrace {
			offline = append(offline, identity)
		}
	}
	dropped, err := f.db.SkipAttachmentRecipients(ctx, offline)
	if err == nil {
		for _, identity := range offline {
			delete(f.feed.disconnected, identity)
		}
	}
	f.feed.mu.Unlock()
	if err != nil {
		return err
	}
	if err = f.applyDeliveryChanges(dropped); err != nil {
		return err
	}
	changed, err := f.db.ReconcileAttachments(ctx)
	if err != nil {
		return err
	}
	return f.applyDeliveryChanges(changed)
}
func (s *Server) attachmentList(w http.ResponseWriter, r *http.Request, m store.Member) {
	if s.attachments == nil {
		httpresponse.Error(w, 503, "ATTACHMENTS_UNAVAILABLE", "附件服务未启用")
		return
	}
	if r.URL.RawQuery != "" {
		httpresponse.Error(w, 400, "BAD_REQUEST", "不接受查询参数")
		return
	}
	f := s.attachments
	roomID := r.PathValue("room")
	// Capture the hint BEFORE reading metadata: a concurrent mutation must
	// remain a newer notification, rather than being hidden behind this reply.
	revision := f.feed.currentRevision(roomID)
	list, err := s.store.Attachments(r.Context(), m, roomID, r.Header.Get("X-Chirp-Entry"))
	if err != nil {
		s.attachmentError(w, r, err)
		return
	}
	result := make([]attachmentResponse, 0, len(list))
	for _, a := range list {
		result = append(result, attachmentResponse{Attachment: a, Protocol: store.AttachmentProtocol, ChunkBytes: store.AttachmentChunkBytes})
	}
	httpresponse.JSON(w, 200, struct {
		ServerID    string               `json:"server_id"`
		RoomID      string               `json:"room_id"`
		Revision    uint64               `json:"revision"`
		Attachments []attachmentResponse `json:"attachments"`
	}{f.feed.serverID, roomID, revision, result})
}
func (s *Server) attachmentEvents(w http.ResponseWriter, r *http.Request, m store.Member) {
	if s.attachments == nil {
		httpresponse.Error(w, 503, "ATTACHMENTS_UNAVAILABLE", "附件服务未启用")
		return
	}
	roomID, entryID := r.PathValue("room"), r.Header.Get("X-Chirp-Entry")
	if r.URL.RawQuery != "" || !store.ValidRoomID(roomID) || !store.ValidEntryID(entryID) {
		httpresponse.Error(w, 400, "BAD_REQUEST", "事件订阅无效")
		return
	}
	identity := store.AdmissionIdentity(m, entryID)
	allowed, err := s.store.AdmissionAllowed(r.Context(), roomID, identity)
	if err != nil || !allowed {
		if err == nil {
			err = store.ErrAdmissionChanged
		}
		s.attachmentError(w, r, err)
		return
	}
	f := s.attachments
	stop, unregister, err := f.connect(r.Context(), identity)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	defer unregister()
	check := time.NewTicker(time.Second)
	defer check.Stop()
	ping := time.NewTicker(2 * time.Second)
	defer ping.Stop()
	httpstream.Start(w)
	var sent uint64
	for {
		revision, changed := f.feed.snapshot(roomID)
		if revision != sent {
			if httpstream.Write(w, "state", revision, map[string]any{"server_id": f.feed.serverID, "room_id": roomID, "revision": revision}) != nil {
				return
			}
			sent = revision
		}
		select {
		case <-r.Context().Done():
			return
		case <-stop:
			return
		case <-changed:
		case <-ping.C:
			if httpstream.Ping(w) != nil {
				return
			}
		case <-check.C:
			allowed, err := s.store.AdmissionAllowed(r.Context(), roomID, identity)
			if err != nil {
				logging.Request(r, s.logger).Warn("Attachment stream authorization failed", "event", "attachment.stream_failed", "room_id", roomID, "error", err)
				_ = httpstream.Write(w, "unavailable", sent, map[string]bool{"available": false})
				return
			}
			if !allowed {
				_ = httpstream.Write(w, "revoked", sent, map[string]bool{"available": false})
				return
			}
		}
	}
}

func (s *Server) changeAttachment(w http.ResponseWriter, r *http.Request, m store.Member) {
	if s.attachments == nil {
		httpresponse.Error(w, 503, "ATTACHMENTS_UNAVAILABLE", "附件服务未启用")
		return
	}
	if r.URL.RawQuery != "" || r.ContentLength != 0 {
		httpresponse.Error(w, 400, "BAD_REQUEST", "附件操作不接受正文或查询参数")
		return
	}
	f := s.attachments
	if !f.mu.TryRLock() {
		s.attachmentBusy(w)
		return
	}
	defer f.mu.RUnlock()
	a, err := s.store.Attachment(r.Context(), m, r.PathValue("room"), r.Header.Get("X-Chirp-Entry"), r.PathValue("attachment"))
	if err != nil {
		s.attachmentError(w, r, err)
		return
	}
	if a.Owner != store.AdmissionIdentity(m, r.Header.Get("X-Chirp-Entry")) {
		s.attachmentError(w, r, store.ErrNotFound)
		return
	}
	target := store.AttachmentCancelled
	if strings.HasSuffix(r.URL.Path, "/pause") {
		target = store.AttachmentPaused
	}
	if strings.HasSuffix(r.URL.Path, "/complete") {
		target = store.AttachmentCompleted
		if a.State.Terminal() && a.State != store.AttachmentDelivered {
			s.attachmentTerminal(w, a.State)
			return
		}
		if a.CompletedAt == 0 {
			select {
			case f.transfers <- struct{}{}:
				defer func() { <-f.transfers }()
			default:
				s.attachmentBusy(w)
				return
			}
			stripe, _ := strconv.ParseUint(a.ID[:2], 16, 8)
			writer := &f.writers[stripe%uint64(len(f.writers))]
			if !writer.TryLock() {
				s.attachmentBusy(w)
				return
			}
			defer writer.Unlock()
			if a.Uploaded != a.ChunkCount() {
				s.attachmentError(w, r, store.ErrAttachmentConflict)
				return
			}
			if err := f.verify(r.Context(), a); err != nil {
				if r.Context().Err() != nil {
					return
				}
				logging.Request(r, s.logger).Warn("Attachment integrity verification failed", "event", "attachment.integrity_failed", "room_id", a.RoomID, "attachment_id", a.ID, "error", err)
				if current, lookupErr := s.store.Attachment(r.Context(), m, a.RoomID, r.Header.Get("X-Chirp-Entry"), a.ID); lookupErr == nil && current.State.Terminal() {
					s.attachmentTerminal(w, current.State)
					return
				}
				httpresponse.Error(w, 409, "ATTACHMENT_INTEGRITY", "附件密文校验失败，请重新选择文件")
				return
			}
		}
	}
	result, err := s.store.SetAttachmentState(r.Context(), m, a.RoomID, r.Header.Get("X-Chirp-Entry"), a.ID, target)
	if err != nil {
		s.attachmentError(w, r, err)
		return
	}
	logging.Request(r, s.logger).Info("Attachment state changed", "event", "attachment.state_changed", "room_id", a.RoomID, "attachment_id", a.ID, "previous_state", a.State, "state", result.State)
	f.feed.notify(a.RoomID)
	if result.State.Terminal() {
		if err := f.root.RemoveAll(a.ID); err != nil {
			s.internalError(w, r, err)
			return
		}
	}
	httpresponse.JSON(w, 200, attachmentResponse{Attachment: result, Protocol: store.AttachmentProtocol, ChunkBytes: store.AttachmentChunkBytes})
}
func (f *AttachmentStorage) verify(ctx context.Context, a store.Attachment) error {
	digest := sha256.New()
	buffer := make([]byte, 32*1024)
	for index := int64(0); index < a.ChunkCount(); index++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		file, err := f.root.Open(fmt.Sprintf("%s/ciphertext", a.ID))
		if err != nil {
			return err
		}
		info, err := file.Stat()
		if err != nil || info.Size() != a.Size {
			file.Close()
			return store.ErrAttachmentConflict
		}
		n, err := io.CopyBuffer(digest, io.NewSectionReader(file, index*store.AttachmentChunkBytes, a.ChunkSize(index)), buffer)
		file.Close()
		if err != nil {
			return err
		}
		if n != a.ChunkSize(index) {
			return store.ErrAttachmentConflict
		}
	}
	if hex.EncodeToString(digest.Sum(nil)) != a.Digest {
		return store.ErrAttachmentConflict
	}
	return nil
}
func (s *Server) attachmentTerminal(w http.ResponseWriter, state store.AttachmentState) {
	if state == store.AttachmentCancelled {
		httpresponse.Error(w, 410, "ATTACHMENT_CANCELLED", "发送者已取消未完成附件")
		return
	}
	httpresponse.Error(w, 410, "ATTACHMENT_EXPIRED", "附件已过期")
}
