// Package application composes the public API, authorization, Passkey, admin UI and group coordinator.
package application

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"sync"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/adminhttp"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/authorization"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/config"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpapi"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/passkeyhttp"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

type Media interface {
	room.Backend
	room.AdminBackend
}

type Application struct {
	http.Handler
	db            *store.Store
	media         Media
	group         *group.Server
	files         *httpapi.AttachmentStorage
	authorization *authorization.Server
	logger        *slog.Logger
	cancel        context.CancelFunc
	wg            sync.WaitGroup
}

func New(db *store.Store, media Media, cfg config.Config, logger *slog.Logger) (*Application, error) {
	passkey, err := passkeyhttp.New(db, cfg.Passkey(), logger.With("module", "passkey"))
	if err != nil {
		return nil, err
	}
	key, err := authorization.ReadKeyFile(cfg.AuthorizationKeyFile)
	if err != nil {
		return nil, fmt.Errorf("read authorization signing key: %w", err)
	}
	origin, err := identity.NormalizeOrigin(cfg.PublicOrigin)
	if err != nil {
		clear(key)
		return nil, err
	}
	authorizations, err := authorization.Open(cfg.AuthorizationDatabasePath, origin, key)
	clear(key)
	if err != nil {
		return nil, fmt.Errorf("open authorization database: %w", err)
	}
	files, err := httpapi.NewAttachmentStorage(db, cfg.AttachmentPath, cfg.AuthorizationDatabasePath, cfg.AuthorizationKeyFile)
	if err != nil {
		_ = authorizations.Close()
		return nil, err
	}
	logger.Info("Attachment storage ready", "event", "attachments.ready", "directory", cfg.AttachmentPath)
	policy := group.DefaultPolicy()
	policy.Rotation = cfg.GroupRotation
	groups := group.New(db, policy, logger.With("module", "group"), cfg.PublicOrigin)
	directory := room.NewDirectory(media, groups.LiveIdentities, logger.With("module", "media"))
	api := httpapi.NewWithAttachments(db, media, room.Issuer{APIKey: cfg.LiveKitAPIKey, APISecret: cfg.LiveKitAPISecret, TTL: cfg.TokenTTL}, cfg.LiveKitWSURL, cfg.PublicOrigin, logger.With("module", "api"), cfg.ClientEndpoints, files, authorizations.DeviceRevoked, directory)
	admin := adminhttp.NewWithDirectory(db, media, cfg.LiveKitWSURL, logger.With("module", "admin"), directory, groups)
	app := &Application{db: db, media: media, group: groups, files: files, authorization: authorizations, logger: logger}
	mux := http.NewServeMux()
	health := logging.FailureTracker{Logger: logger.With("module", "database"), Event: "database.health"}
	mux.HandleFunc("GET /healthz", httpresponse.Health(app, "chirp", &health))
	mux.HandleFunc("GET /livez", func(w http.ResponseWriter, r *http.Request) {
		httpresponse.JSON(w, 200, map[string]string{"service": "chirp", "status": "ok"})
	})
	mux.HandleFunc("GET /admin", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/admin/", http.StatusPermanentRedirect)
	})
	mux.Handle("/admin/", admin)
	mux.Handle("/internal/", http.NotFoundHandler())
	mux.Handle("/authorization/", http.StripPrefix("/authorization", authorizations.Handler()))
	mux.Handle("/v1/group/", groups)
	mux.Handle("/v1/", api)
	mux.Handle("/", passkey)
	app.Handler = mux
	return app, nil
}

func (a *Application) Ping(ctx context.Context) error {
	return errors.Join(a.db.Ping(ctx), a.authorization.Ping(ctx))
}

func (a *Application) Start(parent context.Context) {
	ctx, cancel := context.WithCancel(parent)
	a.cancel = cancel
	for _, run := range []func(context.Context){
		a.group.Monitor,
		func(ctx context.Context) { httpapi.MonitorSessions(ctx, a.db, a.media, a.logger) },
		func(ctx context.Context) { a.files.Monitor(ctx, a.logger) },
	} {
		a.wg.Add(1)
		go func(run func(context.Context)) { defer a.wg.Done(); run(ctx) }(run)
	}
	a.logger.Info("Background monitors started", "event", "application.monitors_started", "monitors", 3)
}

// Call after HTTP requests have drained; the store belongs to the caller.
func (a *Application) Close() error {
	if a.cancel != nil {
		a.cancel()
	}
	a.wg.Wait()
	return errors.Join(a.files.Close(), a.authorization.Close())
}
