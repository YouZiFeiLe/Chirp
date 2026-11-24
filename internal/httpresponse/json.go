package httpresponse

import (
	"encoding/json"
	"net/http"
)

func Error(w http.ResponseWriter, status int, code, message string) {
	if recorder, ok := w.(interface{ RecordError(string) }); ok {
		recorder.RecordError(code)
	}
	JSON(w, status, struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}{Error: struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}{code, message}})
}

func JSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
