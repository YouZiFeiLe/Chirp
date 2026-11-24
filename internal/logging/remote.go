package logging

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	maxQueuedBytes  = 8 << 20
	maxRecordBytes  = 64 << 10
	maxBatchBytes   = 256 << 10
	remoteDrainTime = 5 * time.Second
)

type remoteWriter struct {
	mu          sync.Mutex
	closed      bool
	queuedBytes int
	queue       chan []byte
	done        chan struct{}
	ctx         context.Context
	cancel      context.CancelFunc
	endpoint    string
	client      *http.Client
	dropped     atomic.Uint64
	diagnostic  *diagnostic
	closeErr    error
	once        sync.Once
}

func newRemoteWriter(rawURL string, diagnostic *diagnostic) (*remoteWriter, error) {
	u, err := url.Parse(rawURL)
	if err != nil || u.Hostname() == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || strings.Contains(rawURL, "#") {
		return nil, errors.New("a VictoriaLogs HTTP(S) base URL without credentials, query or fragment is required")
	}
	u.Path = strings.TrimRight(u.Path, "/") + "/insert/jsonline"
	u.RawPath = ""
	query := url.Values{"_time_field": {"time"}, "_msg_field": {"msg"}, "_stream_fields": {"service,instance"}}
	u.RawQuery = query.Encode()
	ctx, cancel := context.WithCancel(context.Background())
	w := &remoteWriter{queue: make(chan []byte, 1024), done: make(chan struct{}), ctx: ctx, cancel: cancel, endpoint: u.String(), diagnostic: diagnostic,
		client: &http.Client{Timeout: 3 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
	go w.run()
	return w, nil
}

// Write never waits for the network and never spools to disk. Bound bytes as
// well as record count so an unavailable server cannot exhaust process memory.
func (w *remoteWriter) Write(data []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return 0, io.ErrClosedPipe
	}
	if len(data) > maxRecordBytes || w.queuedBytes+len(data) > maxQueuedBytes {
		w.drop(1)
		return len(data), nil
	}
	select {
	case w.queue <- bytes.Clone(data):
		w.queuedBytes += len(data)
	default:
		w.drop(1)
	}
	return len(data), nil
}

func (w *remoteWriter) drop(count uint64) {
	w.dropped.Add(count)
	w.diagnostic.report("logging.records_dropped", errors.New("remote log queue or retry budget exhausted; logs were not saved locally"))
}

func (w *remoteWriter) run() {
	defer close(w.done)
	defer w.client.CloseIdleConnections()
	for first := range w.queue {
		batch := append([]byte(nil), first...)
		count := uint64(1)
	drain:
		for len(batch) < maxBatchBytes {
			select {
			case next, ok := <-w.queue:
				if !ok {
					break drain
				}
				batch = append(batch, next...)
				count++
			default:
				break drain
			}
		}
		err := w.deliver(batch)
		w.mu.Lock()
		w.queuedBytes -= len(batch)
		w.mu.Unlock()
		if err != nil {
			w.drop(count)
		} else if dropped := w.dropped.Swap(0); dropped > 0 {
			// Make loss observable in VictoriaLogs after connectivity recovers.
			host, _ := os.Hostname()
			summary, _ := json.Marshal(map[string]any{"time": time.Now(), "level": "WARN", "msg": "Remote log delivery recovered after dropping records", "service": "chirp", "instance": host, "module": "logging", "event": "logging.delivery_recovered", "dropped_records": dropped})
			if err := w.deliver(append(summary, '\n')); err != nil {
				w.dropped.Add(dropped)
			}
		}
	}
}

func (w *remoteWriter) deliver(data []byte) error {
	var last error
	for attempt := range 3 {
		if attempt > 0 {
			timer := time.NewTimer(time.Duration(attempt) * 200 * time.Millisecond)
			select {
			case <-w.ctx.Done():
				timer.Stop()
				return w.ctx.Err()
			case <-timer.C:
			}
		}
		req, err := http.NewRequestWithContext(w.ctx, http.MethodPost, w.endpoint, bytes.NewReader(data))
		if err != nil {
			return err
		}
		req.Header.Set("Content-Type", "application/stream+json")
		response, err := w.client.Do(req)
		if err == nil {
			_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
			_ = response.Body.Close()
			if response.StatusCode >= 200 && response.StatusCode < 300 {
				return nil
			}
			err = fmt.Errorf("VictoriaLogs returned HTTP %d", response.StatusCode)
			// Authentication/format errors cannot be repaired by immediate retry.
			if response.StatusCode < 500 && response.StatusCode != http.StatusTooManyRequests && response.StatusCode != http.StatusRequestTimeout {
				w.diagnostic.report("logging.delivery_failed", err)
				return err
			}
		}
		last = err
		if w.ctx.Err() != nil {
			return w.ctx.Err()
		}
	}
	w.diagnostic.report("logging.delivery_failed", last)
	return last
}

func (w *remoteWriter) Close() error {
	w.once.Do(func() {
		w.mu.Lock()
		w.closed = true
		close(w.queue)
		w.mu.Unlock()
		timer := time.AfterFunc(remoteDrainTime, w.cancel)
		<-w.done
		timer.Stop()
		w.cancel()
		if dropped := w.dropped.Load(); dropped > 0 {
			w.closeErr = fmt.Errorf("%d log records could not be delivered; no local files were created", dropped)
		}
	})
	return w.closeErr
}
