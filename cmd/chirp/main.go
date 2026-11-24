package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/application"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/config"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpserver"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

var version = "0.14.0-dev"

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "chirp:", err)
		os.Exit(1)
	}
}

func run(args []string, output io.Writer) error {
	if len(args) == 0 {
		args = []string{"serve"}
	}
	if len(args) == 1 && (args[0] == "help" || args[0] == "-h" || args[0] == "--help") {
		_, err := fmt.Fprintln(output, "chirp serve | version | authorization -generate-key|-export-trust|-verify-trust FILE [-key-file FILE] | admin bootstrap --request-id ID | admin grant --id MEMBER_ID | admin grant --request-id ID | admin revoke --id MEMBER_ID | admin reopen-registration | member list|disable --id MEMBER_ID")
		return err
	}
	if len(args) == 1 && args[0] == "version" {
		return json.NewEncoder(output).Encode(map[string]any{"version": version, "service": "chirp", "database_engine": "sqlite", "sqlite_target_version": store.SQLiteVersion, "schema": store.SchemaVersion})
	}
	if len(args) == 1 && args[0] == "healthcheck" {
		client := &http.Client{Timeout: 2 * time.Second}
		response, err := client.Get("http://127.0.0.1:18115/healthz")
		if err != nil {
			return err
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			return errors.New("application unavailable")
		}
		return nil
	}
	if args[0] == "authorization" {
		return manageAuthorization(args[1:], output)
	}
	if args[0] == "admin" || args[0] == "member" {
		return manage(args, output)
	}
	if len(args) != 1 || args[0] != "serve" {
		return errors.New("unknown command; run chirp help")
	}
	return serve()
}

func openLogger() (*slog.Logger, io.Closer, error) {
	_, serverURL, err := config.LogServer()
	if err != nil {
		return nil, nil, err
	}
	levelText := os.Getenv("CHIRP_LOG_LEVEL")
	if levelText == "" {
		levelText = "info"
	}
	var level slog.Level
	if err := level.UnmarshalText([]byte(levelText)); err != nil {
		return nil, nil, fmt.Errorf("invalid CHIRP_LOG_LEVEL: %w", err)
	}
	logger, sink, err := logging.Open(logging.Options{Level: level, ServerURL: serverURL})
	if err != nil {
		return nil, nil, err
	}
	return logger.With("version", version), sink, nil
}

func serve() (result error) {
	logger, sink, err := openLogger()
	if err != nil {
		return err
	}
	previous := slog.Default()
	slog.SetDefault(logger)
	defer slog.SetDefault(previous)
	defer func() {
		if result != nil {
			logger.Error("Application stopped with an error", "event", "application.failed", "error", result)
		} else {
			logger.Info("Application stopped", "event", "application.stopped")
		}
		if err := sink.Close(); err != nil {
			result = errors.Join(result, fmt.Errorf("close application logs: %w", err))
		}
	}()
	logger.Info("Application starting", "event", "application.starting", "timezone", time.Now().Format("MST -07:00"))
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	if err := cfg.ValidateServer(); err != nil {
		return err
	}
	mode := "local"
	if cfg.LogServerEnabled {
		mode = "victorialogs"
	}
	logger.Info("Application configuration loaded", "event", "application.configured", "log_mode", mode, "log_level", cfg.LogLevel, "listen", cfg.ListenAddr)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	db, err := store.Open(ctx, cfg.DatabasePath)
	if err != nil {
		return fmt.Errorf("open database: %w", err)
	}
	logger.Info("Database ready", "event", "database.ready", "schema", store.SchemaVersion, "path", db.Path())
	defer func() {
		if err := db.Close(); err != nil {
			logger.Error("Database close failed", "event", "database.close_failed", "error", err)
		}
	}()
	app, err := application.New(db, room.New(cfg.LiveKitHTTPURL, cfg.LiveKitAPIKey, cfg.LiveKitAPISecret), cfg, logger)
	if err != nil {
		return err
	}
	app.Start(ctx)
	defer func() {
		stop()
		if err := app.Close(); err != nil {
			logger.Error("Application shutdown failed", "event", "application.shutdown_failed", "error", err)
		}
	}()
	return httpserver.Serve(ctx, cfg.ListenAddr, app, logger)
}

// Local management loads only the database path, so it also works during media/config failures.
func manage(args []string, output io.Writer) (result error) {
	if len(args) < 2 {
		return errors.New("a management operation is required; run chirp help")
	}
	operation := args[0] + " " + args[1]
	switch operation {
	case "admin bootstrap", "admin grant", "admin revoke", "admin reopen-registration", "member list", "member disable":
	default:
		return errors.New("unknown management operation; run chirp help")
	}
	flags := flag.NewFlagSet(operation, flag.ContinueOnError)
	flags.SetOutput(output)
	var identifier *string
	if operation == "admin bootstrap" {
		identifier = flags.String("request-id", "", "registration receipt from /register")
	} else if operation != "member list" && operation != "admin reopen-registration" {
		identifier = flags.String("id", "", "member ID")
	}
	var registration *string
	if operation == "admin grant" {
		registration = flags.String("request-id", "", "approve a pending registration as administrator")
	}
	if err := flags.Parse(args[2:]); err != nil {
		return err
	}
	if flags.NArg() != 0 || (identifier != nil && *identifier == "" && (registration == nil || *registration == "")) || (registration != nil && *registration != "" && *identifier != "") {
		return errors.New("provide the required identifier; run chirp help")
	}
	path, err := config.DatabasePath()
	if err != nil {
		return err
	}
	// Logging must never prevent emergency local maintenance of the database.
	logger, sink, logErr := openLogger()
	if logErr != nil {
		logger = slog.New(slog.NewJSONHandler(os.Stderr, nil)).With("service", "chirp", "module", "cli")
		logger.Error("CLI log initialization failed", "event", "logging.cli_init_failed", "error", logErr)
	}
	defer func() {
		attrs := []any{"event", "admin.cli_operation", "operation", operation, "success", result == nil}
		if identifier != nil && operation != "admin bootstrap" && *identifier != "" {
			attrs = append(attrs, "target_member_id", *identifier)
		}
		if result != nil {
			logger.Warn("Local maintenance failed", append(attrs, "error", result)...)
		} else {
			logger.Info("Local maintenance completed", attrs...)
		}
		if sink != nil {
			if err := sink.Close(); err != nil {
				fmt.Fprintln(os.Stderr, "chirp: close CLI logs:", err)
			}
		}
	}()
	ctx := context.Background()
	db, err := store.Open(ctx, path)
	if err != nil {
		return err
	}
	defer db.Close()
	switch operation {
	case "admin bootstrap":
		member, err := db.BootstrapAdministrator(ctx, *identifier)
		if err != nil {
			return err
		}
		return json.NewEncoder(output).Encode(member)
	case "admin grant", "admin revoke":
		if registration != nil && *registration != "" {
			member, err := db.GrantAdministratorRegistration(ctx, *registration)
			if err != nil {
				return err
			}
			return json.NewEncoder(output).Encode(member)
		}
		return db.SetAdministrator(ctx, *identifier, operation == "admin grant")
	case "admin reopen-registration":
		return db.SetRegistrationClosed(ctx, false)
	case "member list":
		members, err := db.ListMembers(ctx)
		if err != nil {
			return err
		}
		return json.NewEncoder(output).Encode(members)
	case "member disable":
		return db.DisableMember(ctx, *identifier)
	}
	return nil
}
