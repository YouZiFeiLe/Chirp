package main

import (
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"unsafe"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"golang.org/x/sys/windows"
)

type checkpoint struct {
	Version int64
	Hash    string
}
type deviceKey struct {
	Seed   []byte
	Device identity.Device
}
type storedAccount struct {
	Active, Candidate *deviceKey
	Backup            []byte
	BackupRoot        string
	BackupExported    bool
	BackupConfirmed   bool
	Heads             map[string]checkpoint
	Denied            map[string]bool
	Pending           *identity.SocialEvent
	PendingRevocation string
	Friends           []friend
	SocialHead        checkpoint
	Blacklist         []store.BlacklistEntry
	PairSeed          []byte
}
type vault struct {
	Accounts    map[string]*storedAccount
	Connection  *savedConnection
	Blacklists  map[string][]store.BlacklistEntry
	path        string
	unavailable bool
	dirty       bool
}

// Signed history belongs to the service origin and root, even when a different
// local account observed the longer prefix.
func (v *vault) knownHead(origin, root string) (checkpoint, error) {
	var head checkpoint
	for scope, account := range v.Accounts {
		if !strings.HasPrefix(scope, origin+"|") {
			continue
		}
		next := account.Heads[root]
		if next.Version == head.Version && next.Hash != head.Hash {
			return checkpoint{}, invalid
		}
		if next.Version > head.Version {
			head = next
		}
	}
	return head, nil
}

func (v *vault) acceptBlacklist(origin string, next []store.BlacklistEntry) bool {
	seen := make(map[int64]store.BlacklistEntry, len(next))
	for _, item := range next {
		if _, duplicate := seen[item.Sequence]; duplicate || item.Subject == "" || (item.Kind != "account" && item.Kind != "device") {
			return false
		}
		seen[item.Sequence] = item
	}
	current := v.Blacklists[origin]
	for _, record := range current {
		if seen[record.Sequence] != record {
			return false
		}
	}
	if len(current) == len(next) {
		return false
	}
	if v.Blacklists == nil {
		v.Blacklists = make(map[string][]store.BlacklistEntry)
	}
	v.Blacklists[origin] = slices.Clone(next)
	return true
}

func protect(data []byte, encrypt bool) ([]byte, error) {
	if len(data) == 0 {
		return nil, errors.New("empty identity store")
	}
	input := windows.DataBlob{Size: uint32(len(data)), Data: &data[0]}
	var output windows.DataBlob
	var err error
	if encrypt {
		err = windows.CryptProtectData(&input, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &output)
	} else {
		err = windows.CryptUnprotectData(&input, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &output)
	}
	if err != nil {
		return nil, err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(output.Data)))
	raw := unsafe.Slice(output.Data, output.Size)
	defer clear(raw)
	return append([]byte(nil), raw...), nil
}
func openIdentityVault(dir string) *vault {
	v, err := loadVault(dir)
	if err != nil {
		return &vault{path: filepath.Join(dir, "identities.v5"), Accounts: map[string]*storedAccount{}, unavailable: true}
	}
	return v
}
func loadVault(dir string) (*vault, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	v := &vault{Accounts: map[string]*storedAccount{}, path: filepath.Join(dir, "identities.v5")}
	data, err := os.ReadFile(v.path)
	if os.IsNotExist(err) {
		return v, nil
	}
	if err != nil {
		return nil, err
	}
	plain, err := protect(data, false)
	if err != nil {
		return nil, err
	}
	defer clear(plain)
	if json.Unmarshal(plain, v) != nil || v.Accounts == nil {
		return nil, errors.New("invalid identity store")
	}
	for scope, account := range v.Accounts {
		if account == nil {
			return nil, identity.ErrInvalid
		}
		// Earlier Windows versions saved permanent administrator bans with the
		// account that happened to observe them. Preserve all observed records.
		if len(account.Blacklist) > 0 {
			origin, _, _ := strings.Cut(scope, "|")
			if v.Blacklists == nil {
				v.Blacklists = make(map[string][]store.BlacklistEntry)
			}
			for _, record := range account.Blacklist {
				if !slices.Contains(v.Blacklists[origin], record) {
					v.Blacklists[origin] = append(v.Blacklists[origin], record)
				}
			}
			account.Blacklist = nil
		}
		for _, d := range []*deviceKey{account.Active, account.Candidate} {
			if d != nil && (len(d.Seed) != 32 || b64(ed25519.NewKeyFromSeed(d.Seed).Public().(ed25519.PublicKey)) != d.Device.LeafKey()) {
				return nil, identity.ErrInvalid
			}
		}
	}
	return v, nil
}
func (v *vault) save() (err error) {
	if v.unavailable {
		return errors.New("IDENTITY_STORE_UNAVAILABLE")
	}
	defer func() { v.dirty = err != nil }()
	plain, err := json.Marshal(v)
	if err != nil {
		return err
	}
	defer clear(plain)
	data, err := protect(plain, true)
	if err != nil {
		return err
	}
	return writePrivateFile(v.path, ".identity-*", data)
}

func writePrivateFile(path, pattern string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), pattern)
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	closed := f.Close()
	if err != nil {
		return err
	}
	if closed != nil {
		return closed
	}
	return os.Rename(f.Name(), path)
}
func (d *deviceKey) sign(message []byte) string {
	key := ed25519.NewKeyFromSeed(d.Seed)
	defer clear(key)
	return identity.Sign(key, message)
}
