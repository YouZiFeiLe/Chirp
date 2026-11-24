package logging

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const dateFormat = "2006-01-02"

type dailyWriter struct {
	mu         sync.Mutex
	directory  string
	date       string
	file       *os.File
	closed     bool
	done       chan struct{}
	stopped    chan struct{}
	now        func() time.Time
	diagnostic *diagnostic
}

func newDailyWriter(directory string, diagnostic *diagnostic) (*dailyWriter, error) {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, fmt.Errorf("create log directory: %w", err)
	}
	w := &dailyWriter{directory: directory, done: make(chan struct{}), stopped: make(chan struct{}), now: time.Now, diagnostic: diagnostic}
	if err := w.rotate(w.now()); err != nil {
		if w.file != nil {
			_ = w.file.Close()
		}
		return nil, err
	}
	go w.maintain()
	return w, nil
}

// rotate and cleanup run under mu. Only our dated regular files are reclaimed.
func (w *dailyWriter) rotate(now time.Time) error {
	date := now.Format(dateFormat)
	if date != w.date {
		file, err := os.OpenFile(filepath.Join(w.directory, "chirp-"+date+".log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
		if err != nil {
			return fmt.Errorf("open daily log: %w", err)
		}
		old := w.file
		w.file, w.date = file, date
		if old != nil {
			if err := old.Close(); err != nil {
				w.diagnostic.report("logging.file_close_failed", err)
			}
		}
	}
	return w.cleanup(now)
}

func (w *dailyWriter) cleanup(now time.Time) error {
	entries, err := os.ReadDir(w.directory)
	if err != nil {
		return fmt.Errorf("read log directory: %w", err)
	}
	cutoff := now.AddDate(0, 0, -6).Format(dateFormat)
	var result error
	for _, entry := range entries {
		if !entry.Type().IsRegular() {
			continue
		}
		name := entry.Name()
		date := strings.TrimSuffix(strings.TrimPrefix(name, "chirp-"), ".log")
		if name != "chirp-"+date+".log" || len(date) != len(dateFormat) {
			continue
		}
		if _, err := time.Parse(dateFormat, date); err != nil || date >= cutoff {
			continue
		}
		if err := os.Remove(filepath.Join(w.directory, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
			result = errors.Join(result, fmt.Errorf("remove expired log %s: %w", name, err))
		}
	}
	return result
}

func (w *dailyWriter) Write(data []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return 0, io.ErrClosedPipe
	}
	// Maintenance also runs without traffic; writes handle the midnight race.
	if now := w.now(); now.Format(dateFormat) != w.date {
		if err := w.rotate(now); err != nil {
			w.diagnostic.report("logging.file_rotation_failed", err)
			if w.date != now.Format(dateFormat) {
				return 0, err
			}
		}
	}
	n, err := w.file.Write(data)
	if err != nil {
		w.diagnostic.report("logging.file_write_failed", err)
	}
	return n, err
}

func (w *dailyWriter) maintain() {
	defer close(w.stopped)
	// Check once a minute, including while idle, and retry failed cleanup.
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-w.done:
			return
		case <-ticker.C:
			w.mu.Lock()
			if !w.closed {
				if err := w.rotate(w.now()); err != nil {
					w.diagnostic.report("logging.file_maintenance_failed", err)
				}
			}
			w.mu.Unlock()
		}
	}
}

func (w *dailyWriter) Close() error {
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return nil
	}
	w.closed = true
	close(w.done)
	err := errors.Join(w.file.Sync(), w.file.Close())
	w.mu.Unlock()
	<-w.stopped
	return err
}
