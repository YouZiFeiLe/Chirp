package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/google/uuid"
	_ "modernc.org/sqlite"
)

const logHourMS int64 = 3_600_000
const logRetentionMS = 24 * logHourMS

var logTables = [...]string{"application", "navigation", "account", "identity", "network", "room", "call", "audio", "crypto", "chat", "attachment", "settings"}
var errLogFormat = errors.New("unsupported client log database")
var errLogEmpty = errors.New("no client log events")

// Only the writer goroutine accesses these SQLite connections and private snapshots.
type logStore struct {
	dir    string
	active *sql.DB
	hour   int64
}

func (s *logStore) close() {
	if s.active != nil {
		s.active.Close()
		s.active = nil
	}
}

func logTransaction(db *sql.DB, work func(*sql.Tx) error) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err = work(tx); err != nil {
		return err
	}
	return tx.Commit()
}

func validateLogDB(db *sql.DB, schema string) error {
	var appID, version int
	if err := db.QueryRow("PRAGMA " + schema + ".application_id").Scan(&appID); err != nil {
		return err
	}
	if err := db.QueryRow("PRAGMA " + schema + ".user_version").Scan(&version); err != nil {
		return err
	}
	if appID != 0x43485250 || version != 1 {
		return errLogFormat
	}
	return nil
}

func openLogDB(path string, create bool) (*sql.DB, error) {
	fresh := false
	if create {
		f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		switch {
		case err == nil:
			fresh = true
			if err = f.Close(); err != nil {
				return nil, err
			}
		case !errors.Is(err, os.ErrExist):
			return nil, err
		}
	} else if _, err := os.Stat(path); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	// PRAGMAs and ATTACH are connection-local. A shard has a single owner.
	db.SetMaxOpenConns(1)
	if _, err = db.Exec("PRAGMA secure_delete=ON"); err == nil {
		if fresh {
			if _, err = db.Exec("PRAGMA journal_mode=DELETE"); err == nil {
				err = logTransaction(db, func(tx *sql.Tx) error {
					if _, err := tx.Exec("PRAGMA application_id=1128813136; PRAGMA user_version=1"); err != nil {
						return err
					}
					for _, table := range logTables {
						if _, err := tx.Exec("CREATE TABLE " + table + " (time_ms INTEGER NOT NULL, event TEXT NOT NULL, outcome TEXT, error_code TEXT, duration_us INTEGER, http_status INTEGER, details TEXT, segment TEXT NOT NULL, seq INTEGER NOT NULL); CREATE INDEX " + table + "_time ON " + table + "(time_ms)"); err != nil {
							return err
						}
					}
					return nil
				})
			}
		} else {
			err = validateLogDB(db, "main")
		}
	}
	if err != nil {
		db.Close()
		if fresh {
			_ = removeLogFiles(path)
		}
		return nil, err
	}
	return db, nil
}

func (s *logStore) write(hour int64, entries []logEntry) error {
	if s.active == nil || s.hour != hour {
		s.close()
		if err := os.MkdirAll(s.dir, 0700); err != nil {
			return err
		}
		db, err := openLogDB(filepath.Join(s.dir, strconv.FormatInt(hour, 10)+".chirplog"), true)
		if err != nil {
			return err
		}
		s.active, s.hour = db, hour
	}
	return logTransaction(s.active, func(tx *sql.Tx) error {
		stmts := make(map[string]*sql.Stmt)
		for _, row := range entries {
			stmt := stmts[row.op.table]
			if stmt == nil {
				var err error
				stmt, err = tx.Prepare("INSERT INTO " + row.op.table + " VALUES (?,?,?,?,?,?,?,?,?)")
				if err != nil {
					return err
				}
				stmts[row.op.table] = stmt // closed by the transaction
			}
			var details any
			if row.details != nil {
				data, err := json.Marshal(row.details)
				if err != nil {
					return err
				}
				details = string(data)
			}
			if _, err := stmt.Exec(row.ms, row.op.name, logNull(row.outcome), logNull(row.code), row.duration, row.status, details, row.segment, row.seq); err != nil {
				return err
			}
		}
		return nil
	})
}

func logNull(value string) any {
	if value == "" {
		return nil
	}
	return value
}

func removeLogFiles(path string) error {
	var result error
	for _, suffix := range []string{"", "-journal", "-wal", "-shm"} {
		if err := os.Remove(path + suffix); err != nil && !errors.Is(err, os.ErrNotExist) {
			result = errors.Join(result, err)
		}
	}
	return result
}

func shardHour(name string) (int64, bool) {
	base, ok := strings.CutSuffix(name, ".chirplog")
	h, err := strconv.ParseInt(base, 10, 64)
	return h, ok && err == nil && strconv.FormatInt(h, 10) == base
}

func (s *logStore) files() ([]os.DirEntry, error) {
	files, err := os.ReadDir(s.dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	return files, err
}

func (s *logStore) prune(now int64, startup bool) error {
	files, err := s.files()
	if err != nil {
		return err
	}
	cutoff := now - logRetentionMS
	var result error
	for _, f := range files {
		name := f.Name()
		if f.IsDir() {
			continue
		}
		if startup && strings.HasPrefix(name, "export.") {
			if err := os.Remove(filepath.Join(s.dir, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
				result = errors.Join(result, err)
			}
			continue
		}
		base, _, sidecar := strings.Cut(name, ".chirplog-")
		if sidecar {
			base += ".chirplog"
		}
		h, shard := shardHour(base)
		if !shard || h > cutoff/logHourMS {
			continue
		}
		path := filepath.Join(s.dir, base)
		if s.active != nil && s.hour == h {
			s.close()
		}
		if h < cutoff/logHourMS {
			result = errors.Join(result, removeLogFiles(path))
			continue
		}
		if sidecar {
			continue
		}
		result = errors.Join(result, pruneLogRows(path, cutoff))
	}
	return result
}

func pruneLogRows(path string, cutoff int64) error {
	db, err := openLogDB(path, false)
	if err != nil {
		return err
	}
	occupied := false
	err = logTransaction(db, func(tx *sql.Tx) error {
		for _, table := range logTables {
			if _, err := tx.Exec("DELETE FROM "+table+" WHERE time_ms < ?", cutoff); err != nil {
				return err
			}
			if !occupied {
				if err := tx.QueryRow("SELECT EXISTS(SELECT 1 FROM " + table + ")").Scan(&occupied); err != nil {
					return err
				}
			}
		}
		return nil
	})
	closeErr := db.Close()
	if err != nil || closeErr != nil {
		return errors.Join(err, closeErr)
	}
	if !occupied {
		return removeLogFiles(path)
	}
	return nil
}

func (s *logStore) snapshot(now int64) (path string, err error) {
	if err := s.prune(now, false); err != nil {
		return "", err
	}
	files, err := s.files()
	if err != nil {
		return "", err
	}
	cutoff := now - logRetentionMS
	var shards []string
	for _, f := range files {
		if h, ok := shardHour(f.Name()); ok && !f.IsDir() && h >= cutoff/logHourMS && h <= now/logHourMS {
			shards = append(shards, filepath.Join(s.dir, f.Name()))
		}
	}
	if len(shards) == 0 {
		return "", errLogEmpty
	}
	temp := filepath.Join(s.dir, "export."+uuid.NewString()+".chirplog")
	db, err := openLogDB(temp, true)
	if err != nil {
		return "", err
	}
	defer func() {
		err = errors.Join(err, db.Close())
		if err != nil {
			_ = removeLogFiles(temp)
			path = ""
		}
	}()
	var count int64
	for _, shard := range shards {
		if _, err := db.Exec("ATTACH DATABASE ? AS shard", shard); err != nil {
			return "", err
		}
		if err := validateLogDB(db, "shard"); err != nil {
			return "", err
		}
		err := logTransaction(db, func(tx *sql.Tx) error {
			for _, table := range logTables {
				res, err := tx.Exec("INSERT INTO main."+table+" SELECT * FROM shard."+table+" WHERE time_ms BETWEEN ? AND ?", cutoff, now)
				if err != nil {
					return err
				}
				n, err := res.RowsAffected()
				if err != nil {
					return err
				}
				count += n
			}
			return nil
		})
		if err != nil {
			return "", err
		}
		if _, err := db.Exec("DETACH DATABASE shard"); err != nil {
			return "", err
		}
	}
	if count == 0 {
		return "", errLogEmpty
	}
	return temp, nil
}
