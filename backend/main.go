package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, nil)))
	cfg := loadConfig()

	hub := NewHub()
	store, err := NewStore(cfg.DataDir, hub)
	if err != nil {
		slog.Error("no se pudo abrir el almacén", "err", err)
		os.Exit(1)
	}
	whisper, ollama := NewWhisper(cfg), NewOllama(cfg)
	worker := NewWorker(store, whisper, ollama, cfg.TmpDir)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go worker.Run(ctx)
	if cfg.InboxDir != "" {
		go NewInbox(cfg.InboxDir, store, worker).Run(ctx)
	}
	go runRetention(ctx, store, cfg.retention())
	for session, ids := range store.Pending() {
		slog.Info("reanudando trabajo pendiente", "session", session, "audios", len(ids))
		_ = worker.Enqueue(batch{session: session, items: ids})
	}

	api := &API{cfg: cfg, store: store, worker: worker, hub: hub, whisper: whisper, ollama: ollama, settings: NewSettingsStore(cfg.DataDir)}
	srv := &http.Server{Addr: cfg.Addr, Handler: api.Handler(), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()

	slog.Info("escuchando", "addr", cfg.Addr, "data", cfg.DataDir, "retención_días", cfg.RetentionDays)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("servidor detenido", "err", err)
		os.Exit(1)
	}
}
