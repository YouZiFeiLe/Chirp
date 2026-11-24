package authorization

import (
	"context"
	"crypto/ed25519"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sort"
	"strconv"
	"sync"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	_ "modernc.org/sqlite"
)

type Server struct {
	db       *sql.DB
	key      ed25519.PrivateKey
	origin   string
	mu       sync.Mutex
	now      func() time.Time
	requests chan struct{}
}

func Open(path, origin string, key ed25519.PrivateKey) (*Server, error) {
	normalized, err := identity.NormalizeOrigin(origin)
	encodedOrigin, _ := json.Marshal(origin)
	if err != nil || normalized != origin || len(encodedOrigin) > 2048 || len(key) != ed25519.PrivateKeySize {
		return nil, ErrInvalid
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err = db.Exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;
		CREATE TABLE IF NOT EXISTS authorization_accounts(root TEXT PRIMARY KEY, document BLOB NOT NULL);`); err != nil {
		db.Close()
		return nil, err
	}
	return &Server{db: db, key: append(ed25519.PrivateKey(nil), key...), origin: origin, now: time.Now, requests: make(chan struct{}, 2)}, nil
}

func (s *Server) Close() error { return s.db.Close() }

func (s *Server) Ping(ctx context.Context) error { return s.db.PingContext(ctx) }

func (s *Server) tryRequest() bool {
	select {
	case s.requests <- struct{}{}:
		return true
	default:
		return false
	}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		if s.db.PingContext(r.Context()) != nil {
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("POST /v5/snapshot", s.snapshot)
	mux.HandleFunc("POST /v5/append", s.appendEvent)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if r.URL.Path != "/healthz" {
			if !s.tryRequest() {
				http.Error(w, "busy", http.StatusTooManyRequests)
				return
			}
			defer func() { <-s.requests }()
		}
		mux.ServeHTTP(w, r)
	})
}

func read(w http.ResponseWriter, r *http.Request, value any) bool {
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 65536))
	d.DisallowUnknownFields()
	if d.Decode(value) != nil || d.Decode(new(any)) != io.EOF {
		http.Error(w, "invalid request", http.StatusBadRequest)
		return false
	}
	return true
}

func (s *Server) account(ctx context.Context, root string) (Account, error) {
	account := Account{Root: root, Records: []Record{}}
	var data []byte
	err := s.db.QueryRowContext(ctx, "SELECT document FROM authorization_accounts WHERE root=?", root).Scan(&data)
	if errors.Is(err, sql.ErrNoRows) {
		return account, nil
	}
	if err != nil {
		return account, err
	}
	err = json.Unmarshal(data, &account)
	return account, err
}

// DeviceRevoked verifies the committed history at each event's acceptance time.
func (s *Server) DeviceRevoked(ctx context.Context, root, deviceKey string) (bool, error) {
	if !s.tryRequest() {
		return false, errors.New("authorization service is busy")
	}
	defer func() { <-s.requests }()
	account, err := s.account(ctx, root)
	if err != nil {
		return false, err
	}
	if account.Root != root {
		return false, ErrInvalid
	}
	state, err := Replay(s.origin, account)
	if err != nil {
		return false, err
	}
	return state.Revoked[deviceKey], nil
}

func (s *Server) appendEvent(w http.ResponseWriter, r *http.Request) {
	var event Event
	if !read(w, r, &event) {
		return
	}
	if event.Origin != s.origin {
		http.Error(w, "invalid origin", http.StatusForbidden)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	account, err := s.account(r.Context(), event.Signer.AccountKey)
	if err != nil {
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	// A retry of an already committed operation must not create a new event.
	if event.Version > 0 && event.Version <= int64(len(account.Records)) && account.Records[event.Version-1].Event.Hash() == event.Hash() {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	state, err := Replay(s.origin, account)
	if err != nil {
		http.Error(w, "invalid history", http.StatusServiceUnavailable)
		return
	}
	now := s.now()
	if len(account.Records) > 0 && now.Unix() < account.Records[len(account.Records)-1].AcceptedAt {
		http.Error(w, "authority clock moved backwards", http.StatusServiceUnavailable)
		return
	}
	if err = state.Apply(event, now); err != nil {
		status := http.StatusForbidden
		if errors.Is(err, ErrConflict) {
			status = http.StatusConflict
		}
		http.Error(w, "rejected transition", status)
		return
	}
	if len(account.Records) == 0 {
		var count int
		if s.db.QueryRowContext(r.Context(), "SELECT count(*) FROM authorization_accounts").Scan(&count) != nil || count >= 4096 {
			http.Error(w, "capacity reached", http.StatusServiceUnavailable)
			return
		}
	}
	previous, err := json.Marshal(account)
	if err != nil {
		http.Error(w, "invalid history", http.StatusServiceUnavailable)
		return
	}
	newAccount := len(account.Records) == 0
	account.Records = append(account.Records, Record{Event: event, AcceptedAt: now.Unix()})
	data, err := json.Marshal(account)
	if err == nil && (len(data) > 2*1024*1024 || (event.Operation != "revoke" && len(data) > 512*1024)) {
		err = ErrInvalid
	}
	var changed int64
	if err == nil {
		// The database, not the process mutex, arbitrates writers. A second
		// process must never overwrite a concurrent committed revocation.
		var result sql.Result
		if newAccount {
			result, err = s.db.ExecContext(r.Context(), "INSERT INTO authorization_accounts(root,document) VALUES(?,?) ON CONFLICT(root) DO NOTHING", account.Root, data)
		} else {
			result, err = s.db.ExecContext(r.Context(), "UPDATE authorization_accounts SET document=? WHERE root=? AND document=?", data, account.Root, previous)
		}
		if err == nil {
			changed, err = result.RowsAffected()
		}
	}
	if err != nil {
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	if changed != 1 {
		http.Error(w, "authorization head changed", http.StatusConflict)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type SnapshotRequest struct {
	Origin    string           `json:"origin"`
	Nonce     string           `json:"nonce"`
	Roots     []string         `json:"roots"`
	Device    *identity.Device `json:"device,omitempty"`
	SignedAt  int64            `json:"signed_at,omitempty"`
	Signature string           `json:"signature,omitempty"`
}

func (r SnapshotRequest) Message() []byte {
	if r.Device == nil {
		return nil
	}
	roots := append([]string(nil), r.Roots...)
	sort.Strings(roots)
	fields := []string{r.Origin, r.Nonce, r.Device.Hash(), strconv.FormatInt(r.SignedAt, 10)}
	return identity.Message("Chirp authorization read v5", append(fields, roots...)...)
}

type Snapshot struct {
	Protocol int       `json:"protocol"`
	Origin   string    `json:"origin"`
	Nonce    string    `json:"nonce"`
	IssuedAt int64     `json:"issued_at"`
	Accounts []Account `json:"accounts"`
}

type Envelope struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

func SnapshotMessage(origin, nonce string, payload []byte) []byte {
	return identity.Message("Chirp authorization snapshot v5", origin, nonce, identity.Hash(payload))
}

func (s *Server) snapshot(w http.ResponseWriter, r *http.Request) {
	var request SnapshotRequest
	if !read(w, r, &request) {
		return
	}
	_, nonceOK := identity.Bytes(request.Nonce, 32)
	if request.Origin != s.origin || !nonceOK || len(request.Roots) == 0 || len(request.Roots) > 2 {
		http.Error(w, "invalid request", http.StatusBadRequest)
		return
	}
	sort.Strings(request.Roots)
	for i, root := range request.Roots {
		if _, ok := identity.Bytes(root, 32); !ok || (i > 0 && request.Roots[i-1] == root) {
			http.Error(w, "invalid roots", http.StatusBadRequest)
			return
		}
	}
	now := s.now()
	if request.Device != nil {
		if request.SignedAt < now.Add(-time.Minute).Unix() || request.SignedAt > now.Add(time.Minute).Unix() ||
			request.Device.Validate(now) != nil || !identity.Verify(request.Device.LeafKey(), request.Signature, request.Message()) {
			http.Error(w, "invalid read proof", http.StatusForbidden)
			return
		}
	} else if request.SignedAt != 0 || request.Signature != "" {
		http.Error(w, "invalid read proof", http.StatusForbidden)
		return
	}
	s.mu.Lock()
	result := Snapshot{Protocol: 5, Origin: s.origin, Nonce: request.Nonce, IssuedAt: now.Unix(), Accounts: []Account{}}
	for _, root := range request.Roots {
		account, err := s.account(r.Context(), root)
		if err != nil {
			s.mu.Unlock()
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
			return
		}
		state, replayErr := Replay(s.origin, account)
		if replayErr != nil {
			s.mu.Unlock()
			http.Error(w, "invalid history", http.StatusServiceUnavailable)
			return
		}
		// Peers need the complete signed sequence and device transitions, not
		// somebody else's contact list. The digest preserves event signatures
		// and the checkpoint chain without disclosing private social bodies.
		if request.Device == nil || request.Device.AccountKey != root || !state.Active(*request.Device, now) {
			for i := range account.Records {
				event := &account.Records[i].Event
				if event.Social != nil {
					event.SocialHash = event.Social.Hash()
					event.Social = nil
				}
			}
		}
		result.Accounts = append(result.Accounts, account)
	}
	result.IssuedAt = s.now().Unix()
	s.mu.Unlock()
	for _, account := range result.Accounts {
		if len(account.Records) > 0 && account.Records[len(account.Records)-1].AcceptedAt > result.IssuedAt {
			http.Error(w, "authority clock moved backwards", http.StatusServiceUnavailable)
			return
		}
	}
	payload, err := json.Marshal(result)
	if err != nil || len(payload) > 6*1024*1024 {
		http.Error(w, "snapshot too large", http.StatusServiceUnavailable)
		return
	}
	envelope := Envelope{Payload: base64.StdEncoding.EncodeToString(payload), Signature: identity.Sign(s.key, SnapshotMessage(s.origin, request.Nonce, payload))}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(envelope)
}
