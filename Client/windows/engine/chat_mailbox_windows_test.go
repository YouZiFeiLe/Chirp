package main

import (
	"context"
	"fmt"
	"sync"
	"testing"
)

func TestChat26MailboxBurst(t *testing.T) {
	b := newActorMailbox[chatDelivery]()
	var producers sync.WaitGroup
	for k := 0; k < 4; k++ {
		producers.Go(func() {
			for i := 0; i < 500; i++ {
				b.push(chatDelivery{message: chatMessage{ID: fmt.Sprintf("%d/%d", k, i)}})
			}
		})
	}
	producers.Wait()
	ids := map[string]bool{}
	for len(ids) < 2000 {
		select {
		case <-b.wake:
		default:
			t.Fatalf("lost wakeup after %d", len(ids))
		}
		for _, d := range b.take(32) {
			if ids[d.message.ID] {
				t.Fatal("duplicate")
			}
			ids[d.message.ID] = true
		}
	}
}

func TestJoin15CancellationBehindQueuedUICommands(t *testing.T) {
	e := engine{}
	mailbox := newActorMailbox[command]()
	e.enqueueCommand(t.Context(), mailbox, command{Op: "join", Args: args{Key: "attempt"}})
	for i := 0; i < 100; i++ {
		e.enqueueCommand(t.Context(), mailbox, command{Op: "profile", ID: uint64(i + 1)})
	}
	e.enqueueCommand(t.Context(), mailbox, command{Op: "cancelJoin", Args: args{Key: "attempt"}})
	all := mailbox.take(102)
	if len(all) != 102 || all[0].join.ctx.Err() != context.Canceled || all[101].Op != "cancelJoin" {
		t.Fatal("UI backlog blocked cancellation")
	}
	for i := 1; i <= 100; i++ {
		if all[i].ID != uint64(i) {
			t.Fatal("ordinary commands reordered")
		}
	}
}

func TestChat26ClearingFilesPreservesText(t *testing.T) {
	e := engine{room: &activeRoom{join: admission{Identity: "current"}}}
	count := 0
	send := func(name string, data any) {
		if data.(obj)["entry"] != "current" {
			t.Fatal("wrong admission")
		}
		count++
	}
	e.acceptChat(chatDelivery{message: chatMessage{localEntry: "old", Text: "old admission"}}, send)
	e.acceptChat(chatDelivery{message: chatMessage{localEntry: "current", Text: "while clearing attachments"}}, send)
	if count != 1 {
		t.Fatalf("delivered %d messages", count)
	}
}
