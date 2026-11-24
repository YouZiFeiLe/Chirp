package main

import (
	"context"
	"errors"
	"math"
	"strings"
	"sync"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

var errJoinCancelled = errors.New("JOIN_CANCELLED")

func validAdmissionProof(proof string) bool {
	payload, signature, ok := strings.Cut(proof, ".")
	if !ok || payload == "" || signature == "" || len(proof) > 2048 {
		return false
	}
	for _, segment := range []string{payload, signature} {
		for _, c := range []byte(segment) {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
				return false
			}
		}
	}
	return true
}

type joinAttempt struct {
	key  string
	ctx  context.Context
	stop context.CancelFunc
}

// Registration happens on the pipe reader, before either command enters the
// room actor. A cancellation can therefore interrupt an HTTP or RTC wait.
type joinRequests struct {
	mu       sync.Mutex
	current  *joinAttempt
	login    string
	sequence int64
}

// An abandoned HTTP request can still commit after a newer request starts.
// Use a strictly increasing sequence within this login, including failed and
// cancelled attempts, so a delayed request cannot replace the newer admission.
func (j *joinRequests) next(login string, server int64) (int64, error) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.login != login {
		j.login = login
		j.sequence = 0
	}
	if server < 0 || max(server, j.sequence) == math.MaxInt64 {
		return 0, invalid
	}
	j.sequence = max(server, j.sequence) + 1
	return j.sequence, nil
}

func (j *joinRequests) begin(parent context.Context, key string) *joinAttempt {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.current != nil {
		j.current.stop()
	}
	ctx, stop := context.WithCancel(parent)
	j.current = &joinAttempt{key, ctx, stop}
	return j.current
}

func (j *joinRequests) cancel(key string) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.current != nil && j.current.key == key {
		j.current.stop()
	}
}

func (j *joinRequests) finish(a *joinAttempt) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.current == a {
		j.current = nil
	}
	a.stop()
}

// Linearize the handoff from preparation to the active room. A subsequent
// join may supersede a pending attempt, but cannot cancel a committed call.
func (j *joinRequests) commit(ctx context.Context) bool {
	j.mu.Lock()
	defer j.mu.Unlock()
	if ctx.Err() != nil {
		return false
	}
	if j.current != nil && j.current.ctx == ctx {
		j.current = nil
	}
	return true
}

func (e *engine) runJoin(parent context.Context, c command) error {
	a := c.join
	if a == nil {
		a = e.joins.begin(parent, c.Args.Key)
	} else {
		// The pipe reader owns immediate user cancellation. The session monitor
		// can independently retire this admission while the actor waits for HTTP.
		stop := context.AfterFunc(parent, a.stop)
		defer stop()
	}
	defer e.joins.finish(a)
	err := e.prepareRoom(a.ctx, parent, c.Args.ID, c.Args.Password, a.key)
	if a.ctx.Err() != nil {
		return errJoinCancelled
	}
	return err
}

func (e *engine) cancelCommittedJoin(ctx context.Context, key string) error {
	if key != "" && e.room != nil && e.room.attemptKey == key {
		e.leaveRoom(ctx)
	}
	return nil
}

// A server may already have committed an admission when the caller cancels
// its wait. Drain the response separately and release only that entry.
func claimAdmission(ctx, lifetime context.Context, base, credential, id string, seq int64, proof string) (admission, error) {
	type result struct {
		join admission
		err  error
	}
	replies := make(chan result)
	base = strings.TrimRight(base, "/") + "/"
	go func() {
		var j admission
		_, err := request(lifetime, "admission", "POST", base+"join", obj{"join_sequence": seq, "preflight_proof": proof}, credential, nil, &j, 2<<20)
		select {
		case replies <- result{j, err}:
		case <-ctx.Done():
			if err == nil && j.Room == id && j.Sequence == seq && store.ValidEntryID(j.Entry) {
				cleanup, cancel := context.WithTimeout(context.WithoutCancel(lifetime), 3*time.Second)
				defer cancel()
				_, _ = request(cleanup, "leave", "POST", base+"leave", obj{"entry_id": j.Entry}, credential, nil, nil, 65536)
			}
		}
	}()
	select {
	case v := <-replies:
		return v.join, v.err
	case <-ctx.Done():
		return admission{}, errJoinCancelled
	}
}
