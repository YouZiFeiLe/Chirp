package main

import (
	"context"
	"errors"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/google/uuid"
)

// The pipe can carry arbitrary strings. Only the values of these code-owned maps
// become events. No argument, URL, exception message or model is a log detail.
var commandLogOps = map[string]logOp{
	"discover": {"settings", "discoverServer"}, "confirmConnection": {"settings", "confirmServer"}, "restoreConnection": {"settings", "restoreServer"},
	"register": {"account", "register"}, "savedIdentities": {"identity", "savedIdentities"}, "savedAccounts": {"account", "savedAccounts"},
	"browser": {"account", "browserLogin"}, "phone": {"account", "phoneLogin"}, "exchange": {"account", "exchangeLogin"},
	"resumeLogin": {"account", "resumeLogin"}, "commitResume": {"account", "unlockLogin"},
	"pollPhone": {"account", "pollPhoneLogin"}, "finishPhone": {"account", "finishPhoneLogin"}, "cancelLogin": {"account", "cancelLogin"}, "logout": {"account", "logout"},
	"backup": {"identity", "createBackup"}, "unlockBackup": {"identity", "unlockBackup"}, "backupExported": {"identity", "backupExported"},
	"verifyBackup": {"identity", "verifyBackup"}, "finishBackup": {"identity", "finishBackup"}, "confirmBackup": {"identity", "confirmBackup"}, "recover": {"identity", "recoverIdentity"},
	"pairNew": {"identity", "pairNewDevice"}, "pairOld": {"identity", "approveDevice"}, "pairPoll": {"identity", "pollDevicePairing"},
	"pairCheckCode": {"identity", "checkPairingCode"}, "pairConfirm": {"identity", "confirmDevice"}, "finishPair": {"identity", "finishDevicePairing"}, "pairCancel": {"identity", "cancelDevicePairing"},
	"watchDirectory": {"network", "watchDirectory"}, "unwatchDirectory": {"network", "unwatchDirectory"}, "state": {"network", "refreshDirectory"}, "networkRestored": {"network", "networkRestored"},
	"join": {"room", "join"}, "cancelJoin": {"room", "cancelJoin"}, "leave": {"room", "leave"},
	"verify": {"identity", "verifyDevice"}, "mute": {"audio", "setMicrophone"}, "setListening": {"audio", "setListening"}, "audioSuspended": {"audio", "audioInterruption"},
	"chat": {"chat", "sendMessage"}, "upload": {"attachment", "selectUpload"}, "download": {"attachment", "selectDownload"},
	"resumeFile": {"attachment", "retryTransfer"}, "pauseFile": {"attachment", "pauseTransfer"}, "cancelFile": {"attachment", "cancelTransfer"},
	"previewFile": {"attachment", "previewAttachment"}, "prepareExport": {"attachment", "prepareExport"},
	"friends": {"identity", "loadFriends"}, "friend": {"identity", "addFriend"}, "removeFriend": {"identity", "removeFriend"}, "untrust": {"identity", "removeTrust"},
	"devices": {"identity", "loadDevices"}, "blacklist": {"identity", "loadBlacklist"}, "cachedBlacklist": {"identity", "cachedBlacklist"},
	"renameDevice": {"identity", "renameDevice"}, "revoke": {"identity", "revokeDevice"}, "profile": {"account", "loadProfile"}, "rename": {"account", "renameProfile"},
	"avatar": {"account", "setAvatar"}, "removeAvatar": {"account", "removeAvatar"}, "getAvatar": {"account", "loadAvatar"},
	"cacheSize": {"settings", "cacheSize"}, "clearCache": {"settings", "clearCache"},
}

var uiLogOps = func() map[string]logOp {
	ops := map[string]logOp{}
	for table, names := range map[string]string{
		"navigation":  "login room roomChat friends settings logSettings roomInfo memberInfo friendInfo profile audioSettings cacheSettings devices blacklist backup devicePairing pairingCamera joinPrompt attachmentPreview",
		"application": "newWindow",
		"settings":    "changeLanguage changeTheme editServer exportLogs",
		"identity":    "selectBackup saveBackup selectPairingImage savePairingImage",
		"account":     "openBrowser openRegistration selectAvatar",
		"audio":       "selectInput preferOutput changePreset changeInputGain changeOutputVolume changeActivationThreshold changeVoiceActivation changeSoundEffects memberVolume microphoneTestStarted microphoneTestStopped playMicrophoneTest captureInitialized captureFailed routeChanged",
		"chat":        "compose clearDraft restoreDraft",
		"attachment":  "selectFile exportAttachment",
	} {
		for _, name := range strings.Fields(names) {
			ops[name] = logOp{table, name}
		}
	}
	return ops
}()

func (c *command) logOperation() logOp {
	if c.Op == "verify" {
		if name := verificationLogNames[c.Args.Action]; name != "" {
			return logOp{"identity", name}
		}
	}
	return commandLogOps[c.Op]
}

var verificationLogNames = map[string]string{"start": "startVerification", "accept": "acceptVerification", "confirm": "confirmVerification", "mismatch": "verificationMismatch", "cancel": "cancelVerification", "retryTrust": "retryTrust"}

func (c *command) beginLog() {
	if installationLog.epoch() == 0 {
		return
	}
	op := c.logOperation()
	if op.name == "" {
		return
	}
	c.span = installationLog.begin()
	installationLog.record(c.span.generation, logEntry{op: op, outcome: "started"})
}

func (c *command) finishLog(err error) {
	if c.span.generation != 0 {
		installationLog.finish(c.span, c.logOperation(), err, 0)
	}
}

func (l *clientLog) uiEvent(a args) {
	if l.epoch() == 0 || a.Generation != l.epoch() {
		return
	}
	op, ok := uiLogOps[a.Action]
	if !ok {
		return
	}
	row := logEntry{op: op}
	switch a.Outcome {
	case "started", "succeeded", "failed", "cancelled":
		row.outcome = a.Outcome
	case "":
	default:
		return
	}
	if a.DurationUs != nil && *a.DurationUs >= 0 && (row.outcome == "succeeded" || row.outcome == "failed" || row.outcome == "cancelled") {
		row.duration = a.DurationUs
	}
	if row.outcome == "failed" {
		row.code = "CLIENT_UNEXPECTED"
	}
	if op.table == "navigation" {
		row.details = struct {
			Visible bool `json:"visible"`
		}{a.Enabled}
	}
	if a.Action == "captureInitialized" {
		row.details = struct {
			Rate     int `json:"sample_rate_hz"`
			Channels int `json:"channels"`
			Noise    int `json:"rnnoise"`
		}{48000, 1, int(boolBit(a.Enabled))}
	}
	l.record(a.Generation, row)
}

func (l *clientLog) state() obj { return obj{"generation": l.generation.Load()} }

// Do not queue a snapshot merge on the room actor or wait on SQLite in the pipe
// reader: RTP, cancellation, UI commands and the 900 ms media tick stay live.
func (l *clientLog) dispatch(c command, reply func(any)) bool {
	switch c.Op {
	case "logUI":
		l.uiEvent(c.Args)
	case "logAudioContext":
		l.setAudioContext(c.Args)
	case "logState", "setLogging", "clearLogs", "exportLogs", "releaseLogExport", "logActivity":
		l.jobs.push(func() {
			data, err := l.manage(c)
			if err != nil {
				// OS and SQLite errors may contain paths.
				reply(clientErrorReply(c.ID, errors.New("LOG_STORAGE_UNAVAILABLE")))
			} else {
				reply(obj{"id": c.ID, "data": data})
			}
		})
		return true
	default:
		return false
	}
	if c.ID != 0 {
		reply(obj{"id": c.ID})
	}
	return true
}

func (l *clientLog) manage(c command) (any, error) {
	switch c.Op {
	case "setLogging":
		if err := l.setEnabled(c.Args.Enabled); err != nil {
			return nil, err
		}
	case "clearLogs":
		if err := l.clear(false); err != nil {
			return nil, err
		}
	case "exportLogs":
		now, err := l.flush()
		if err != nil {
			return nil, err
		}
		path, err := l.store.snapshot(now)
		if errors.Is(err, errLogEmpty) {
			return obj{"empty": true}, nil
		}
		if err != nil {
			return nil, err
		}
		return obj{"path": path, "id": strings.TrimSuffix(strings.TrimPrefix(filepath.Base(path), "export."), ".chirplog")}, nil
	case "releaseLogExport":
		id, err := uuid.Parse(c.Args.ID)
		if err != nil || id.String() != c.Args.ID {
			return nil, invalid
		}
		return nil, removeLogFiles(filepath.Join(l.store.dir, "export."+id.String()+".chirplog"))
	case "logActivity":
		event := "background"
		if c.Args.Enabled {
			event = "active"
		}
		l.record(l.epoch(), logEntry{op: logOp{"application", event}})
		if c.Args.Enabled {
			return nil, l.store.prune(l.now().UnixMilli(), false)
		}
		_, err := l.flush()
		return nil, err
	}
	return l.state(), nil
}

func safeLogError(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return "CLIENT_NETWORK_TIMEOUT"
	}
	if err != nil {
		code := err.Error()
		if len(code) > 81 {
			return "CLIENT_UNKNOWN_SERVER_ERROR"
		}
		if mapped := logErrorAliases[code]; mapped != "" {
			return mapped
		}
		if knownLogErrors[code] {
			return code
		}
		if knownLogErrors["CLIENT_"+code] {
			return "CLIENT_" + code
		}
	}
	return "CLIENT_UNKNOWN_SERVER_ERROR"
}

var logErrorAliases = map[string]string{
	"SERVER_UNAVAILABLE": "CLIENT_NETWORK_UNAVAILABLE", "LOGIN_EXPIRED": "CLIENT_LOGIN_EXPIRED",
	"MEDIA_CONNECTION_FAILED": "CLIENT_VOICE_CONNECTION_FAILED", "INVALID_LOGIN_CALLBACK": "CLIENT_INVALID_LOGIN_CALLBACK",
}

func streamLog(span logSpan, name string, ctx context.Context, resp *http.Response, err error) func() {
	return func() {
		if span.generation == 0 {
			return
		}
		status := 0
		if resp != nil {
			status = resp.StatusCode
			if status == 200 && !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
				err = invalid
			}
		}
		if ctx.Err() != nil {
			err = ctx.Err()
		}
		installationLog.finish(span, logOp{"network", name}, err, status)
	}
}

func apiLogName(method, path string) string {
	switch {
	case path == "v1/state":
		return "directory"
	case path == "v1/identity/blacklist":
		return "blacklist"
	case path == "v1/identity/devices":
		return "devices"
	case strings.HasPrefix(path, "v1/identity/devices/"):
		if method == "PATCH" {
			return "renameDevice"
		}
		return "revokeDevice"
	case strings.HasPrefix(path, "v1/identity/signals"):
		if method == "POST" {
			return "sendVerification"
		}
		return "receiveVerification"
	case strings.HasSuffix(path, "/preflight"):
		return "preflight"
	case strings.HasSuffix(path, "/leave"):
		return "leave"
	default:
		return "apiRequest"
	}
}

var nativeLogNames = map[string]string{
	"authorize": "mlsAuthorize", "identity": "mlsIdentity", "sign": "mlsSign", "clear": "mlsClear", "approve": "mlsApprove",
	"key_package": "mlsKeyPackage", "create": "mlsCreate", "join": "mlsJoin", "staged_key_package": "mlsStagedKeyPackage",
	"staged_create": "mlsStagedCreate", "staged_join": "mlsStagedJoin", "activate_staged": "mlsActivateStaged",
}

var groupLogNames = map[string]string{
	"join": "groupJoin", "heartbeat": "groupHeartbeat", "lease": "mediaLease", "refresh": "groupRefresh", "snapshot": "groupSnapshot",
	"package": "groupPackage", "publish": "groupPublish", "ack": "groupAck", "rotation_package": "rotationPackage", "rotation_publish": "rotationPublish",
	"rotation_ack": "rotationAck", "rotation_activate": "rotationActivate",
}

func groupLogName(op string) string {
	if name, ok := groupLogNames[op]; ok {
		return name
	}
	return "groupRequest"
}

func attachmentRequestName(method, suffix string) string {
	switch {
	case suffix == "":
		return "createAttachment"
	case method == "PUT":
		return "uploadChunk"
	case strings.HasSuffix(suffix, "/complete"):
		return "completeAttachment"
	case strings.HasSuffix(suffix, "/received"):
		return "acknowledgeAttachment"
	case strings.HasSuffix(suffix, "/pause"):
		return "pauseAttachment"
	case strings.HasSuffix(suffix, "/cancel"):
		return "cancelAttachment"
	default:
		return "attachmentStatus"
	}
}

// Fixed codes recognized by the Windows and Apple clients. A syntactically valid unknown code can contain user data.
var knownLogErrors = func() map[string]bool {
	known := map[string]bool{}
	for _, code := range strings.Fields(`
ATTACHMENT_NO_RECIPIENTS ATTACHMENT_PREPARATION_FAILED ATTACHMENT_PUBLICATION_UNKNOWN CHAT_BUSY CONTENT_PAUSED
DEVICE_APPROVAL_NOT_ALLOWED DEVICE_PAIRING_EXPIRED DEVICE_REVOKED IDENTITY_STORE_UNAVAILABLE INVALID_MESSAGE
INVALID_PAIRING_REQUEST PAIRING_CLOCK_MISMATCH PAIRING_SERVER_MISMATCH PAIRING_ACCOUNT_MISMATCH
INVALID_RECOVERY_PASSWORD LOGIN_REQUIRED MEDIA_DISCONNECTED NATIVE_MEDIA_BUILD_REQUIRED PAIRING_ATTEMPTS_EXHAUSTED
PAIRING_CODE_MISMATCH PEER_IDENTITY_BLOCKED RECOVERY_EXPORT_PENDING RECOVERY_IDENTITY_MISMATCH REGISTRATION_CLOSED
REVOCATION_PENDING ROOM_PASSWORD_TOO_LONG SOCIAL_SYNC_PENDING TRANSFER_BUSY UNKNOWN_COMMAND
REGISTRATION_PENDING REGISTRATION_REJECTED IDENTITY_BLACKLISTED IDENTITY_CONFLICT CURRENT_DEVICE
LAST_DEVICE SOCIAL_CONFLICT CLIENT_AUTHORIZATION_STALE DEVICE_IDENTITY_REQUIRED DEVICE_PAIRING_INVALID
V5_IDENTITY_INVALID ROOM_IDENTITY_REQUIRED ROOM_AUTHORIZATION_INVALID CLIENT_IDENTITY_CHANGED CLIENT_IDENTITY_EXPIRED
CLIENT_UNEXPECTED CLIENT_UNKNOWN_SERVER_ERROR CLIENT_INVALID_RESPONSE CLIENT_HTTP_FAILURE CLIENT_NETWORK_UNAVAILABLE
CLIENT_NETWORK_TIMEOUT CLIENT_NETWORK_FAILURE CLIENT_INVALID_SERVER_ADDRESS CLIENT_HOSTED_SERVER_UNSUPPORTED CLIENT_INSECURE_SERVER_ADDRESS
CLIENT_INVALID_SERVER_CONFIGURATION CLIENT_SERVER_CONFIGURATION_CHANGED CLIENT_SERVER_NOT_CONFIGURED CLIENT_BROWSER_OPEN_FAILED CLIENT_VERSION_INVALID
CLIENT_UPDATE_REQUIRED CLIENT_VERSION_POLICY_UNAVAILABLE CLIENT_CONFIG_UNAVAILABLE DATABASE_UNAVAILABLE CLIENT_INVALID_ROOM_LIST
CLIENT_INVALID_PREFLIGHT CLIENT_INVALID_ADMISSION CLIENT_INVALID_JOIN_SEQUENCE CLIENT_JOIN_SEQUENCE_EXHAUSTED CLIENT_LEAVE_FAILED
CLIENT_INVALID_LOGIN_CALLBACK CLIENT_LOGIN_VERIFICATION_FAILED CLIENT_SECURE_LOGIN_FAILED CLIENT_INVALID_LOGIN_SESSION CLIENT_LOGIN_INCOMPLETE
CLIENT_LOGIN_EXPIRED CLIENT_LOGIN_CANCELLED RESUMPTION_PROOF_INVALID LOGIN_STORAGE_UNAVAILABLE HELLO_KEY_UNAVAILABLE CLIENT_INVALID_DEVICE_AUTHORIZATION CLIENT_DEVICE_LOGIN_UNSUPPORTED CLIENT_DEVICE_REQUEST_FAILED
CLIENT_DEVICE_STATUS_INVALID CLIENT_QR_GENERATION_FAILED CLIENT_CALL_BUSY CLIENT_SECURE_TRANSPORT_MISSING CLIENT_MICROPHONE_PERMISSION_REQUIRED
CLIENT_LOCAL_ENCRYPTION_FAILED CLIENT_MICROPHONE_UPDATE_FAILED CLIENT_AUDIO_PRESET_BUSY CLIENT_AUDIO_CONTROL_UNAVAILABLE CLIENT_AUDIO_CONTROL_BUSY
CLIENT_AUDIO_DEVICE_CHANGE_FAILED CLIENT_MICROPHONE_TEST_FAILED CLIENT_AUDIO_SERVICES_RESET CLIENT_AUDIO_DECRYPTION_RECOVERY_FAILED CLIENT_AUDIO_PRESET_RECOVERY_FAILED
CLIENT_SECURE_CONNECTION_NOT_READY CLIENT_MICROPHONE_ENCRYPTOR_NOT_READY CLIENT_LOCAL_TRACK_UNENCRYPTED CLIENT_REMOTE_TRACK_UNENCRYPTED CLIENT_VOICE_DISCONNECTED
CLIENT_VOICE_CONNECTION_FAILED CLIENT_SECURE_CONNECTION_RECOVERY_FAILED CLIENT_AUDIO_ENCRYPTION_FAILED CLIENT_AUDIO_ENCRYPTION_UNKNOWN CLIENT_APPLE_AUDIO_UNAVAILABLE
CLIENT_AUDIO_PRESET_UNCONFIRMED CLIENT_NOISE_SUPPRESSION_FAILED CLIENT_NOISE_INITIALIZATION_FAILED CLIENT_NOISE_FORMAT_INVALID CLIENT_NOISE_PROCESSING_FAILED
CLIENT_AUDIO_PROCESSING_FAILED CLIENT_GROUP_STATE_CHANGED CLIENT_GROUP_UNAVAILABLE CLIENT_INVALID_GROUP_RESPONSE CLIENT_GROUP_IDENTITY_INVALID
CLIENT_GROUP_REQUEST_REJECTED CLIENT_GROUP_LEASE_EXPIRED CLIENT_GROUP_CONNECTION_LOST CLIENT_GROUP_MEMBERS_UNVERIFIED CLIENT_GROUP_PROTOCOL_MISMATCH
CLIENT_PREVIOUS_GROUP_ACTIVE CLIENT_GROUP_MEMBERSHIP_LOST CLIENT_GROUP_AUTHORIZATION_LOST CLIENT_GROUP_CONFIRMATION_MISMATCH CLIENT_GROUP_LEASE_RESPONSE_EXPIRED
CLIENT_GROUP_UPDATE_TIMED_OUT CLIENT_GROUP_CRYPTO_FAILED CLIENT_INVALID_MEDIA_LEASE CLIENT_CHAT_TEXT_TOO_LONG CLIENT_CHAT_NOT_READY
CLIENT_CHAT_PACKET_TOO_LONG CLIENT_CHAT_PREPARATION_FAILED CLIENT_CHAT_SEND_FAILED ATTACHMENT_INVALID ATTACHMENT_UNAVAILABLE
ATTACHMENT_QUOTA ATTACHMENT_CONFLICT ATTACHMENT_PENDING ATTACHMENT_CANCELLED ATTACHMENT_EXPIRED
ATTACHMENT_INTEGRITY ATTACHMENT_BUSY ATTACHMENTS_UNAVAILABLE CLIENT_ATTACHMENT_CACHE_FAILED CLIENT_ATTACHMENT_TRANSFER_FAILED
CLIENT_PASSWORD_TOO_LONG CLIENT_INVALID_MEMBER_PROFILES AVATAR_TOO_LARGE AVATAR_INVALID AVATAR_DIMENSIONS_EXCEEDED
AVATAR_FORMAT_UNSUPPORTED AVATAR_BUSY INVALID_DISPLAY_NAME MEMBER_NOT_FOUND UNAUTHORIZED
MEMBER_DISABLED ROOM_NOT_FOUND ADMISSION_CHANGED ROOM_PASSWORD_REQUIRED ROOM_PASSWORD_INCORRECT
ROOM_PASSWORD_CHANGED ROOM_PREFLIGHT_EXPIRED ROOM_PASSWORD_RATE_LIMITED ROOM_PASSWORD_BUSY BAD_REQUEST
INTERNAL_ERROR MEDIA_SERVICE_UNAVAILABLE DEVICE_AUTHORIZATION_EXPIRED INVALID_AUTHORIZATION LOGIN_NOT_ALLOWED
RETRY_LOGIN TRY_LATER UNAVAILABLE INVALID_PROOF ADMISSION_EXPIRED
`) {
		known[code] = true
	}
	return known
}()
