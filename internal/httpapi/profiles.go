package httpapi

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func (s *Server) getProfiles(w http.ResponseWriter, r *http.Request, _ store.Member) {
	profiles, err := s.store.MemberProfiles(r.Context())
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, struct {
		Members []store.MemberProfile `json:"members"`
	}{profiles})
}

func (s *Server) updateProfile(w http.ResponseWriter, r *http.Request, member store.Member) {
	var request struct {
		DisplayName string `json:"display_name"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2048))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil || decoder.Decode(new(any)) != io.EOF {
		httpresponse.Error(w, 400, "BAD_REQUEST", "请提交有效的昵称")
		return
	}
	p, err := s.store.UpdateOwnDisplayName(r.Context(), member, request.DisplayName)
	if err != nil {
		s.profileError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, p)
}

func (s *Server) putAvatar(w http.ResponseWriter, r *http.Request, member store.Member) {
	controller := http.NewResponseController(w)
	_ = controller.SetReadDeadline(time.Now().Add(time.Minute))
	_ = controller.SetWriteDeadline(time.Now().Add(time.Minute))
	if r.ContentLength >= store.MaxAvatarBytes {
		httpresponse.Error(w, 413, "AVATAR_TOO_LARGE", "头像图片须小于 5 MB")
		return
	}
	contentType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || (contentType != "image/png" && contentType != "image/jpeg") {
		httpresponse.Error(w, 415, "AVATAR_FORMAT_UNSUPPORTED", "请上传静态 JPEG 或 PNG 图片")
		return
	}
	// Bound concurrent full image decodes independently of the SQL write lock.
	select {
	case s.avatarProcessing <- struct{}{}:
		defer func() { <-s.avatarProcessing }()
	default:
		w.Header().Set("Retry-After", "1")
		httpresponse.Error(w, 429, "AVATAR_BUSY", "头像处理繁忙，请稍后重试")
		return
	}
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, store.MaxAvatarBytes))
	var tooLarge *http.MaxBytesError
	if errors.As(err, &tooLarge) || len(data) >= store.MaxAvatarBytes {
		httpresponse.Error(w, 413, "AVATAR_TOO_LARGE", "头像图片须小于 5 MB")
		return
	}
	if err != nil {
		httpresponse.Error(w, 400, "AVATAR_INVALID", "无法读取头像图片")
		return
	}
	normalized, err := normalizeAvatar(data)
	if errors.Is(err, errAvatarDimensions) {
		httpresponse.Error(w, 400, "AVATAR_DIMENSIONS_EXCEEDED", "图片尺寸过大，请缩小后重试")
		return
	}
	if err != nil {
		httpresponse.Error(w, 400, "AVATAR_INVALID", "图片无效，请选择其他图片")
		return
	}
	p, err := s.store.SetOwnAvatar(r.Context(), member, normalized)
	if err != nil {
		s.profileError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, p)
}

func (s *Server) deleteAvatar(w http.ResponseWriter, r *http.Request, member store.Member) {
	p, err := s.store.DeleteOwnAvatar(r.Context(), member)
	if err != nil {
		s.profileError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, p)
}

func (s *Server) getAvatar(w http.ResponseWriter, r *http.Request, _ store.Member) {
	revision := r.PathValue("revision")
	hash, err := hex.DecodeString(revision)
	if err != nil || len(hash) != 32 || len(revision) != 64 {
		s.profileError(w, r, store.ErrNotFound)
		return
	}
	data, err := s.store.MemberAvatar(r.Context(), r.PathValue("member"), revision)
	if err != nil {
		s.profileError(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "private, no-cache")
	etag := `"` + revision + `"`
	w.Header().Set("ETag", etag)
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func (s *Server) profileError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, store.ErrInvalidName):
		httpresponse.Error(w, 400, "INVALID_DISPLAY_NAME", "昵称须为 1–80 个字符，不能包含控制字符")
	case errors.Is(err, store.ErrProfileSessionChanged):
		httpresponse.Error(w, 401, "UNAUTHORIZED", "登录已失效，请重新认证")
	case errors.Is(err, store.ErrNotFound):
		httpresponse.Error(w, 404, "MEMBER_NOT_FOUND", "成员资料或头像不存在")
	default:
		s.internalError(w, r, err)
	}
}
