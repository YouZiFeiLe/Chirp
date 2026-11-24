package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"github.com/google/uuid"
	"golang.org/x/sys/windows"
)

// Installed once, before the protocol and media workers start. No account state enters the writer.
var installationLog *clientLog

type logOp struct{ table, name string }
type logEntry struct {
	op                     logOp
	ms, seq                int64
	segment, outcome, code string
	duration               *int64
	status                 *int
	details                any // constructed only by the fixed event producers, never from a protocol payload
}

type logSpan struct {
	generation uint64
	start      uint64
}

type clientLog struct {
	store        logStore
	preference   string
	now          func() time.Time
	generation   atomic.Uint64 // odd while enabled, even while disabled
	audio        atomic.Uint32 // only route categories, processing preset and listening
	mu           sync.Mutex
	segment      string
	seq          int64
	callSequence uint64
	callStart    time.Time
	pending      []logEntry
	wake         chan struct{}
	jobs         *actorMailbox[func()]
	done         chan struct{}
	retryAt      time.Time // writer only
}

func openClientLog(data, cache string, now func() time.Time) *clientLog {
	l := &clientLog{store: logStore{dir: filepath.Join(cache, "ClientLogs")}, preference: filepath.Join(data, "client-log.enabled"),
		segment: uuid.NewString(), now: now, wake: make(chan struct{}, 1), jobs: newActorMailbox[func()](), done: make(chan struct{})}
	if b, err := os.ReadFile(l.preference); err == nil && string(b) == "1" {
		l.generation.Store(1)
	}
	l.setAudioContext(args{Listening: true, Preset: defaultAudioPreset})
	go l.run()
	if l.epoch() != 0 {
		l.record(l.epoch(), logEntry{op: logOp{"application", "launch"}, details: logEnvironment()})
	}
	return l
}

func logEnvironment() any {
	v := windows.RtlGetVersion()
	return struct {
		Platform string `json:"platform"`
		Version  string `json:"app_version"`
		Build    int    `json:"app_build"`
		OS       string `json:"os_version"`
	}{"windows", version, build, fmt.Sprintf("%d.%d.%d", v.MajorVersion, v.MinorVersion, v.BuildNumber)}
}

func (l *clientLog) epoch() uint64 {
	if l == nil {
		return 0
	}
	g := l.generation.Load()
	if g%2 == 0 {
		return 0
	}
	return g
}

// Go's Windows monotonic clock can advance in millisecond ticks. A voice frame
// usually authenticates inside one tick, so use QPC for measured operations.
// Media sessions reuse scratch under their existing mutex.
var logKernel = windows.NewLazySystemDLL("kernel32.dll")
var logCounter = logKernel.NewProc("QueryPerformanceCounter")
var logFrequency = sync.OnceValue(func() uint64 {
	var frequency uint64
	logKernel.NewProc("QueryPerformanceFrequency").Call(uintptr(unsafe.Pointer(&frequency)))
	return frequency
})

func logClock(scratch *uint64) uint64 {
	logCounter.Call(uintptr(unsafe.Pointer(scratch)))
	return *scratch
}

func logInterval(start, end uint64) time.Duration {
	ticks, hz := end-start, logFrequency()
	// Split the conversion to avoid overflow on a long-lived stream.
	return time.Duration(ticks/hz)*time.Second + time.Duration(ticks%hz*uint64(time.Second)/hz)
}

func (l *clientLog) begin() logSpan {
	if g := l.epoch(); g != 0 {
		var scratch uint64
		return logSpan{g, logClock(&scratch)}
	}
	return logSpan{}
}

func (l *clientLog) finish(s logSpan, op logOp, err error, status int) {
	if s.generation == 0 || s.generation != l.epoch() || op.name == "" {
		return
	}
	var scratch uint64
	us := logInterval(s.start, logClock(&scratch)).Microseconds()
	row := logEntry{op: op, duration: &us, outcome: "succeeded"}
	var remote *apiError
	if status == 0 && errors.As(err, &remote) {
		status = remote.status
	}
	if status >= 100 && status <= 599 {
		row.status = &status
	}
	switch {
	case errors.Is(err, context.Canceled), errors.Is(err, errJoinCancelled), err != nil && err.Error() == "ATTACHMENT_CANCELLED":
		row.outcome = "cancelled"
	case err != nil || status >= 300:
		row.outcome, row.code = "failed", safeLogError(err)
	}
	l.record(s.generation, row)
}

func (l *clientLog) record(g uint64, row logEntry) {
	if g == 0 || l.epoch() != g {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.epoch() == g {
		l.appendLocked(row)
	}
}

func (l *clientLog) appendLocked(row logEntry) {
	l.seq++
	row.ms, row.seq, row.segment = l.now().UnixMilli(), l.seq, l.segment
	l.pending = append(l.pending, row)
	l.boundLocked()
	if len(l.pending) == 64 {
		signalWorker(l.wake)
	}
}

type omittedLogs struct {
	Count int64 `json:"count"`
}

func (l *clientLog) boundLocked() {
	for len(l.pending) > 2048 {
		var count int64
		for _, row := range l.pending[:512] {
			if lost, ok := row.details.(omittedLogs); ok {
				count += lost.Count
			} else {
				count++
			}
		}
		first := l.pending[0]
		clear(l.pending[:512])
		l.pending = l.pending[511:]
		l.pending[0] = logEntry{op: logOp{"application", "storageOverflow"}, ms: first.ms, seq: first.seq, segment: first.segment, details: omittedLogs{count}}
	}
}

func (l *clientLog) run() {
	_ = l.store.prune(l.now().UnixMilli(), true)
	batch := time.NewTicker(400 * time.Millisecond)
	prune := time.NewTicker(time.Minute)
	defer batch.Stop()
	defer prune.Stop()
	defer l.store.close()
	for {
		select {
		case <-l.done:
			return
		case <-l.jobs.wake:
			for _, work := range l.jobs.take(16) {
				work()
			}
		case <-prune.C:
			_ = l.store.prune(l.now().UnixMilli(), false)
		case <-batch.C:
			l.flushSoon()
		case <-l.wake:
			l.flushSoon()
		}
	}
}

func (l *clientLog) flushSoon() {
	l.mu.Lock()
	pending := len(l.pending) > 0
	l.mu.Unlock()
	if !pending || time.Now().Before(l.retryAt) {
		return
	}
	if _, err := l.flush(); err != nil {
		l.retryAt = time.Now().Add(5 * time.Second)
	}
}

// Detach a snapshot under the short producer lock. No clock, serialization or I/O
// on a disabled media path, and no disk work while holding a producer lock.
func (l *clientLog) flush() (int64, error) {
	l.mu.Lock()
	now := l.now().UnixMilli()
	batch := l.pending
	l.pending = nil
	l.mu.Unlock()
	batch = slices.DeleteFunc(batch, func(e logEntry) bool { return e.ms < now-logRetentionMS })
	for len(batch) != 0 {
		hour, n := batch[0].ms/logHourMS, 1
		for n < len(batch) && batch[n].ms/logHourMS == hour {
			n++
		}
		if err := l.store.write(hour, batch[:n]); err != nil {
			l.mu.Lock()
			l.pending = append(batch, l.pending...)
			l.boundLocked()
			l.mu.Unlock()
			return now, err
		}
		batch = batch[n:]
	}
	l.retryAt = time.Time{}
	return now, nil
}

func (l *clientLog) sync(work func() error) error {
	done := make(chan error, 1)
	l.jobs.push(func() { done <- work() })
	return <-done
}

func (l *clientLog) shutdown() {
	_ = l.sync(func() error {
		l.record(l.epoch(), logEntry{op: logOp{"application", "terminate"}})
		_, err := l.flush()
		l.store.close()
		close(l.done)
		return err
	})
}

func (l *clientLog) newSegmentLocked() {
	l.segment, l.seq, l.callSequence = uuid.NewString(), 0, 0
	l.callStart = time.Time{}
}

// Management operations below run on the same writer as commits and maintenance.
func (l *clientLog) setEnabled(enable bool) error {
	if (l.epoch() != 0) == enable {
		return nil
	}
	if enable {
		if err := os.MkdirAll(filepath.Dir(l.preference), 0700); err != nil {
			return err
		}
		if err := os.WriteFile(l.preference, []byte("1"), 0600); err != nil {
			return err
		}
	} else if err := os.Remove(l.preference); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	l.mu.Lock()
	if enable {
		l.newSegmentLocked()
		l.generation.Add(1)
		l.appendLocked(logEntry{op: logOp{"settings", "recordingEnabled"}, details: logEnvironment()})
	} else {
		l.appendLocked(logEntry{op: logOp{"settings", "recordingDisabled"}})
		l.generation.Add(1)
	}
	l.mu.Unlock()
	l.flushSoon()
	return nil
}

func (l *clientLog) clear(reset bool) error {
	if reset {
		if err := os.Remove(l.preference); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	l.mu.Lock()
	if reset && l.epoch() != 0 {
		l.generation.Add(1)
	} else {
		l.generation.Add(2)
	}
	l.newSegmentLocked()
	l.pending = nil
	l.mu.Unlock()
	l.retryAt = time.Time{}
	l.store.close()
	return os.RemoveAll(l.store.dir)
}
