package httpapi

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"hash/crc32"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

func avatarFixture(t *testing.T) []byte {
	t.Helper()
	im := image.NewRGBA(image.Rect(0, 0, 6, 2))
	for y := range 2 {
		for x := range 6 {
			c := color.RGBA{R: 255, A: 255}
			if x == 2 || x == 3 {
				c = color.RGBA{G: 255, A: 255}
			}
			im.SetRGBA(x, y, c)
		}
	}
	var data bytes.Buffer
	if err := png.Encode(&data, im); err != nil {
		t.Fatal(err)
	}
	return data.Bytes()
}

func TestAvatarNormalizesPixelsAndRejectsHugeDimensionsBeforeDecode(t *testing.T) {
	input := avatarFixture(t)
	normalized, err := normalizeAvatar(append(bytes.Clone(input), []byte("private-source-payload")...))
	if err != nil {
		t.Fatal(err)
	}
	im, err := png.Decode(bytes.NewReader(normalized))
	if err != nil || im.Bounds() != image.Rect(0, 0, 512, 512) {
		t.Fatal("incorrect normalized size", err)
	}
	for _, point := range []image.Point{{0, 0}, {255, 255}, {511, 511}} {
		if color.RGBAModel.Convert(im.At(point.X, point.Y)) != (color.RGBA{G: 255, A: 255}) {
			t.Fatal("center crop did not preserve pixels")
		}
	}
	if bytes.Contains(normalized, []byte("private-source-payload")) {
		t.Fatal("original ancillary data was retained")
	}
	var jpg bytes.Buffer
	if err := jpeg.Encode(&jpg, im, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := normalizeAvatar(jpg.Bytes()); err != nil {
		t.Fatal("valid JPEG rejected", err)
	}
	huge := bytes.Clone(input)
	binary.BigEndian.PutUint32(huge[16:20], 8193)
	binary.BigEndian.PutUint32(huge[29:33], crc32.ChecksumIEEE(huge[12:29]))
	if _, err := normalizeAvatar(huge); !errors.Is(err, errAvatarDimensions) {
		t.Fatal("huge dimensions were not rejected before pixel decode", err)
	}
	for _, bad := range [][]byte{nil, []byte("<svg></svg>"), input[:len(input)/2]} {
		if _, err := normalizeAvatar(bad); err == nil {
			t.Fatal("invalid image accepted")
		}
	}
}

func TestProfileAPIEnforcesOwnershipUploadLimitsAndAvatarVersions(t *testing.T) {
	ctx := context.Background()
	db, err := store.Open(ctx, testdb.Path(t))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	member, token, err := db.AddMember(ctx, "Oliver")
	if err != nil {
		t.Fatal(err)
	}
	other, otherToken, err := db.AddMember(ctx, "Alice")
	if err != nil {
		t.Fatal(err)
	}
	handler := New(db, &fakeMedia{}, room.Issuer{}, "", "https://auth.example.com", slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := func(method, path, credential, contentType string, data []byte, chunked bool, status int) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(method, path, bytes.NewReader(data))
		if chunked {
			r.ContentLength = -1
		}
		if credential != "" {
			r.Header.Set("Authorization", "Bearer "+credential)
		}
		r.Header.Set("Content-Type", contentType)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != status {
			t.Fatalf("%s %s: got %d want %d: %s", method, path, w.Code, status, w.Body.String())
		}
		return w
	}
	profile := func(w *httptest.ResponseRecorder) store.MemberProfile {
		t.Helper()
		var p store.MemberProfile
		if err := json.Unmarshal(w.Body.Bytes(), &p); err != nil {
			t.Fatal(err)
		}
		return p
	}
	request("GET", "/v1/members", "", "", nil, false, 401)
	request("PATCH", "/v1/me", "", "application/json", []byte(`{"display_name":"new"}`), false, 401)
	request("PUT", "/v1/me/avatar", "", "image/png", avatarFixture(t), false, 401)
	request("DELETE", "/v1/me/avatar", "", "", nil, false, 401)
	for _, body := range []string{`null`, `{}`, `{"display_name":"\n"}`, `{"display_name":"new","enabled":true}`, `{"display_name":"new","id":"` + other.ID + `"}`, `{"display_name":"new"} {}`} {
		request("PATCH", "/v1/me", token, "application/json", []byte(body), false, 400)
	}
	p := profile(request("PATCH", "/v1/me", token, "application/json", []byte(`{"display_name":"  朋友 😀  "}`), false, 200))
	if p.ID != member.ID || p.DisplayName != "朋友 😀" || p.ProfileRevision != 1 {
		t.Fatal("rename did not update only own display name", p)
	}
	if got, _ := db.MemberProfile(ctx, other.ID); got.DisplayName != other.DisplayName {
		t.Fatal("another account was modified")
	}
	input := avatarFixture(t)
	request("PUT", "/v1/me/avatar", token, "image/svg+xml", []byte("<svg/>"), false, 415)
	request("PUT", "/v1/me/avatar", token, "image/png", []byte("forged-image"), false, 400)
	request("PUT", "/v1/me/avatar", token, "image/png", make([]byte, store.MaxAvatarBytes), false, 413)
	request("PUT", "/v1/me/avatar", token, "image/png", make([]byte, store.MaxAvatarBytes+1), true, 413)
	nearLimit := append(bytes.Clone(input), make([]byte, store.MaxAvatarBytes-1-len(input))...)
	p = profile(request("PUT", "/v1/me/avatar", token, "image/png", nearLimit, true, 200))
	if p.AvatarRevision == "" || p.ProfileRevision != 2 {
		t.Fatal("avatar version missing", p)
	}
	path := "/v1/members/" + member.ID + "/avatar/" + p.AvatarRevision
	request("GET", path, "", "", nil, false, 401)
	avatar := request("GET", path, otherToken, "", nil, false, 200)
	if avatar.Header().Get("Content-Type") != "image/png" || avatar.Header().Get("X-Content-Type-Options") != "nosniff" || avatar.Body.Len() >= len(nearLimit) {
		t.Fatal("avatar was not normalized")
	}
	r := httptest.NewRequest("GET", path, nil)
	r.Header.Set("Authorization", "Bearer "+otherToken)
	r.Header.Set("If-None-Match", avatar.Header().Get("ETag"))
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 304 || w.Body.Len() != 0 {
		t.Fatal("conditional avatar read failed")
	}
	listed := request("GET", "/v1/members", otherToken, "", nil, false, 200)
	for _, private := range []string{"credential", "login_id", "image_data", "created_at"} {
		if strings.Contains(listed.Body.String(), private) {
			t.Fatal("public profile response contains private fields", private)
		}
	}
	if got := profile(request("GET", "/v1/me", token, "", nil, false, 200)); got.AvatarRevision != p.AvatarRevision {
		t.Fatal("current profile lost avatar revision")
	}
	// A changed avatar invalidates the old version URL.
	var changed bytes.Buffer
	if err := jpeg.Encode(&changed, image.NewRGBA(image.Rect(0, 0, 2, 2)), nil); err != nil {
		t.Fatal(err)
	}
	profile(request("PUT", "/v1/me/avatar", token, "image/jpeg", changed.Bytes(), false, 200))
	request("GET", path, otherToken, "", nil, false, 404)
	p = profile(request("DELETE", "/v1/me/avatar", token, "", nil, false, 200))
	if p.AvatarRevision != "" || p.ProfileRevision != 4 {
		t.Fatal("avatar deletion did not update profile", p)
	}
	request("DELETE", "/v1/me/avatar", token, "", nil, false, 200)
	if err := db.DisableMember(ctx, member.ID); err != nil {
		t.Fatal(err)
	}
	request("PATCH", "/v1/me", token, "application/json", []byte(`{"display_name":"restore"}`), false, 403)
	request("PUT", "/v1/me/avatar", token, "image/png", input, false, 403)
}
