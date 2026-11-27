package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/config"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

const version = "2026.11.27"
const build = 1

type obj = map[string]any

var invalid = errors.New("INVALID_RESPONSE")
var tokenRE = regexp.MustCompile(`^[a-zA-Z0-9_-]{43}$`)
var client = &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

func random(n int) []byte       { b := make([]byte, n); rand.Read(b); return b }
func b64(b []byte) string       { return base64.StdEncoding.EncodeToString(b) }
func rawURL(b []byte) string    { return base64.RawURLEncoding.EncodeToString(b) }
func challenge(s string) string { sum := sha256.Sum256([]byte(s)); return rawURL(sum[:]) }

type apiError struct {
	code          string
	status        int
	authenticated bool
	retryAfter    time.Duration
	policy        *store.ClientVersionPolicy
}

func (e *apiError) Error() string { return e.code }
func parseRetryAfter(header string) time.Duration {
	value := strings.TrimSpace(header)
	if seconds, err := strconv.ParseUint(value, 10, 32); err == nil {
		return time.Duration(seconds) * time.Second
	}
	if until, err := http.ParseTime(value); err == nil {
		return max(time.Duration(0), time.Until(until))
	}
	return 0
}
func clientErrorReply(id uint64, err error) obj {
	reply := obj{"id": id, "error": err.Error(), "temporary": temporarilyUnavailable(err)}
	var remote *apiError
	if errors.As(err, &remote) {
		if remote.retryAfter > 0 {
			reply["retryAfter"] = int64((remote.retryAfter + time.Second - 1) / time.Second)
		}
		if p := remote.policy; p != nil && p.Platform == "windows" && p.Valid() {
			reply["minimumVersion"], reply["minimumBuild"] = p.MinimumVersion, p.MinimumBuild
		}
	}
	return reply
}
func temporarilyUnavailable(err error) bool {
	var remote *apiError
	return err != nil && (err.Error() == "SERVER_UNAVAILABLE" || errors.As(err, &remote) && (remote.status == 408 || remote.status == 429 || remote.status >= 500))
}
func request(ctx context.Context, operation, method, endpoint string, body any, bearer string, headers http.Header, result any, limit int64) (status int, resultErr error) {
	span := installationLog.begin()
	defer func() { installationLog.finish(span, logOp{"network", operation}, resultErr, status) }()
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	var reader io.Reader
	if body != nil {
		var data []byte
		var err error
		switch b := body.(type) {
		case json.RawMessage:
			data = b
		case []byte:
			data = b
		default:
			data, err = json.Marshal(body)
		}
		if err != nil {
			return 0, err
		}
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, reader)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("X-Chirp-Platform", "windows")
	req.Header.Set("X-Chirp-Version", version)
	req.Header.Set("X-Chirp-Build", strconv.Itoa(build))
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	for k, vs := range headers {
		req.Header[k] = vs
	}
	resp, err := client.Do(req)
	if err != nil {
		if errors.Is(ctx.Err(), context.Canceled) {
			return 0, ctx.Err()
		}
		return 0, errors.New("SERVER_UNAVAILABLE")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		if errors.Is(ctx.Err(), context.Canceled) {
			return resp.StatusCode, ctx.Err()
		}
		return resp.StatusCode, errors.New("SERVER_UNAVAILABLE")
	}
	if int64(len(data)) > limit {
		return resp.StatusCode, invalid
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var f struct {
			Error  struct{ Code string }
			Policy *store.ClientVersionPolicy `json:"client_policy"`
		}
		_ = json.Unmarshal(data, &f)
		if !regexp.MustCompile(`^[A-Z][A-Z_0-9]{1,80}$`).MatchString(f.Error.Code) {
			f.Error.Code = fmt.Sprintf("HTTP_%d", resp.StatusCode)
		}
		return resp.StatusCode, &apiError{code: f.Error.Code, status: resp.StatusCode, authenticated: bearer != "", retryAfter: parseRetryAfter(resp.Header.Get("Retry-After")), policy: f.Policy}
	}
	if result != nil && resp.StatusCode != 204 {
		if pngBytes, ok := result.(*[]byte); ok {
			if resp.Header.Get("Content-Type") != "image/png" || !normalizedAvatar(data) {
				return resp.StatusCode, errors.New("AVATAR_INVALID")
			}
			*pngBytes = data
			return resp.StatusCode, nil
		}
		mediaType, _, err := mime.ParseMediaType(resp.Header.Get("Content-Type"))
		if err != nil || mediaType != "application/json" || json.Unmarshal(data, result) != nil {
			return resp.StatusCode, invalid
		}
	}
	return resp.StatusCode, nil
}

type connection struct {
	discovery           string
	origin              string
	endpoints           config.ClientEndpoints
	defaultRoom         string
	registration, phone bool
	verifiedAt          time.Time
}

// The last confirmed discovery is stored inside the user's DPAPI vault.
// Its origins are checked again against fresh discovery before leaving the app.
type savedConnection struct {
	Discovery, Origin, DefaultRoom string
	Endpoints                      config.ClientEndpoints
	Registration, Phone            bool
}

func (e *engine) rememberConnection(c *connection) error {
	previous := e.vault.Connection
	e.vault.Connection = &savedConnection{c.discovery, c.origin, c.defaultRoom, c.endpoints, c.registration, c.phone}
	if err := e.vault.save(); err != nil {
		e.vault.Connection = previous
		return err
	}
	e.conn = c
	return nil
}
func (e *engine) restoreConnection() (obj, error) {
	s := e.vault.Connection
	if s == nil {
		return nil, nil
	}
	origin, err := identity.NormalizeOrigin(s.Origin)
	if err != nil || origin != s.Origin || !store.ValidRoomID(s.DefaultRoom) {
		return nil, invalid
	}
	for _, raw := range []string{s.Discovery, s.Origin, s.Endpoints.APIBaseURL, s.Endpoints.HealthURL, s.Endpoints.GroupBaseURL} {
		if _, err := validateURL(raw, e.local); err != nil {
			return nil, invalid
		}
	}
	for _, raw := range []string{s.Endpoints.AuthorizationURL, s.Endpoints.RegistrationURL, s.Endpoints.TokenURL, s.Endpoints.DeviceStartURL, s.Endpoints.DevicePollURL, s.Endpoints.DeviceCancelURL, s.Endpoints.DeviceVerificationURL} {
		u, err := validateURL(raw, e.local)
		if err != nil || originOf(u) != origin {
			return nil, invalid
		}
	}
	e.conn = &connection{discovery: s.Discovery, origin: s.Origin, endpoints: s.Endpoints,
		defaultRoom: s.DefaultRoom, registration: s.Registration, phone: s.Phone}
	return e.connectionView(), nil
}
func (e *engine) connectionView() obj {
	c := e.conn
	return obj{"address": c.discovery, "origin": c.origin, "api": c.endpoints.APIBaseURL, "registration": c.registration, "phone": c.phone, "canApprove": len(e.savedIssuers()) != 0}
}
func (e *engine) refreshConnection(ctx context.Context) (*connection, error) {
	if e.conn == nil {
		return nil, invalid
	}
	c, err := detect(ctx, e.conn.discovery, e.local)
	if err != nil {
		if err.Error() == "CLIENT_UPDATE_REQUIRED" {
			e.cancelLogin(ctx)
			e.conn = nil
		}
		return nil, err
	}
	if c.origin != e.conn.origin ||
		!sameEndpointOrigin(e.conn.endpoints.APIBaseURL, c.endpoints.APIBaseURL) ||
		!sameEndpointOrigin(e.conn.endpoints.GroupBaseURL, c.endpoints.GroupBaseURL) {
		return nil, errors.New("SERVER_CONFIGURATION_CHANGED")
	}
	if err = e.rememberConnection(c); err != nil {
		return nil, err
	}
	return c, nil
}

func originOf(u *url.URL) string {
	normalized, _ := identity.NormalizeOrigin(u.Scheme + "://" + u.Host)
	return normalized
}

func sameEndpointOrigin(previous, next string) bool {
	a, errA := url.Parse(previous)
	b, errB := url.Parse(next)
	if errA != nil || errB != nil {
		return false
	}
	origin := originOf(a)
	return origin != "" && origin == originOf(b)
}

func validateURL(raw string, local bool) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.Opaque != "" || u.User != nil || strings.ContainsAny(raw, "\\?# \t\r\n") || u.Hostname() == "" {
		return nil, invalid
	}
	h := strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")
	if strings.Contains(h, "*") || regexp.MustCompile(`(^|\.)livekit\.(cloud|run|io)$`).MatchString(h) || originOf(u) == "" {
		return nil, invalid
	}
	if u.Scheme != "https" && !(local && u.Scheme == "http" && (h == "localhost" || net.ParseIP(h).IsLoopback())) {
		return nil, invalid
	}
	return u, nil
}

func parseServerAddress(raw string, local bool) (*url.URL, error) {
	raw = strings.TrimSpace(raw)
	// A scheme ends in ":" before the first slash, while host:port ends in a digit.
	beforeSlash, _, _ := strings.Cut(raw, "/")
	if beforeSlash != "" && !strings.HasSuffix(beforeSlash, ":") {
		raw = "https://" + raw
	}
	base, err := validateURL(strings.TrimRight(raw, "/"), local)
	if err != nil {
		return nil, errors.New("INVALID_SERVER_ADDRESS")
	}
	base.Host = strings.ToLower(base.Host)
	if base.Scheme == "https" && base.Port() == "443" || base.Scheme == "http" && base.Port() == "80" {
		base.Host = strings.TrimSuffix(base.Host, ":"+base.Port())
	}
	return base, nil
}

func detect(ctx context.Context, raw string, local bool) (*connection, error) {
	base, err := parseServerAddress(raw, local)
	if err != nil {
		return nil, err
	}
	var configData json.RawMessage
	status, err := request(ctx, "clientConfig", "GET", base.JoinPath("v1/client-config").String(), nil, "", nil, &configData, 16384)
	if err != nil {
		return nil, err
	}
	var envelope struct {
		Service  string
		Protocol int                       `json:"protocol_version"`
		Policy   store.ClientVersionPolicy `json:"client_policy"`
	}
	if status != http.StatusOK || json.Unmarshal(configData, &envelope) != nil || envelope.Service != "chirp" || envelope.Protocol != 5 || !envelope.Policy.Valid() || envelope.Policy.Platform != "windows" {
		return nil, invalid
	}
	compare := func(a, b string) int {
		aa, bb := strings.Split(a, "."), strings.Split(b, ".")
		for i := range aa {
			x, _ := strconv.Atoi(aa[i])
			y, _ := strconv.Atoi(bb[i])
			if x != y {
				return x - y
			}
		}
		return 0
	}
	if order := compare(version, envelope.Policy.MinimumVersion); order < 0 || order == 0 && build < envelope.Policy.MinimumBuild {
		return nil, &apiError{code: "CLIENT_UPDATE_REQUIRED", status: http.StatusForbidden, policy: &envelope.Policy}
	}
	var reply struct {
		Origin    string `json:"passkey_origin"`
		Room      string `json:"default_room_id"`
		Endpoints config.ClientEndpoints
		Caps      map[string]json.RawMessage `json:"capabilities"`
	}
	if json.Unmarshal(configData, &reply) != nil || !store.ValidRoomID(reply.Room) {
		return nil, invalid
	}
	origin, err := identity.NormalizeOrigin(reply.Origin)
	if err != nil {
		return nil, invalid
	}
	if _, err := validateURL(reply.Origin, local); err != nil {
		return nil, invalid
	}
	c := &connection{discovery: base.String(), origin: origin, endpoints: reply.Endpoints, defaultRoom: reply.Room}
	if json.Unmarshal(reply.Caps["registration"], &c.registration) != nil || json.Unmarshal(reply.Caps["device_login"], &c.phone) != nil || string(reply.Caps["dynamic_rooms"]) != "true" || string(reply.Caps["state_events"]) != "true" || string(reply.Caps["attachment_protocol"]) != "3" || string(reply.Caps["max_members"]) != "0" || string(reply.Caps["max_room_participants"]) != "0" {
		return nil, invalid
	}
	ep := &c.endpoints
	for _, p := range []*string{&ep.APIBaseURL, &ep.HealthURL, &ep.AuthorizationURL, &ep.RegistrationURL, &ep.TokenURL, &ep.DeviceStartURL, &ep.DevicePollURL, &ep.DeviceCancelURL, &ep.DeviceVerificationURL, &ep.GroupBaseURL} {
		auth := p != &ep.APIBaseURL && p != &ep.GroupBaseURL && p != &ep.HealthURL
		ref, err := url.Parse(*p)
		if err != nil || *p == "" || strings.HasPrefix(*p, "//") || auth && !ref.IsAbs() {
			return nil, invalid
		}
		directory := *base
		directory.Path = strings.TrimRight(directory.Path, "/") + "/"
		*p = directory.ResolveReference(ref).String()
		u, err := validateURL(*p, local)
		if err != nil || auth && originOf(u) != origin {
			return nil, invalid
		}
	}
	var health struct{ Status, Service string }
	if status, err = request(ctx, "health", "GET", ep.HealthURL, nil, "", nil, &health, 16384); err != nil {
		return nil, err
	}
	if status != http.StatusOK || health.Service != "chirp" || health.Status != "ok" {
		return nil, invalid
	}
	c.verifiedAt = time.Now()
	return c, nil
}
func (c *connection) api(path string) string {
	return strings.TrimRight(c.endpoints.APIBaseURL, "/") + "/" + path
}
