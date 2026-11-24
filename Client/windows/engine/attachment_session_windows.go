package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"
)

const attachmentCacheLimit int64 = 512 << 20

var errTransferBusy = errors.New("TRANSFER_BUSY")
var errDuplicateFile = errors.New("ATTACHMENT_CONFLICT")

// An entry owns its files until it leaves or its cache is explicitly cleared.
// A group generation limits publication of keys, independently of this lifetime.
type attachmentSession struct {
	ctx                                            context.Context
	cancel                                         context.CancelFunc
	entry, room, base, credential, revision, cache string
	media                                          *mediaSession
	notify                                         func(string, any)

	mu           sync.Mutex
	files        map[string]*transfer
	registered   map[string]bool // Includes terminal descriptors for this cache revision.
	reserved     int64
	closed       bool
	revoked      bool
	uploading    bool
	downloads    int
	automatic    bool
	queue        []string
	catalogWake  chan struct{}
	scheduleWake chan struct{}
	workers      sync.WaitGroup
}

func (e *engine) beginFiles(r *activeRoom) {
	ctx, cancel := context.WithCancel(context.Background())
	s := &attachmentSession{
		ctx: ctx, cancel: cancel, entry: r.join.Identity, room: r.join.Room,
		base: e.conn.api("v1/rooms/" + r.join.Room + "/attachments"), credential: e.session.Credential,
		revision: rawURL(random(16)), cache: e.cache, media: r.media, notify: e.notify,
		files: make(map[string]*transfer), catalogWake: make(chan struct{}, 1), scheduleWake: make(chan struct{}, 1),
	}
	e.fileScope.Store(s)
	r.cancelAttachments = cancel
	s.workers.Go(s.watch)
	s.workers.Go(s.catalogLoop)
	s.workers.Go(s.downloadLoop)
}

func (s *attachmentSession) report(name string, data obj) {
	data["entry"] = s.entry
	data["revision"] = s.revision
	s.notify(name, data)
}

func (s *attachmentSession) wakeCatalog()   { signalWorker(s.catalogWake) }
func (s *attachmentSession) wakeDownloads() { signalWorker(s.scheduleWake) }

func signalWorker(ch chan struct{}) {
	select {
	case ch <- struct{}{}:
	default:
	}
}

func (s *attachmentSession) file(id string) *transfer {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.files[id]
}

func (s *attachmentSession) register(t *transfer) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	id := t.d.Info.ID
	if s.closed || s.ctx.Err() != nil {
		return invalid
	}
	if s.registered[id] {
		return errDuplicateFile
	}
	size := t.d.Info.cipherSize()
	if len(s.registered) >= 1000 || size > attachmentCacheLimit-s.reserved {
		return errors.New("ATTACHMENT_QUOTA")
	}
	if t.source != "" {
		pending := 0
		for _, item := range s.files {
			if item.source != "" && !item.completed && !item.terminal {
				pending++
			}
		}
		if pending >= 16 {
			return errors.New("ATTACHMENT_QUOTA")
		}
	}
	t.ctx, t.retire = context.WithCancel(s.ctx)
	if s.registered == nil {
		s.registered = make(map[string]bool)
	}
	s.registered[id] = true
	s.files[id] = t
	s.reserved += size
	return nil
}

func (s *attachmentSession) remove(t *transfer) {
	s.mu.Lock()
	if s.files[t.d.Info.ID] == t {
		delete(s.files, t.d.Info.ID)
		if t.source != "" && !t.prepared && !t.reservationAttempted {
			delete(s.registered, t.d.Info.ID)
		}
		s.reserved -= t.d.Info.cipherSize()
	}
	s.mu.Unlock()
}

// Close admission to new work first. Network requests honour cancellation and
// keys are erased only after the last reader of the sealed file has finished.
func (e *engine) clearFiles() error {
	previous := e.fileScope.Load()
	err := errors.Join(e.closeFiles(), e.purgeFileCache())
	if e.room != nil && previous != nil && !previous.revoked {
		e.beginFiles(e.room)
	}
	return err
}

// This private session directory contains only app-owned ciphertext. Include
// orphaned files whose earlier cleanup was interrupted.
func (e *engine) purgeFileCache() error {
	if e.cache == "" {
		return nil
	}
	entries, err := os.ReadDir(e.cache)
	if err != nil {
		return err
	}
	var result error
	for _, entry := range entries {
		if err := os.Remove(filepath.Join(e.cache, entry.Name())); err != nil && !os.IsNotExist(err) {
			result = errors.Join(result, err)
		}
	}
	return result
}
func (e *engine) closeFiles() error {
	s := e.fileScope.Swap(nil)
	if s == nil {
		return nil
	}
	s.mu.Lock()
	s.closed = true
	s.cancel()
	items := make([]*transfer, 0, len(s.files))
	for _, t := range s.files {
		items = append(items, t)
	}
	s.mu.Unlock()
	s.workers.Wait()
	var reports sync.WaitGroup
	var result error
	for _, t := range items {
		if t.source != "" && t.reservationAttempted && !t.completed {
			reports.Go(func() {
				ctx, stop := context.WithTimeout(context.Background(), 3*time.Second)
				defer stop()
				_, _ = request(ctx, "cancelAttachment", http.MethodPost, t.base+"/"+t.d.Info.ID+"/cancel", nil, t.credential, t.headers(), nil, 4096)
			})
		}
		t.keyMu.Lock()
		clear(t.d.Key)
		t.keyMu.Unlock()
		if err := os.Remove(t.cache); err != nil && !os.IsNotExist(err) {
			result = errors.Join(result, err)
		}
	}
	// Complete these scoped reports before sending the old entry's leave.
	reports.Wait()
	return result
}

func (e *engine) transferFor(r *activeRoom, d descriptor) *transfer {
	s := e.fileScope.Load()
	return &transfer{session: s, d: d, group: groupID(r.snap), base: s.base, entry: s.entry, credential: s.credential,
		media: s.media, cache: filepath.Join(s.cache, d.Info.ID+".cipher")}
}

func (s *attachmentSession) start(t *transfer, dest string, auto bool) error {
	if dest != "" {
		t.hasCachedFile()
	}
	s.mu.Lock()
	if s.closed || s.files[t.d.Info.ID] != t || t.ctx.Err() != nil || t.terminal || t.cancelling {
		s.mu.Unlock()
		return errors.New("ATTACHMENT_UNAVAILABLE")
	}
	outgoing := t.source != "" && !t.completed && dest == ""
	download := !outgoing && (dest == "" || !t.cached)
	if t.running || outgoing && s.uploading || download && (s.downloads >= 2 || auto && (s.automatic || t.paused)) {
		s.mu.Unlock()
		return errTransferBusy
	}
	if outgoing {
		s.uploading = true
		t.operation = "upload"
	} else if download {
		s.downloads++
		t.operation = "download"
	} else {
		t.operation = "export"
	}
	if auto {
		s.automatic = true
	}
	ctx, cancel := context.WithTimeout(t.ctx, 15*time.Minute)
	t.cancel = cancel
	t.running = true
	t.paused = false
	t.lastError = ""
	t.retryable = false
	t.jobDone = make(chan struct{})
	done := t.jobDone
	started := t.eventLocked()
	s.workers.Add(1)
	s.mu.Unlock()
	s.report("transfer", started)
	span := installationLog.begin()
	go func() {
		defer s.workers.Done()
		defer cancel()
		var err error
		if outgoing {
			err = t.upload(ctx)
		} else {
			err = t.download(ctx, dest)
		}
		event := "download"
		if outgoing {
			event = "upload"
		}
		installationLog.finish(span, logOp{"attachment", event}, err, 0)
		s.mu.Lock()
		t.running = false
		t.operation = ""
		t.cancel = nil
		if outgoing {
			s.uploading = false
		} else if download {
			s.downloads--
		}
		if auto {
			s.automatic = false
		}
		if err == nil && outgoing {
			t.completed = true
		}
		// Preparation consumes the attachment key once. A failed preparation
		// has no resumable ciphertext and must be reselected as a new object.
		broken := outgoing && err != nil && t.preparationStarted && !t.prepared
		if broken {
			t.terminal = true
		}
		abandon := outgoing && err != nil && !t.completed && !t.terminal && !t.paused && !t.cancelling && !s.closed && (t.publicationAttempted && !t.announced || !retryableAttachment(err))
		if abandon {
			t.cancelling = true
		}
		retryPause := outgoing && t.reservationAttempted && err != nil && retryableAttachment(err) && !t.cancelling && !t.terminal
		exportError := dest != "" && err != nil && t.cached && !t.terminal && !t.cancelling && !errors.Is(err, context.Canceled)
		if err != nil && !exportError && !t.paused && !t.terminal && !t.cancelling {
			t.paused = true
		}
		t.networkPolicy = ""
		if err != nil && !exportError {
			t.lastError = err.Error()
			t.retryable = retryableAttachment(err)
		}
		if t.paused && errors.Is(err, context.Canceled) {
			t.lastError = "ATTACHMENT_PAUSED"
			t.retryable = true
		}
		if broken {
			t.lastError = "ATTACHMENT_PREPARATION_FAILED"
		}
		if err == nil {
			t.progressPercent = 100
		}
		data := t.eventLocked()
		live := !s.closed && s.files[t.d.Info.ID] == t
		close(done)
		s.mu.Unlock()
		if live {
			s.report("transfer", data)
			if exportError {
				s.report("attachmentError", obj{"id": t.d.Info.ID, "error": err.Error()})
			}
		}
		if broken {
			s.discard(t)
		}
		if abandon {
			_, _ = s.confirmCancel(t.ctx, t)
		}
		if retryPause {
			_ = t.control(t.ctx, "pause", nil)
		}
		s.wakeDownloads()
	}()
	return nil
}

func (t *transfer) eventLocked() obj {
	t.eventNumber++
	data := obj{"id": t.d.Info.ID, "group": t.group, "name": t.d.Info.Name, "mine": t.source != "", "cached": t.cached,
		"announced": t.announced,
		"operation": t.operation,
		"terminal":  t.terminal, "cancelling": t.cancelling, "paused": t.paused, "state": t.remoteState,
		"number": t.eventNumber, "running": t.running, "retryable": t.retryable, "progress": t.progressPercent,
		"done": t.cached && (t.source == "" || t.completed), "network": t.networkPolicy}
	if t.lastError != "" {
		data["error"] = t.lastError
	}
	return data
}

// discard is invoked by a session-owned worker or by the command loop. Stop
// this object's work before deleting the ciphertext, including pending receipts.
func (s *attachmentSession) discard(t *transfer) {
	s.mu.Lock()
	if s.files[t.d.Info.ID] != t || t.discarding {
		s.mu.Unlock()
		return
	}
	t.discarding = true
	t.terminal = true
	t.retire()
	done := t.jobDone
	receiptDone := t.receiptDone
	s.mu.Unlock()
	if done != nil {
		<-done
	}
	if receiptDone != nil {
		<-receiptDone
	}
	// Decryption and key ownership are serialized with previews and cleanup.
	t.keyMu.Lock()
	clear(t.d.Key)
	t.keyMu.Unlock()
	_ = os.Remove(t.cache)
	s.remove(t)
}

func (s *attachmentSession) command(ctx context.Context, op string, a args) (any, error) {
	if s.ctx.Err() != nil || a.Entry != s.entry || a.Revision != s.revision {
		return nil, errors.New("ATTACHMENT_UNAVAILABLE")
	}
	t := s.file(a.ID)
	if t == nil {
		return nil, errors.New("ATTACHMENT_UNAVAILABLE")
	}
	switch op {
	case "previewFile":
		return t.preview(ctx)
	case "prepareExport":
		if err := t.ensureCached(ctx); err != nil {
			return nil, err
		}
		return obj{"entry": s.entry, "revision": s.revision, "name": exportFilename(t.d.Info.Name)}, nil
	case "pauseFile":
		s.mu.Lock()
		if t.source != "" || !t.running || t.operation != "download" || t.cancelling || t.terminal {
			s.mu.Unlock()
			return nil, invalid
		}
		t.paused = true
		if t.cancel != nil {
			t.cancel()
		}
		done := t.jobDone
		s.mu.Unlock()
		if done != nil {
			<-done
		}
		return nil, nil
	case "cancelFile":
		s.mu.Lock()
		if t.source == "" {
			s.mu.Unlock()
			return nil, invalid
		}
		if t.completed && t.source != "" {
			s.mu.Unlock()
			return obj{"completed": true}, nil
		}
		t.cancelling = true
		data := t.eventLocked()
		if t.cancel != nil {
			t.cancel()
		}
		done := t.jobDone
		s.mu.Unlock()
		s.report("transfer", data)
		if done != nil {
			<-done
		}
		return s.confirmCancel(ctx, t)
	case "download":
		if !filepath.IsAbs(a.Path) || !filepath.IsLocal(filepath.Base(a.Path)) {
			return nil, invalid
		}
		return nil, s.export(t, a.Path)
	case "resumeFile":
		s.mu.Lock()
		retry := t.retryable && !t.running && !t.terminal && !t.cancelling
		s.mu.Unlock()
		if !retry {
			return nil, errors.New("ATTACHMENT_UNAVAILABLE")
		}
		return nil, s.start(t, "", false)
	default:
		return nil, invalid
	}
}
func (s *attachmentSession) confirmCancel(ctx context.Context, t *transfer) (any, error) {
	t.controlMu.Lock()
	defer t.controlMu.Unlock()
	if t.source != "" && t.reservationAttempted {
		var remote remoteFile
		if err := t.control(ctx, "cancel", &remote); err != nil {
			return nil, err
		}
		if !t.identifies(remote) {
			return nil, invalid
		}
		s.apply(remote)
		if remote.uploaded() {
			return obj{"completed": true}, nil
		}
		if !remote.terminal() {
			return nil, invalid
		}
	}
	s.mu.Lock()
	t.remoteState = "cancelled"
	t.terminal = true
	t.cached = false
	data := t.eventLocked()
	s.mu.Unlock()
	s.report("transfer", data)
	s.discard(t)
	return obj{"removed": true}, nil
}

func (s *attachmentSession) export(t *transfer, dest string) error {
	s.mu.Lock()
	if s.closed || t.ctx.Err() != nil || t.terminal || t.cancelling {
		s.mu.Unlock()
		return errors.New("ATTACHMENT_UNAVAILABLE")
	}
	if t.exportPending {
		s.mu.Unlock()
		return errTransferBusy
	}
	if !t.running {
		s.mu.Unlock()
		return s.start(t, dest, false)
	}
	// A user can select Save while automatic reception is still in flight.
	// Join the running download, then export the authenticated copy.
	done := t.jobDone
	t.exportPending = true
	s.workers.Add(1)
	s.mu.Unlock()
	go func() {
		defer s.workers.Done()
		defer func() { s.mu.Lock(); t.exportPending = false; s.mu.Unlock() }()
		select {
		case <-done:
		case <-t.ctx.Done():
			return
		}
		s.mu.Lock()
		cached := t.cached
		s.mu.Unlock()
		if !cached {
			return
		}
		if err := s.start(t, dest, false); err != nil && t.ctx.Err() == nil {
			s.report("attachmentError", obj{"id": t.d.Info.ID, "error": err.Error()})
		}
	}()
	return nil
}

func (s *attachmentSession) enqueueLocked(t *transfer) {
	if t.source == "" && !t.running && !t.paused && !t.cached && !t.terminal && !t.cancelling && !slices.Contains(s.queue, t.d.Info.ID) {
		s.queue = append(s.queue, t.d.Info.ID)
	}
}
func (s *attachmentSession) downloadLoop() {
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-s.scheduleWake:
		}
		for {
			s.mu.Lock()
			if len(s.queue) == 0 || s.automatic || s.downloads >= 2 || s.closed {
				s.mu.Unlock()
				break
			}
			id := s.queue[0]
			s.queue = s.queue[1:]
			t := s.files[id]
			eligible := t != nil && !t.paused && !t.cached && t.remoteState == "completed"
			s.mu.Unlock()
			if eligible && errors.Is(s.start(t, "", true), errTransferBusy) {
				// A manual download may have claimed the last slot after
				// dequeue. Keep this item for the next worker completion.
				s.mu.Lock()
				s.enqueueLocked(t)
				s.mu.Unlock()
				break
			}
		}
	}
}
