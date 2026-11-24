package config

import (
	"fmt"
	"net/url"
	"strconv"
	"strings"
)

// Relative URLs resolve against the API base address entered by the user.
type ClientEndpoints struct {
	APIBaseURL            string `json:"api_base_url"`
	HealthURL             string `json:"health_url"`
	AuthorizationURL      string `json:"authorization_url"`
	RegistrationURL       string `json:"registration_url"`
	TokenURL              string `json:"token_url"`
	DeviceStartURL        string `json:"device_start_url"`
	DevicePollURL         string `json:"device_poll_url"`
	DeviceCancelURL       string `json:"device_cancel_url"`
	DeviceVerificationURL string `json:"device_verification_url"`
	GroupBaseURL          string `json:"group_base_url"`
}

func DefaultClientEndpoints(origin string) ClientEndpoints {
	origin = strings.TrimRight(origin, "/")
	return ClientEndpoints{origin + "/", origin + "/healthz", origin + "/", origin + "/register", origin + "/api/client/exchange",
		origin + "/api/client/device/start", origin + "/api/client/device/poll", origin + "/api/client/device/cancel",
		origin + "/device", origin + "/v1/group"}
}

func (c ClientEndpoints) Validate(origin string) error {
	trusted, err := url.Parse(origin)
	if err != nil {
		return err
	}
	for _, raw := range []string{c.APIBaseURL, c.HealthURL, c.AuthorizationURL, c.RegistrationURL, c.TokenURL, c.DeviceStartURL, c.DevicePollURL, c.DeviceCancelURL, c.DeviceVerificationURL, c.GroupBaseURL} {
		u, err := url.Parse(raw)
		if err != nil || raw == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || strings.Contains(raw, "#") || (u.Host != "" && u.Scheme == "") {
			return fmt.Errorf("invalid public client endpoint")
		}
		if port := u.Port(); port != "" {
			n, err := strconv.Atoi(port)
			if err != nil || n < 1 || n > 65535 {
				return fmt.Errorf("invalid public endpoint port")
			}
		}
		if strings.Contains(u.Hostname(), "*") {
			return fmt.Errorf("public endpoints require an exact host")
		}
		if u.IsAbs() && (u.Hostname() == "" || (u.Scheme != "https" && !(u.Scheme == "http" && (u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1" || u.Hostname() == "::1")))) {
			return fmt.Errorf("client endpoints require HTTPS, except loopback development")
		}
	}
	for _, raw := range []string{c.AuthorizationURL, c.RegistrationURL, c.TokenURL, c.DeviceStartURL, c.DevicePollURL, c.DeviceCancelURL, c.DeviceVerificationURL} {
		u, err := url.Parse(raw)
		if err != nil || u.Scheme != trusted.Scheme || u.Host != trusted.Host {
			return fmt.Errorf("authentication endpoints must belong to CHIRP_PUBLIC_ORIGIN")
		}
	}
	return nil
}
