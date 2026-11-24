package main

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/livekit/protocol/livekit"
	lk "github.com/livekit/server-sdk-go/v2"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func checkTrustStatementArrivalOrder(t *testing.T, f fixture, left, right *engine) {
	t.Helper()
	consume := func(e *engine) []store.RoutedSignal {
		var incoming []store.RoutedSignal
		ok(t, e.api(f.ctx, "GET", "v1/identity/signals/"+strconv.FormatInt(e.room.signalSeq, 10), nil, &incoming))
		for _, v := range incoming {
			e.room.signalSeq = v.Sequence
		}
		return incoming
	}
	for _, e := range []*engine{left, right} {
		consume(e)
		clear(e.room.statements)
		e.room.broadcastAt = 0
	}
	ok(t, left.signals(f.ctx, left.room))
	// A lagging peer reads this statement before it applies the new member list.
	lost := consume(right)
	if len(lost) != 1 || lost[0].Signal.Kind != "trust" {
		t.Fatal("expected the first signed trust statement")
	}
	ok(t, right.signals(f.ctx, right.room))
	if right.mutual(right.room) {
		t.Fatal("missing statement granted mutual trust")
	}
	ok(t, left.signals(f.ctx, left.room))
	ok(t, right.signals(f.ctx, right.room))
	if !left.mutual(left.room) || !right.mutual(right.room) {
		t.Fatal("peer waited for the periodic rebroadcast after announcing its roster")
	}
	ok(t, left.signals(f.ctx, left.room))
	if len(consume(right)) != 0 || len(consume(left)) != 0 {
		t.Fatal("repeated statements triggered a reply loop")
	}
}

func TestSessionSequenceRequiresAnExplicitCounter(t *testing.T) {
	s := session{Expires: time.Now().Add(time.Minute).Unix()}
	for _, body := range []string{`{}`, `{"join_sequence":null}`, `{"join_sequence":-1}`, `{"join_sequence":9223372036854775807}`, `{"join_sequence":0}`} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(body))
		}))
		seq, err := s.joinSequence(t.Context(), server.URL)
		server.Close()
		if (err == nil) != (body == `{"join_sequence":0}`) || seq != 0 {
			t.Fatal("invalid join sequence handling", body, seq, err)
		}
	}
}

func TestAdmissionProofAndPasswordBounds(t *testing.T) {
	for _, p := range []string{"", "only", ".two", "three.", "one.two.three", "base64=.signature", "签.字", strings.Repeat("a", 2047) + ".b"} {
		if validAdmissionProof(p) {
			t.Fatalf("invalid proof accepted, length %d", len(p))
		}
	}
	if !validAdmissionProof(strings.Repeat("z", 2046)+".B") || !validAdmissionProof("a_Z-4.2_C-k") {
		t.Fatal("valid preflight was rejected")
	}
	e := &engine{}
	if err := e.joinRoom(t.Context(), "protected", strings.Repeat("密", 171)); err == nil || err.Error() != "ROOM_PASSWORD_TOO_LONG" {
		t.Fatal("513-byte password reached admission", err)
	}
}

func TestPublicInformationRejectsStaleAndInconsistentData(t *testing.T) {
	info := &group.RoomInformation{ServerTimeMS: 30_000, EstablishedAtMS: 10_000, NextRotationAtMS: 35_000, RotationIntervalMS: 5_000, MemberCount: 1, UpdateReason: "initial_connection"}
	s := group.Snapshot{Generation: 2, Revision: 7, RotationRevision: 15, Members: []group.Member{{}}, RoomInformation: info}
	v := roomInformation{}
	v.snapshot(s, 100)
	if p, at, unavailable := v.view(); p != info || at != 100 || unavailable {
		t.Fatal("initial information unavailable")
	}
	reply := pulse{Generation: s.Generation, Revision: s.Revision, RotationRevision: s.RotationRevision, Information: info}
	v.pulse(reply, 120)
	s.RoomInformation = nil
	v.snapshot(s, 110)
	if p, at, unavailable := v.view(); p != info || at != 120 || unavailable {
		t.Fatal("slow snapshot replaced more recent pulse")
	}
	bad := *info
	bad.MemberCount = 2
	reply.Information = &bad
	v.pulse(reply, 130)
	if p, at, unavailable := v.view(); p != info || at != 120 || !unavailable {
		t.Fatal("invalid aggregate erased last known history or stayed live")
	}
	reply.Information = info
	reply.Generation--
	v.pulse(reply, 150)
	if _, _, unavailable := v.view(); !unavailable {
		t.Fatal("old admission marked history fresh")
	}
	reply.Generation++
	reply.RotationRevision++
	if !v.pulse(reply, 150) {
		t.Fatal("rotation change did not request new snapshot")
	}
	for _, corrupt := range []func(*group.RoomInformation){
		func(i *group.RoomInformation) { i.ServerTimeMS = 0 }, func(i *group.RoomInformation) { i.RotationIntervalMS = 86_400_001 },
		func(i *group.RoomInformation) { i.LastRotationAtMS = 1000 }, func(i *group.RoomInformation) { i.NextRotationAtMS++ },
		func(i *group.RoomInformation) { i.RotationPhase = "switching" }, func(i *group.RoomInformation) { i.ActivatedMembers = 1 },
		func(i *group.RoomInformation) { i.UpdateReason = "arbitrary" },
	} {
		b := *info
		corrupt(&b)
		if validInformation(&b) {
			t.Fatalf("accepted invalid metadata: %+v", b)
		}
	}
}

func TestScopeMicrophoneSubscriptionsAndReconnect(t *testing.T) {
	m := &mediaSession{entry: "self"}
	defer m.close()
	k, err := newSenderKey(random(32))
	ok(t, err)
	m.stage("g", testRoster, 0, map[string]*senderKey{"self": k, "peer": k})
	check := func(want bool, terminal bool, owner string, kind lk.TrackKind, source livekit.TrackSource, encryption livekit.Encryption_Type) {
		t.Helper()
		yes, err := m.wantMicrophone(owner, kind, source, encryption)
		if yes != want || errors.Is(err, errUnencryptedMicrophone) != terminal {
			t.Fatalf("subscribe=%v err=%v", yes, err)
		}
	}
	check(false, false, "peer", lk.TrackKindAudio, livekit.TrackSource_MICROPHONE, livekit.Encryption_GCM)
	grant := func(g string) bool {
		m.mu.Lock()
		defer m.mu.Unlock()
		return m.grantLocked(g, testRoster, 0, ticks()+2900)
	}
	if !grant("g") {
		t.Fatal("initial grant failed")
	}
	check(true, false, "peer", lk.TrackKindAudio, livekit.TrackSource_MICROPHONE, livekit.Encryption_GCM)
	check(false, true, "peer", lk.TrackKindAudio, livekit.TrackSource_MICROPHONE, livekit.Encryption_NONE)
	check(false, false, "unknown", lk.TrackKindAudio, livekit.TrackSource_MICROPHONE, livekit.Encryption_NONE)
	check(false, false, "peer", lk.TrackKindVideo, livekit.TrackSource_CAMERA, livekit.Encryption_GCM)
	m.setAudioSuspended(true)
	m.setAudioSuspended(false)
	if m.stage("g", testRoster, 0, map[string]*senderKey{"peer": k}) || !m.refresh.Load() {
		t.Fatal("resume reused the preceding group")
	}
	m.stage("next", testRoster, 0, map[string]*senderKey{"peer": k})
	m.transportChanged(transportReconnecting)
	if m.ready() || grant("next") {
		t.Fatal("RTC disconnect retained live authorization")
	}
	m.transportChanged(transportNeedsRefresh)
	old := m.transportRevision
	m.transportChanged(transportReconnecting)
	if m.transportRestored(old) {
		t.Fatal("a delayed refresh overrode the current disconnect")
	}
	m.transportChanged(transportNeedsRefresh)
	if !m.transportRestored(m.transportRevision) {
		t.Fatal("completed reconnect rejected")
	}
	m.transportChanged(transportDisconnected)
	m.transportChanged(transportNeedsRefresh)
	if m.transportRestored(m.transportRevision) {
		t.Fatal("late reconnect revived a terminated room")
	}
}
