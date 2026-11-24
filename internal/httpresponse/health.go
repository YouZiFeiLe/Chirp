package httpresponse

import (
	"context"
	"net/http"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
)

type databasePinger interface{ Ping(context.Context) error }

func Health(db databasePinger, service string, trackers ...*logging.FailureTracker) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		err := db.Ping(ctx)
		for _, tracker := range trackers {
			tracker.Observe(r.Context(), err)
		}
		if err != nil {
			Error(w, http.StatusServiceUnavailable, "DATABASE_UNAVAILABLE", "数据库暂时不可用")
			return
		}
		JSON(w, http.StatusOK, map[string]string{"status": "ok", "service": service})
	}
}
