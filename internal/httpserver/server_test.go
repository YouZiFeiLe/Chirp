package httpserver

import (
	"bufio"
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"testing"
	"time"
)

func TestServeReturnsListenFailureWithoutLeakingShutdown(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	err = Serve(ctx, listener.Addr().String(), http.NotFoundHandler(), logger)
	var operation *net.OpError
	if !errors.As(err, &operation) || operation.Op != "listen" {
		t.Fatal("listen failure was not returned", err)
	}
}

func TestServeShutdownCancelsAndDrainsActiveEventStream(t *testing.T) {
	reservation, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := reservation.Addr().String()
	reservation.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	exited := make(chan struct{})
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer close(exited)
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, ": connected\n\n")
		if err := http.NewResponseController(w).Flush(); err != nil {
			return
		}
		<-r.Context().Done()
	})
	done := make(chan error, 1)
	go func() {
		done <- Serve(ctx, address, handler, slog.New(slog.NewTextHandler(io.Discard, nil)))
	}()
	defer func() {
		cancel()
		select {
		case err := <-done:
			if err != nil {
				t.Error("HTTP shutdown failed", err)
			}
		case <-time.After(3 * time.Second):
			t.Error("HTTP server did not drain")
		}
	}()
	client := &http.Client{Timeout: 3 * time.Second}
	deadline := time.Now().Add(2 * time.Second)
	var response *http.Response
	for {
		response, err = client.Get("http://" + address + "/events")
		if err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("HTTP server did not start", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	defer response.Body.Close()
	if line, err := bufio.NewReader(response.Body).ReadString('\n'); err != nil || line != ": connected\n" {
		t.Fatal("stream was not established", line, err)
	}
	cancel()
	select {
	case <-exited:
	case <-time.After(time.Second):
		t.Fatal("shutdown left the active event handler running")
	}
}
