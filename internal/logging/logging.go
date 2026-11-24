// Package logging owns structured application logs and their storage lifecycle.
package logging

import (
	"io"
	"log/slog"
	"os"
	"sync"
	"time"
)

type Options struct {
	Level     slog.Level
	Directory string
	ServerURL string // VictoriaLogs base URL; empty selects local files.
}

// Open selects exactly one sink. Diagnostics never go back through that sink.
func Open(options Options) (*slog.Logger, io.Closer, error) {
	diagnostic := newDiagnostic(os.Stderr)
	var sink io.WriteCloser
	var err error
	if options.ServerURL != "" {
		sink, err = newRemoteWriter(options.ServerURL, diagnostic)
	} else {
		directory := options.Directory
		if directory == "" {
			directory = "log"
		}
		sink, err = newDailyWriter(directory, diagnostic)
	}
	if err != nil {
		return nil, nil, err
	}
	host, _ := os.Hostname()
	logger := slog.New(slog.NewJSONHandler(sink, &slog.HandlerOptions{Level: options.Level})).With("service", "chirp", "instance", host)
	return logger, sink, nil
}

type diagnostic struct {
	mu     sync.Mutex
	logger *slog.Logger
	last   time.Time
}

func newDiagnostic(output io.Writer) *diagnostic {
	return &diagnostic{logger: slog.New(slog.NewJSONHandler(output, nil)).With("service", "chirp", "module", "logging")}
}

func (d *diagnostic) report(event string, err error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if time.Since(d.last) < 30*time.Second {
		return
	}
	d.last = time.Now()
	d.logger.Error("Log output unavailable", "event", event, "error", err)
}
