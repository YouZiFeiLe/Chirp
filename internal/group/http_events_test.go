package group

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

type eventAuthority struct {
	member           store.Member
	revoked, offline atomic.Bool
	touches          atomic.Int32
}

func (d *eventAuthority) MemberByCredential(_ context.Context, token string) (store.Member, error) {
	if token != "current-credential" {
		return store.Member{}, store.ErrNotFound
	}
	return d.member, nil
}
func (d *eventAuthority) AdmissionAllowed(context.Context, string, string) (bool, error) {
	if d.offline.Load() {
		return false, errors.New("offline")
	}
	return !d.revoked.Load(), nil
}
func (d *eventAuthority) ActiveAdmissions(context.Context) (map[string]string, error) {
	if d.offline.Load() {
		return nil, errors.New("offline")
	}
	result := map[string]string{}
	if !d.revoked.Load() {
		result[store.AdmissionIdentity(d.member, testEntryID)] = "friends"
	}
	return result, nil
}
func (d *eventAuthority) TouchAdmission(context.Context, string, string) error {
	d.touches.Add(1)
	return nil
}
func (*eventAuthority) Ping(context.Context) error { return nil }
func (*eventAuthority) Room(context.Context, string) (store.RoomConfig, error) {
	return store.RoomConfig{RoomID: "friends"}, nil
}

func readGroupEvent(t *testing.T, reader *bufio.Reader) (string, map[string]any) {
	t.Helper()
	name, data := "", ""
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			t.Fatal("stream ended", err)
		}
		line = strings.TrimSuffix(line, "\n")
		if line == "" && data != "" {
			var object map[string]any
			if err := json.Unmarshal([]byte(data), &object); err != nil {
				t.Fatal(err)
			}
			return name, object
		}
		if strings.HasPrefix(line, "event: ") {
			name = strings.TrimPrefix(line, "event: ")
		}
		if strings.HasPrefix(line, "data: ") {
			data = strings.TrimPrefix(line, "data: ")
		}
	}
}

func TestGroupHTTPSeparatesLeaseHeartbeatSnapshotsAndAuthenticatedEvents(t *testing.T) {
	db := &eventAuthority{member: store.Member{ID: "member_test", LoginID: "login_current", Enabled: true}}
	s := New(db, DefaultPolicy(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	h := s.hubs["friends"]
	p := hubPeer{db.member, public}
	ready := complete(t, h, p)
	bindHTTPPeer(h, p)
	server := httptest.NewServer(s)
	defer server.Close()
	client := &http.Client{Timeout: 8 * time.Second}
	request := func(endpoint string, action Request, proofEndpoint string) *http.Response {
		t.Helper()
		body, _ := json.Marshal(action)
		stamp := strconv.FormatInt(time.Now().Unix(), 10)
		nonce := randomID()
		r, _ := http.NewRequest("POST", server.URL+"/v1/group/rooms/friends/"+endpoint, bytes.NewReader(body))
		r.Header.Set("Authorization", "Bearer current-credential")
		r.Header.Set("X-Chirp-Time", stamp)
		r.Header.Set("X-Chirp-Nonce", nonce)
		r.Header.Set("X-Chirp-Key", base64.StdEncoding.EncodeToString(public))
		r.Header.Set("X-Chirp-Signature", base64.StdEncoding.EncodeToString(ed25519.Sign(private, proofMessage(p.identity(), "friends", proofEndpoint, stamp, nonce, body))))
		response, err := client.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		return response
	}
	decode := func(op string, action Request) map[string]json.RawMessage {
		t.Helper()
		response := request("action", action, "action")
		defer response.Body.Close()
		if response.StatusCode != 200 {
			t.Fatal(op, response.StatusCode)
		}
		var result map[string]json.RawMessage
		if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
			t.Fatal(err)
		}
		return result
	}
	if _, ok := decode("snapshot", roundRequest(ready, "snapshot"))["lease_ms"]; ok {
		t.Fatal("full snapshot granted media lease")
	}
	heartbeat := decode("heartbeat", roundRequest(ready, "heartbeat"))
	if string(heartbeat["lease_ms"]) != "0" || heartbeat["members"] != nil || heartbeat["welcome"] != nil {
		t.Fatal("heartbeat retransmitted roster or granted media authority")
	}
	leaseRequest := roundRequest(ready, "lease")
	leaseRequest.Revision = ready.Revision
	leaseRequest.Confirmation = ready.Confirmation
	lease := decode("lease", leaseRequest)
	if string(lease["lease_ms"]) != "3000" || lease["members"] != nil {
		t.Fatal("compact lease failed")
	}
	if db.touches.Load() != 1 {
		t.Fatal("read/sending authority renewed persistent admission")
	}
	watch := roundRequest(ready, "watch")
	wrong := request("events", watch, "action")
	_ = wrong.Body.Close()
	if wrong.StatusCode != 403 {
		t.Fatal("action proof was accepted by events endpoint")
	}
	stream := request("events", watch, "events")
	defer stream.Body.Close()
	if stream.StatusCode != 200 || !strings.HasPrefix(stream.Header.Get("Content-Type"), "text/event-stream") {
		t.Fatal("events not streamed", stream.StatusCode)
	}
	reader := bufio.NewReader(stream.Body)
	name, hint := readGroupEvent(t, reader)
	if name != "state" || len(hint) != 3 || hint["revision"] != float64(ready.Revision) {
		t.Fatal("event carried state/lease instead of version hint", name, hint)
	}
	// A replacing subscriber cancels the old connection without renewing entry.
	replacement := request("events", watch, "events")
	defer replacement.Body.Close()
	replacementReader := bufio.NewReader(replacement.Body)
	_, _ = readGroupEvent(t, replacementReader)
	if _, err := io.ReadAll(reader); err != nil {
		t.Fatal("replaced stream remained open", err)
	}
	if db.touches.Load() != 1 {
		t.Fatal("watch renewed entry")
	}
	db.offline.Store(true)
	name, hint = readGroupEvent(t, replacementReader)
	if name != "state" || hint["revision"].(float64) <= float64(ready.Revision) {
		t.Fatal("authority suspension did not notify")
	}
	stale := request("action", leaseRequest, "action")
	_ = stale.Body.Close()
	if stale.StatusCode != 503 {
		t.Fatal("old revision renewed while authority unavailable", stale.StatusCode)
	}
	leaseRequest.Revision = uint64(hint["revision"].(float64))
	paused := decode("lease", leaseRequest)
	if string(paused["lease_ms"]) != "0" || string(paused["suspended"]) != "true" {
		t.Fatal("authority outage granted a lease")
	}
	db.revoked.Store(true)
	db.offline.Store(false)
	name, _ = readGroupEvent(t, replacementReader)
	if name != "revoked" {
		t.Fatal("revoked admission kept a bound stream", name)
	}
	if _, err := io.ReadAll(replacementReader); err != nil {
		t.Fatal(err)
	}
}

type racingBatchAuthority struct {
	*eventAuthority
	entered, release, next chan struct{}
	reads                  atomic.Int32
}

func (d *racingBatchAuthority) ActiveAdmissions(ctx context.Context) (map[string]string, error) {
	read := d.reads.Add(1)
	if read == 1 {
		close(d.entered)
		select {
		case <-d.release:
			return map[string]string{}, nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if read == 2 {
		close(d.next)
	}
	<-ctx.Done()
	return nil, ctx.Err()
}

func TestBatchMonitorCannotRemoveAJoinNewerThanItsAuthorityRead(t *testing.T) {
	db := &racingBatchAuthority{eventAuthority: &eventAuthority{member: store.Member{ID: "member_test", LoginID: "login_current", Enabled: true}}, entered: make(chan struct{}), release: make(chan struct{}), next: make(chan struct{})}
	s := New(db, DefaultPolicy(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { defer close(done); s.Monitor(ctx) }()
	select {
	case <-db.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("monitor did not read authority")
	}
	key, _, _ := ed25519.GenerateKey(rand.Reader)
	apply(t, s.hubs["friends"], hubPeer{db.member, key}, Request{Operation: "join"})
	close(db.release)
	// Entering the next tick proves the previous reconciliation completed.
	select {
	case <-db.next:
	case <-time.After(3 * time.Second):
		t.Fatal("monitor did not finish reconciliation")
	}
	if len(s.hubs["friends"].Identities()) != 1 {
		t.Fatal("a stale batch snapshot removed a newly committed join")
	}
	cancel()
	<-done
}
