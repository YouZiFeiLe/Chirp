package config

import (
	"errors"
	"net/url"
	"strconv"
	"strings"
)

// LogServer is independent of media/public configuration, including for CLI
// maintenance. A disabled server does not require a URL or a network connection.
func LogServer() (bool, string, error) {
	enabled, err := strconv.ParseBool(env("CHIRP_LOG_SERVER_ENABLED", "false"))
	if err != nil {
		return false, "", errors.New("CHIRP_LOG_SERVER_ENABLED must be true or false")
	}
	if !enabled {
		return false, "", nil
	}
	raw := strings.TrimSpace(env("CHIRP_LOG_SERVER_URL", ""))
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" || (u.Scheme != "https" && u.Scheme != "http") || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || strings.Contains(raw, "#") {
		return false, "", errors.New("CHIRP_LOG_SERVER_URL must be a VictoriaLogs HTTP(S) base URL without credentials, query or fragment")
	}
	if u.Port() != "" {
		port, err := strconv.Atoi(u.Port())
		if err != nil || port < 1 || port > 65535 {
			return false, "", errors.New("CHIRP_LOG_SERVER_URL port must be between 1 and 65535")
		}
	}
	return true, strings.TrimRight(u.String(), "/"), nil
}
