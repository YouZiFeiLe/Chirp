package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net/http"
	"strings"
	"time"
)

type remoteFile struct {
	ID        string
	Room      string `json:"room_id"`
	Size      int64  `json:"ciphertext_size"`
	Digest    string `json:"ciphertext_sha256"`
	Uploaded  int    `json:"uploaded_chunks"`
	State     string
	Revision  uint64
	Updated   int64    `json:"updated_at"`
	Completed int64    `json:"completed_at"`
	Expires   int64    `json:"expires_at"`
	Protocol  int      `json:"protocol_version"`
	Chunk     int      `json:"chunk_bytes"`
	Hashes    []string `json:"chunk_sha256"`
}

func (r remoteFile) uploaded() bool { return r.State == "completed" || r.State == "delivered" }
func (r remoteFile) terminal() bool { return r.State == "cancelled" || r.State == "expired" }
func (t *transfer) identifies(r remoteFile) bool {
	t.session.mu.Lock()
	defer t.session.mu.Unlock()
	return r.valid(t.d.Info)
}
func (r remoteFile) valid(i fileInfo) bool {
	count := int((i.cipherSize() + fileChunk - 1) / fileChunk)
	switch r.State {
	case "reserved", "uploading", "paused", "completed", "delivered", "cancelled", "expired":
	default:
		return false
	}
	return r.Protocol == 3 && r.Chunk == fileChunk && r.ID == i.ID && r.Room == i.Room && r.Size == i.cipherSize() && r.Digest == i.Digest &&
		r.Revision > 0 && r.Updated > 0 && r.Expires > 0 && r.Completed >= 0 && r.Uploaded >= 0 && r.Uploaded <= count &&
		(r.State != "reserved" || r.Uploaded == 0) && (!r.uploaded() || r.Uploaded == count && r.Completed > 0) &&
		(r.Completed == 0 || r.uploaded() || r.State == "expired") && (r.terminal() || r.State == "delivered" || r.Expires > time.Now().Unix())
}
func (t *transfer) matches(r remoteFile) bool { return !r.terminal() && t.identifies(r) }
func admissionEntry(identity string) string {
	_, after, _ := strings.Cut(identity, ".login_")
	_, entry, _ := strings.Cut(after, ".")
	return entry
}
func (t *transfer) headers() http.Header {
	return http.Header{"X-Chirp-Entry": {admissionEntry(t.entry)}}
}
func waitAttachment(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
func retryableAttachment(err error) bool {
	if err == nil {
		return false
	}
	var remote *apiError
	if errors.As(err, &remote) {
		return remote.status == 408 || remote.status == 429 || remote.status >= 500
	}
	return err.Error() == "SERVER_UNAVAILABLE" || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, context.DeadlineExceeded)
}
func retryAttachment(ctx context.Context, work func(context.Context) error) error {
	ctx, stop := context.WithTimeout(ctx, 30*time.Second)
	defer stop()
	deadline, _ := ctx.Deadline()
	for attempt := 0; ; attempt++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		err := work(ctx)
		if !retryableAttachment(err) || attempt == 3 {
			return err
		}
		var remote *apiError
		backoff := 250 * time.Millisecond << attempt
		if errors.As(err, &remote) {
			backoff = max(backoff, remote.retryAfter)
		}
		backoff += time.Duration(rand.IntN(151)) * time.Millisecond
		if time.Until(deadline) <= backoff {
			return err
		}
		if err = waitAttachment(ctx, backoff); err != nil {
			return err
		}
	}
}
func (t *transfer) request(ctx context.Context, method, suffix string, body, out any) error {
	h := t.headers()
	if _, ok := body.([]byte); ok {
		h.Set("Content-Type", "application/octet-stream")
	}
	_, err := request(ctx, attachmentRequestName(method, suffix), method, t.base+suffix, body, t.credential, h, out, 256<<10)
	return err
}
func (t *transfer) budget(ctx context.Context, n int64, direction int) error {
	m := t.media
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := t.ctx.Err(); err != nil {
			return err
		}
		m.mu.Lock()
		now := ticks()
		if m.closed {
			m.mu.Unlock()
			return errors.New("ATTACHMENT_UNAVAILABLE")
		}
		rate := m.fileRateLocked()
		ready := rate > 0 && now < m.until && now >= m.nextFile[direction]
		if ready && n > 0 {
			m.nextFile[direction] = now + max(1, n*1000/rate)
		}
		m.mu.Unlock()
		policy := ""
		if rate == 0 {
			policy = "paused"
		} else if rate < 8<<20 {
			policy = "constrained"
		}
		s := t.session
		s.mu.Lock()
		var update obj
		if t.running && t.networkPolicy != policy {
			t.networkPolicy = policy
			update = t.eventLocked()
		}
		s.mu.Unlock()
		if update != nil {
			s.report("transfer", update)
		}
		if ready {
			return nil
		}
		if err := waitAttachment(ctx, 25*time.Millisecond); err != nil {
			return err
		}
	}
}
func (t *transfer) api(ctx context.Context, method, suffix string, body, out any) error {
	return retryAttachment(ctx, func(ctx context.Context) error {
		if err := t.budget(ctx, 0, 0); err != nil {
			return err
		}
		return t.request(ctx, method, suffix, body, out)
	})
}
func (t *transfer) control(ctx context.Context, op string, out any) error {
	var body any
	if op == "received" {
		body = obj{"ciphertext_sha256": t.d.Info.Digest}
	}
	return retryAttachment(ctx, func(ctx context.Context) error {
		if err := t.ctx.Err(); err != nil {
			return err
		}
		return t.request(ctx, "POST", "/"+t.d.Info.ID+"/"+op, body, out)
	})
}
func (t *transfer) chunk(ctx context.Context, index int, size int64) (result []byte, resultErr error) {
	span := installationLog.begin()
	status := 0
	defer func() { installationLog.finish(span, logOp{"network", "downloadChunk"}, resultErr, status) }()
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", fmt.Sprintf("%s/%s/chunks/%d", t.base, t.d.Info.ID, index), nil)
	if err != nil {
		return nil, err
	}
	req.Header = t.headers()
	req.Header.Set("Authorization", "Bearer "+t.credential)
	resp, err := client.Do(req)
	if err != nil {
		return nil, errors.New("SERVER_UNAVAILABLE")
	}
	status = resp.StatusCode
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, &apiError{code: fmt.Sprintf("HTTP_%d", resp.StatusCode), status: resp.StatusCode, authenticated: true, retryAfter: parseRetryAfter(resp.Header.Get("Retry-After"))}
	}
	if resp.Header.Get("Content-Type") != "application/octet-stream" {
		return nil, invalid
	}
	if resp.ContentLength > size {
		return nil, errAttachmentIntegrity
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, size+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) != size {
		return nil, errAttachmentIntegrity
	}
	return b, nil
}
func (t *transfer) receipt() {
	s := t.session
	s.mu.Lock()
	if s.closed || t.ctx.Err() != nil || t.source != "" || !t.cached || t.acknowledged || t.receiptDone != nil {
		s.mu.Unlock()
		return
	}
	done := make(chan struct{})
	t.receiptDone = done
	s.workers.Add(1)
	s.mu.Unlock()
	go func() {
		defer s.workers.Done()
		defer func() { s.mu.Lock(); close(done); t.receiptDone = nil; s.mu.Unlock() }()
		ctx, stop := context.WithTimeout(t.ctx, 15*time.Minute)
		defer stop()
		for ctx.Err() == nil {
			var remote remoteFile
			err := t.control(ctx, "received", &remote)
			if err == nil {
				if remote.uploaded() && t.identifies(remote) {
					s.apply(remote)
					s.mu.Lock()
					t.acknowledged = true
					s.mu.Unlock()
				}
				return
			}
			if !retryableAttachment(err) || waitAttachment(ctx, 2*time.Second) != nil {
				return
			}
		}
	}()
}

type fileHint struct {
	Server   string `json:"server_id"`
	Room     string `json:"room_id"`
	Revision uint64 `json:"revision"`
}

func (h fileHint) valid(room string) bool {
	return h.Room == room && h.Server != "" && len(h.Server) <= 128 && h.Revision > 0
}

type fileCatalog struct {
	fileHint
	Files []remoteFile `json:"attachments"`
}

func (s *attachmentSession) apply(r remoteFile) {
	s.mu.Lock()
	t := s.files[r.ID]
	if t == nil || s.closed || t.terminal || !r.valid(t.d.Info) || r.Revision < t.remoteRevision {
		s.mu.Unlock()
		return
	}
	prev := t.remoteState
	erase := r.State == "cancelled" || r.State == "expired" && (!t.cached || r.Completed == 0) || r.State == "delivered" && !t.cached
	if t.remoteRevision == r.Revision && prev == r.State && !erase {
		s.mu.Unlock()
		return
	}
	if prev == "delivered" && r.State != "delivered" || prev == "completed" && !r.uploaded() && r.State != "expired" || (prev == "cancelled" || prev == "expired") && !r.terminal() {
		s.mu.Unlock()
		return
	}
	t.remoteState, t.remoteRevision = r.State, r.Revision
	if erase {
		t.terminal = true
		t.cached = false
		t.retire()
		s.workers.Add(1)
	} else if r.uploaded() && t.source != "" {
		t.completed = true
		t.cancelling = false
		t.paused = false
	}
	if r.State == "completed" {
		s.enqueueLocked(t)
	}
	data := t.eventLocked()
	data["done"] = !erase && t.cached && (t.source == "" || t.completed)
	s.mu.Unlock()
	s.report("transfer", data)
	if erase {
		go func() { defer s.workers.Done(); s.discard(t) }()
	}
	s.wakeDownloads()
}
func (s *attachmentSession) revoke() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed, s.revoked = true, true
	s.cancel()
	s.mu.Unlock()
	s.notify("attachmentRevoked", s)
}
func (s *attachmentSession) catalogLoop() {
	var latest fileHint
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-s.catalogWake:
		}
		// Only expire objects already known to this entry before issuing this GET.
		s.mu.Lock()
		known := map[string]uint64{}
		for id, t := range s.files {
			if t.remoteRevision > 0 && t.source == "" && !t.cached {
				known[id] = t.remoteRevision
			}
		}
		s.mu.Unlock()
		var c fileCatalog
		err := retryAttachment(s.ctx, func(ctx context.Context) error {
			_, err := request(ctx, "attachmentCatalog", "GET", s.base, nil, s.credential, http.Header{"X-Chirp-Entry": {admissionEntry(s.entry)}}, &c, 4<<20)
			return err
		})
		if err != nil {
			var api *apiError
			if errors.As(err, &api) && (api.status == 401 || api.status == 403) {
				s.revoke()
				return
			}
			if s.ctx.Err() != nil {
				return
			}
			if waitAttachment(s.ctx, time.Second) == nil {
				s.wakeCatalog()
			}
			continue
		}
		if !c.valid(s.room) || c.Files == nil || len(c.Files) > 4096 || c.Server == latest.Server && c.Revision < latest.Revision {
			continue
		}
		present := map[string]bool{}
		valid := true
		for _, r := range c.Files {
			if !fileID.MatchString(r.ID) || present[r.ID] {
				valid = false
				break
			}
			present[r.ID] = true
		}
		if !valid {
			continue
		}
		latest = c.fileHint
		for _, r := range c.Files {
			s.apply(r)
		}
		for id, revision := range known {
			if present[id] {
				continue
			}
			s.mu.Lock()
			t := s.files[id]
			expired := t != nil && t.remoteRevision == revision && !t.cached && !t.terminal
			var data obj
			if expired {
				t.terminal = true
				t.remoteState = "expired"
				data = t.eventLocked()
			}
			s.mu.Unlock()
			if expired {
				s.report("transfer", data)
				s.discard(t)
			}
		}
	}
}
func (s *attachmentSession) watch() {
	delays := []time.Duration{500 * time.Millisecond, time.Second, 2 * time.Second, 5 * time.Second}
	for failures := 0; s.ctx.Err() == nil; failures++ {
		req, err := http.NewRequestWithContext(s.ctx, "GET", s.base+"/events", nil)
		if err != nil {
			return
		}
		req.Header.Set("X-Chirp-Entry", admissionEntry(s.entry))
		req.Header.Set("Authorization", "Bearer "+s.credential)
		req.Header.Set("Accept", "text/event-stream")
		span := installationLog.begin()
		resp, err := client.Do(req)
		endStream := streamLog(span, "attachmentEventStreamEnded", s.ctx, resp, err)
		if err == nil {
			revoked := resp.StatusCode == 401 || resp.StatusCode == 403
			if resp.StatusCode == 200 && strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
				s.wakeCatalog()
				scanner := bufio.NewScanner(resp.Body)
				var event, data string
				var last fileHint
			stream:
				for scanner.Scan() {
					line := scanner.Text()
					switch {
					case line == "":
						switch event {
						case "revoked":
							revoked = true
							break stream
						case "state":
							var h fileHint
							if json.Unmarshal([]byte(data), &h) != nil || !h.valid(s.room) {
								break stream
							}
							if h.Server != last.Server || h.Revision > last.Revision {
								s.wakeCatalog()
								last = h
							}
							failures = 0
						case "":
						default:
							break stream
						}
						event, data = "", ""
					case strings.HasPrefix(line, "event:"):
						event = strings.TrimSpace(line[6:])
					case strings.HasPrefix(line, "data:"):
						data = strings.TrimSpace(line[5:])
					}
				}
			}
			resp.Body.Close()
			endStream()
			if revoked {
				s.revoke()
				return
			}
		} else {
			endStream()
		}
		if waitAttachment(s.ctx, delays[min(failures, len(delays)-1)]) != nil {
			return
		}
	}
}
