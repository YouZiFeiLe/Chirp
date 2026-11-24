package logging

import (
	"context"
	"crypto/rand"
	"errors"
	"log/slog"
	"net/http"
	"runtime/debug"
	"strings"
	"sync"
	"time"
)

type requestKey struct{}
type requestFields struct {
	mu    sync.Mutex
	id    string
	attrs map[string]any
}

// Annotate adds identifiers/results to the request summary, never raw bodies or
// credentials. It is also safe for background work scoped to this request.
func Annotate(ctx context.Context, attrs ...any) {
	fields, _ := ctx.Value(requestKey{}).(*requestFields)
	if fields == nil {
		return
	}
	fields.mu.Lock()
	defer fields.mu.Unlock()
	for i := 0; i+1 < len(attrs); i += 2 {
		if key, ok := attrs[i].(string); ok {
			fields.attrs[key] = attrs[i+1]
		}
	}
}

func Request(r *http.Request, logger *slog.Logger) *slog.Logger {
	attrs := []any{"method", r.Method, "route", route(r)}
	if fields, ok := r.Context().Value(requestKey{}).(*requestFields); ok {
		fields.mu.Lock()
		attrs = append(attrs, "request_id", fields.id)
		for key, value := range fields.attrs {
			attrs = append(attrs, key, value)
		}
		fields.mu.Unlock()
	}
	return logger.With(attrs...)
}

func route(r *http.Request) string {
	if r.Pattern != "" {
		return r.Pattern
	}
	// Unmatched paths and query strings can contain registration receipts or
	// login proofs. Never include the original URL as a fallback.
	return "unmatched"
}

type responseWriter struct {
	http.ResponseWriter
	status    int
	bytes     int64
	errorCode string
	writeErr  error
}

func (w *responseWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
func (w *responseWriter) RecordError(code string)     { w.errorCode = code }
func (w *responseWriter) WriteHeader(status int) {
	if status >= 100 && status < 200 && status != http.StatusSwitchingProtocols {
		w.ResponseWriter.WriteHeader(status)
		return
	}
	if w.status != 0 {
		return
	}
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}
func (w *responseWriter) Write(data []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	n, err := w.ResponseWriter.Write(data)
	w.bytes += int64(n)
	if err != nil && w.writeErr == nil {
		w.writeErr = err
	}
	return n, err
}
func (w *responseWriter) FlushError() error {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	err := http.NewResponseController(w.ResponseWriter).Flush()
	if err != nil && w.writeErr == nil {
		w.writeErr = err
	}
	return err
}
func (w *responseWriter) Flush() { _ = w.FlushError() }

// HTTP records completed requests while preserving ResponseController access to
// flushing and deadlines, which the SSE and attachment handlers depend on.
func HTTP(next http.Handler, logger *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		fields := &requestFields{id: rand.Text(), attrs: make(map[string]any)}
		r = r.WithContext(context.WithValue(r.Context(), requestKey{}, fields))
		w.Header().Set("X-Request-ID", fields.id)
		response := &responseWriter{ResponseWriter: w}
		defer func() {
			panicked := recover()
			abort := panicked == http.ErrAbortHandler
			if panicked != nil && !abort {
				Request(r, logger).Error("HTTP handler panicked", "event", "http.panic", "panic", panicked, "stack", string(debug.Stack()))
				response.RecordError("INTERNAL_ERROR")
				if response.status == 0 {
					response.Header().Set("Content-Type", "application/json; charset=utf-8")
					response.WriteHeader(http.StatusInternalServerError)
					_, _ = response.Write([]byte("{\"error\":{\"code\":\"INTERNAL_ERROR\",\"message\":\"服务暂时出现错误\"}}\n"))
				} else {
					abort = true // Terminate an already-started response/stream.
				}
			}
			if response.status == 0 {
				response.status = http.StatusOK
			}
			stream := strings.HasPrefix(response.Header().Get("Content-Type"), "text/event-stream")
			elapsed := time.Since(started)
			level := slog.LevelInfo
			if quietRequest(r, stream) {
				level = slog.LevelDebug
			}
			if !stream && elapsed >= time.Second {
				level = slog.LevelWarn
			}
			if response.status >= 400 {
				level = slog.LevelWarn
			}
			if response.status >= 500 || panicked != nil && panicked != http.ErrAbortHandler {
				level = slog.LevelError
			}
			attrs := []any{"event", "http.request_completed", "status", response.status, "bytes", response.bytes, "duration_ms", elapsed.Milliseconds()}
			if abort {
				attrs = append(attrs, "aborted", true)
			}
			if response.errorCode != "" {
				attrs = append(attrs, "error_code", response.errorCode)
			}
			if r.Context().Err() != nil {
				attrs = append(attrs, "cancelled", true)
			} else if response.writeErr != nil && !errors.Is(response.writeErr, context.Canceled) {
				attrs = append(attrs, "error", response.writeErr)
				level = slog.LevelWarn
			}
			Request(r, logger).Log(r.Context(), level, "HTTP request completed", attrs...)
			if abort {
				panic(http.ErrAbortHandler)
			}
		}()
		next.ServeHTTP(response, r)
	})
}

func quietRequest(r *http.Request, stream bool) bool {
	if stream {
		return true
	}
	switch r.Pattern {
	case "GET /healthz", "GET /livez", "GET /admin/healthz", "GET /v1/state", "GET /v1/session", "GET /api/auth/session", "GET /admin/api/overview", "POST /api/client/device/poll":
		return true
	}
	if fields, ok := r.Context().Value(requestKey{}).(*requestFields); ok {
		fields.mu.Lock()
		defer fields.mu.Unlock()
		switch fields.attrs["group_operation"] {
		case "heartbeat", "lease", "snapshot":
			return true
		}
	}
	return false
}
