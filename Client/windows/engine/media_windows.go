package main

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"maps"
	"net"
	"net/url"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/go-logr/logr"
	"github.com/google/uuid"
	"github.com/livekit/mediatransportutil/pkg/red"
	"github.com/livekit/protocol/codecs"
	"github.com/livekit/protocol/livekit"
	protolog "github.com/livekit/protocol/logger"
	lk "github.com/livekit/server-sdk-go/v2"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"google.golang.org/protobuf/proto"
)

// The build overlay exposes only the already negotiated reliable channel. This
// keeps the deadline and the sender-specific AEAD at the final write boundary.
type channels interface {
	ChirpReliable() (*webrtc.DataChannel, *webrtc.DataChannel)
	ChirpAllowLoopback()
	ChirpPrepareData()
}
type senderKey struct {
	material [32]byte
	aead     cipher.AEAD
	seen     map[[12]byte]struct{}
}
type keySlot struct {
	group  string
	roster string
	until  int64
	keys   map[string]*senderKey
}
type transportState uint8

const (
	transportConnected transportState = iota
	transportReconnecting
	transportNeedsRefresh
	transportDisconnected
)

type mediaSession struct {
	mu                                                       sync.Mutex
	micMu                                                    sync.Mutex
	room                                                     *lk.Room
	stopRTC                                                  context.CancelFunc
	track                                                    *lk.LocalTrack
	pub                                                      *lk.LocalTrackPublication
	entry, group                                             string
	loginExpires                                             int64
	slots                                                    [2]keySlot
	members                                                  map[string]bool
	index                                                    byte
	until                                                    int64
	expiryAt                                                 int64
	expiry, retirement                                       *time.Timer
	version                                                  uint64
	leaseRevision                                            uint64
	blockedGroup                                             string
	refresh                                                  atomic.Bool
	audioSuspended                                           bool
	muted, closed, switching                                 bool
	watched                                                  *webrtc.DataChannel
	subscriptionWake                                         chan struct{}
	subscriptions                                            map[*lk.RemoteTrackPublication]bool
	subscriptionFailure                                      error
	seq                                                      uint64
	readSeq                                                  map[string]uint64
	messageIDs                                               map[receivedID]struct{}
	recentIDs                                                []receivedID
	outbox                                                   reliableQueue
	lost                                                     atomic.Bool
	transport                                                transportState
	transportRevision                                        uint64
	quality                                                  map[string]livekit.ConnectionQuality
	packets                                                  map[string]uint64
	tracks                                                   map[string]*voiceTrack
	logPhase                                                 string
	logClockScratch                                          uint64
	firstDecryptGeneration, logKeyRevision, sampleGeneration uint64
	lastLogSample, lastVoiceWindow                           int64
	lastLogAudio                                             logAudio
	decryptWindow                                            decryptWindow
	recoveryAt                                               int64
	recoveries                                               int
	rtt                                                      *float64
	sampledAt                                                int64
	nextFile                                                 [2]int64
	notify                                                   func(string, any)
}

func connectMedia(ctx, lifetime context.Context, j admission, notify func(string, any)) (*mediaSession, error) {
	type result struct {
		m   *mediaSession
		err error
	}
	done := make(chan result)
	rtcCtx, stop := context.WithCancel(lifetime)
	unlink := context.AfterFunc(ctx, stop)
	defer unlink()
	go func() {
		m, err := openMedia(rtcCtx, j, notify)
		if m != nil {
			m.stopRTC = stop
		} else {
			stop()
		}
		select {
		case done <- result{m, err}:
		case <-ctx.Done():
			m.close()
		}
	}()
	select {
	case v := <-done:
		return v.m, v.err
	case <-ctx.Done():
		stop()
		return nil, ctx.Err()
	}
}
func silenceMediaLogger() { lk.SetLogger(protolog.LogRLogger(logr.Discard())) }

func openMedia(ctx context.Context, j admission, notify func(string, any)) (*mediaSession, error) {
	m := &mediaSession{entry: j.Identity, muted: true, readSeq: map[string]uint64{}, quality: map[string]livekit.ConnectionQuality{}, packets: map[string]uint64{}, notify: notify,
		subscriptionWake: make(chan struct{}, 1), subscriptions: map[*lk.RemoteTrackPublication]bool{}}
	cb := lk.NewRoomCallback()
	m.observeTracks(cb)
	cb.OnTrackSubscribed = func(track *webrtc.TrackRemote, pub *lk.RemoteTrackPublication, owner *lk.RemoteParticipant) {
		info := pub.TrackInfo()
		if track.Kind() != webrtc.RTPCodecTypeAudio || info.GetEncryption() != livekit.Encryption_GCM || info.GetSource() != livekit.TrackSource_MICROPHONE {
			return
		}
		state := m.subscribed(pub, owner.Identity(), track.SSRC())
		go m.play(track, owner.Identity(), state)
	}
	cb.OnReconnecting = func() { m.transportChanged(transportReconnecting) }
	cb.OnReconnected = func() { m.transportChanged(transportNeedsRefresh) }
	cb.OnDisconnected = func() { m.transportChanged(transportDisconnected) }
	cb.OnConnectionQualityChanged = func(info *livekit.ConnectionQualityInfo, p lk.Participant) {
		m.mu.Lock()
		if old, ok := m.quality[p.Identity()]; !ok || old != info.GetQuality() {
			m.quality[p.Identity()] = info.GetQuality()
			if m.members[p.Identity()] {
				m.logTracksLocked(true)
			}
		}
		m.mu.Unlock()
	}
	cb.OnParticipantDisconnected = func(p *lk.RemoteParticipant) {
		m.mu.Lock()
		delete(m.quality, p.Identity())
		delete(m.packets, p.Identity())
		for sid, t := range m.tracks {
			if t.owner == p.Identity() {
				delete(m.tracks, sid)
			}
		}
		m.logTracksLocked(true)
		m.mu.Unlock()
	}
	r := lk.NewRoom(cb)
	r.SetLogger(protolog.LogRLogger(logr.Discard()))
	if _, ok := any(r).(channels); !ok {
		return nil, errors.New("NATIVE_MEDIA_BUILD_REQUIRED")
	}
	// Windows cannot send to 127.0.0.1 from a physical-interface source.
	// Only offer loopback host candidates to an explicitly local RTC endpoint.
	if u, err := url.Parse(j.URL); err == nil && (strings.EqualFold(u.Hostname(), "localhost") || net.ParseIP(u.Hostname()).IsLoopback()) {
		any(r).(channels).ChirpAllowLoopback()
	}
	if err := r.JoinWithContextAndToken(ctx, j.URL, j.Token, lk.WithAutoSubscribe(false), lk.WithDisableRegionDiscovery(), lk.WithDisableTURN(), lk.WithConnectTimeout(7*time.Second)); err != nil {
		r.Disconnect()
		return nil, errors.New("MEDIA_CONNECTION_FAILED")
	}
	if r.LocalParticipant.Identity() != j.Identity || r.Name() != j.Room {
		r.Disconnect()
		return nil, invalid
	}
	if err := ctx.Err(); err != nil {
		r.Disconnect()
		return nil, err
	}
	m.room = r
	any(r).(channels).ChirpPrepareData()
	track, err := lk.NewLocalTrack(codecs.OpusCodecParameters.RTPCodecCapability)
	if err != nil {
		r.Disconnect()
		return nil, err
	}
	m.track = track
	go m.watchSubscriptions(ctx)
	m.mu.Lock()
	m.recordLocked("mediaConnected")
	m.mu.Unlock()
	m.listen()
	return m, nil
}
func (m *mediaSession) listen() {
	_, sub := any(m.room).(channels).ChirpReliable()
	if sub != nil && sub != m.watched {
		m.watched = sub
		sub.OnMessage(func(msg webrtc.DataChannelMessage) {
			if !msg.IsString {
				m.receive(msg.Data)
			}
		})
	}
}
func (m *mediaSession) invalidate() {
	m.mu.Lock()
	m.retireLocked()
	m.refresh.Store(false)
	m.mu.Unlock()
}
func (m *mediaSession) transportChanged(state transportState) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed || m.transport == transportDisconnected {
		return
	}
	m.transportRevision++
	m.transport = state
	m.lost.Store(true)
	if state == transportNeedsRefresh {
		signalWorker(m.subscriptionWake)
		return
	}
	m.retireLocked()
	m.recordLocked("reconnecting")
}

func (m *mediaSession) transportRestored(revision uint64) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed || m.transport != transportNeedsRefresh || m.transportRevision != revision {
		return false
	}
	m.transport = transportConnected
	m.lost.Store(false)
	m.recordLocked("reconnected")
	return true
}
func (m *mediaSession) retireLocked() {
	m.version++
	m.revokeLeaseLocked()
	if m.expiry != nil {
		m.expiry.Stop()
	}
	if m.retirement != nil {
		m.retirement.Stop()
	}
	m.expiryAt = 0
	m.switching = false
	m.slots = [2]keySlot{}
	m.members = nil
	signalWorker(m.subscriptionWake)
	m.group = ""
	for _, t := range m.tracks {
		t.encryption = "waiting"
		t.issueSince = 0
		t.lastDecryption = 0
	}
}
func (m *mediaSession) expireLocked() bool {
	if m.expiryAt == 0 || ticks() < m.expiryAt {
		return false
	}
	m.blockedGroup = m.group
	m.retireLocked()
	m.refresh.Store(true)
	m.recordLocked("mediaLeaseExpired")
	return true
}
func (m *mediaSession) pause() {
	m.mu.Lock()
	m.pauseLocked()
	m.mu.Unlock()
}
func (m *mediaSession) pauseLocked() {
	m.version++
	m.revokeLeaseLocked()
}
func (m *mediaSession) revokeLeaseLocked() {
	if m.until == 0 {
		return
	}
	m.until = 0
	m.leaseRevision++
	if m.notify != nil {
		event := obj{"entry": m.entry, "group": m.group, "deadline": int64(0), "revision": m.leaseRevision}
		go m.notify("mediaLease", event)
		go m.applyMicrophone()
	}
}
func (m *mediaSession) forceMute() {
	m.mu.Lock()
	m.muted = true
	m.mu.Unlock()
	m.applyMicrophone()
}
func (m *mediaSession) applyMicrophone() {
	m.micMu.Lock()
	defer m.micMu.Unlock()
	m.mu.Lock()
	pub, muted := m.pub, m.muted || m.closed || ticks() >= m.until
	m.mu.Unlock()
	if pub != nil {
		pub.SetMuted(muted)
	}
}
func (m *mediaSession) close() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.closed = true
	m.retireLocked()
	m.mu.Unlock()
	if m.stopRTC != nil {
		m.stopRTC()
	}
	if m.room != nil {
		m.room.Disconnect()
	}
}

// Application and SDK queues are closed synchronously on an OS audio
// interruption. Heartbeats continue, but a fresh group is required on resume.
func (m *mediaSession) setAudioSuspended(value bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed || m.audioSuspended == value {
		return
	}
	m.audioSuspended = value
	if value {
		if m.group != "" {
			m.blockedGroup = m.group
		}
		m.retireLocked()
		m.recordLocked("audioInterrupted")
	} else {
		m.refresh.Store(true)
		m.recordLocked("audioResumed")
	}
}
func (m *mediaSession) install(n *native, group, roster string, index byte, ids []string, staged bool) error {
	keys := map[string]*senderKey{}
	for _, id := range ids {
		key, err := n.key(id, staged)
		if err != nil {
			return err
		}
		sender, err := newSenderKey(key)
		clear(key)
		if err != nil {
			return err
		}
		keys[id] = sender
	}
	if !m.stage(group, roster, index, keys) {
		return errContentPaused
	}
	return nil
}

func newSenderKey(key []byte) (*senderKey, error) {
	derived, err := hkdf.Key(sha256.New, key, []byte("LKFrameEncryptionKey"), string(make([]byte, 128)), 16)
	if err != nil {
		return nil, err
	}
	defer clear(derived)
	block, err := aes.NewCipher(derived)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &senderKey{material: sha256.Sum256(derived), aead: aead, seen: map[[12]byte]struct{}{}}, nil
}

func (m *mediaSession) stage(group, roster string, index byte, keys map[string]*senderKey) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.expireLocked()
	if roster == "" || m.closed || m.audioSuspended || m.transport != transportConnected || (m.blockedGroup != "" && (group == m.blockedGroup || strings.HasPrefix(group, m.blockedGroup+"/key/"))) {
		return false
	}
	if m.slots[index].group == group {
		return m.slots[index].roster == roster
	}
	// A key may appear in both slots while peers switch epochs. A received
	// nonce belongs to that sender and key independently of the trailer index.
	for id, key := range keys {
		for _, slot := range m.slots {
			if existing := slot.keys[id]; existing != nil && existing.material == key.material {
				keys[id] = existing
				break
			}
		}
	}
	m.slots[index] = keySlot{group: group, roster: roster, keys: keys}
	m.members = make(map[string]bool, len(keys))
	for id := range keys {
		m.members[id] = true
	}
	for id := range m.readSeq {
		if keys[id] == nil {
			delete(m.readSeq, id)
		}
	}
	m.recordLocked("keysInstalled")
	return true
}
func (m *mediaSession) grantLocked(group, roster string, index byte, until int64) bool {
	previousDuringSwitch := m.switching && index != m.index
	// The server can still acknowledge the previous epoch after its voice
	// overlap ended. It may extend membership, never reopen that receiver.
	slot := m.slots[index]
	if previousDuringSwitch {
		slot = m.slots[m.index]
	}
	keyAvailable := roster != "" && slot.roster == roster && slot.keys != nil
	if m.expireLocked() || m.closed || m.audioSuspended || m.transport != transportConnected || m.subscriptionFailure != nil || ticks() >= until || !keyAvailable || group == m.blockedGroup {
		return false
	}
	if m.index != index && !previousDuringSwitch {
		m.switchLocked(index)
	}
	if m.until == 0 {
		m.recordLocked("activated")
		signalWorker(m.subscriptionWake)
	}
	m.leaseRevision++
	m.group, m.until, m.expiryAt = group, until, until
	if previousDuringSwitch {
		m.slots[index].until = min(m.slots[index].until, until)
	} else {
		m.slots[index].until = until
	}
	if m.expiry != nil {
		m.expiry.Stop()
	}
	m.expiry = time.AfterFunc(time.Duration(max(1, until-ticks()+16))*time.Millisecond, func() {
		m.mu.Lock()
		m.expireLocked()
		m.mu.Unlock()
	})
	return true
}
func (m *mediaSession) beginSwitch(index byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.expireLocked() || m.closed || ticks() >= m.until || m.slots[index].keys == nil || m.slots[index].roster != m.slots[m.index].roster {
		return errContentPaused
	}
	m.switchLocked(index)
	m.switching = true
	return nil
}
func (m *mediaSession) switchLocked(index byte) {
	if m.index == index {
		return
	}
	slot := &m.slots[m.index]
	slot.until = min(slot.until, ticks()+1000)
	m.version++
	m.index = index
}

// Close the receive window at the local switch, then remove the old slot
// one second after the group confirms that every participant has switched.
func (m *mediaSession) retirePrevious() {
	m.mu.Lock()
	defer m.mu.Unlock()
	old := m.index ^ 1
	oldGroup := m.slots[old].group
	if m.retirement != nil {
		m.retirement.Stop()
	}
	m.retirement = time.AfterFunc(time.Second, func() {
		m.mu.Lock()
		if m.index != old && m.slots[old].group == oldGroup {
			m.slots[old] = keySlot{}
		}
		m.mu.Unlock()
	})
}
func (m *mediaSession) ready() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.expireLocked()
	return !m.closed && ticks() < m.until
}
func (m *mediaSession) mute(value bool) error {
	m.mu.Lock()
	if !value && (m.closed || ticks() >= m.until) {
		m.mu.Unlock()
		return errors.New("CONTENT_PAUSED")
	}
	m.muted = value
	m.recordLocked("microphoneChanged")
	m.mu.Unlock()
	if !value {
		if err := m.publishMicrophone(); err != nil {
			m.forceMute()
			return err
		}
	}
	m.applyMicrophone()
	return nil
}

func (m *mediaSession) publishMicrophone() error {
	m.micMu.Lock()
	defer m.micMu.Unlock()
	m.mu.Lock()
	if m.pub != nil || m.room == nil {
		m.mu.Unlock()
		return nil
	}
	if m.closed || m.muted || m.audioSuspended || ticks() >= m.until {
		m.mu.Unlock()
		return errContentPaused
	}
	version := m.version
	m.mu.Unlock()
	pub, err := m.room.LocalParticipant.PublishTrack(m.track, &lk.TrackPublicationOptions{Name: "Microphone", Source: livekit.TrackSource_MICROPHONE, Encryption: livekit.Encryption_GCM})
	if err != nil {
		return err
	}
	m.mu.Lock()
	m.pub = pub
	allowed := !m.closed && !m.muted && !m.audioSuspended && version == m.version && ticks() < m.until
	m.mu.Unlock()
	pub.SetMuted(!allowed)
	if !allowed {
		return errContentPaused
	}
	return nil
}
func (m *mediaSession) capture(id string, packet []byte, audioLevel *uint8) {
	if len(packet) < 1 || len(packet) > 1275 {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed || m.switching || id != m.group || m.muted || ticks() >= m.until {
		return
	}
	k := m.slots[m.index].keys[m.entry]
	if k == nil {
		return
	}
	iv := random(12)
	out := k.aead.Seal(append([]byte{}, packet[0]), iv, packet[1:], packet[:1])
	out = append(out, iv...)
	out = append(out, 12, m.index)
	if ticks() < m.until {
		_ = m.track.WriteSample(media.Sample{Data: out, Duration: 20 * time.Millisecond}, &lk.SampleWriteOptions{AudioLevel: audioLevel})
	}
}
func (m *mediaSession) play(track *webrtc.TrackRemote, id string, state *voiceTrack) {
	for {
		p, _, err := track.ReadRTP()
		if err != nil {
			return
		}
		codec := track.Codec().MimeType
		isRED := strings.EqualFold(codec, "audio/red")
		if !isRED && !strings.EqualFold(codec, webrtc.MimeTypeOpus) {
			continue
		}
		m.mu.Lock()
		if m.tracks[state.sid] != state || !state.subscribed {
			m.mu.Unlock()
			continue
		}
		state.received++
		if state.muted {
			m.mu.Unlock()
			continue
		}
		now := ticks()
		var measured voiceMeasurement
		plain, deadline, status := m.decryptVoice(id, p.Payload, &measured)
		changed := status != "" && state.encryption != status
		state.observeDecryption(status, now)
		if changed {
			m.logTracksLocked(true)
		}
		if isRED && len(plain) > 0 {
			// WebRTC applies encryption after RED combines the Opus blocks.
			plain, err = red.ExtractPrimaryEncoding(plain)
		}
		playable := err == nil && len(plain) > 0 && len(plain) <= 1275 && ticks() < deadline
		if playable && measured.generation != 0 {
			m.countDecryptionLocked(measured)
		}
		groupID := m.group
		m.mu.Unlock()
		if playable {
			m.notify("audio", obj{"entry": m.entry, "group": groupID, "sender": id, "packet": plain, "deadline": deadline})
		}
	}
}
func (m *mediaSession) openVoice(id string, frame []byte) ([]byte, int64) {
	p, d, _ := m.decryptVoice(id, frame, nil)
	return p, d
}
func (m *mediaSession) decryptVoice(id string, frame []byte, measured *voiceMeasurement) ([]byte, int64, string) {
	if len(frame) < 31 || len(frame) > 1500 || frame[len(frame)-2] != 12 || m.closed || ticks() >= m.until {
		return nil, 0, ""
	}
	index := frame[len(frame)-1]
	if index > 1 {
		return nil, 0, ""
	}
	slot := m.slots[index]
	until := min(slot.until, m.until)
	key := slot.keys[id]
	if key == nil && index == m.index && m.members[id] {
		return nil, 0, "missingKey"
	}
	if key == nil || ticks() >= until || len(key.seen) >= 65536 {
		return nil, 0, ""
	}
	pos := len(frame) - 14
	iv := [12]byte(frame[pos : pos+12])
	if _, ok := key.seen[iv]; ok {
		return nil, 0, ""
	}
	var start uint64
	if g := installationLog.epoch(); g != 0 && measured != nil && m.members[id] {
		measured.generation = g
		start = logClock(&m.logClockScratch)
	}
	plain, err := key.aead.Open([]byte{frame[0]}, iv[:], frame[1:pos], frame[:1])
	if start != 0 {
		measured.elapsed = logInterval(start, logClock(&m.logClockScratch))
	}
	if err != nil && index == m.index && ticks() < until {
		return nil, 0, "decryptionFailed"
	}
	if err != nil || ticks() >= until {
		return nil, 0, ""
	}
	key.seen[iv] = struct{}{}
	m.packets[id]++
	return plain, until, "verified"
}

type chatMessage struct {
	localEntry string      // The receiving admission, kept off the wire.
	Version    int         `json:"version"`
	ID         string      `json:"id"`
	Group      string      `json:"groupID"`
	Sender     string      `json:"sender"`
	Seq        uint64      `json:"sequence"`
	Text       string      `json:"text"`
	Attachment *descriptor `json:"attachment,omitempty"`
}

func validText(s string) bool {
	return utf8.ValidString(s) && len(s) <= 4096 && strings.TrimSpace(s) != "" && strings.IndexFunc(s, func(r rune) bool { return unicode.IsControl(r) && r != '\n' && r != '\t' }) < 0
}

var errChatBusy = errors.New("CHAT_BUSY")

func (m *mediaSession) send(text string, file *descriptor) error {
	return m.sendTo(context.Background(), "", text, file)
}
func (m *mediaSession) sendFile(group string, file *descriptor) error {
	return m.sendFileContext(context.Background(), group, file)
}
func (m *mediaSession) sendFileContext(ctx context.Context, group string, file *descriptor) error {
	return m.sendTo(ctx, group, "", file)
}
func (m *mediaSession) sendTo(ctx context.Context, group, text string, file *descriptor) error {
	if file == nil && !validText(text) {
		return errors.New("INVALID_MESSAGE")
	}
	m.mu.Lock()
	currentChannel := any(m.room).(channels).ChirpReliable
	pub, _ := currentChannel()
	permit := m.sendPermitLocked()
	if !permit.validLocked(m) || group != "" && group != permit.group {
		m.mu.Unlock()
		return errContentPaused
	}
	m.mu.Unlock()
	if pub == nil {
		return errChatBusy
	}
	// Bind BEFORE waiting for an earlier message. A later lease, track
	// reconnection or rotated provider cannot authorize these queued bytes.
	release, err := m.outbox.acquire(ctx, permit.deadline)
	if err != nil {
		return err
	}
	defer release()
	m.mu.Lock()
	if !permit.validLocked(m) || m.seq == ^uint64(0) {
		m.mu.Unlock()
		return errContentPaused
	}
	m.seq++
	id := uuid.New()
	msg := chatMessage{localEntry: m.entry, Version: 1, ID: id.String(), Group: permit.group, Sender: m.entry, Seq: m.seq, Text: text, Attachment: file}
	recipients := slices.Sorted(maps.Keys(m.slots[m.index].keys))
	m.mu.Unlock()
	if file != nil {
		msg.Version = 2
	}
	body, err := json.Marshal(msg)
	if err != nil || len(body) > 12<<10 {
		return invalid
	}
	topic := "chirp.room-chat.v1"
	payload, err := proto.Marshal(&livekit.EncryptedPacketPayload{Value: &livekit.EncryptedPacketPayload_User{User: &livekit.UserPacket{ParticipantIdentity: m.entry, Payload: body, Topic: &topic}}})
	if err != nil {
		return err
	}
	err = m.publish(permit, m.entry, payload, recipients, file != nil, func(data []byte) error { return m.dispatch(ctx, permit, pub, currentChannel, data) })
	if err != nil {
		return err
	}
	m.mu.Lock()
	ok := permit.validLocked(m)
	if ok {
		m.rememberMessage(receivedID{m.entry, id})
	}
	m.mu.Unlock()
	if !ok {
		return errContentPaused
	}
	m.notify("chat", msg)
	return nil
}
func (m *mediaSession) publish(permit sendPermit, sender string, payload []byte, recipients []string, attachment bool, write func([]byte) error) error {
	if len(recipients) == 0 {
		return invalid
	}
	batch := len(recipients)
	if attachment {
		batch = min(batch, 8)
	}
	for destinations := range slices.Chunk(recipients, batch) {
		iv := random(12)
		m.mu.Lock()
		if !permit.validLocked(m) {
			m.mu.Unlock()
			return errContentPaused
		}
		ciphertext := m.slots[permit.index].keys[m.entry].aead.Seal(nil, iv, payload, nil)
		m.mu.Unlock()
		encrypted := &livekit.EncryptedPacket{Iv: iv, KeyIndex: uint32(permit.index), EncryptedValue: ciphertext, EncryptionType: livekit.Encryption_GCM}
		packet := &livekit.DataPacket{Kind: livekit.DataPacket_RELIABLE, ParticipantIdentity: sender, DestinationIdentities: destinations, Value: &livekit.DataPacket_EncryptedPacket{EncryptedPacket: encrypted}}
		data, err := proto.Marshal(packet)
		if err != nil || len(data) > 15<<10 {
			return invalid
		}
		if err = write(data); err != nil {
			return err
		}
	}
	return nil
}

var errContentPaused = errors.New("CONTENT_PAUSED")

type sendPermit struct {
	group                  string
	version                uint64
	index                  byte
	keyHash                [32]byte // Queued writes must not retain the cipher after retirement.
	deadline, loginExpires int64
}

func (m *mediaSession) sendPermitLocked() sendPermit {
	p := sendPermit{group: m.group, version: m.version, index: m.index, deadline: m.until, loginExpires: m.loginExpires}
	if key := m.slots[m.index].keys[m.entry]; key != nil {
		p.keyHash = key.material
	}
	return p
}
func (p sendPermit) validLocked(m *mediaSession) bool {
	key := m.slots[m.index].keys[m.entry]
	return !m.closed && !m.switching && key != nil && p.keyHash == key.material && p.group == m.group && p.version == m.version && p.index == m.index && ticks() < min(p.deadline, m.until) && p.loginExpires > time.Now().Unix()
}
func (m *mediaSession) dispatch(ctx context.Context, p sendPermit, channel *webrtc.DataChannel, currentChannel func() (*webrtc.DataChannel, *webrtc.DataChannel), data []byte) error {
	for {
		m.mu.Lock()
		if err := ctx.Err(); err != nil {
			m.mu.Unlock()
			return err
		}
		current, _ := currentChannel()
		if !p.validLocked(m) || current != channel {
			m.mu.Unlock()
			return errContentPaused
		}
		switch channel.ReadyState() {
		case webrtc.DataChannelStateClosing, webrtc.DataChannelStateClosed:
			m.mu.Unlock()
			return errContentPaused
		case webrtc.DataChannelStateOpen:
			if channel.BufferedAmount() == 0 {
				// Pion Send is the RTC handoff. There is no SDK replay buffer
				// on this path. Retrying a parked write re-enters this gate.
				err := channel.Send(data)
				m.mu.Unlock()
				return err
			}
		}
		m.mu.Unlock()
		time.Sleep(10 * time.Millisecond)
	}
}

type receivedID struct {
	sender string
	id     uuid.UUID
}

func (m *mediaSession) receive(data []byte) {
	if len(data) > 16<<10 {
		return
	}
	var pkt livekit.DataPacket
	if proto.Unmarshal(data, &pkt) != nil {
		return
	}
	ep := pkt.GetEncryptedPacket()
	if ep == nil || len(ep.Iv) != 12 || ep.KeyIndex > 1 || ep.EncryptionType != livekit.Encryption_GCM {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	slot := m.slots[ep.KeyIndex]
	key := slot.keys[pkt.ParticipantIdentity]
	if key == nil || pkt.ParticipantIdentity == m.entry || m.closed || ticks() >= min(m.until, slot.until) {
		return
	}
	raw, err := key.aead.Open(nil, ep.Iv, ep.EncryptedValue, nil)
	if err != nil {
		return
	}
	var inner livekit.EncryptedPacketPayload
	if proto.Unmarshal(raw, &inner) != nil {
		return
	}
	u := inner.GetUser()
	if u == nil || u.ParticipantIdentity != pkt.ParticipantIdentity || u.GetTopic() != "chirp.room-chat.v1" || len(u.Payload) > 12<<10 {
		return
	}
	var msg chatMessage
	if json.Unmarshal(u.Payload, &msg) != nil || msg.Sender != pkt.ParticipantIdentity || msg.Group != m.group || msg.Seq <= m.readSeq[msg.Sender] {
		return
	}
	parsed, err := uuid.Parse(msg.ID)
	if err != nil {
		return
	}
	if msg.Attachment == nil {
		if msg.Version != 1 || !validText(msg.Text) {
			return
		}
	} else if msg.Version != 2 || msg.Text != "" || !msg.Attachment.valid(strings.Split(m.group, "/")[0], msg.Sender) {
		return
	}
	if ticks() >= min(m.until, slot.until) {
		return
	}
	if !m.rememberMessage(receivedID{msg.Sender, parsed}) {
		return
	}
	m.readSeq[msg.Sender] = msg.Seq
	msg.localEntry = m.entry
	m.notify("chat", msg)
}

func (m *mediaSession) rememberMessage(id receivedID) bool {
	if _, duplicate := m.messageIDs[id]; duplicate {
		return false
	}
	if m.messageIDs == nil {
		m.messageIDs = map[receivedID]struct{}{}
	}
	if len(m.recentIDs) == 1000 {
		delete(m.messageIDs, m.recentIDs[0])
		m.recentIDs = m.recentIDs[1:]
	}
	m.recentIDs = append(m.recentIDs, id)
	m.messageIDs[id] = struct{}{}
	return true
}
