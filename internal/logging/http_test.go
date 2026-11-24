package logging_test

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpstream"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
)

type logBuffer struct {
	mu sync.Mutex
	bytes.Buffer
}

func (b *logBuffer) Write(data []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.Buffer.Write(data)
}
func (b *logBuffer) snapshot() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.Buffer.String()
}

func TestHTTPLogCorrelatesNestedRoutesAndErrorsWithoutCredentials(t *testing.T) {
	var output logBuffer
	logger := slog.New(slog.NewJSONHandler(&output, nil))
	api := http.NewServeMux()
	api.HandleFunc("POST /v1/rooms/{room}/join", func(w http.ResponseWriter, r *http.Request) {
		logging.Annotate(r.Context(), "member_id", "member_test", "room_id", r.PathValue("room"))
		logging.Request(r, logger).Warn("test failure", "event", "room.join_failed")
		httpresponse.Error(w, 409, "ADMISSION_CHANGED", "retry")
	})
	mux := http.NewServeMux()
	mux.Handle("/v1/", api)
	request := httptest.NewRequest("POST", "/v1/rooms/friends/join?code=secret-query", strings.NewReader(`{"password":"secret-body"}`))
	request.Header.Set("Authorization", "Bearer secret-token")
	request.Header.Set("Cookie", "session=secret-cookie")
	request.Header.Set("X-Request-ID", "untrusted-client-id")
	response := httptest.NewRecorder()
	logging.HTTP(mux, logger).ServeHTTP(response, request)
	id := response.Header().Get("X-Request-ID")
	if id == "" || id == "untrusted-client-id" {
		t.Fatal("request ID missing or trusted caller input", id)
	}
	var records []map[string]any
	decoder := json.NewDecoder(strings.NewReader(output.snapshot()))
	for decoder.More() {
		var record map[string]any
		if err := decoder.Decode(&record); err != nil {
			t.Fatal(err)
		}
		records = append(records, record)
		if record["request_id"] != id || record["route"] != "POST /v1/rooms/{room}/join" || record["member_id"] != "member_test" {
			t.Fatal("uncorrelated request log", record)
		}
	}
	if len(records) != 2 || records[1]["error_code"] != "ADMISSION_CHANGED" || records[1]["status"] != float64(409) {
		t.Fatal("missing completion details", records)
	}
	for _, secret := range []string{"secret-query", "secret-body", "secret-token", "secret-cookie", "untrusted-client-id"} {
		if strings.Contains(output.snapshot(), secret) {
			t.Fatal("credential appeared in logs", secret)
		}
	}
	logging.HTTP(mux, logger).ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/unknown/secret-path?token=hidden", nil))
	if strings.Contains(output.snapshot(), "secret-path") || strings.Contains(output.snapshot(), "token=hidden") {
		t.Fatal("unmatched URL leaked into logs")
	}
}

func TestHTTPPanicReturnsSafeErrorAndRecordsStack(t *testing.T) {
	var output logBuffer
	logger := slog.New(slog.NewJSONHandler(&output, nil))
	handler := logging.HTTP(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { panic("handler broke") }), logger)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest("GET", "/panic", nil))
	if response.Code != 500 || !strings.Contains(response.Body.String(), "INTERNAL_ERROR") || strings.Contains(response.Body.String(), "handler broke") {
		t.Fatal("panic leaked or was not handled", response.Code, response.Body.String())
	}
	for _, expected := range []string{"http.panic", "stack", "http.request_completed", "INTERNAL_ERROR"} {
		if !strings.Contains(output.snapshot(), expected) {
			t.Fatal("panic diagnostic missing", expected)
		}
	}
}

func TestHTTPAbortPreservesNetHTTPContract(t *testing.T) {
	var output logBuffer
	logger := slog.New(slog.NewJSONHandler(&output, nil))
	handler := logging.HTTP(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { panic(http.ErrAbortHandler) }), logger)
	defer func() {
		if value := recover(); value != http.ErrAbortHandler {
			t.Fatal("abort sentinel swallowed", value)
		}
		if strings.Contains(output.snapshot(), "http.panic") {
			t.Fatal("intentional abort logged as a handler panic")
		}
	}()
	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/abort", nil))
}

type deadlineRecorder struct {
	*httptest.ResponseRecorder
	deadlines int
}

func (r *deadlineRecorder) SetWriteDeadline(time.Time) error { r.deadlines++; return nil }

func TestHTTPPreservesSSEFlushAndResponseControllerDeadlines(t *testing.T) {
	var streamError error
	handler := logging.HTTP(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		httpstream.Start(w)
		streamError = errors.Join(httpstream.Write(w, "state", 1, map[string]int{"revision": 1}), httpstream.Ping(w))
	}), slog.New(slog.NewJSONHandler(&logBuffer{}, nil)))
	response := &deadlineRecorder{ResponseRecorder: httptest.NewRecorder()}
	handler.ServeHTTP(response, httptest.NewRequest("GET", "/events", nil))
	if streamError != nil || !response.Flushed || response.deadlines != 4 || !strings.Contains(response.Body.String(), "event: state") {
		t.Fatal("logging wrapper broke SSE/deadlines", streamError, response.Flushed, response.deadlines, response.Body.String())
	}
}

func TestHTTPEventStreamRemainsLiveUntilClientCancels(t *testing.T) {
	exited := make(chan struct{})
	logger := slog.New(slog.NewJSONHandler(&logBuffer{}, nil))
	server := httptest.NewServer(logging.HTTP(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer close(exited)
		httpstream.Start(w)
		if err := httpstream.Write(w, "state", 1, map[string]int{"revision": 1}); err != nil {
			return
		}
		<-r.Context().Done()
	}), logger))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	request, _ := http.NewRequestWithContext(ctx, "GET", server.URL, nil)
	client := &http.Client{Timeout: 2 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	line, err := bufio.NewReader(response.Body).ReadString('\n')
	if err != nil || line != "event: state\n" {
		t.Fatal("stream not flushed immediately", line, err)
	}
	select {
	case <-exited:
		t.Fatal("stream closed before client cancellation")
	default:
	}
	cancel()
	select {
	case <-exited:
	case <-time.After(time.Second):
		t.Fatal("stream did not stop after client cancellation")
	}
}
