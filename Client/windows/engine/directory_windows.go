package main

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
)

var memberPattern = regexp.MustCompile("^member_[A-Za-z0-9_-]{1,57}$")

func validName(s string) bool {
	return s != "" && strings.TrimSpace(s) == s && utf8.ValidString(s) && utf8.RuneCountInString(s) <= 80 && !strings.ContainsFunc(s, unicode.IsControl)
}

func validRoomPresence(r room.Overview) bool {
	switch r.MediaStatus {
	case "unavailable":
		return r.Participants == nil
	case "available":
		if r.Participants == nil {
			return false
		}
	default:
		return false
	}
	seen := make(map[string]bool, len(r.Participants))
	for _, participant := range r.Participants {
		if participant.ID == "" || strings.TrimSpace(participant.ID) != participant.ID || len(participant.ID) > 256 ||
			strings.ContainsFunc(participant.ID, unicode.IsControl) || !validName(participant.DisplayName) || seen[participant.ID] {
			return false
		}
		seen[participant.ID] = true
	}
	return true
}

func trustedFriendName(friends []friend, id, root string) string {
	for _, friend := range friends {
		if friend.ID == id && friend.Root == root {
			return friend.Name
		}
	}
	return ""
}

func (e *engine) stopWatchingDirectory() {
	e.directoryWatch.Add(1)
	if e.stopDirectory != nil {
		e.stopDirectory()
		e.stopDirectory = nil
	}
}

// The event stream contains revision hints. Every reconnect and revocation
// triggers a new authenticated snapshot; only snapshots update the directory.
func watchDirectory(ctx context.Context, endpoint, credential string, notify func(string, any)) {
	backoff := 500 * time.Millisecond
	reconnecting := false
	for ctx.Err() == nil {
		conn, cancel := context.WithCancel(ctx)
		idle := time.AfterFunc(25*time.Second, cancel)
		req, err := http.NewRequestWithContext(conn, "GET", endpoint, nil)
		if err != nil {
			idle.Stop()
			cancel()
			return
		}
		req.Header.Set("Accept", "text/event-stream")
		req.Header.Set("Authorization", "Bearer "+credential)
		span := installationLog.begin()
		resp, err := client.Do(req)
		endStream := streamLog(span, "eventStreamEnded", req.Context(), resp, err)
		if err == nil {
			if (resp.StatusCode == 401 || resp.StatusCode == 403) && ctx.Err() == nil {
				// The authenticated snapshot and login monitor decide whether to
				// sign out. A stream-specific denial must not disable future hints.
				notify("directoryChanged", nil)
			}
			if resp.StatusCode == 200 && strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
				if reconnecting && ctx.Err() == nil {
					notify("directoryChanged", nil)
				}
				sc := bufio.NewScanner(resp.Body)
				sc.Buffer(make([]byte, 2048), 16384)
				event, data := "", ""
				for sc.Scan() && ctx.Err() == nil {
					idle.Reset(25 * time.Second)
					line := sc.Text()
					switch {
					case strings.HasPrefix(line, "event:"):
						event = strings.TrimSpace(line[len("event:"):])
					case strings.HasPrefix(line, "data:"):
						data = strings.TrimSpace(line[len("data:"):])
					case line == "" && event != "":
						var hint struct {
							Server   string `json:"server_id"`
							Revision uint64 `json:"revision"`
						}
						if event != "state" || json.Unmarshal([]byte(data), &hint) != nil || len(hint.Server) == 0 || len(hint.Server) > 128 || hint.Revision == 0 {
							notify("directoryChanged", nil)
							cancel()
						} else {
							backoff = 500 * time.Millisecond
							notify("directoryChanged", nil)
						}
						event, data = "", ""
					}
				}
			}
			resp.Body.Close()
		}
		endStream()
		idle.Stop()
		cancel()
		if ctx.Err() == nil {
			reconnecting = true
			notify("directoryStale", nil)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(5*time.Second, backoff*2)
	}
}
