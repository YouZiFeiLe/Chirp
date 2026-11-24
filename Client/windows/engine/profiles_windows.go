package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"image/png"
	"net/http"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

// A missing or null revision must not be treated as the legitimate first revision (zero).
type wireProfile store.MemberProfile

func (p *wireProfile) UnmarshalJSON(data []byte) error {
	var value struct {
		store.MemberProfile
		Revision *int64 `json:"profile_revision"`
	}
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	if !memberPattern.MatchString(value.ID) || !validName(value.DisplayName) || value.Revision == nil || *value.Revision < 0 ||
		value.AvatarRevision != "" && !hashID.MatchString(value.AvatarRevision) {
		return invalid
	}
	value.ProfileRevision = *value.Revision
	*p = wireProfile(value.MemberProfile)
	return nil
}

func normalizedAvatar(data []byte) bool {
	if len(data) == 0 || len(data) >= store.MaxAvatarBytes {
		return false
	}
	cfg, err := png.DecodeConfig(bytes.NewReader(data))
	return err == nil && cfg.Width == 512 && cfg.Height == 512
}

func (e *engine) ownProfile(ctx context.Context, c command) (any, error) {
	method, path := "GET", "v1/me"
	var body any
	var headers http.Header
	switch c.Op {
	case "rename":
		if !validName(c.Args.Name) {
			return nil, errors.New("INVALID_DISPLAY_NAME")
		}
		method, body = "PATCH", obj{"display_name": c.Args.Name}
	case "removeAvatar":
		method, path = "DELETE", "v1/me/avatar"
	case "avatar":
		if !normalizedAvatar(c.Args.File) {
			return nil, errors.New("AVATAR_INVALID")
		}
		method, path, body = "PUT", "v1/me/avatar", c.Args.File
		headers = http.Header{"Content-Type": {"image/png"}}
	}
	var profile wireProfile
	_, err := request(ctx, commandLogOps[c.Op].name, method, e.conn.api(path), body, e.session.Credential, headers, &profile, 65536)
	if err != nil {
		return nil, err
	}
	if profile.ID != e.session.Member.ID {
		return nil, invalid
	}
	return store.MemberProfile(profile), nil
}

func fetchAvatar(ctx context.Context, conn *connection, credential string, a args) (obj, error) {
	if !memberPattern.MatchString(a.ID) || !hashID.MatchString(a.Key) {
		return nil, invalid
	}
	var data []byte
	_, err := request(ctx, "fetchAvatar", "GET", conn.api("v1/members/"+a.ID+"/avatar/"+a.Key), nil, credential,
		http.Header{"Accept": {"image/png"}}, &data, store.MaxAvatarBytes-1)
	if err != nil {
		return nil, err
	}
	if len(data) == 0 {
		return nil, invalid
	}
	return obj{"file": data}, nil
}

type avatarReply struct {
	id    uint64
	owner *session
	data  obj
	err   error
}

// Only immutable request data crosses the actor boundary. A slow CDN must not
// delay room admission, chat or sign-out. Retiring a login cancels its requests.
func (e *engine) startAvatar(root context.Context, c command, replies chan<- avatarReply) {
	if e.stopAvatars == nil {
		e.avatarContext, e.stopAvatars = context.WithCancel(root)
	}
	ctx, conn, owner := e.avatarContext, e.conn, e.session
	go func() {
		data, err := fetchAvatar(ctx, conn, owner.Credential, c.Args)
		c.finishLog(err)
		select {
		case replies <- avatarReply{c.ID, owner, data, err}:
		case <-root.Done():
		}
	}()
}
