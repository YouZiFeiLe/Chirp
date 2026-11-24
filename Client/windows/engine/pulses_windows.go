package main

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

// The actor publishes an immutable authorization decision. Workers never read
// the actor's mutable identity, verification, snapshot or session objects.
type leasePlan struct {
	request group.Request
	group   string
	roster  string
	version uint64
	hard    int64
}

type roomPulses struct {
	mu        sync.Mutex
	heartbeat group.Request
	revision  uint64
	lease     *leasePlan
	wake      chan struct{}
	cancel    context.CancelFunc
	workers   sync.WaitGroup
	changed   atomic.Bool
	failure   error
}

func (p *roomPulses) setHeartbeat(q group.Request, revision uint64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.revision != revision || p.heartbeat.Generation != q.Generation {
		p.lease = nil
	}
	p.heartbeat, p.revision = q, revision
}

func (p *roomPulses) setLease(plan leasePlan) {
	p.mu.Lock()
	defer p.mu.Unlock()
	old := p.lease
	p.lease = &plan
	if old == nil || old.version != plan.version || old.group != plan.group || old.roster != plan.roster || old.request.KeyEpoch != plan.request.KeyEpoch || old.request.Revision != plan.request.Revision {
		select {
		case p.wake <- struct{}{}:
		default:
		}
	}
}

func (p *roomPulses) stop() {
	if p.cancel != nil {
		p.cancel()
		p.workers.Wait()
	}
}

func (r *activeRoom) startPulses(parent context.Context, heartbeatMS, leaseRefreshMS int) {
	p := &r.pulses
	ctx, cancel := context.WithCancel(parent)
	p.cancel = cancel
	p.wake = make(chan struct{}, 1)
	heartbeat := time.Duration(max(1, min(heartbeatMS, 2000))) * time.Millisecond
	refresh := int64(max(1, min(leaseRefreshMS, 1000)))
	p.workers.Go(func() {
		t := time.NewTicker(heartbeat)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
			}
			p.mu.Lock()
			q, revision := p.heartbeat, p.revision
			p.mu.Unlock()
			var reply pulse
			started := ticks()
			err := r.post(ctx, q, &reply)
			if (err == nil && (!reply.matches(q, revision) || reply.Suspended)) || deniedPulse(err) {
				r.observePulseChange(q, revision, err)
			} else if err == nil && r.information.pulse(reply, started) {
				p.changed.Store(true)
			}
		}
	})
	p.workers.Go(func() {
		timer := time.NewTimer(0)
		defer timer.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-p.wake:
			case <-timer.C:
			}
			next := r.refreshLease(ctx, refresh)
			timer.Reset(time.Duration(max(15, next)) * time.Millisecond)
		}
	})
}

func deniedPulse(err error) bool {
	var api *apiError
	return errors.As(err, &api) && (api.status == 401 || api.status == 403)
}
func (r *activeRoom) observePulseChange(q group.Request, revision uint64, err error) {
	p := &r.pulses
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.heartbeat.Generation != q.Generation || p.revision != revision {
		return
	}
	// An old-epoch lease reply may finish after a smooth switch. It has
	// no authority to stop or resume the successor.
	if q.Operation == "lease" && (p.lease == nil || p.lease.request.KeyEpoch != q.KeyEpoch) {
		return
	}
	p.lease = nil
	p.changed.Store(true)
	if deniedPulse(err) {
		p.failure = err
	}
	r.media.pause()
	signalWorker(r.progress)
}
func (p *roomPulses) takeFailure() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	err := p.failure
	p.failure = nil
	return err
}

func (p pulse) matches(q group.Request, revision uint64) bool {
	return p.Room == q.RoomID && p.Server == q.ServerID && p.Session == q.SessionID && p.Protocol == identity.Protocol && p.Generation == q.Generation && p.Revision == revision
}

func (r *activeRoom) refreshLease(ctx context.Context, cadence int64) int64 {
	p := &r.pulses
	p.mu.Lock()
	plan := p.lease
	p.mu.Unlock()
	started := ticks()
	if plan == nil || started >= plan.hard {
		return cadence
	}
	r.watchMu.Lock()
	connected := r.watchLive && r.watchRev <= plan.request.Revision && started-r.watchSeen < 15000
	r.watchMu.Unlock()
	if !connected {
		return cadence
	}
	var reply pulse
	if err := r.post(ctx, plan.request, &reply); err != nil {
		p.changed.Store(true)
		var remote *apiError
		if deniedPulse(err) || errors.As(err, &remote) && remote.status == 409 && remote.code == "GROUP_CHANGED" {
			r.observePulseChange(plan.request, plan.request.Revision, err)
		}
		return min(cadence, 250)
	}
	if !reply.matches(plan.request, plan.request.Revision) || reply.Suspended || reply.Phase != "ready" || reply.Epoch != plan.request.KeyEpoch || reply.Lease <= 0 || reply.Lease > 3000 {
		r.observePulseChange(plan.request, plan.request.Revision, nil)
		return min(cadence, 250)
	}
	if r.information.pulse(reply, started) {
		p.changed.Store(true)
	}
	p.mu.Lock()
	r.watchMu.Lock()
	m := r.media
	m.mu.Lock()
	// An actor update can extend authority while this request is in flight.
	// Both the old and new hard deadlines still constrain this reply.
	valid := p.lease != nil && p.lease.version == plan.version && p.lease.group == plan.group && p.lease.roster == plan.roster && p.lease.request.KeyEpoch == reply.Epoch && p.lease.request.Revision == reply.Revision
	firstGrant := m.until == 0
	granted := false
	deadline := min(started+reply.Lease, plan.hard)
	versionMatches := m.version == plan.version || (m.switching && m.version == plan.version+1 && m.index != byte(reply.Epoch%2))
	if valid && ctx.Err() == nil && r.watchLive && r.watchRev <= reply.Revision && ticks()-r.watchSeen < 15000 && versionMatches {
		deadline = min(deadline, p.lease.hard)
		granted = m.grantLocked(plan.group, plan.roster, byte(reply.Epoch%2), deadline)
	}
	revision := m.leaseRevision
	m.mu.Unlock()
	r.watchMu.Unlock()
	p.mu.Unlock()
	if granted {
		if m.notify != nil {
			m.applyMicrophone()
			m.notify("mediaLease", obj{"entry": r.join.Identity, "group": plan.group, "deadline": deadline, "revision": revision})
		}
		if firstGrant {
			signalWorker(r.progress)
		}
	}
	return min(cadence, started+reply.Lease/3-ticks())
}
