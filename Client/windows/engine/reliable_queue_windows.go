package main

import (
	"context"
	"slices"
	"sync"
	"time"
)

// Publish in arrival order, including contiguous batches of a descriptor.
// A waiting operation retains its original deadline and can withdraw before
// reaching the front even if the current RTC channel is backpressured.
type reliableQueue struct {
	mu      sync.Mutex
	waiters []chan struct{}
}

func (q *reliableQueue) acquire(ctx context.Context, deadline int64) (func(), error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if ticks() >= deadline {
		return nil, errContentPaused
	}
	turn := make(chan struct{})
	q.mu.Lock()
	q.waiters = append(q.waiters, turn)
	if len(q.waiters) == 1 {
		close(turn)
	}
	q.mu.Unlock()
	release := func() {
		q.mu.Lock()
		defer q.mu.Unlock()
		i := slices.Index(q.waiters, turn)
		if i < 0 {
			return
		}
		q.waiters = slices.Delete(q.waiters, i, i+1)
		if i == 0 && len(q.waiters) > 0 {
			close(q.waiters[0])
		}
	}
	timer := time.NewTimer(time.Duration(max(0, deadline-ticks())) * time.Millisecond)
	defer timer.Stop()
	select {
	case <-turn:
		if err := ctx.Err(); err != nil {
			release()
			return nil, err
		}
		if ticks() >= deadline {
			release()
			return nil, errContentPaused
		}
		return release, nil
	case <-ctx.Done():
		release()
		return nil, ctx.Err()
	case <-timer.C:
		release()
		return nil, errContentPaused
	}
}
