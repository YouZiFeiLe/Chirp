package logging

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

// FailureTracker exposes outages at the default level without logging every
// background tick. Recovery is recorded once, with the number of failed checks.
type FailureTracker struct {
	mu     sync.Mutex
	Logger *slog.Logger
	Event  string
	failed uint64
	last   time.Time
}

func (f *FailureTracker) Observe(ctx context.Context, err error, attrs ...any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if ctx.Err() != nil {
		return
	}
	if err != nil {
		f.failed++
		if f.failed == 1 || time.Since(f.last) >= 30*time.Second {
			f.last = time.Now()
			f.Logger.WarnContext(ctx, "Background operation unavailable", append([]any{"event", f.Event + ".failed", "error", err, "failed_checks", f.failed}, attrs...)...)
		}
	} else if f.failed > 0 {
		f.Logger.InfoContext(ctx, "Background operation recovered", append([]any{"event", f.Event + ".recovered", "failed_checks", f.failed}, attrs...)...)
		f.failed = 0
	}
}
