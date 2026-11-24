package config

import "testing"

func TestPasskeyUsesUnifiedOrigin(t *testing.T) {
	setDatabaseEnv(t)
	t.Setenv("CHIRP_PUBLIC_ORIGIN", "https://chirp.youzifeile.cn")
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	p := c.Passkey()
	if !p.SecureCookies || p.RPID != "chirp.youzifeile.cn" || len(p.Origins) != 1 || p.Origins[0] != c.PublicOrigin || p.DeviceVerificationURL != c.PublicOrigin+"/device" {
		t.Fatal(p)
	}
	t.Setenv("CHIRP_PUBLIC_ORIGIN", "http://localhost:18115")
	c, err = Load()
	if err != nil || c.Passkey().SecureCookies || c.Passkey().RPID != "localhost" {
		t.Fatal(c, err)
	}
}
