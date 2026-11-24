package config

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	ListenAddr                string
	DatabasePath              string
	AuthorizationDatabasePath string
	AuthorizationKeyFile      string
	AttachmentPath            string
	PublicOrigin              string
	LiveKitHTTPURL            string
	LiveKitWSURL              string
	LiveKitAPIKey             string
	LiveKitAPISecret          string
	TokenTTL                  time.Duration
	GroupRotation             time.Duration
	LogLevel                  string
	LogServerEnabled          bool
	LogServerURL              string
	ClientEndpoints           ClientEndpoints
}

func Load() (Config, error) {
	c := Config{
		ListenAddr:       env("CHIRP_LISTEN_ADDR", "127.0.0.1:18115"),
		LiveKitHTTPURL:   env("LIVEKIT_HTTP_URL", "http://livekit:7880"),
		LiveKitAPIKey:    os.Getenv("LIVEKIT_API_KEY"),
		LiveKitAPISecret: os.Getenv("LIVEKIT_API_SECRET"),
		LogLevel:         env("CHIRP_LOG_LEVEL", "info"),
	}
	if _, _, err := net.SplitHostPort(c.ListenAddr); err != nil {
		return c, fmt.Errorf("invalid CHIRP_LISTEN_ADDR: %w", err)
	}
	var err error
	c.LogServerEnabled, c.LogServerURL, err = LogServer()
	if err != nil {
		return c, err
	}
	c.PublicOrigin, err = PublicPasskeyOrigin(env("CHIRP_PUBLIC_ORIGIN", "https://chirp.youzifeile.cn"))
	if err != nil {
		return c, fmt.Errorf("CHIRP_PUBLIC_ORIGIN: %w", err)
	}
	origin, _ := url.Parse(c.PublicOrigin)
	if origin.Scheme == "https" {
		origin.Scheme = "wss"
	} else {
		origin.Scheme = "ws"
	}
	c.LiveKitWSURL = origin.String()
	c.ClientEndpoints = DefaultClientEndpoints(c.PublicOrigin)
	c.TokenTTL, err = time.ParseDuration(env("CHIRP_TOKEN_TTL", "5m"))
	if err != nil || c.TokenTTL < time.Second || c.TokenTTL > 15*time.Minute {
		return c, errors.New("CHIRP_TOKEN_TTL must be between 1s and 15m")
	}
	c.GroupRotation, err = time.ParseDuration(env("CHIRP_GROUP_ROTATION", "60s"))
	if err != nil || c.GroupRotation < 30*time.Second || c.GroupRotation > 30*time.Minute {
		return c, errors.New("CHIRP_GROUP_ROTATION must be between 30s and 30m")
	}
	c.DatabasePath, err = DatabasePath()
	if err == nil {
		c.AttachmentPath = env("CHIRP_ATTACHMENT_PATH", filepath.Join(filepath.Dir(c.DatabasePath), "attachments"))
		c.AuthorizationDatabasePath, c.AuthorizationKeyFile, err = authorizationPaths(c.DatabasePath)
	}
	if path := os.Getenv("CHIRP_LIVEKIT_KEYS_FILE"); err == nil && path != "" {
		c.LiveKitAPISecret, err = liveKitFileSecret(path, c.LiveKitAPIKey)
	}
	return c, err
}

// PublicPasskeyOrigin is a browser-facing origin, never a Docker upstream URL.
func PublicPasskeyOrigin(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" || strings.ContainsAny(u.Host, "*\\") || u.User != nil ||
		(u.Path != "" && u.Path != "/") || u.RawPath != "" || strings.ContainsAny(raw, "?#") {
		return "", errors.New("an exact HTTPS origin without credentials, path, query or fragment is required")
	}
	if u.Port() != "" {
		port, err := strconv.Atoi(u.Port())
		if err != nil || port < 1 || port > 65535 {
			return "", errors.New("origin port must be between 1 and 65535")
		}
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && u.Hostname() == "localhost") {
		return "", errors.New("HTTPS is required; HTTP is allowed only for localhost development")
	}
	u.Path = ""
	u.Host = strings.ToLower(u.Host)
	if (u.Scheme == "https" && u.Port() == "443") || (u.Scheme == "http" && u.Port() == "80") {
		u.Host = strings.TrimSuffix(u.Host, ":"+u.Port())
	}
	return u.String(), nil
}

func (c Config) ValidateServer() error {
	if c.LiveKitAPIKey == "" || len(c.LiveKitAPISecret) < 32 {
		return errors.New("LIVEKIT_API_KEY and a LIVEKIT_API_SECRET of at least 32 characters are required")
	}
	if err := ValidateURL(c.LiveKitHTTPURL, false); err != nil {
		return fmt.Errorf("LIVEKIT_HTTP_URL: %w", err)
	}
	if err := ValidateURL(c.LiveKitWSURL, true); err != nil {
		return fmt.Errorf("LIVEKIT_WS_URL: %w", err)
	}
	return nil
}

// ValidateURL rejects Cloud endpoints and limits plaintext to local endpoints or internal management.
func ValidateURL(raw string, websocket bool) error {
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("a server URL without credentials, query or fragment is required")
	}
	host := strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")
	for _, cloud := range []string{"livekit.cloud", "livekit.run", "livekit.io"} {
		if host == cloud || strings.HasSuffix(host, "."+cloud) {
			return errors.New("LiveKit Cloud endpoints are not allowed")
		}
	}
	secure, plain := "https", "http"
	if websocket {
		secure, plain = "wss", "ws"
	}
	if u.Scheme != secure && u.Scheme != plain {
		return fmt.Errorf("URL scheme must be %s", secure)
	}
	if u.Scheme == plain {
		ip := net.ParseIP(host)
		local := host == "localhost" || (ip != nil && ip.IsLoopback())
		// The Compose service name is resolved on the project's bridge network.
		// This exception applies only to server management, never client WebSocket URLs.
		if !websocket && (host == "livekit" || (ip != nil && ip.IsPrivate())) {
			local = true
		}
		if !local {
			return errors.New("plaintext URLs are only allowed for local or private server management")
		}
	}
	return nil
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
