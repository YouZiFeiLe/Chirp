// Package httpstream writes bounded, unbuffered SSE notifications.
package httpstream

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"
)

func Start(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Accel-Buffering", "no")
}

func Write(w http.ResponseWriter, event string, revision uint64, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(data) > 4096 {
		return errors.New("event notification exceeds limit")
	}
	controller := http.NewResponseController(w)
	if err := controller.SetWriteDeadline(time.Now().Add(3 * time.Second)); err != nil && !errors.Is(err, http.ErrNotSupported) {
		return err
	}
	// Bound the write, not the idle stream: HTTP/2 otherwise resets an idle
	// response when this timer expires before the next keepalive.
	defer controller.SetWriteDeadline(time.Time{})
	if _, err := fmt.Fprintf(w, "event: %s\nid: %d\ndata: %s\n\n", event, revision, data); err != nil {
		return err
	}
	return controller.Flush()
}

func Ping(w http.ResponseWriter) error {
	controller := http.NewResponseController(w)
	if err := controller.SetWriteDeadline(time.Now().Add(3 * time.Second)); err != nil && !errors.Is(err, http.ErrNotSupported) {
		return err
	}
	defer controller.SetWriteDeadline(time.Time{})
	if _, err := fmt.Fprint(w, ": keepalive\n\n"); err != nil {
		return err
	}
	return controller.Flush()
}
