package httpapi

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

const preflightTTL = 30 * time.Second
const preflightDomain = "Chirp room admission preflight v1\n"

type preflightClaims struct {
	Identity string `json:"identity"`
	RoomID   string `json:"room_id"`
	Sequence int64  `json:"join_sequence"`
	Revision int64  `json:"password_revision"`
	Expires  int64  `json:"expires_at"`
}

type preflightProofs struct{ key [32]byte }

func newPreflightProofs() preflightProofs {
	var p preflightProofs
	if _, err := rand.Read(p.key[:]); err != nil {
		panic("cannot create room admission proof key")
	}
	return p
}

func (p *preflightProofs) issue(m store.Member, roomID string, sequence, revision int64, now time.Time) (string, int64, error) {
	expires := min(now.Add(preflightTTL).Unix(), m.CredentialExpiresAt)
	claims := preflightClaims{m.ParticipantIdentity(), roomID, sequence, revision, expires}
	body, err := json.Marshal(claims)
	if err != nil {
		return "", 0, err
	}
	payload := base64.RawURLEncoding.EncodeToString(body)
	mac := hmac.New(sha256.New, p.key[:])
	mac.Write([]byte(preflightDomain + payload))
	return payload + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), expires, nil
}

func (p *preflightProofs) verify(proof string, m store.Member, roomID string, sequence int64, now time.Time) (int64, bool) {
	if len(proof) > 2048 {
		return 0, false
	}
	parts := strings.Split(proof, ".")
	if len(parts) != 2 {
		return 0, false
	}
	signature, err := base64.RawURLEncoding.Strict().DecodeString(parts[1])
	if err != nil || len(signature) != sha256.Size {
		return 0, false
	}
	mac := hmac.New(sha256.New, p.key[:])
	mac.Write([]byte(preflightDomain + parts[0]))
	if !hmac.Equal(signature, mac.Sum(nil)) {
		return 0, false
	}
	body, err := base64.RawURLEncoding.Strict().DecodeString(parts[0])
	if err != nil {
		return 0, false
	}
	var claims preflightClaims
	if json.Unmarshal(body, &claims) != nil || claims.Identity != m.ParticipantIdentity() || claims.RoomID != roomID || claims.Sequence != sequence || claims.Revision < 0 || claims.Expires <= now.Unix() || claims.Expires > m.CredentialExpiresAt {
		return 0, false
	}
	return claims.Revision, true
}

type passwordAttempts struct {
	mu      sync.Mutex
	entries map[string]attemptWindow
}
type attemptWindow struct {
	start time.Time
	count int
}

// A member cannot evade this by changing IP or logging in again. The map has a
// hard cap and ages entries; one member never locks the entire voice room.
func (a *passwordAttempts) begin(key string, now time.Time) time.Duration {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.entries == nil {
		a.entries = make(map[string]attemptWindow)
	}
	for k, v := range a.entries {
		if now.Sub(v.start) >= 30*time.Second {
			delete(a.entries, k)
		}
	}
	v, exists := a.entries[key]
	if !exists {
		if len(a.entries) >= 256 {
			return time.Second
		}
		v.start = now
	}
	if v.count >= 5 {
		return max(time.Second, 30*time.Second-now.Sub(v.start))
	}
	v.count++
	a.entries[key] = v
	return 0
}
func (a *passwordAttempts) success(key string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	delete(a.entries, key)
}

func (s *Server) preflight(w http.ResponseWriter, r *http.Request, m store.Member) {
	var request struct {
		Sequence int64  `json:"join_sequence"`
		Password string `json:"password"`
	}
	if !readRoomJSON(w, r, &request) {
		return
	}
	roomID := r.PathValue("room")
	if !store.ValidRoomID(roomID) {
		s.roomError(w, r, store.ErrNotFound)
		return
	}
	if request.Sequence <= 0 {
		s.roomError(w, r, store.ErrAdmissionChanged)
		return
	}
	logging.Annotate(r.Context(), "room_id", roomID, "join_sequence", request.Sequence)
	key := m.ID + "/" + roomID
	if delay := s.passwordAttempts.begin(key, time.Now()); delay > 0 {
		w.Header().Set("Retry-After", fmt.Sprint(int(delay.Seconds())+1))
		httpresponse.Error(w, 429, "ROOM_PASSWORD_RATE_LIMITED", "尝试过于频繁，请稍后再试")
		return
	}
	revision, err := s.store.CheckRoomPassword(r.Context(), roomID, request.Password)
	request.Password = ""
	if err != nil {
		s.roomError(w, r, err)
		return
	}
	s.passwordAttempts.success(key)
	proof, expires, err := s.preflightProofs.issue(m, roomID, request.Sequence, revision, time.Now())
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, struct {
		RoomID   string `json:"room_id"`
		Sequence int64  `json:"join_sequence"`
		Proof    string `json:"preflight_proof"`
		Expires  int64  `json:"expires_at"`
	}{roomID, request.Sequence, proof, expires})
}

func passwordError(w http.ResponseWriter, err error) bool {
	switch {
	case errors.Is(err, store.ErrRoomPasswordRequired):
		httpresponse.Error(w, 403, "ROOM_PASSWORD_REQUIRED", "此房间需要输入入房密码")
	case errors.Is(err, store.ErrRoomPasswordWrong):
		httpresponse.Error(w, 403, "ROOM_PASSWORD_INCORRECT", "房间密码不正确，请重新输入")
	case errors.Is(err, store.ErrRoomPasswordChanged):
		httpresponse.Error(w, 409, "ROOM_PASSWORD_CHANGED", "房间密码设置已改变，请重新验证后加入")
	case errors.Is(err, store.ErrPasswordBusy):
		w.Header().Set("Retry-After", "1")
		httpresponse.Error(w, 429, "ROOM_PASSWORD_BUSY", "密码验证繁忙，请稍后再试")
	default:
		return false
	}
	return true
}
