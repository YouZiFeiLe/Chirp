package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/livekit/protocol/auth"
	"github.com/livekit/protocol/codecs"
	"github.com/livekit/protocol/livekit"
	lk "github.com/livekit/server-sdk-go/v2"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"google.golang.org/protobuf/proto"
)

func TestWindowsRoomVoice(t *testing.T) {
	publisher := lk.NewRoom(nil)
	transport, okBuild := any(publisher).(channels)
	if !okBuild {
		t.Skip("requires the Windows LiveKit build")
	}
	url := startSFU(t)
	admit := func(identity string) admission {
		token, err := auth.NewAccessToken("chirp-test", strings.Repeat("sample-", 8)).SetIdentity(identity).
			SetVideoGrant(&auth.VideoGrant{RoomJoin: true, Room: "voice"}).ToJWT()
		ok(t, err)
		return admission{URL: url, Token: token, Room: "voice", Identity: identity}
	}
	received := make(chan []byte, 1)
	listener, err := connectMedia(t.Context(), t.Context(), admit("listener"), func(name string, data any) {
		if name == "audio" {
			select {
			case received <- data.(obj)["packet"].([]byte):
			default:
			}
		}
	})
	ok(t, err)
	t.Cleanup(listener.close)
	transport.ChirpAllowLoopback()
	err = publisher.JoinWithContextAndToken(t.Context(), url, admit("phone").Token,
		lk.WithCodecs([]livekit.Codec{{Mime: "audio/red"}, {Mime: webrtc.MimeTypeOpus}}))
	ok(t, err)
	t.Cleanup(publisher.Disconnect)
	track, err := webrtc.NewTrackLocalStaticRTP(codecs.RedCodecParameters.RTPCodecCapability, "mic", "phone")
	ok(t, err)
	_, err = publisher.LocalParticipant.PublishTrack(track, &lk.TrackPublicationOptions{Source: livekit.TrackSource_MICROPHONE, Encryption: livekit.Encryption_GCM})
	ok(t, err)

	key, err := newSenderKey(random(32))
	ok(t, err)
	localKey, err := newSenderKey(random(32))
	ok(t, err)
	listener.stage("group", testRoster, 0, map[string]*senderKey{"phone": key, "listener": localKey})
	// 20 ms of a 400 Hz tone encoded by the desktop client's mono Opus encoder.
	opus, err := hex.DecodeString("28822e38f043dbaec91bf391756b9e04f658daa09409930b46f83cbbe22968267e636b99ddb9babf93d938e0d564fbc0")
	ok(t, err)
	t.Run("receive encrypted RED", func(t *testing.T) {
		// WebRTC encrypts the complete RED frame, including its redundant and primary blocks.
		redFrame := append([]byte{0xef, 0x0f, 0x00, 0x03, 111, 0xf8, 0xff, 0xfe}, opus...)
		for seq := 1; seq <= 200; seq++ {
			listener.grant("group", 0, ticks()+2500)
			iv := random(12)
			sealed := key.aead.Seal(bytes.Clone(redFrame[:1]), iv, redFrame[1:], redFrame[:1])
			sealed = append(sealed, iv...)
			err := track.WriteRTP(&rtp.Packet{
				Header:  rtp.Header{Version: 2, SequenceNumber: uint16(seq), Timestamp: uint32(seq * 960)},
				Payload: append(sealed, 12, 0),
			})
			ok(t, err)
			select {
			case got := <-received:
				if !bytes.Equal(got, opus) {
					t.Fatalf("expected the primary Opus block, got %x", got)
				}
				return
			case <-time.After(20 * time.Millisecond):
			}
		}
		t.Fatalf("no primary Opus block delivered: %v", listener.peerDiagnostic("phone"))
	})
	t.Run("report speech and silence to both participants", func(t *testing.T) {
		listener.grant("group", 0, ticks()+2500)
		ok(t, listener.mute(false))
		for _, level := range []uint8{19, 127} {
			want := level != 127
			packet := opus
			if !want {
				packet = []byte{0xf8, 0xff, 0xfe}
			}
			deadline := time.Now().Add(6 * time.Second)
			for {
				listener.grant("group", 0, ticks()+2500)
				listener.capture("group", packet, &level)
				remote := publisher.GetParticipantByIdentity("listener")
				if remote != nil && remote.IsSpeaking() == want && listener.room.LocalParticipant.IsSpeaking() == want {
					break
				}
				if time.Now().After(deadline) {
					t.Fatalf("both participants should report speaking=%v for audio level %d", want, level)
				}
				time.Sleep(20 * time.Millisecond)
			}
		}
	})
}

func checkSlowRoomCommand(t *testing.T, f fixture, left, right *engine) {
	t.Helper()
	deadline := func(m *mediaSession) int64 { m.mu.Lock(); defer m.mu.Unlock(); return m.until }
	old := deadline(left.room.media)
	f.mux.HandleFunc("/v1/slow-parity-command", func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(3300 * time.Millisecond)
		w.WriteHeader(http.StatusNoContent)
	})
	// The actor is occupied for longer than a maximum 3-second media lease.
	ok(t, left.api(f.ctx, "GET", "v1/slow-parity-command", nil, nil))
	if ticks() < old || deadline(left.room.media) <= old || !left.room.media.ready() || !right.room.media.ready() {
		t.Fatal("lease/heartbeat workers stalled behind an ordinary RPC")
	}
	f.mux.HandleFunc("/v1/rooms/protected/preflight", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":{"code":"ROOM_PASSWORD_INVALID"}}`))
	})
	original := left.room
	err := left.joinRoom(f.ctx, "protected", "wrong")
	if err == nil || err.Error() != "ROOM_PASSWORD_INVALID" || left.room != original || !original.media.ready() {
		t.Fatal("password rejection detached the existing call", err)
	}
	for _, target := range []string{"bad-policy", "unavailable-policy"} {
		var joins atomic.Int32
		f.mux.HandleFunc("/v1/rooms/"+target+"/preflight", func(w http.ResponseWriter, r *http.Request) {
			var request struct {
				Sequence int64 `json:"join_sequence"`
			}
			_ = json.NewDecoder(r.Body).Decode(&request)
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(obj{"room_id": target, "join_sequence": request.Sequence, "preflight_proof": "fixture.signature", "expires_at": time.Now().Unix() + 30})
		})
		f.mux.HandleFunc("/v1/group/rooms/"+target+"/config", func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			if target == "unavailable-policy" {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			_ = json.NewEncoder(w).Encode(obj{"room_id": target, "server_id": "another", "protocol": identity.Protocol, "max_lease_ms": 3000, "heartbeat_ms": 2000, "lease_refresh_ms": 1000, "identity_policy": identity.MutualRoom(f.origin, "another-room")})
		})
		f.mux.HandleFunc("/v1/rooms/"+target+"/join", func(w http.ResponseWriter, _ *http.Request) { joins.Add(1); w.WriteHeader(http.StatusConflict) })
		if left.joinRoom(f.ctx, target, "") == nil || joins.Load() != 0 || left.room != original || !original.media.ready() {
			t.Fatal("unverified target replaced current admission", target)
		}
	}
}

func checkQueuedRTCWrite(t *testing.T, m *mediaSession) {
	t.Helper()
	release, err := m.outbox.acquire(t.Context(), ticks()+3000)
	ok(t, err)
	defer release()
	done := make(chan error, 1)
	go func() { done <- m.send("stale queued payload", nil) }()
	for limit := time.Now().Add(time.Second); ; {
		m.outbox.mu.Lock()
		waiting := len(m.outbox.waiters)
		m.outbox.mu.Unlock()
		if waiting == 2 {
			break
		}
		if time.Now().After(limit) {
			t.Fatal("message did not reach the RTC send queue")
		}
		time.Sleep(time.Millisecond)
	}
	m.pause()
	release()
	select {
	case err := <-done:
		if !errors.Is(err, errContentPaused) {
			t.Fatal("queued write survived revocation", err)
		}
	case <-time.After(time.Second):
		t.Fatal("stale queued write did not settle")
	}
}

func TestLeaseExpiryRetiresContextAndPreservesIntent(t *testing.T) {
	m := &mediaSession{entry: "self", muted: true}
	defer m.close()
	key, err := newSenderKey(random(32))
	ok(t, err)
	m.stage("first", testRoster, 0, map[string]*senderKey{"self": key})
	m.grant("first", 0, ticks()+90)
	ok(t, m.mute(false))
	m.pause()
	if m.ready() || m.muted {
		t.Fatal("transport suspension changed the user's microphone intent")
	}
	deadline := time.Now().Add(time.Second)
	for !m.refresh.Load() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !m.refresh.Load() {
		t.Fatal("expiry did not request fresh MLS keys")
	}
	m.grant("first", 0, ticks()+3000)
	if m.ready() {
		t.Fatal("expired slot reauthorized")
	}
	m.stage("first", testRoster, 0, map[string]*senderKey{"self": key})
	m.grant("first", 0, ticks()+3000)
	if m.ready() {
		t.Fatal("expired group reauthorized even after restaging")
	}
	fresh, err := newSenderKey(random(32))
	ok(t, err)
	m.stage("next", testRoster, 0, map[string]*senderKey{"self": fresh})
	m.grant("next", 0, ticks()+3000)
	if !m.ready() || m.muted {
		t.Fatal("same-call microphone intent not restored with fresh keys")
	}
	m.forceMute()
	m.pause()
	m.grant("next", 0, ticks()+3000)
	if !m.muted {
		t.Fatal("identity mute lost")
	}
	// A delayed timer after a system suspend must not win a race with renewal.
	m.mu.Lock()
	m.expiryAt = ticks() - 1
	m.mu.Unlock()
	m.grant("next", 0, ticks()+3000)
	if m.ready() {
		t.Fatal("late renewal revived an expired context")
	}
}

func TestStagedVoiceSlotAndTimedRetirement(t *testing.T) {
	m := &mediaSession{packets: map[string]uint64{}}
	defer m.close()
	old, err := newSenderKey(random(32))
	ok(t, err)
	next, err := newSenderKey(random(32))
	ok(t, err)
	m.stage("generation", testRoster, 0, map[string]*senderKey{"speaker": old})
	m.grant("generation", 0, ticks()+3000)
	m.stage("generation/key/1", testRoster, 1, map[string]*senderKey{"speaker": next})
	frame := func(k *senderKey, index byte) []byte {
		iv := random(12)
		b := k.aead.Seal([]byte{0xf8}, iv, []byte{0xff, 0xfe}, []byte{0xf8})
		return append(append(b, iv...), 12, index)
	}
	if out, _ := m.openVoice("speaker", frame(next, 1)); out != nil {
		t.Fatal("staged receiver authorized before epoch lease")
	}
	ok(t, m.beginSwitch(1))
	m.grant("generation", 0, ticks()+3000)
	if m.index != 1 || m.slots[1].until > 0 {
		t.Fatal("in-flight old-epoch lease opened the candidate or switched the sender back")
	}
	m.mu.Lock()
	m.switching = false
	m.mu.Unlock()
	m.grant("generation", 1, ticks()+3000)
	m.retirePrevious()
	for i, k := range []*senderKey{old, next} {
		if out, _ := m.openVoice("speaker", frame(k, byte(i))); out == nil {
			t.Fatal("missing overlap", i)
		}
	}
	time.Sleep(1100 * time.Millisecond)
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.slots[0].keys != nil || m.slots[1].keys["speaker"] != next {
		t.Fatal("old receiver key was not retired independently")
	}
}

func TestInFlightAdmissionCancellationReleasesExactEntry(t *testing.T) {
	entered, respond, left := make(chan struct{}), make(chan struct{}), make(chan string, 1)
	var once sync.Once
	deferReply := func() { once.Do(func() { close(respond) }) }
	entry := "entry_" + strings.Repeat("z", 32)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer fixture" {
			t.Error("wrong credential")
		}
		switch r.URL.Path {
		case "/rooms/room/join":
			close(entered)
			<-respond
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(admission{Room: "room", Entry: entry, Sequence: 19})
		case "/rooms/room/leave":
			var body struct {
				Entry string `json:"entry_id"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Error(err)
			}
			left <- body.Entry
		default:
			t.Error("unexpected path", r.URL.Path)
		}
	}))
	defer server.Close()
	defer deferReply()
	var joins joinRequests
	seq, err := joins.next("login", 18)
	ok(t, err)
	next, err := joins.next("login", 18)
	ok(t, err)
	if seq != 19 || next != 20 {
		t.Fatal("overlapping admission reused a sequence")
	}
	a := joins.begin(t.Context(), "operation")
	done := make(chan error, 1)
	go func() {
		_, err := claimAdmission(a.ctx, t.Context(), server.URL+"/rooms/room", "fixture", "room", 19, "proof")
		done <- err
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("admission never submitted")
	}
	joins.cancel("previous")
	select {
	case <-done:
		t.Fatal("old cancellation stopped the current admission")
	default:
	}
	joins.cancel("operation")
	select {
	case err := <-done:
		if !errors.Is(err, errJoinCancelled) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("cancel waited for server response")
	}
	deferReply()
	select {
	case id := <-left:
		if id != entry {
			t.Fatal("released another entry")
		}
	case <-time.After(time.Second):
		t.Fatal("committed admission not released")
	}
}

func TestTrackRecoveryPrivacyAndAudibleBandwidth(t *testing.T) {
	now := ticks()
	const private = "secret-member.secret-entry"
	m := &mediaSession{until: now + 200000, quality: map[string]livekit.ConnectionQuality{private: livekit.ConnectionQuality_POOR}}
	m.members = map[string]bool{private: true}
	track := m.trackLocked("secret-track", private)
	track.microphone = true
	track.subscribed = true
	if m.fileRateLocked() != 512<<10 {
		t.Fatal("audible poor track did not constrain attachments")
	}
	track.muted = true
	if m.fileRateLocked() != 8<<20 {
		t.Fatal("muted track throttled attachments")
	}
	track.muted = false
	m.quality[private] = livekit.ConnectionQuality_GOOD
	track.jitter = metric(40)
	if m.fileRateLocked() != 512<<10 {
		t.Fatal("jitter threshold not applied")
	}
	m.quality[private] = livekit.ConnectionQuality_LOST
	if m.fileRateLocked() != 0 {
		t.Fatal("audible lost track not paused")
	}
	m.quality[private] = livekit.ConnectionQuality_GOOD
	track.received++
	track.observeDecryption("missingKey", now)
	track.received++ // unrelated/late RTP does not constitute another failed decryption
	if retry, err := m.decryptionRecovery(now + 5500); retry || err != nil {
		t.Fatal("silence or late old frames initiated recovery")
	}
	check := func(start int64, want bool, fatal bool) {
		t.Helper()
		for i := int64(0); i <= 5000; i += 1000 {
			track.received++
			track.observeDecryption("decryptionFailed", start+i)
		}
		retry, err := m.decryptionRecovery(start + 5000)
		if retry != want || errors.Is(err, errDecryptionRecovery) != fatal {
			t.Fatalf("recovery = %v, %v", retry, err)
		}
	}
	check(now+8000, true, false)
	check(now+15000, true, false)
	check(now+22000, false, true)
	check(now+90000, true, false)
	m.recordLocked("activated")
	m.logPhase = callLogPhase("untrusted server text " + private)
	track.packetsReceived = &track.received
	m.rtt = metric(15)
	data, err := json.Marshal(m.trackSampleLocked(logAudio{}, now))
	ok(t, err)
	for _, s := range []string{"secret-member", "secret-entry", "secret-track", "untrusted server text"} {
		if bytes.Contains(data, []byte(s)) {
			t.Fatal("sensitive diagnostic value", s)
		}
	}
	for _, s := range []string{"packetsReceived", "jitterMS", "roundTripMS", "subscriptionFailed"} {
		if !bytes.Contains(data, []byte(s)) {
			t.Fatal("missing diagnostic field", s)
		}
	}
}

func TestReliableBatchesAndSenderUUIDWindow(t *testing.T) {
	key, err := newSenderKey(random(32))
	ok(t, err)
	m := mediaSession{entry: "listener", group: "room", until: ticks() + 3000, readSeq: map[string]uint64{}, loginExpires: time.Now().Unix() + 120}
	m.slots[0] = keySlot{group: "room", until: m.until, keys: map[string]*senderKey{"alice": key, "bob": key, "listener": key}}
	var accepted []chatMessage
	m.notify = func(event string, val any) { accepted = append(accepted, val.(chatMessage)) }
	record := func(sender, id string, seq uint64, innerSender string) []byte {
		msg := chatMessage{Version: 1, ID: id, Group: "room", Sender: sender, Seq: seq, Text: "hello"}
		body, err := json.Marshal(msg)
		ok(t, err)
		topic := "chirp.room-chat.v1"
		p, err := proto.Marshal(&livekit.EncryptedPacketPayload{Value: &livekit.EncryptedPacketPayload_User{User: &livekit.UserPacket{ParticipantIdentity: innerSender, Topic: &topic, Payload: body}}})
		ok(t, err)
		return p
	}
	var dest []string
	for i := range 19 {
		dest = append(dest, fmt.Sprintf("peer-%02d", i))
	}
	id := uuid.NewString()
	permit := m.sendPermitLocked()
	var sizes []int
	var delivered []string
	data := record("alice", id, 1, "alice")
	ok(t, m.publish(permit, "alice", data, dest, true, func(raw []byte) error {
		var packet livekit.DataPacket
		if err := proto.Unmarshal(raw, &packet); err != nil {
			return err
		}
		sizes = append(sizes, len(packet.DestinationIdentities))
		delivered = append(delivered, packet.DestinationIdentities...)
		m.receive(raw)
		return nil
	}))
	if !slices.Equal(sizes, []int{8, 8, 3}) || !slices.Equal(delivered, dest) || len(accepted) != 1 {
		t.Fatal("recipient partition/repeated envelope", sizes, len(accepted))
	}
	calls := 0
	err = m.publish(permit, "alice", data, dest, true, func([]byte) error {
		calls++
		if calls == 2 {
			return errContentPaused
		}
		return nil
	})
	if calls != 2 || !errors.Is(err, errContentPaused) || errors.Is(err, errChatBusy) {
		t.Fatal("partial submission was retried", calls, err)
	}
	for _, v := range []struct {
		sender, inner string
		seq           uint64
	}{{"alice", "alice", 2}, {"bob", "alice", 1}, {"bob", "bob", 1}} {
		ok(t, m.publish(permit, v.sender, record(v.sender, id, v.seq, v.inner), dest, false, func(raw []byte) error { m.receive(raw); return nil }))
	}
	if len(accepted) != 2 || accepted[1].Sender != "bob" {
		t.Fatalf("UUID was not scoped by sender: %v", accepted)
	}
	m.mu.Lock()
	m.until += 1000
	permit.deadline = ticks() - 1
	if permit.validLocked(&m) {
		t.Fatal("queued message inherited a new deadline")
	}
	permit = m.sendPermitLocked()
	permit.loginExpires = time.Now().Unix()
	if permit.validLocked(&m) {
		t.Fatal("expired login authorized dispatch")
	}
	m.mu.Unlock()
}

func TestParkedPionWriteCannotCrossRenewal(t *testing.T) {
	se := webrtc.SettingEngine{}
	se.SetIncludeLoopbackCandidate(true)
	se.SetIPFilter(func(ip net.IP) bool { return ip.IsLoopback() })
	se.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	api := webrtc.NewAPI(webrtc.WithSettingEngine(se))
	sender, err := api.NewPeerConnection(webrtc.Configuration{})
	ok(t, err)
	defer sender.Close()
	receiver, err := api.NewPeerConnection(webrtc.Configuration{})
	ok(t, err)
	defer receiver.Close()
	msgs := make(chan string, 4)
	receiver.OnDataChannel(func(dc *webrtc.DataChannel) {
		dc.OnMessage(func(msg webrtc.DataChannelMessage) { msgs <- string(msg.Data) })
	})
	channel, err := sender.CreateDataChannel("reliable", nil)
	ok(t, err)
	opened := make(chan struct{})
	channel.OnOpen(func() { close(opened) })
	m := mediaSession{entry: "self", loginExpires: time.Now().Unix() + 60}
	defer m.close()
	key, err := newSenderKey(random(32))
	ok(t, err)
	m.stage("group", testRoster, 0, map[string]*senderKey{"self": key})
	m.grant("group", 0, ticks()+3000)
	m.mu.Lock()
	old := m.sendPermitLocked()
	m.mu.Unlock()
	parked := make(chan struct{})
	var once sync.Once
	current := func() (*webrtc.DataChannel, *webrtc.DataChannel) {
		once.Do(func() { close(parked) })
		return channel, nil
	}
	done := make(chan error, 1)
	go func() { done <- m.dispatch(t.Context(), old, channel, current, []byte("stale")) }()
	select {
	case <-parked:
	case <-time.After(time.Second):
		t.Fatal("write never reached the real (connecting) data channel")
	}
	m.pause()
	m.grant("group", 0, ticks()+3000)
	select {
	case err := <-done:
		if !errors.Is(err, errContentPaused) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("parked write survived a new authorization")
	}

	offer, err := sender.CreateOffer(nil)
	ok(t, err)
	gather := webrtc.GatheringCompletePromise(sender)
	ok(t, sender.SetLocalDescription(offer))
	select {
	case <-gather:
	case <-time.After(5 * time.Second):
		t.Fatal("offer gathering timed out")
	}
	ok(t, receiver.SetRemoteDescription(*sender.LocalDescription()))
	answer, err := receiver.CreateAnswer(nil)
	ok(t, err)
	gather = webrtc.GatheringCompletePromise(receiver)
	ok(t, receiver.SetLocalDescription(answer))
	select {
	case <-gather:
	case <-time.After(5 * time.Second):
		t.Fatal("answer gathering timed out")
	}
	ok(t, sender.SetRemoteDescription(*receiver.LocalDescription()))
	select {
	case <-opened:
	case <-time.After(5 * time.Second):
		t.Fatal("local RTC channel did not open")
	}
	m.grant("group", 0, ticks()+3000)
	m.mu.Lock()
	fresh := m.sendPermitLocked()
	m.mu.Unlock()
	ok(t, m.dispatch(t.Context(), fresh, channel, current, []byte("fresh")))
	select {
	case v := <-msgs:
		if v != "fresh" {
			t.Fatal("stale wire bytes delivered", v)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("authorized bytes did not arrive")
	}
}

func TestCancelledQueuedPublicationWithdrawsBeforeDrain(t *testing.T) {
	var q reliableQueue
	release, err := q.acquire(t.Context(), ticks()+3000)
	ok(t, err)
	defer release()
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	_, err = q.acquire(ctx, ticks()+3000)
	if !errors.Is(err, context.Canceled) {
		t.Fatal("cancelled descriptor remained queued", err)
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.waiters) != 1 {
		t.Fatal("cancelled waiter retained")
	}
}

func TestShortLeaseCadenceWhileHeartbeatRunsIndependently(t *testing.T) {
	requireNative(t)
	heartbeat := make(chan struct{}, 32)
	leases := make(chan time.Time, 32)
	holdFirst := make(chan struct{})
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(holdFirst) }) }
	var count atomic.Uint32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		var q group.Request
		if err := json.NewDecoder(req.Body).Decode(&q); err != nil {
			t.Error(err)
			return
		}
		reply := pulse{Room: q.RoomID, Server: q.ServerID, Session: q.SessionID, Generation: q.Generation, Protocol: identity.Protocol, Phase: "ready", Revision: 8}
		if q.Operation == "heartbeat" {
			select {
			case heartbeat <- struct{}{}:
			default:
			}
		} else {
			select {
			case leases <- time.Now():
			default:
			}
			if count.Add(1) == 1 {
				<-holdFirst
			}
			reply.Lease = 450
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(reply)
	}))
	defer server.Close()
	defer release()
	n, err := newNative("tester")
	ok(t, err)
	defer n.close()
	m := &mediaSession{entry: "tester"}
	defer m.close()
	k, err := newSenderKey(random(32))
	ok(t, err)
	m.stage("generation", testRoster, 0, map[string]*senderKey{"tester": k})
	r := activeRoom{join: admission{Room: "room", Identity: "tester"}, base: server.URL, n: n, media: m, watchLive: true, watchSeen: ticks(), watchRev: 8, progress: make(chan struct{}, 1)}
	q := group.Request{RoomID: "room", ServerID: "server", SessionID: "session", Generation: 2, Operation: "heartbeat"}
	r.pulses.setHeartbeat(q, 8)
	r.startPulses(t.Context(), 45, 1000)
	defer func() { release(); r.pulses.stop() }()
	q.Operation = "lease"
	q.Revision = 8
	r.pulses.setLease(leasePlan{request: q, group: "generation", roster: testRoster, hard: ticks() + 4000})
	select {
	case <-leases:
	case <-time.After(time.Second):
		t.Fatal("missing lease")
	}
	select {
	case <-heartbeat:
	case <-time.After(300 * time.Millisecond):
		t.Fatal("heartbeat waited for pending lease response")
	}
	select {
	case <-r.progress:
		t.Fatal("announced a media grant before the server replied")
	default:
	}
	release()
	select {
	case <-r.progress:
	case <-time.After(time.Second):
		t.Fatal("first media grant did not wake the room")
	}
	var previous time.Time
	for range 3 {
		select {
		case t0 := <-leases:
			if !previous.IsZero() && t0.Sub(previous) > 350*time.Millisecond {
				t.Fatal("short lease used the one-second default cadence")
			}
			previous = t0
		case <-time.After(500 * time.Millisecond):
			t.Fatal("short lease expired before renewal")
		}
	}
	if !m.ready() || m.refresh.Load() {
		t.Fatal("short leases expired with active workers")
	}
	select {
	case <-r.progress:
		t.Fatal("ordinary renewals kept waking the room")
	default:
	}
}
