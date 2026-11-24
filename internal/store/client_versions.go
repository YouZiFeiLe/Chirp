package store

import (
	"cmp"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const MaxClientBuild = 2147483647
const WindowsClientPlatform = "windows"
const AndroidClientPlatform = "android"

var ErrInvalidClientVersion = errors.New("client platform, version, and build are required")
var ErrClientPolicyUnavailable = errors.New("client version policy unavailable")
var ErrInvalidClientPolicy = errors.New("invalid client version policy")
var versionPattern = regexp.MustCompile(`^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$`)

type ClientIdentity struct {
	Platform string `json:"platform"`
	Version  string `json:"version"`
	Build    int    `json:"build"`
}

func ValidClientPlatform(platform string) bool {
	return platform == "ios" || platform == "macos" ||
		platform == WindowsClientPlatform || platform == AndroidClientPlatform
}
func ValidClientVersion(version string) bool { return versionPattern.MatchString(version) }

// compareClientVersion orders validated numeric versions, then builds within the same version.
func compareClientVersion(version string, build int, otherVersion string, otherBuild int) int {
	left, right := strings.Split(version, "."), strings.Split(otherVersion, ".")
	for i := range left {
		a, _ := strconv.Atoi(left[i])
		b, _ := strconv.Atoi(right[i])
		if order := cmp.Compare(a, b); order != 0 {
			return order
		}
	}
	return cmp.Compare(build, otherBuild)
}

func (c ClientIdentity) Valid() bool {
	return ValidClientPlatform(c.Platform) && ValidClientVersion(c.Version) && c.Build > 0 && c.Build <= MaxClientBuild
}

type ClientVersionPolicy struct {
	Platform       string `json:"platform"`
	LatestVersion  string `json:"latest_version"`
	LatestBuild    int    `json:"latest_build"`
	MinimumVersion string `json:"minimum_version"`
	MinimumBuild   int    `json:"minimum_build"`
	UpdatedAt      string `json:"updated_at"`
}

func (p ClientVersionPolicy) Valid() bool {
	return ValidClientPlatform(p.Platform) && ValidClientVersion(p.LatestVersion) && ValidClientVersion(p.MinimumVersion) &&
		p.LatestBuild > 0 && p.LatestBuild <= MaxClientBuild && p.MinimumBuild > 0 && p.MinimumBuild <= MaxClientBuild &&
		compareClientVersion(p.MinimumVersion, p.MinimumBuild, p.LatestVersion, p.LatestBuild) <= 0
}

type ClientUpdateRequired struct{ Policy ClientVersionPolicy }

func (*ClientUpdateRequired) Error() string { return "client update required" }

type clientPolicyReader interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func readClientPolicy(ctx context.Context, reader clientPolicyReader, platform string) (ClientVersionPolicy, error) {
	var p ClientVersionPolicy
	if !ValidClientPlatform(platform) {
		return p, ErrInvalidClientVersion
	}
	err := reader.QueryRowContext(ctx, "SELECT platform, latest_version, latest_build, minimum_version, minimum_build, updated_at FROM client_version_policies WHERE platform = ?", platform).
		Scan(&p.Platform, &p.LatestVersion, &p.LatestBuild, &p.MinimumVersion, &p.MinimumBuild, &p.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return p, ErrClientPolicyUnavailable
	}
	if err == nil && !p.Valid() {
		return p, ErrClientPolicyUnavailable
	}
	if err != nil {
		return p, fmt.Errorf("%w: %v", ErrClientPolicyUnavailable, err)
	}
	return p, nil
}

func checkClientVersion(ctx context.Context, reader clientPolicyReader, c ClientIdentity) (ClientVersionPolicy, error) {
	if !c.Valid() {
		return ClientVersionPolicy{}, ErrInvalidClientVersion
	}
	p, err := readClientPolicy(ctx, reader, c.Platform)
	if err != nil {
		return p, err
	}
	if compareClientVersion(c.Version, c.Build, p.MinimumVersion, p.MinimumBuild) < 0 {
		return p, &ClientUpdateRequired{Policy: p}
	}
	return p, nil
}

func (s *Store) CheckClientVersion(ctx context.Context, c ClientIdentity) (ClientVersionPolicy, error) {
	return checkClientVersion(ctx, s.db, c)
}

func (s *Store) ClientVersionPolicies(ctx context.Context) ([]ClientVersionPolicy, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT platform, latest_version, latest_build, minimum_version, minimum_build, updated_at FROM client_version_policies ORDER BY platform")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	policies := []ClientVersionPolicy{}
	for rows.Next() {
		var p ClientVersionPolicy
		if err := rows.Scan(&p.Platform, &p.LatestVersion, &p.LatestBuild, &p.MinimumVersion, &p.MinimumBuild, &p.UpdatedAt); err != nil {
			return nil, err
		}
		if !p.Valid() {
			return nil, ErrInvalidClientPolicy
		}
		policies = append(policies, p)
	}
	return policies, rows.Err()
}

func (s *Store) UpdateClientVersionPolicy(ctx context.Context, p ClientVersionPolicy) (ClientVersionPolicy, error) {
	if !p.Valid() {
		return ClientVersionPolicy{}, ErrInvalidClientPolicy
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return ClientVersionPolicy{}, err
	}
	defer tx.Rollback()
	p.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	result, err := tx.ExecContext(ctx, "UPDATE client_version_policies SET latest_version = ?, latest_build = ?, minimum_version = ?, minimum_build = ?, updated_at = ? WHERE platform = ?", p.LatestVersion, p.LatestBuild, p.MinimumVersion, p.MinimumBuild, p.UpdatedAt, p.Platform)
	if err = changed(result, err); err != nil {
		return ClientVersionPolicy{}, err
	}
	return p, tx.Commit()
}
