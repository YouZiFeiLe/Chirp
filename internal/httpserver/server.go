package httpserver

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
)

func Serve(parent context.Context, address string, handler http.Handler, logger *slog.Logger) error {
	server := &http.Server{Addr: address, Handler: logging.HTTP(handler, logger.With("module", "http")), ErrorLog: slog.NewLogLogger(logger.With("module", "http", "event", "http.server_error").Handler(), slog.LevelError), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second}
	ctx, stop := context.WithCancel(parent)
	defer stop()
	server.BaseContext = func(net.Listener) context.Context { return ctx }
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		<-ctx.Done()
		logger.Info("HTTP server draining", "event", "http.draining")
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdown); err != nil {
			logger.Error("HTTP shutdown failed", "event", "http.shutdown_failed", "error", err)
			_ = server.Close()
		}
	}()
	listener, err := net.Listen("tcp", address)
	if err != nil {
		stop()
		<-stopped
		return err
	}
	logger.Info("HTTP server listening", "event", "http.listening", "listen", listener.Addr().String())
	err = server.Serve(listener)
	stop()
	<-stopped
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
