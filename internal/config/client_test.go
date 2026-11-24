package config

import "testing"

func TestClientEndpointsUseOneOrigin(t *testing.T) {
	c := DefaultClientEndpoints("https://chirp.youzifeile.cn")
	if err := c.Validate("https://chirp.youzifeile.cn"); err != nil {
		t.Fatal(err)
	}
	if c.APIBaseURL != "https://chirp.youzifeile.cn/" || c.GroupBaseURL != "https://chirp.youzifeile.cn/v1/group" || c.HealthURL != "https://chirp.youzifeile.cn/healthz" {
		t.Fatal(c)
	}
}

func TestClientEndpointsRejectUnsafeURLsAndForeignAuthenticationOrigin(t *testing.T) {
	for _, raw := range []string{"", "http://public.example.test", "//public.example.test/path", "https://user:password@public.example.test", "https://public.example.test:65536", "https://public.example.test?", "https://public.example.test#", "javascript:alert(1)"} {
		c := DefaultClientEndpoints("https://keys.example.test")
		c.GroupBaseURL = raw
		if c.Validate("https://keys.example.test") == nil {
			t.Fatalf("unsafe endpoint accepted: %q", raw)
		}
	}
	c := DefaultClientEndpoints("https://keys.example.test")
	c.TokenURL = "https://other.example.test/token"
	if c.Validate("https://keys.example.test") == nil {
		t.Fatal("authentication crosses trusted origin")
	}
}
