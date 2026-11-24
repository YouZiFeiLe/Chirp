package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

// Exercise the same IPC, signed admissions, media transport and on-disk files
// as WinUI. Both accounts and the LiveKit instance are disposable.
func TestProtocolChirpLogEncryptedCall(t *testing.T) {
	if *startupProtocol == "" {
		t.Skip("set -chirp-startup-protocol to the built Windows protocol executable")
	}
	f := service(t, startSFU(t))
	first := enrollStartupDevice(t, f, "PrivateLogOne")
	first.enrolled.reset(f.ctx)
	second := f.account(t, "PrivateLogTwo")
	f.enroll(t, first.enrolled, second, true)
	host := launchProtocol(t, f, *startupProtocol, first)
	var state struct {
		Empty    bool
		Path, ID string
	}
	ok(t, json.Unmarshal(host.call(t, "exportLogs", args{}).Data, &state))
	if !state.Empty {
		t.Fatal("fresh pre-login log was not empty")
	}
	host.call(t, "setLogging", args{Enabled: true})
	host.login(t, f, first.account)
	host.call(t, "logout", args{})
	host.login(t, f, second)
	guest := startProtocol(t, f, *startupProtocol, enrollStartupDevice(t, f, "PrivateLogPeer"))
	hostEntry := host.join(t).state().Identity
	host.room(t, time.Time{}, "host active", func(s startupState) bool { return s.Ready && len(s.Peers) == 1 })
	start := time.Now()
	guestEntry := guest.join(t).state().Identity
	verifyStartupPeers(t, start, guest, host, guestEntry, hostEntry)
	_, group := waitForStartupGroup(t, start, []*startupClient{host, guest}, guestEntry)
	firstVoice(t, guest, host, guestEntry, hostEntry, group)
	const message = "UNIQUE_PRIVATE_CHAT_MARKER"
	sentAt := time.Now()
	guest.call(t, "chat", args{Entry: guestEntry, Group: group, Text: message})
	host.wait(t, sentAt, "remote chat delivery", func(frame startupFrame) bool {
		return frame.Event == "chat" && bytes.Contains(frame.Data, []byte(message))
	})
	host.call(t, "logAudioContext", args{Listening: true, Preset: 2, SelectedOutput: true})
	// Hold sender rate and receiver constant across both consent states.
	for _, enabled := range []bool{false, true} {
		host.call(t, "setLogging", args{Enabled: enabled})
		since := time.Now()
		t.Logf("voice window enabled=%t pid=%d", enabled, host.pid)
		tick := time.NewTicker(20 * time.Millisecond)
		for range 300 {
			<-tick.C
			ok(t, guest.input.Encode(command{Op: "voice", Args: args{Group: group, Packet: []byte{0xf8, 0xff, 0xfe}}}))
			// Drain the listener regularly, just as the UI consumes its pipe.
			if len(host.out) > 100 {
				host.call(t, "room", args{})
			}
		}
		tick.Stop()
		host.call(t, "room", args{})
		var frames int
		for _, frame := range host.read {
			if frame.Event == "audio" && frame.at.After(since) {
				frames++
			}
		}
		if frames < 200 {
			t.Fatalf("enabled=%t: only %d decrypted frames", enabled, frames)
		}
		t.Logf("voice window finished enabled=%t received=%d", enabled, frames)
	}
	host.call(t, "leave", args{})
	host.call(t, "setLogging", args{})
	ok(t, json.Unmarshal(host.call(t, "exportLogs", args{}).Data, &state))
	db, err := openLogDB(state.Path, false)
	ok(t, err)
	defer db.Close()
	logScalar(t, db, "PRAGMA integrity_check", "ok")
	logScalar(t, db, "SELECT count(*) FROM account WHERE event='loginAccepted'", 2)
	logScalar(t, db, "SELECT count(DISTINCT segment) FROM account WHERE event='loginAccepted'", 1)
	var windows, frames, total, peak int64
	ok(t, db.QueryRow("SELECT count(*), coalesce(sum(json_extract(details,'$.frames')),0), coalesce(sum(json_extract(details,'$.total_ns')),0), coalesce(max(json_extract(details,'$.max_ns')),0) FROM crypto WHERE event='voiceDecrypt'").Scan(&windows, &frames, &total, &peak))
	t.Logf("decrypted frames=%d aggregate rows=%d total_ns=%d peak_ns=%d", frames, windows, total, peak)
	for _, query := range []string{
		"SELECT count(*)>0 FROM network WHERE event='mediaLease' AND http_status=200 AND duration_us>0",
		"SELECT count(*)>0 FROM call WHERE event='lifecycle' AND json_extract(details,'$.event')='authorizationStarted'",
		"SELECT count(*)>0 FROM call WHERE event='lifecycle' AND json_extract(details,'$.event')='activated'",
		"SELECT count(*)>0 FROM call WHERE event='trackSample' AND json_extract(details,'$.preset')='software' AND json_extract(details,'$.tracks[0].encryption')='verified'",
		"SELECT count(*)>0 FROM chat WHERE event='receiveMessage'",
		"SELECT sum(json_extract(details,'$.frames'))>200 AND count(*)<40 AND min(json_extract(details,'$.max_ns'))>0 FROM crypto WHERE event='voiceDecrypt'",
	} {
		logScalar(t, db, query, true)
	}
	ok(t, db.Close())
	b, err := os.ReadFile(state.Path)
	ok(t, err)
	for _, private := range []string{message, "PrivateLog", guestEntry, hostEntry, f.origin, first.account.ID, second.ID, store.DefaultRoomID, password} {
		if len(private) > 0 && bytes.Contains(b, []byte(private)) {
			t.Fatalf("export contained a private value")
		}
	}
	host.call(t, "releaseLogExport", args{ID: state.ID})
	if _, err = os.Stat(state.Path); !os.IsNotExist(err) {
		t.Fatal("snapshot survived release", err)
	}
}

func manageLog(t *testing.T, l *clientLog, op string, a args) obj {
	t.Helper()
	var result any
	ok(t, l.sync(func() error { var err error; result, err = l.manage(command{Op: op, Args: a}); return err }))
	if result == nil {
		return nil
	}
	return result.(obj)
}

func exportedLog(t *testing.T, l *clientLog) (*sql.DB, string) {
	t.Helper()
	result := manageLog(t, l, "exportLogs", args{})
	path, okPath := result["path"].(string)
	if !okPath {
		t.Fatal("expected nonempty snapshot", result)
	}
	db, err := openLogDB(path, false)
	ok(t, err)
	t.Cleanup(func() { db.Close() })
	return db, path
}

func logScalar[T comparable](t *testing.T, db *sql.DB, query string, want T) {
	t.Helper()
	var got T
	ok(t, db.QueryRow(query).Scan(&got))
	if got != want {
		t.Fatalf("%s = %v, want %v", query, got, want)
	}
}

func TestClientLogConsentPrivacyAndClear(t *testing.T) {
	data, cache := t.TempDir(), t.TempDir()
	now := func() time.Time { return time.UnixMilli(1800000000000) }
	l := openClientLog(data, cache, now)
	defer l.shutdown()
	if l.epoch() != 0 || manageLog(t, l, "exportLogs", args{})["empty"] != true {
		t.Fatal("fresh install recorded events")
	}
	if _, err := os.Stat(l.store.dir); !os.IsNotExist(err) {
		t.Fatal("unexpected default log folder", err)
	}
	manageLog(t, l, "setLogging", args{Enabled: true})
	g := l.epoch()
	const secret = "UNRECOGNIZED_PRIVATE_SENTINEL"
	a := args{Generation: g, Action: "memberInfo", Enabled: true, Address: "https://" + secret, Name: secret, Text: secret, Password: secret, Entry: secret, Group: secret, Path: secret, Code: secret, Packet: []byte(secret)}
	l.uiEvent(a)
	a.Action = secret
	l.uiEvent(a)
	span := l.begin()
	l.finish(span, commandLogOps["exchange"], &apiError{code: secret, status: 403}, 0)
	l.finish(span, commandLogOps["join"], errJoinCancelled, 0)
	manageLog(t, l, "setLogging", args{})
	l.uiEvent(a)
	l.finish(span, commandLogOps["phone"], nil, 0)
	db, path := exportedLog(t, l)
	logScalar(t, db, "PRAGMA integrity_check", "ok")
	logScalar(t, db, "PRAGMA application_id", 1128813136)
	logScalar(t, db, "PRAGMA user_version", 1)
	for _, table := range logTables {
		logScalar(t, db, "SELECT group_concat(name,',') FROM pragma_table_info('"+table+"')", "time_ms,event,outcome,error_code,duration_us,http_status,details,segment,seq")
		logScalar(t, db, "SELECT count(*) FROM sqlite_schema WHERE type='index' AND name='"+table+"_time'", 1)
	}
	logScalar(t, db, "SELECT count(*) FROM sqlite_schema WHERE type='table'", 12)
	logScalar(t, db, "SELECT count(*) FROM account WHERE event='exchangeLogin' AND outcome='failed' AND http_status=403 AND duration_us >= 0 AND error_code='CLIENT_UNKNOWN_SERVER_ERROR'", 1)
	logScalar(t, db, "SELECT count(*) FROM room WHERE outcome='cancelled' AND error_code IS NULL", 1)
	logScalar(t, db, "SELECT details FROM navigation", `{"visible":true}`)
	logScalar(t, db, "SELECT group_concat(event,',') FROM (SELECT event FROM settings ORDER BY seq)", "recordingEnabled,recordingDisabled")
	logScalar(t, db, "SELECT count(*) FROM account", 1)
	var segment string
	ok(t, db.QueryRow("SELECT segment FROM account").Scan(&segment))
	if id, err := uuid.Parse(segment); err != nil || id.String() != segment {
		t.Fatal("invalid segment")
	}
	ok(t, db.Close())
	b, err := os.ReadFile(path)
	ok(t, err)
	if !bytes.HasPrefix(b, []byte("SQLite format 3\x00")) || bytes.Contains(b, []byte(secret)) {
		t.Fatal("private data or invalid header")
	}
	for _, suffix := range []string{"-wal", "-journal", "-shm"} {
		if _, err := os.Stat(path + suffix); !os.IsNotExist(err) {
			t.Fatal("export has a sidecar", err)
		}
	}

	manageLog(t, l, "setLogging", args{Enabled: true})
	cleared := l.begin()
	manageLog(t, l, "clearLogs", args{})
	manageLog(t, l, "clearLogs", args{})
	l.finish(cleared, commandLogOps["browser"], nil, 0)
	a.Generation, a.Action = g, "room"
	l.uiEvent(a)
	if l.epoch() == 0 || manageLog(t, l, "exportLogs", args{})["empty"] != true {
		t.Fatal("old work survived clear")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("clear retained staged export", err)
	}
	l.uiEvent(args{Action: "settings", Generation: l.epoch(), Enabled: true})
	next, _ := exportedLog(t, l)
	logScalar(t, next, "SELECT seq FROM navigation", 1)
	var nextSegment string
	ok(t, next.QueryRow("SELECT segment FROM navigation").Scan(&nextSegment))
	if nextSegment == segment {
		t.Fatal("segment reused")
	}
	ok(t, next.Close())
	ok(t, l.sync(func() error { return l.clear(true) }))
	if l.epoch() != 0 || manageLog(t, l, "exportLogs", args{})["empty"] != true {
		t.Fatal("clear local data retained logs or consent")
	}
}

func TestLogHourlyRetentionOnDisabledStartup(t *testing.T) {
	data, cache := t.TempDir(), t.TempDir()
	var clock atomic.Int64
	now := func() time.Time { return time.UnixMilli(clock.Load()) }
	cutoff := time.Date(2026, 11, 20, 23, 51, 0, 0, time.UTC).UnixMilli()
	clock.Store(cutoff - 2*logHourMS)
	l := openClientLog(data, cache, now)
	manageLog(t, l, "setLogging", args{Enabled: true})
	shard := func(ms int64) string {
		return filepath.Join(l.store.dir, strconv.FormatInt(ms/logHourMS, 10)+".chirplog")
	}
	record := func(ms int64, name string) {
		clock.Store(ms)
		l.record(l.epoch(), logEntry{op: logOp{"account", name}})
	}
	record(cutoff-1, "expired")
	record(cutoff, "atBoundary")
	ok(t, l.sync(func() error { _, err := l.flush(); return err }))
	record(cutoff+86400000, "atNow")
	record(cutoff+86400001, "future")
	manageLog(t, l, "setLogging", args{})
	l.shutdown()
	old := shard(cutoff - 2*logHourMS)
	ok(t, os.WriteFile(old+"-shm", []byte("old"), 0600))
	orphan := filepath.Join(filepath.Dir(old), "export.interrupted.chirplog")
	ok(t, os.WriteFile(orphan, nil, 0600))
	clock.Store(cutoff + logRetentionMS)
	l = openClientLog(data, cache, now)
	defer l.shutdown()
	manageLog(t, l, "logState", args{})
	if l.epoch() != 0 {
		t.Fatal("consent changed on restart")
	}
	for _, p := range []string{old, old + "-shm", orphan} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatal("retained expired file", err)
		}
	}
	db, _ := exportedLog(t, l)
	logScalar(t, db, "SELECT group_concat(event,',') FROM (SELECT event FROM account ORDER BY time_ms)", "atBoundary,atNow")
	ok(t, db.Close())
	boundary, err := openLogDB(shard(cutoff), false)
	ok(t, err)
	logScalar(t, boundary, "SELECT count(*) FROM account WHERE event='expired'", 0)
	ok(t, boundary.Close())
	clock.Add(1)
	manageLog(t, l, "logActivity", args{Enabled: true})
	if _, err := os.Stat(shard(cutoff)); !os.IsNotExist(err) {
		t.Fatal("empty boundary shard retained", err)
	}
}

func TestLogConcurrentExportAndDiskRecovery(t *testing.T) {
	data := t.TempDir()
	l := openClientLog(data, data, time.Now)
	defer l.shutdown()
	ok(t, os.WriteFile(l.store.dir, nil, 0600))
	manageLog(t, l, "setLogging", args{Enabled: true})
	for i := 0; i < 2300; i++ {
		l.record(l.epoch(), logEntry{op: logOp{"room", "join"}})
	}
	if err := l.sync(func() error { _, err := l.flush(); return err }); err == nil {
		t.Fatal("unwritable storage accepted commit")
	}
	ok(t, os.Remove(l.store.dir))
	recovered, _ := exportedLog(t, l)
	logScalar(t, recovered, "SELECT (SELECT count(*) FROM room)+(SELECT coalesce(sum(json_extract(details,'$.count')),0) FROM application)+(SELECT count(*) FROM settings)", 2301)
	ok(t, recovered.Close())
	manageLog(t, l, "clearLogs", args{})
	var producers sync.WaitGroup
	for range 8 {
		producers.Go(func() {
			for range 80 {
				l.record(l.epoch(), logEntry{op: logOp{"chat", "compose"}})
			}
		})
	}
	manageLog(t, l, "exportLogs", args{})
	producers.Wait()
	db, _ := exportedLog(t, l)
	logScalar(t, db, "SELECT count(DISTINCT seq) FROM chat", 640)
	logScalar(t, db, "SELECT max(seq) FROM chat", 640)
	logScalar(t, db, "PRAGMA integrity_check", "ok")
}

func TestLogRejectsForeignShard(t *testing.T) {
	s := logStore{dir: t.TempDir()}
	now := time.Now().UnixMilli()
	path := filepath.Join(s.dir, strconv.FormatInt(now/logHourMS, 10)+".chirplog")
	db, err := sql.Open("sqlite", path)
	ok(t, err)
	_, err = db.Exec("CREATE TABLE foreign_data(x); PRAGMA user_version=2")
	ok(t, err)
	ok(t, db.Close())
	if _, err = openLogDB(path, true); !errors.Is(err, errLogFormat) {
		t.Fatal("foreign database adopted", err)
	}
	if _, err = s.snapshot(now); !errors.Is(err, errLogFormat) {
		t.Fatal("foreign shard exported", err)
	}
	files, err := s.files()
	ok(t, err)
	if len(files) != 1 {
		t.Fatal("failed snapshot left scratch files", files)
	}
}

func TestLogRestartStartsNewAnonymousSegment(t *testing.T) {
	data := t.TempDir()
	first := openClientLog(data, data, time.Now)
	manageLog(t, first, "setLogging", args{Enabled: true})
	first.lifecycle(first.epoch(), "authorizationStarted", "authorizing", nil, nil)
	first.shutdown()
	second := openClientLog(data, data, time.Now)
	defer second.shutdown()
	if second.epoch() == 0 {
		t.Fatal("recording preference lost at restart")
	}
	second.lifecycle(second.epoch(), "decryptionRecovery", "recovering", &mediaSession{muted: true}, nil)
	db, _ := exportedLog(t, second)
	logScalar(t, db, "SELECT count(DISTINCT segment) FROM call", 2)
	logScalar(t, db, "SELECT count(*) FROM call WHERE json_extract(details,'$.sequence')=1 AND json_extract(details,'$.elapsedMilliseconds')=0", 2)
	logScalar(t, db, "SELECT count(*) FROM application WHERE event='launch' AND seq=1 AND json_extract(details,'$.platform')='windows'", 1)
}
