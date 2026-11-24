package store

import (
	"bufio"
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

func TestSQLitePragmasOnEveryConnection(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	for range 2 {
		var connections []*sql.Conn
		for range 4 {
			conn, err := s.db.Conn(ctx)
			if err != nil {
				t.Fatal(err)
			}
			connections = append(connections, conn)
			for pragma, want := range map[string]string{
				"journal_mode": "wal", "foreign_keys": "1", "busy_timeout": "10000", "synchronous": "2", "locking_mode": "normal",
			} {
				var got string
				if err := conn.QueryRowContext(ctx, "PRAGMA "+pragma).Scan(&got); err != nil || got != want {
					t.Errorf("%s = %s, want %s: %v", pragma, got, want, err)
				}
			}
			if _, err := conn.ExecContext(ctx, "INSERT INTO passkey_credentials(id,account_id,credential_json) VALUES(?, ?, ?)", []byte("invalid"), "missing", []byte(`{}`)); err == nil {
				t.Error("foreign key violation accepted")
			}
		}
		// Force fresh physical connections for the second pass.
		s.db.SetMaxIdleConns(0)
		for _, conn := range connections {
			conn.Close()
		}
		s.db.SetMaxIdleConns(4)
	}
}

func TestSQLiteWriterWaitsWithoutBlockingReaders(t *testing.T) {
	ctx := context.Background()
	path := testdb.Path(t)
	one, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer one.Close()
	two, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer two.Close()
	member, token, err := one.AddMember(ctx, "committed")
	if err != nil {
		t.Fatal(err)
	}
	tx, err := one.beginWrite(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "UPDATE members SET display_name = 'new name' WHERE id = ?", member.ID); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := two.UpdateMember(ctx, member.ID, "writer after commit", true)
		done <- err
	}()
	readCtx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	if got, err := two.MemberByCredential(readCtx, token); err != nil || got.DisplayName != "committed" {
		t.Fatal("reader blocked or saw an uncommitted write", got, err)
	}
	select {
	case err := <-done:
		t.Fatal("second writer did not wait for the transaction", err)
	case <-time.After(100 * time.Millisecond):
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal("waiting writer failed", err)
	}
	if got, err := one.MemberByCredential(ctx, token); err != nil || got.DisplayName != "writer after commit" {
		t.Fatal("committed changes are not visible across pools", got, err)
	}
}

func TestSQLiteWaitingWriterHonorsCancellation(t *testing.T) {
	ctx := context.Background()
	s := openTestStore(t)
	tx, err := s.beginWrite(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	waitCtx, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
	defer cancel()
	started := time.Now()
	_, _, err = s.AddMember(waitCtx, "cancelled writer")
	if !errors.Is(err, context.DeadlineExceeded) || time.Since(started) > 2*time.Second {
		t.Fatal("waiting writer did not honor cancellation", time.Since(started), err)
	}
	if err := tx.Rollback(); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.AddMember(ctx, "next writer"); err != nil {
		t.Fatal("cancellation leaked a transaction or connection", err)
	}
}

// Each worker is a separate OS process with its own pools and SQLite runtime.
// Running this test under -race also exercises the process-local driver code.
func TestSQLiteMultiProcessInitializationAndAuthorization(t *testing.T) {
	ctx := context.Background()
	path := testdb.Path(t)
	runSQLiteWorkers(t, path, "create", Member{})
	s, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	members, err := s.ListMembers(ctx)
	if err != nil || len(members) != 160 {
		t.Fatal("concurrent process writes were lost", len(members), err)
	}
	rooms, err := s.Rooms(ctx)
	if err != nil || len(rooms) != 41 {
		t.Fatal("concurrent room creation failed", len(rooms), err)
	}
	if err := s.SavePasskeyCeremony(ctx, "process-once", "", "login", []byte(`{}`), time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if accepted := runSQLiteWorkers(t, path, "consume", Member{}); accepted != 1 {
		t.Fatalf("one ceremony was consumed %d times across processes", accepted)
	}
	member, _, err := s.AddMember(ctx, "concurrent room member")
	if err != nil {
		t.Fatal(err)
	}
	runSQLiteWorkers(t, path, "join", member)
	var sequence, count int
	if err := s.db.QueryRow("SELECT room_join_sequence FROM members WHERE id = ?", member.ID).Scan(&sequence); err != nil || sequence != 160 {
		t.Fatal("latest join sequence lost", sequence, err)
	}
	if err := s.db.QueryRow("SELECT COUNT(*) FROM room_admissions WHERE member_id = ? AND join_sequence = 160", member.ID).Scan(&count); err != nil || count != 1 {
		t.Fatal("admission and member sequence disagree", count, err)
	}
	assertSQLiteIntegrity(t, s)
}

func runSQLiteWorkers(t *testing.T, path, action string, member Member) int {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	encoded, _ := json.Marshal(member)
	var commands []*exec.Cmd
	var gates []io.WriteCloser
	var outputs []*bytes.Buffer
	for i := range 4 {
		cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestSQLiteWorkerProcess$")
		cmd.Env = append(os.Environ(), "CHIRP_TEST_SQLITE_WORKER="+action, "CHIRP_TEST_SQLITE_PATH="+path, "CHIRP_TEST_SQLITE_MEMBER="+string(encoded), "CHIRP_TEST_SQLITE_LOGIN="+member.LoginID, "CHIRP_TEST_SQLITE_INDEX="+strconv.Itoa(i))
		gate, err := cmd.StdinPipe()
		if err != nil {
			t.Fatal(err)
		}
		output := new(bytes.Buffer)
		cmd.Stdout, cmd.Stderr = output, output
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		commands, gates, outputs = append(commands, cmd), append(gates, gate), append(outputs, output)
	}
	for _, gate := range gates {
		_, _ = gate.Write([]byte("start"))
		gate.Close()
	}
	accepted := 0
	for i, cmd := range commands {
		if err := cmd.Wait(); err != nil {
			t.Fatalf("SQLite %s worker failed: %v\n%s", action, err, outputs[i])
		}
		for _, line := range strings.Split(outputs[i].String(), "\n") {
			if strings.HasPrefix(line, "consumed=") {
				n, err := strconv.Atoi(strings.TrimPrefix(line, "consumed="))
				if err != nil {
					t.Fatal(err)
				}
				accepted += n
			}
		}
	}
	return accepted
}

func TestSQLiteRecoveryAfterKilledWriter(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	path := testdb.Path(t)
	s, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	member, _, err := s.AddMember(ctx, "before crash")
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	encoded, _ := json.Marshal(member)
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestSQLiteWorkerProcess$")
	cmd.Env = append(os.Environ(), "CHIRP_TEST_SQLITE_WORKER=crash", "CHIRP_TEST_SQLITE_PATH="+path, "CHIRP_TEST_SQLITE_MEMBER="+string(encoded))
	cmd.Stdin = strings.NewReader("start")
	output, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	scanner := bufio.NewScanner(output)
	if !scanner.Scan() || scanner.Text() != "uncommitted" {
		_ = cmd.Wait()
		t.Fatal("crash worker did not acquire the lock", scanner.Err(), stderr.String())
	}
	_ = cmd.Process.Kill()
	_ = cmd.Wait()
	s, err = Open(ctx, path)
	if err != nil {
		t.Fatal("database did not recover after a killed writer", err)
	}
	defer s.Close()
	members, err := s.ListMembers(ctx)
	if err != nil || len(members) != 1 || members[0].DisplayName != "before crash" {
		t.Fatal("uncommitted changes survived a killed writer", members, err)
	}
	if _, err := s.UpdateMember(ctx, member.ID, "after recovery", true); err != nil {
		t.Fatal("writer lock was not released by process death", err)
	}
	assertSQLiteIntegrity(t, s)
}

func assertSQLiteIntegrity(t *testing.T, s *Store) {
	t.Helper()
	var integrity string
	if err := s.db.QueryRow("PRAGMA integrity_check").Scan(&integrity); err != nil || integrity != "ok" {
		t.Fatal("SQLite integrity check", integrity, err)
	}
	rows, err := s.db.Query("PRAGMA foreign_key_check")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	if rows.Next() || rows.Err() != nil {
		t.Fatal("foreign key check failed", rows.Err())
	}
}

func TestSQLiteWorkerProcess(t *testing.T) {
	action := os.Getenv("CHIRP_TEST_SQLITE_WORKER")
	if action == "" {
		return
	}
	var start [1]byte
	if _, err := io.ReadFull(os.Stdin, start[:]); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	s, err := Open(ctx, os.Getenv("CHIRP_TEST_SQLITE_PATH"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	var member Member
	if raw := os.Getenv("CHIRP_TEST_SQLITE_MEMBER"); raw != "" {
		if err := json.Unmarshal([]byte(raw), &member); err != nil {
			t.Fatal(err)
		}
	}
	member.LoginID = os.Getenv("CHIRP_TEST_SQLITE_LOGIN")
	index, _ := strconv.Atoi(os.Getenv("CHIRP_TEST_SQLITE_INDEX"))
	consumed := 0
	switch action {
	case "create":
		for i := range 40 {
			if _, _, err := s.AddMember(ctx, fmt.Sprintf("process %d member %d 😀", index, i)); err != nil {
				t.Fatal(err)
			}
			if i%4 == 0 {
				if _, err := s.CreateRoom(ctx, fmt.Sprintf("process %d room %d", index, i)); err != nil {
					t.Fatal(err)
				}
			}
		}
	case "consume":
		for range 8 {
			if _, err := s.ConsumePasskeyCeremony(ctx, "process-once", "login"); err == nil {
				consumed++
			} else if !errors.Is(err, ErrNotFound) {
				t.Fatal(err)
			}
		}
		fmt.Printf("consumed=%d\n", consumed)
	case "join":
		for i := range 40 {
			if _, err := s.JoinRoom(ctx, member, DefaultRoomID, int64(i*4+index+1), 0); err != nil && !errors.Is(err, ErrAdmissionChanged) {
				t.Fatal(err)
			}
		}
	case "crash":
		tx, err := s.beginWrite(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback()
		if _, err := tx.Exec("UPDATE members SET display_name='uncommitted' WHERE id=?", member.ID); err != nil {
			t.Fatal(err)
		}
		fmt.Println("uncommitted")
		time.Sleep(time.Hour) // The parent kills this process while the lock is held.
	default:
		t.Fatal("unknown worker action", action)
	}
}
