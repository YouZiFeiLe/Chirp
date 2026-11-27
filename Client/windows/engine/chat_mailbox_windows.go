package main

import (
	"context"
	"errors"
	"slices"
	"sync"
)

type chatDelivery struct {
	message chatMessage
	scope   *attachmentSession
}

// Producers never wait on the actor. Media callbacks can hold RTC locks, and
// the pipe reader must remain available to cancel an in-flight admission.
type actorMailbox[T any] struct {
	mu      sync.Mutex
	pending []T
	wake    chan struct{}
}

func newActorMailbox[T any]() *actorMailbox[T] { return &actorMailbox[T]{wake: make(chan struct{}, 1)} }
func (b *actorMailbox[T]) push(d T) {
	b.mu.Lock()
	b.pending = append(b.pending, d)
	b.mu.Unlock()
	signalWorker(b.wake)
}
func (b *actorMailbox[T]) take(limit int) []T {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := min(limit, len(b.pending))
	batch := slices.Clone(b.pending[:n])
	clear(b.pending[:n])
	b.pending = b.pending[n:]
	if len(b.pending) > 0 {
		signalWorker(b.wake)
	} else {
		b.pending = nil
	}
	return batch
}
func (e *engine) acceptChat(delivery chatDelivery, send func(string, any)) {
	s, msg := e.fileScope.Load(), delivery.message
	if e.room == nil || msg.localEntry != e.room.join.Identity {
		return
	}
	data := obj{"group": msg.Group, "sender": msg.Sender, "text": msg.Text, "id": msg.ID, "entry": msg.localEntry}
	if d := msg.Attachment; d != nil {
		if s == nil || s != delivery.scope || s.ctx.Err() != nil || !d.valid(s.room, msg.Sender) {
			return
		}
		t := s.file(d.Info.ID)
		if t == nil {
			if msg.Sender == s.entry {
				return
			}
			owned := *d
			owned.Key = slices.Clone(d.Key)
			t = e.transferFor(e.room, owned)
			t.group = msg.Group
			if err := s.register(t); err != nil {
				clear(owned.Key)
				if !errors.Is(err, errDuplicateFile) {
					s.report("attachmentError", obj{"error": err.Error()})
				}
				return
			}
		} else if msg.Sender != s.entry || t.d.Info.Sender != msg.Sender {
			return
		}
		data["revision"] = s.revision
		data["file"] = d.Info
		if len(d.Thumbnail) > 0 {
			t.keyMu.Lock()
			if t.ctx.Err() == nil {
				if plain, err := d.thumbnail(d.Thumbnail, true); err == nil {
					data["thumbnail"] = plain
				}
			}
			t.keyMu.Unlock()
		}
		s.wakeCatalog()
	}
	if msg.Sender != e.room.join.Identity {
		event := "receiveMessage"
		if msg.Attachment != nil {
			event = "receiveAttachment"
		}
		installationLog.record(installationLog.epoch(), logEntry{op: logOp{"chat", event}, outcome: "succeeded"})
	}
	send("chat", data)
}
func (e *engine) enqueueCommand(ctx context.Context, commands *actorMailbox[command], c command) {
	switch c.Op {
	case "resumeLogin":
		c.resume = e.beginResume(ctx, c.Args.ID)
	case "cancelResume":
		e.stopResume(c.Args.ID)
	case "logout", "clearLocalData":
		e.stopResume("")
	case "join":
		c.join = e.joins.begin(ctx, c.Args.Key)
	case "cancelJoin":
		e.joins.cancel(c.Args.Key)
	case "audioSuspended":
		// Preserve input order even if the actor is waiting on HTTP. Suspending
		// withdraws the lease immediately; resuming only requests a fresh group.
		if m := e.audio.Load(); m != nil && c.Args.Entry != "" && c.Args.Entry == m.entry {
			m.setAudioSuspended(c.Args.Enabled)
			c.suspensionApplied = true
		}
	case "voice":
		if m := e.audio.Load(); m != nil {
			m.capture(c.Args.Group, c.Args.Packet, c.Args.AudioLevel)
		}
		return
	}
	c.beginLog()
	commands.push(c)
}
