package httpapi

import (
	"encoding/json"
	"io"
	"net/http"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func (s *Server) receiveAttachment(w http.ResponseWriter, r *http.Request, m store.Member) {
	if s.attachments == nil {
		httpresponse.Error(w, 503, "ATTACHMENTS_UNAVAILABLE", "附件服务未启用")
		return
	}
	var body struct {
		Digest string `json:"ciphertext_sha256"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || decoder.Decode(new(any)) != io.EOF {
		s.attachmentError(w, r, store.ErrAttachmentInvalid)
		return
	}
	f := s.attachments
	if !f.mu.TryRLock() {
		s.attachmentBusy(w)
		return
	}
	defer f.mu.RUnlock()
	a, err := s.store.ReceiveAttachment(r.Context(), m, r.PathValue("room"), r.Header.Get("X-Chirp-Entry"), r.PathValue("attachment"), body.Digest)
	if err != nil {
		s.attachmentError(w, r, err)
		return
	}
	f.feed.notify(a.RoomID)
	logging.Request(r, s.logger).Info("Attachment receipt accepted", "event", "attachment.received", "room_id", a.RoomID, "attachment_id", a.ID, "state", a.State)
	if a.State == store.AttachmentDelivered {
		if err := f.root.RemoveAll(a.ID); err != nil {
			s.internalError(w, r, err)
			return
		}
	}
	httpresponse.JSON(w, 200, attachmentResponse{Attachment: a, Protocol: store.AttachmentProtocol, ChunkBytes: store.AttachmentChunkBytes})
}
