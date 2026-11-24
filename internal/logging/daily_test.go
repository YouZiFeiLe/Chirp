package logging

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testfs"
)

func TestDailyRetentionUsesCalendarDatesAndOnlyOwnedRegularFiles(t *testing.T) {
	directory := t.TempDir()
	now := time.Now()
	for offset := -10; offset <= 0; offset++ {
		name := "chirp-" + now.AddDate(0, 0, offset).Format(dateFormat) + ".log"
		if err := os.WriteFile(filepath.Join(directory, name), nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"operator.log", "chirp-invalid.log", "chirp-2026-99-99.log"} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte("keep"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	oldDirectory := filepath.Join(directory, "chirp-2000-01-01.log")
	if err := os.Mkdir(oldDirectory, 0700); err != nil {
		t.Fatal(err)
	}
	w, err := newDailyWriter(directory, newDiagnostic(io.Discard))
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	for offset := -10; offset <= 0; offset++ {
		_, err := os.Stat(filepath.Join(directory, "chirp-"+now.AddDate(0, 0, offset).Format(dateFormat)+".log"))
		if (err == nil) != (offset >= -6) {
			t.Fatalf("date offset %d retained incorrectly: %v", offset, err)
		}
	}
	for _, path := range []string{oldDirectory, filepath.Join(directory, "operator.log"), filepath.Join(directory, "chirp-invalid.log"), filepath.Join(directory, "chirp-2026-99-99.log")} {
		if _, err := os.Lstat(path); err != nil {
			t.Fatalf("unrelated file removed: %s: %v", path, err)
		}
	}
	t.Run("symlink", func(t *testing.T) {
		link := filepath.Join(directory, "chirp-2000-01-02.log")
		testfs.Symlink(t, filepath.Join(directory, "operator.log"), link)
		w.mu.Lock()
		err := w.cleanup(now)
		w.mu.Unlock()
		if err != nil {
			t.Fatal(err)
		}
		if _, err := os.Lstat(link); err != nil {
			t.Fatal("retention removed a symbolic link", err)
		}
	})
}

func TestDailyRotationAcrossMidnightAndIdleCleanup(t *testing.T) {
	w, err := newDailyWriter(t.TempDir(), newDiagnostic(io.Discard))
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	zone := time.FixedZone("UTC+8", 8*60*60)
	before := time.Date(2026, 10, 26, 23, 59, 59, 0, zone)
	w.mu.Lock()
	w.now = func() time.Time { return before }
	w.mu.Unlock()
	if _, err := w.Write([]byte("before\n")); err != nil {
		t.Fatal(err)
	}
	w.mu.Lock()
	w.now = func() time.Time { return before.Add(2 * time.Second) }
	w.mu.Unlock()
	if _, err := w.Write([]byte("after\n")); err != nil {
		t.Fatal(err)
	}
	for date, expected := range map[string]string{"2026-10-26": "before\n", "2026-10-27": "after\n"} {
		data, err := os.ReadFile(filepath.Join(w.directory, "chirp-"+date+".log"))
		if err != nil || string(data) != expected {
			t.Fatalf("%s: %q, %v", date, data, err)
		}
	}
	// Exercise the same maintenance operation used by the timer, with no write.
	w.mu.Lock()
	err = w.rotate(before.AddDate(0, 0, 7))
	w.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(w.directory, "chirp-2026-10-26.log")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("idle maintenance did not remove expired log", err)
	}
	if _, err := os.Stat(filepath.Join(w.directory, "chirp-2026-10-27.log")); err != nil {
		t.Fatal("idle maintenance removed a retained date", err)
	}
}

func TestLocalConcurrentJSONWritesAppendAndPermissions(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "log")
	for range 2 {
		logger, sink, err := Open(Options{Directory: directory})
		if err != nil {
			t.Fatal(err)
		}
		var wg sync.WaitGroup
		for worker := range 16 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for entry := range 32 {
					logger.Info("test", "worker", worker, "entry", entry)
				}
			}()
		}
		wg.Wait()
		if err := sink.Close(); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(directory, "chirp-"+time.Now().Format(dateFormat)+".log")
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	count := 0
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		var record map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &record); err != nil || record["service"] != "chirp" {
			t.Fatal("corrupt concurrent JSON log", scanner.Text(), err)
		}
		count++
	}
	if err := scanner.Err(); err != nil || count != 1024 {
		t.Fatal("missing log records", count, err)
	}
	// FileMode.Perm does not represent Windows ACLs.
	if runtime.GOOS == "windows" {
		return
	}
	for path, mode := range map[string]os.FileMode{directory: 0700, path: 0600} {
		stat, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if stat.Mode().Perm() != mode {
			t.Errorf("permissions for %s = %04o, want %04o", path, stat.Mode().Perm(), mode)
		}
	}
}
