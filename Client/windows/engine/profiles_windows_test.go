package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/config"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func TestProfileRoutesAndAvatarSession(t *testing.T) {
	const id = "member_fixture"
	rev := strings.Repeat("a", 64)
	var data bytes.Buffer
	ok(t, png.Encode(&data, image.NewRGBA(image.Rect(0, 0, 512, 512))))
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/me", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == "PATCH" {
			var fields map[string]string
			if json.NewDecoder(r.Body).Decode(&fields) != nil || len(fields) != 1 || fields["display_name"] != "新昵称" {
				t.Error("wrong rename request")
			}
		}
		_ = json.NewEncoder(w).Encode(store.MemberProfile{ID: id, DisplayName: "新昵称", ProfileRevision: 4})
	})
	mux.HandleFunc("PUT /v1/me/avatar", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Content-Type") != "image/png" {
			t.Error("wrong upload type")
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(obj{"id": id, "display_name": "missing revision"})
	})
	mux.HandleFunc("GET /v1/members/"+id+"/avatar/"+rev, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Accept") != "image/png" {
			t.Error("wrong avatar Accept")
		}
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(data.Bytes())
	})
	started := make(chan struct{})
	mux.HandleFunc("GET /v1/members/"+id+"/avatar/"+strings.Repeat("b", 64), func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-r.Context().Done()
	})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer fixture-credential" {
			t.Error("missing credential")
		}
		mux.ServeHTTP(w, r)
	}))
	defer srv.Close()
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	e := &engine{session: &session{Credential: "fixture-credential"}, conn: &connection{endpoints: config.ClientEndpoints{APIBaseURL: srv.URL}}, vault: &vault{}}
	e.session.Member.ID = id
	p, err := e.handle(ctx, command{Op: "rename", Args: args{Name: "新昵称"}})
	ok(t, err)
	if p.(store.MemberProfile).ProfileRevision != 4 {
		t.Fatal("lost revision")
	}
	if _, err = e.handle(ctx, command{Op: "avatar", Args: args{File: data.Bytes()}}); err == nil {
		t.Fatal("accepted missing revision")
	}
	p, err = e.handle(ctx, command{Op: "getAvatar", Args: args{ID: id, Key: rev}})
	ok(t, err)
	if !bytes.Equal(p.(obj)["file"].([]byte), data.Bytes()) {
		t.Fatal("avatar changed")
	}
	oldSession := e.session
	replies := make(chan avatarReply, 1)
	e.startAvatar(ctx, command{ID: 47, Args: args{ID: id, Key: strings.Repeat("b", 64)}}, replies)
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("download did not start")
	}
	if _, err = e.handle(ctx, command{Op: "profile"}); err != nil {
		t.Fatal(err)
	}
	e.reset(ctx)
	select {
	case reply := <-replies:
		if reply.id != 47 || reply.owner != oldSession || !errors.Is(reply.err, context.Canceled) {
			t.Fatal("late image escaped its login", reply.err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("sign-out did not cancel profile request")
	}
}

func TestDirectoryMemberRevision(t *testing.T) {
	var members []wireProfile
	for _, revision := range []string{"", `,"profile_revision":null`, `,"profile_revision":-1`} {
		err := json.Unmarshal([]byte(`[{"id":"member_test","display_name":"Test"`+revision+`}]`), &members)
		if err == nil {
			t.Fatal("accepted invalid member revision", revision)
		}
	}
	ok(t, json.Unmarshal([]byte(`[{"id":"member_test","display_name":"Test","profile_revision":0}]`), &members))
	out, err := json.Marshal(members)
	ok(t, err)
	if !bytes.Contains(out, []byte(`"profile_revision":0`)) {
		t.Fatal("lost the first revision between the directory and the desktop")
	}
}
