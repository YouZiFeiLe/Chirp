// Chirp's native protocol process belongs to the desktop application session. Its inherited
// pipes carry UI commands and ephemeral media. No TCP listener or renderer.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

type args struct {
	Address, URL, Password, Peer, Action, ID, Key, Root, Name, Text, Path, Device, Group, Code, Entry, Revision string
	File, Packet                                                                                                []byte
	AudioLevel                                                                                                  *uint8
	Enabled                                                                                                     bool

	DurationUs                               *int64
	Generation                               uint64
	Preset                                   int
	SelectedInput, SelectedOutput, Listening bool
	Outcome                                  string
}
type command struct {
	ID                uint64
	Op                string
	Args              args
	span              logSpan
	join              *joinAttempt
	suspensionApplied bool
}
type engine struct {
	vault               *vault
	cache, trustKey     string
	local               bool
	conn                *connection
	pendingConnection   *connection
	pendingConnectionID string
	flow                *loginFlow
	account             *storedAccount
	session             *session
	loginLifetime       context.Context
	stopLoginWatch      context.CancelCauseFunc
	room                *activeRoom
	auth                authority
	audio               atomic.Pointer[mediaSession]
	fileScope           atomic.Pointer[attachmentSession]
	joins               joinRequests
	pairing             *pairing
	notify              func(string, any)
	directoryRev        uint64
	directoryServer     string
	stopDirectory       context.CancelFunc
	directoryWatch      atomic.Uint64
	avatarContext       context.Context
	stopAvatars         context.CancelFunc
}

func (e *engine) handle(ctx context.Context, c command) (any, error) {
	a := c.Args
	if e.vault != nil && e.vault.unavailable && c.Op != "clearLocalData" {
		return nil, errors.New("IDENTITY_STORE_UNAVAILABLE")
	}
	switch c.Op {
	case "clearLocalData":
		if installationLog != nil {
			if err := installationLog.sync(func() error { return installationLog.clear(true) }); err != nil {
				return nil, errors.New("LOG_STORAGE_UNAVAILABLE")
			}
		}
		e.reset(ctx)
		if err := os.Remove(e.vault.path); err != nil && !os.IsNotExist(err) {
			return nil, err
		}
		*e.vault = vault{Accounts: map[string]*storedAccount{}, path: e.vault.path}
		e.conn = nil
		return nil, e.clearFiles()
	case "restoreConnection":
		if e.session != nil {
			return nil, invalid
		}
		return e.restoreConnection()
	case "register":
		if e.session != nil {
			return nil, invalid
		}
		c, err := e.refreshConnection(ctx)
		if err != nil {
			return nil, err
		}
		if !c.registration {
			return nil, errors.New("REGISTRATION_CLOSED")
		}
		return obj{"url": c.endpoints.RegistrationURL}, nil
	case "savedIdentities":
		return e.savedIssuers(), nil
	case "savedAccounts":
		return e.savedAccounts(), nil
	case "invalidateConnection", "discover":
		if e.session != nil {
			return nil, invalid
		}
		e.cancelLogin(ctx)
		e.conn, e.pendingConnection, e.pendingConnectionID = nil, nil, ""
		if c.Op == "invalidateConnection" {
			return nil, nil
		}
		conn, err := detect(ctx, a.Address, e.local)
		if err != nil {
			return nil, err
		}
		if a.Action == "stage" {
			if a.ID == "" {
				return nil, invalid
			}
			e.pendingConnection, e.pendingConnectionID = conn, a.ID
			return obj{"id": a.ID}, nil
		}
		if err := e.rememberConnection(conn); err != nil {
			return nil, err
		}
		return e.connectionView(), nil
	case "confirmConnection":
		if e.session != nil || e.pendingConnection == nil || a.ID == "" || a.ID != e.pendingConnectionID {
			return nil, invalid
		}
		if err := e.rememberConnection(e.pendingConnection); err != nil {
			return nil, err
		}
		e.pendingConnection, e.pendingConnectionID = nil, ""
		return e.connectionView(), nil
	case "browser", "phone":
		return e.begin(ctx, c.Op == "phone")
	case "exchange":
		return e.exchange(ctx, a.URL)
	case "pollPhone", "finishPhone":
		if e.flow == nil || a.ID == "" || e.flow.state != a.ID || !e.flow.phone {
			return nil, errors.New("LOGIN_EXPIRED")
		}
		if c.Op == "pollPhone" {
			return e.claim(ctx, "", true)
		}
		if e.flow.setup.AccountID == "" {
			return nil, invalid
		}
		return e.continueSetup(ctx)
	case "cancelLogin":
		if a.ID != "" && (e.flow == nil || e.flow.state != a.ID) {
			return nil, nil
		}
		e.cancelLogin(ctx)
		return nil, nil
	case "backup":
		if a.ID != "" && (e.flow == nil || e.flow.state != a.ID) {
			return nil, errors.New("LOGIN_EXPIRED")
		}
		return e.backup(a.Password)
	case "unlockBackup", "backupExported", "verifyBackup", "finishBackup":
		return e.backupAction(ctx, c.Op, a)
	case "confirmBackup", "recover":
		if a.ID != "" && (e.flow == nil || e.flow.state != a.ID) {
			return nil, errors.New("LOGIN_EXPIRED")
		}
		return e.recover(ctx, a.File, a.Password, c.Op == "confirmBackup")
	case "pairNew", "pairOld", "pairPoll", "pairCheckCode", "pairConfirm", "finishPair", "pairCancel":
		return e.devicePair(ctx, c.Op, a)
	case "audioSuspended":
		if !c.suspensionApplied && e.room != nil && a.Entry != "" && a.Entry == e.room.join.Identity {
			e.room.media.setAudioSuspended(a.Enabled)
		}
		return nil, nil
	}
	if e.session == nil {
		return nil, errors.New("LOGIN_REQUIRED")
	}
	switch c.Op {
	case "watchDirectory":
		if e.stopDirectory == nil {
			watchCtx, cancel := context.WithCancel(ctx)
			e.stopDirectory = cancel
			revision := e.directoryWatch.Add(1)
			login, key := e.session.Identity, a.Key
			go watchDirectory(watchCtx, e.conn.api("v1/events"), e.session.Credential, func(name string, _ any) {
				if watchCtx.Err() == nil && e.directoryWatch.Load() == revision {
					e.notify(name, obj{"login": login, "watch": key})
				}
			})
		}
		return nil, nil
	case "unwatchDirectory":
		e.stopWatchingDirectory()
		return nil, nil
	case "state":
		var s struct {
			Server   string          `json:"server_id"`
			Revision uint64          `json:"revision"`
			Rooms    []room.Overview `json:"rooms"`
			Members  []wireProfile   `json:"members"`
		}
		if err := e.api(ctx, "GET", "v1/state", nil, &s); err != nil {
			return nil, err
		}
		if s.Server == "" || len(s.Server) > 128 || s.Revision == 0 || s.Server == e.directoryServer && s.Revision < e.directoryRev || len(s.Rooms) == 0 || s.Rooms[0].RoomID != e.conn.defaultRoom || s.Members == nil {
			return nil, invalid
		}
		seen := map[string]bool{}
		for i, r := range s.Rooms {
			if !store.ValidRoomID(r.RoomID) || !validName(r.DisplayName) || seen[r.RoomID] || r.KeyProtocol != "chirp-mls-authenticated-v5" || r.IsDefault != (i == 0) || r.MaxParticipants != 0 || !validRoomPresence(r) {
				return nil, invalid
			}
			seen[r.RoomID] = true
		}
		seen = map[string]bool{}
		for _, p := range s.Members {
			if seen[p.ID] {
				return nil, invalid
			}
			seen[p.ID] = true
		}
		e.directoryRev = s.Revision
		e.directoryServer = s.Server
		return s, nil
	case "networkRestored":
		return nil, e.refreshAmbient(ctx)
	case "join":
		return nil, e.runJoin(ctx, c)
	case "cancelJoin":
		return nil, e.cancelCommittedJoin(ctx, a.Key)
	case "leave":
		e.leaveRoom(ctx)
		return nil, nil
	case "room":
		return e.roomView(), nil
	case "cacheSize":
		entries, err := os.ReadDir(e.cache)
		var bytes int64
		for _, entry := range entries {
			if info, err := entry.Info(); err == nil && info.Mode().IsRegular() {
				bytes += info.Size()
			}
		}
		return obj{"bytes": bytes}, err
	case "clearCache":
		s := e.fileScope.Load()
		if s == nil && e.room == nil && a.Entry == "" && a.Revision == "" {
			return obj{"entry": "", "revision": ""}, e.purgeFileCache()
		}
		if s == nil || s.ctx.Err() != nil || a.Entry != s.entry || a.Revision != s.revision {
			return nil, errors.New("ATTACHMENT_UNAVAILABLE")
		}
		err := e.clearFiles()
		var revision string
		if next := e.fileScope.Load(); next != nil {
			revision = next.revision
		}
		data := obj{"entry": s.entry, "revision": revision, "previous": s.revision}
		e.notify("cacheCleared", data)
		return data, err
	case "verify":
		err := e.verify(ctx, a.Action, a.Peer, a.ID)
		if err == nil {
			signalWorker(e.room.progress)
		}
		return nil, err
	case "mute":
		if e.room == nil || a.Entry != "" && e.room.join.Identity != a.Entry || a.Group != "" && groupID(e.room.snap) != a.Group {
			return nil, invalid
		}
		return nil, e.room.media.mute(a.Enabled)
	case "setListening":
		if r := e.room; r != nil && r.join.Identity == a.Entry && (r.listening == nil || *r.listening != a.Enabled) {
			r.listening = new(a.Enabled)
			r.media.mu.Lock()
			r.media.recordLocked("listeningChanged")
			r.media.logTracksLocked(true)
			r.media.mu.Unlock()
			r.publishListening(true)
		}
		return nil, nil
	case "chat":
		if e.room == nil || a.Entry != e.room.join.Identity || a.Group != groupID(e.room.snap) {
			return nil, invalid
		}
		return nil, e.room.media.sendTo(ctx, a.Group, a.Text, nil)
	case "upload":
		s := e.fileScope.Load()
		if s == nil || a.Entry != s.entry || a.Revision != s.revision || e.room == nil || a.Group != groupID(e.room.snap) {
			return nil, errors.New("ATTACHMENT_UNAVAILABLE")
		}
		return e.upload(ctx, a.Path, a.File)
	case "download", "resumeFile", "pauseFile", "cancelFile", "previewFile", "prepareExport":
		s := e.fileScope.Load()
		if s == nil {
			return nil, errors.New("ATTACHMENT_UNAVAILABLE")
		}
		return s.command(ctx, c.Op, a)
	case "friends":
		if err := e.refreshAuth(ctx, e.roomRoots(), true); err != nil && !temporarilyUnavailable(err) {
			return nil, err
		}
		return e.auth.friends, nil
	case "friend":
		if e.room == nil {
			return nil, invalid
		}
		p := e.room.peer(a.Peer)
		if p == nil || p.Identity == e.room.join.Identity {
			return nil, invalid
		}
		if e.blocked(memberID(p.Identity), p.Binding.Device.AccountKey, p.Binding.Device.LeafKey()) {
			return nil, errors.New("PEER_IDENTITY_BLOCKED")
		}
		return nil, e.social(ctx, "friend", memberID(p.Identity), p.Binding.Device.AccountKey, "", p.Name)
	case "removeFriend", "untrust":
		for _, f := range e.auth.friends {
			if f.ID == a.ID && f.Root == a.Root {
				op := "remove_friend"
				key := ""
				if c.Op == "untrust" {
					if !slices.Contains(f.Devices, a.Key) {
						return nil, invalid
					}
					op = "untrust"
					key = a.Key
				}
				return nil, e.social(ctx, op, f.ID, f.Root, key, f.Name)
			}
		}
		return nil, invalid
	case "devices":
		return e.registeredDevices(ctx)
	case "blacklist":
		if err := e.refreshAuth(ctx, e.roomRoots(), true); err != nil && !temporarilyUnavailable(err) {
			return nil, err
		}
		fallthrough
	case "cachedBlacklist":
		return e.vault.Blacklists[e.conn.origin], nil
	case "renameDevice", "revoke":
		key, err := routeKey(a.Key)
		if err != nil {
			return nil, err
		}
		path := "v1/identity/devices/" + key
		if c.Op == "renameDevice" {
			return nil, e.api(ctx, "PATCH", path, obj{"name": a.Name}, nil)
		}
		if a.Key == e.session.Device.LeafKey() {
			return nil, invalid
		}
		if !e.canEnroll() {
			return nil, errors.New("DEVICE_APPROVAL_NOT_ALLOWED")
		}
		own := e.auth.states[e.session.Device.AccountKey]
		if own == nil || own.Devices[a.Key].LeafKey() == "" {
			return nil, invalid
		}
		if pending := e.account.PendingRevocation; pending != "" && pending != a.Key {
			return nil, errors.New("REVOCATION_PENDING")
		}
		e.account.PendingRevocation = a.Key
		if e.account.Denied == nil {
			e.account.Denied = map[string]bool{}
		}
		e.account.Denied[a.Key] = true
		if e.room != nil {
			e.room.media.pause()
			for _, peer := range e.room.snap.Members {
				if peer.Binding != nil && peer.Binding.Device.LeafKey() == a.Key {
					e.room.media.forceMute()
					break
				}
			}
		}
		if err = e.vault.save(); err != nil {
			return nil, err
		}
		if err := e.refreshAuth(ctx, e.roomRoots(), true); temporarilyUnavailable(err) {
			return nil, errors.New("REVOCATION_PENDING")
		} else {
			return nil, err
		}
	case "profile", "rename", "avatar", "removeAvatar":
		return e.ownProfile(ctx, c)
	case "getAvatar":
		return fetchAvatar(ctx, e.conn, e.session.Credential, a)
	case "logout":
		owner, endpoint := e.session, e.conn.api("v1/logout")
		installationLog.record(installationLog.epoch(), logEntry{op: logOp{"account", "sessionEnded"}})
		e.reset(ctx)
		_, err := request(ctx, "logout", "POST", endpoint, nil, owner.Credential, nil, nil, 65536)
		return nil, err
	}
	return nil, errors.New("UNKNOWN_COMMAND")
}
func (e *engine) canEnroll() bool {
	chain := e.session.Device.Certificates
	return len(chain) != 0 && chain[len(chain)-1].CanEnroll
}

func (e *engine) roomView() any {
	r := e.room
	if r == nil {
		return nil
	}
	peers := []obj{}
	for _, p := range r.snap.Members {
		self := p.Identity == r.join.Identity
		mic, listening, speaking := r.peerAudio(p.Identity)
		r.media.mu.Lock()
		quality := "UNKNOWN"
		if v, ok := r.media.quality[p.Identity]; ok {
			quality = v.String()
		}
		packets := r.media.packets[p.Identity]
		r.media.mu.Unlock()
		peers = append(peers, obj{
			"id": p.Identity, "name": p.Name, "friendName": trustedFriendName(e.auth.friends, memberID(p.Identity), p.Binding.Device.AccountKey),
			"trusted": e.trusted(p), "self": self, "root": p.Binding.Device.AccountKey, "key": p.Binding.Device.LeafKey(),
			"mic": mic, "listening": listening, "speaking": speaking,
			"quality": quality, "packets": packets, "diagnostic": r.media.peerDiagnostic(p.Identity),
		})
	}
	m := r.media
	m.mu.Lock()
	muted := m.muted
	ready := !m.closed && ticks() < m.until
	deadline := m.until
	leaseRevision := m.leaseRevision
	group := m.group
	m.mu.Unlock()
	var cacheRevision string
	if s := e.fileScope.Load(); s != nil && s.ctx.Err() == nil {
		cacheRevision = s.revision
	}
	info, observed, unavailable := r.information.view()
	unavailable = unavailable || r.status == "paused" || r.status == "reconnecting" || r.status == "audioInterrupted"
	return obj{"entry": r.join.Identity, "informationObservedAt": observed, "informationUnavailable": unavailable, "cacheRevision": cacheRevision, "room": r.join.Room, "group": group, "status": r.status, "ready": ready, "deadline": deadline, "leaseRevision": leaseRevision, "muted": muted, "peers": peers, "verification": r.verification, "canRetryVerification": e.canRetryVerification(r), "information": info}
}
func (e *engine) reset(ctx context.Context) {
	if e.stopLoginWatch != nil {
		e.stopLoginWatch(nil)
		e.loginLifetime, e.stopLoginWatch = nil, nil
	}
	if e.stopAvatars != nil {
		e.stopAvatars()
		e.stopAvatars = nil
	}
	e.stopWatchingDirectory()
	e.leaveRoom(ctx)
	e.cancelLogin(ctx)
	e.session = nil
	e.pendingConnection, e.pendingConnectionID = nil, ""
	e.account = nil
	e.auth = authority{}
	e.directoryServer = ""
	e.directoryRev = 0
}

func (e *engine) endLogin(ctx context.Context, owner *session, reason string) bool {
	if owner == nil || e.session != owner || reason == "" {
		return false
	}
	if media := e.audio.Load(); media != nil {
		media.pause()
	}
	installationLog.record(installationLog.epoch(), logEntry{op: logOp{"account", "sessionEnded"}, code: safeLogError(errors.New(reason))})
	e.notify("signedOut", reason)
	e.reset(ctx)
	return true
}

const roomTickInterval = 900 * time.Millisecond

func (e *engine) updateRoom(root, work context.Context) {
	r := e.room
	if r == nil {
		return
	}
	r.progressDue = nil
	if err := e.tickRoom(work); err != nil {
		if e.endLogin(root, e.session, signedOutReason(err)) {
			return
		}
		r.media.pause()
		if r.status != err.Error() {
			r.media.mu.Lock()
			installationLog.lifecycle(installationLog.epoch(), "failed", "recovering", r.media, err)
			r.media.mu.Unlock()
		}
		r.status = err.Error()
		if terminalRoomError(err) {
			e.leaveRoom(root)
			e.notify("roomError", err.Error())
			return
		}
	}
	r.media.logMediaTick(r.status)
	e.notify("room", e.roomView())
}

func main() {
	dir := flag.String("data", "", "application data directory")
	logCache := flag.String("log-cache", "", "installation-local non-backup directory")
	local := flag.Bool("loopback", false, "allow loopback development server")
	flag.Parse()
	if *dir == "" {
		os.Exit(2)
	}
	root, cancel := context.WithCancel(context.Background())
	defer cancel()
	if *logCache == "" {
		*logCache = *dir
	}
	installationLog = openClientLog(*dir, *logCache, time.Now)
	defer installationLog.shutdown()
	silenceMediaLogger()
	var output sync.Mutex
	encoder := json.NewEncoder(os.Stdout)
	write := func(v any) {
		output.Lock()
		defer output.Unlock()
		if encoder.Encode(v) != nil {
			cancel()
		}
	}
	send := func(name string, v any) { write(obj{"event": name, "data": v}) }
	v := openIdentityVault(*dir)
	exe, err := os.Executable()
	if err != nil {
		return
	}
	pin, err := bundledAuthorizationKey(filepath.Dir(exe))
	if err != nil {
		send("fatal", "AUTHORIZATION_KEY_MISSING")
		return
	}
	cache, err := os.MkdirTemp(*dir, "session-")
	if err != nil {
		return
	}
	defer os.RemoveAll(cache)
	// Session directories are private to this app instance and contain only
	// temporary ciphertext. A crash may have left an earlier one behind.
	if entries, err := os.ReadDir(*dir); err == nil {
		for _, entry := range entries {
			path := filepath.Join(*dir, entry.Name())
			if entry.IsDir() && path != cache && strings.HasPrefix(entry.Name(), "session-") {
				_ = os.RemoveAll(path)
			}
		}
	}
	inbox := newActorMailbox[chatDelivery]()
	revoked := make(chan struct{}, 1)
	e := engine{vault: v, cache: cache, trustKey: pin, local: *local}
	e.notify = func(name string, data any) {
		switch name {
		case "chat":
			inbox.push(chatDelivery{data.(chatMessage), e.fileScope.Load()})
		case "attachmentRevoked":
			signalWorker(revoked)
		default:
			send(name, data)
		}
	}
	commands := newActorMailbox[command]()
	avatarResults := make(chan avatarReply, 4)
	go func() {
		defer cancel()
		s := bufio.NewScanner(os.Stdin)
		s.Buffer(make([]byte, 65536), 8<<20)
		for s.Scan() {
			var c command
			if json.Unmarshal(s.Bytes(), &c) != nil {
				return
			}
			if !installationLog.dispatch(c, write) {
				e.enqueueCommand(root, commands, c)
			}
		}
	}()
	ticker := time.NewTicker(roomTickInterval)
	defer ticker.Stop()
	var lastAmbient time.Time
	for {
		work := root
		var loginDone <-chan struct{}
		if e.session != nil {
			if e.loginLifetime == nil {
				e.watchLogin(root, 3*time.Second)
			}
			work = e.loginLifetime
			loginDone = work.Done()
		}
		var roomChanges <-chan struct{}
		var roomDue <-chan time.Time
		if r := e.room; r != nil {
			roomChanges, roomDue = r.progress, r.progressDue
		}
		select {
		case <-root.Done():
			if e.session != nil {
				installationLog.record(installationLog.epoch(), logEntry{op: logOp{"account", "sessionEnded"}})
			}
			cleanup, done := context.WithTimeout(context.Background(), 2*time.Second)
			e.reset(cleanup)
			done()
			return
		case <-loginDone:
			if root.Err() == nil {
				e.endLogin(root, e.session, context.Cause(work).Error())
			}
		case reply := <-avatarResults:
			if e.session != reply.owner {
				write(clientErrorReply(reply.id, context.Canceled))
			} else if reply.err != nil {
				write(clientErrorReply(reply.id, reply.err))
				e.endLogin(root, reply.owner, signedOutReason(reply.err))
			} else {
				write(obj{"id": reply.id, "data": reply.data})
			}
		case <-inbox.wake:
			for _, delivery := range inbox.take(32) {
				e.acceptChat(delivery, send)
			}
		case <-revoked:
			if s := e.fileScope.Load(); s != nil && s.ctx.Err() != nil {
				_ = e.closeFiles()
				send("cacheCleared", obj{"entry": s.entry, "previous": s.revision, "revision": ""})
			}
		case <-commands.wake:
			batch := commands.take(1)
			if len(batch) == 0 {
				continue
			}
			c := batch[0]
			if c.Op == "getAvatar" && e.session != nil {
				e.startAvatar(root, c, avatarResults)
				continue
			}
			if c.Op == "previewFile" || c.Op == "prepareExport" {
				if s := e.fileScope.Load(); s != nil {
					s.workers.Go(func() {
						data, err := s.command(s.ctx, c.Op, c.Args)
						c.finishLog(err)
						if err != nil {
							write(clientErrorReply(c.ID, err))
						} else {
							write(obj{"id": c.ID, "data": data})
							if result, ok := data.(obj); ok {
								if b, ok := result["file"].([]byte); ok {
									clear(b)
								}
							}
						}
					})
					continue
				}
			}
			owner := e.session
			if c.Op == "logout" || c.Op == "clearLocalData" {
				work = root // Completing local sign-out also cancels the login lifetime.
			}
			result, err := e.handle(work, c)
			c.finishLog(err)
			if err != nil {
				write(clientErrorReply(c.ID, err))
				e.endLogin(root, owner, signedOutReason(err))
			} else {
				write(obj{"id": c.ID, "data": result})
			}
		case <-roomChanges:
			// Coalesce revisions from the same exchange. Keep the timer on its
			// admission so a late hint cannot advance a replacement room.
			if e.room.progressDue == nil {
				e.room.progressDue = time.After(40 * time.Millisecond)
			}
		case <-roomDue:
			e.updateRoom(root, work)
		case <-ticker.C:
			if e.session != nil && time.Now().Unix() >= e.session.Expires {
				e.endLogin(root, e.session, "CLIENT_LOGIN_EXPIRED")
				continue
			}
			if e.session != nil && time.Since(lastAmbient) >= 20*time.Second && (e.auth.updated == 0 || ticks()-e.auth.updated >= 20000) {
				lastAmbient = time.Now()
				if err := e.refreshAmbient(work); e.endLogin(root, e.session, signedOutReason(err)) {
					continue
				}
			}
			e.updateRoom(root, work)
		}
	}
}
