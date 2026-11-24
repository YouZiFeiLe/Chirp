package logging

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestRemoteDeliversEveryRecordAndNeverCreatesLocalDirectory(t *testing.T) {
	var mu sync.Mutex
	var records []map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/prefix/insert/jsonline" || r.Header.Get("Content-Type") != "application/stream+json" || r.URL.Query().Get("_time_field") != "time" || r.URL.Query().Get("_msg_field") != "msg" || r.URL.Query().Get("_stream_fields") != "service,instance" {
			t.Errorf("unexpected ingestion request: %s %s", r.Method, r.URL)
		}
		decoder := json.NewDecoder(r.Body)
		for {
			var record map[string]any
			if err := decoder.Decode(&record); err == io.EOF {
				break
			} else if err != nil {
				t.Error(err)
				break
			}
			mu.Lock()
			records = append(records, record)
			mu.Unlock()
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	directory := filepath.Join(t.TempDir(), "must-not-exist")
	logger, sink, err := Open(Options{Directory: directory, ServerURL: server.URL + "/prefix/"})
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for worker := range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for entry := range 20 {
				logger.Info("remote test", "worker", worker, "entry", entry)
			}
		}()
	}
	wg.Wait()
	if err := sink.Close(); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(records) != 160 {
		t.Fatal("missing remotely delivered records", len(records))
	}
	for _, record := range records {
		stamp, err := time.Parse(time.RFC3339Nano, record["time"].(string))
		if err != nil || time.Since(stamp).Abs() > time.Minute || record["service"] != "chirp" || record["msg"] != "remote test" {
			t.Fatal("invalid ingested log", record, err)
		}
	}
	if _, err := os.Stat(directory); !os.IsNotExist(err) {
		t.Fatal("remote mode touched local log directory", err)
	}
}

func TestRemoteRetriesTransientFailureWithSamePayload(t *testing.T) {
	var attempts atomic.Int32
	var mu sync.Mutex
	var payloads [][]byte
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		payloads = append(payloads, body)
		mu.Unlock()
		switch attempts.Add(1) {
		case 1:
			w.WriteHeader(503)
		case 2:
			w.WriteHeader(429)
		default:
			w.WriteHeader(204)
		}
	}))
	defer server.Close()
	w, err := newRemoteWriter(server.URL, newDiagnostic(io.Discard))
	if err != nil {
		t.Fatal(err)
	}
	_, _ = w.Write([]byte("{\"msg\":\"retry\"}\n"))
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	if attempts.Load() != 3 || !bytes.Equal(payloads[0], payloads[1]) || !bytes.Equal(payloads[1], payloads[2]) {
		t.Fatal("retry changed payload or attempt count", payloads)
	}
}

func TestRemoteDoesNotRetryAuthenticationFailureAndReportsLossAfterRecovery(t *testing.T) {
	var attempts atomic.Int32
	first := make(chan struct{})
	var recovered atomic.Uint64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if attempts.Add(1) == 1 {
			w.WriteHeader(401)
			close(first)
			return
		}
		decoder := json.NewDecoder(r.Body)
		for {
			var record map[string]any
			if err := decoder.Decode(&record); err != nil {
				break
			}
			if record["event"] == "logging.delivery_recovered" {
				recovered.Store(uint64(record["dropped_records"].(float64)))
			}
		}
		w.WriteHeader(204)
	}))
	defer server.Close()
	w, err := newRemoteWriter(server.URL, newDiagnostic(io.Discard))
	if err != nil {
		t.Fatal(err)
	}
	_, _ = w.Write([]byte("{\"msg\":\"first\"}\n"))
	select {
	case <-first:
	case <-time.After(time.Second):
		t.Fatal("log delivery was not immediate")
	}
	_, _ = w.Write([]byte("{\"msg\":\"second\"}\n"))
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	if attempts.Load() != 3 || recovered.Load() != 1 {
		t.Fatal("authentication failure was retried or loss was not reported", attempts.Load(), recovered.Load())
	}
}

func TestRemoteQueueIsBoundedAndWritesDoNotWaitForNetwork(t *testing.T) {
	blocked, release := make(chan struct{}), make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-blocked:
		default:
			close(blocked)
		}
		<-release
		w.WriteHeader(503)
	}))
	defer server.Close()
	defer close(release)
	w, err := newRemoteWriter(server.URL, newDiagnostic(io.Discard))
	if err != nil {
		t.Fatal(err)
	}
	_, _ = w.Write([]byte("{}\n"))
	<-blocked
	done := make(chan struct{})
	go func() {
		defer close(done)
		for range 2000 {
			_, _ = w.Write(bytes.Repeat([]byte("x"), 32<<10))
		}
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("log producers blocked on an unavailable server")
	}
	w.mu.Lock()
	queued := w.queuedBytes
	w.mu.Unlock()
	if queued > maxQueuedBytes || w.dropped.Load() == 0 {
		t.Fatal("queue was not bounded", queued, w.dropped.Load())
	}
	w.cancel()
	if err := w.Close(); err == nil {
		t.Fatal("lost logs not reported on close")
	}
}

func TestRemoteCloseHasDeadlineAndCreatesNoFallbackFiles(t *testing.T) {
	t.Chdir(t.TempDir())
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-release }))
	defer server.Close()
	defer close(release)
	logger, sink, err := Open(Options{ServerURL: server.URL})
	if err != nil {
		t.Fatal(err)
	}
	logger.Error("will time out")
	started := time.Now()
	if err := sink.Close(); err == nil || time.Since(started) > remoteDrainTime+time.Second {
		t.Fatal("shutdown was unbounded or failed delivery was hidden", err, time.Since(started))
	}
	entries, err := os.ReadDir(".")
	if err != nil || len(entries) != 0 {
		t.Fatal("remote failure created local log files", entries, err)
	}
}
