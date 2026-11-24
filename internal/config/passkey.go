package config

import "net/url"

type PasskeyConfig struct {
	RPID                  string
	Origins               []string
	DeviceVerificationURL string
	SecureCookies         bool
}

// Passkey uses the same configured origin as the API, admin UI and signaling.
func (c Config) Passkey() PasskeyConfig {
	u, _ := url.Parse(c.PublicOrigin)
	return PasskeyConfig{RPID: u.Hostname(), Origins: []string{c.PublicOrigin},
		DeviceVerificationURL: c.PublicOrigin + "/device", SecureCookies: u.Scheme == "https"}
}
