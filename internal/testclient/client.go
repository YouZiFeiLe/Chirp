// Package testclient builds native client fixtures from a test store's version policy.
package testclient

import (
	"context"
	"fmt"
	"net/http"
	"strconv"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func Latest(ctx context.Context, db *store.Store, platform string) (store.ClientIdentity, error) {
	policies, err := db.ClientVersionPolicies(ctx)
	if err != nil {
		return store.ClientIdentity{}, err
	}
	for _, p := range policies {
		if p.Platform == platform {
			return store.ClientIdentity{Platform: p.Platform, Version: p.LatestVersion, Build: p.LatestBuild}, nil
		}
	}
	return store.ClientIdentity{}, fmt.Errorf("missing %s client version policy", platform)
}

func MustLatest(t *testing.T, db *store.Store, platform string) store.ClientIdentity {
	t.Helper()
	client, err := Latest(t.Context(), db, platform)
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func SetHeaders(r *http.Request, client store.ClientIdentity) {
	r.Header.Set("X-Chirp-Platform", client.Platform)
	r.Header.Set("X-Chirp-Version", client.Version)
	r.Header.Set("X-Chirp-Build", strconv.Itoa(client.Build))
}
