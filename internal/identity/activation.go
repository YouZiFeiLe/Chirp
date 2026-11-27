package identity

import (
	"net"
	"net/url"
	"strconv"
	"strings"

	"golang.org/x/net/idna"
)

func NormalizeOrigin(value string) (string, error) {
	u, err := url.Parse(value)
	if err != nil || u.User != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return "", ErrInvalid
	}
	host := strings.ToLower(u.Hostname())
	if net.ParseIP(host) == nil {
		host, err = idna.Lookup.ToASCII(host)
		if err != nil {
			return "", ErrInvalid
		}
	}
	port := u.Port()
	if port == "" {
		port = "443"
		if u.Scheme == "http" {
			port = "80"
		}
	}
	number, err := strconv.Atoi(port)
	if err != nil || number < 1 || number > 65535 {
		return "", ErrInvalid
	}
	return u.Scheme + "://" + net.JoinHostPort(host, strconv.Itoa(number)), nil
}

// The one-use server challenge binds Passkey + PKCE to this exact account,
// service and candidate. It conveys no room or shared-data authority.
func ActivationMessage(origin, accountID, clientID, token, verifier, challenge string, device Device) []byte {
	return Message("Chirp identity activation v1", origin, accountID, clientID, Hash([]byte(token)), Hash([]byte(verifier)), challenge, device.AccountKey, device.Hash())
}

const ResumptionTokenPrefix = "resume-v1_"

func ResumptionMessage(origin, platform, participant, token, challenge string, device Device) []byte {
	domain := "Chirp login resumption v1"
	if !strings.HasPrefix(token, ResumptionTokenPrefix) {
		// Only previously issued handles use the pre-versioned Apple format.
		domain = "Chirp Apple login resumption v1"
	}
	return Message(domain, origin, platform, participant, Hash([]byte(token)), challenge, device.Hash())
}
