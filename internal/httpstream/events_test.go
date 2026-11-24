package httpstream

import (
	"bufio"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type boundedWriter struct {
	*httptest.ResponseRecorder
	deadline   time.Time
	deadlines  []time.Time
	flushed    bool
	flushError error
}

func (w *boundedWriter) SetWriteDeadline(deadline time.Time) error {
	w.deadline = deadline
	w.deadlines = append(w.deadlines, deadline)
	return nil
}
func (w *boundedWriter) FlushError() error { w.flushed = true; return w.flushError }

func TestEventsAreBoundedFlushedAndHaveAnIndependentWriteDeadline(t *testing.T) {
	w := &boundedWriter{ResponseRecorder: httptest.NewRecorder()}
	Start(w)
	before := time.Now()
	if err := Write(w, "state", 7, map[string]string{"server_id": "server\nnew"}); err != nil {
		t.Fatal(err)
	}
	if !w.flushed || len(w.deadlines) != 2 || w.deadlines[0].Before(before.Add(3*time.Second)) || w.deadlines[0].After(time.Now().Add(3*time.Second)) || !w.deadline.IsZero() {
		t.Fatal("write has no bounded deadline/flush", w.deadline)
	}
	if !strings.Contains(w.Body.String(), "id: 7\n") || strings.Contains(w.Body.String(), "server\nnew") {
		t.Fatal("invalid SSE escaping", w.Body.String())
	}
	beforeBytes := w.Body.Len()
	if err := Write(w, "state", 8, strings.Repeat("x", 4096)); err == nil || beforeBytes != w.Body.Len() {
		t.Fatal("oversized event was buffered or written")
	}
	w.flushError = errors.New("slow consumer disconnected")
	if err := Ping(w); !errors.Is(err, w.flushError) {
		t.Fatal("writer lost downstream error", err)
	}
}

func TestIdleHTTP2EventConnectionSurvivesItsPreviousWriteDeadline(t *testing.T) {
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		Start(w)
		if Write(w, "state", 1, map[string]int{"revision": 1}) != nil {
			return
		}
		timer := time.NewTimer(3200 * time.Millisecond)
		defer timer.Stop()
		select {
		case <-r.Context().Done():
			return
		case <-timer.C:
		}
		_ = Write(w, "state", 2, map[string]int{"revision": 2})
	}))
	server.EnableHTTP2 = true
	server.Config.WriteTimeout = 100 * time.Millisecond
	server.StartTLS()
	defer server.Close()
	client := server.Client()
	client.Timeout = 6 * time.Second
	response, err := client.Get(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.ProtoMajor != 2 {
		t.Fatal("test did not negotiate HTTP/2")
	}
	reader := bufio.NewReader(response.Body)
	for _, revision := range []string{"1", "2"} {
		var frame strings.Builder
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				t.Fatal("idle event stream was reset by the previous write deadline", err)
			}
			frame.WriteString(line)
			if line == "\n" {
				break
			}
		}
		if !strings.Contains(frame.String(), "id: "+revision+"\n") {
			t.Fatal(frame.String())
		}
	}
}
