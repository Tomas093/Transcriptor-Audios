package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

type API struct {
	cfg     Config
	store   *Store
	worker  *Worker
	hub     *Hub
	whisper *Whisper
	ollama  *Ollama
}

func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", a.health)
	mux.HandleFunc("GET /api/events", a.events)
	mux.HandleFunc("GET /api/sessions", a.listSessions)
	mux.HandleFunc("POST /api/sessions", a.createSession)
	mux.HandleFunc("GET /api/sessions/{id}", a.getSession)
	mux.HandleFunc("PATCH /api/sessions/{id}", a.renameSession)
	mux.HandleFunc("DELETE /api/sessions/{id}", a.deleteSession)
	mux.HandleFunc("GET /api/sessions/{id}/export", a.exportSession)
	mux.HandleFunc("POST /api/sessions/{id}/audios", a.upload)
	mux.HandleFunc("POST /api/sessions/{id}/items/{item}/retry", a.retryItem)
	mux.HandleFunc("POST /api/sessions/{id}/global/retry", a.retryGlobal)
	mux.Handle("/", spa(a.cfg.WebDir))
	return secure(mux, a.cfg.AllowedHosts)
}

// hostName devuelve el host de una cabecera Host sin el puerto ("localhost:8080" → "localhost").
func hostName(hostport string) string {
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		return h
	}
	return strings.Trim(hostport, "[]")
}

// secure añade cabeceras de seguridad y dos defensas para una app que escucha en localhost:
//   - Host permitido: evita el DNS rebinding (una web ajena que apunta su dominio a 127.0.0.1
//     y así leería tus transcripciones como si fuera "su mismo origen").
//   - Origin igual al Host en peticiones que cambian estado: evita POST/DELETE desde otras webs.
func secure(next http.Handler, allowedHosts []string) http.Handler {
	allowed := map[string]bool{}
	for _, h := range allowedHosts {
		allowed[strings.ToLower(h)] = true
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if len(allowed) > 0 && !allowed[strings.ToLower(hostName(r.Host))] {
			writeErr(w, http.StatusForbidden, "host no permitido")
			return
		}
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'")
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			if origin := r.Header.Get("Origin"); origin != "" {
				if u, err := url.Parse(origin); err != nil || u.Host != r.Host {
					writeErr(w, http.StatusForbidden, "origen no permitido")
					return
				}
			}
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func writeRaw(w http.ResponseWriter, status int, data []byte) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_, _ = w.Write(data)
}

func (a *API) health(w http.ResponseWriter, r *http.Request) {
	type svc struct {
		OK    bool   `json:"ok"`
		Error string `json:"error,omitempty"`
	}
	out := struct {
		Whisper       svc          `json:"whisper"`
		Ollama        OllamaStatus `json:"ollama"`
		RetentionDays int          `json:"retentionDays"`
	}{RetentionDays: a.cfg.RetentionDays}
	if err := a.whisper.Ping(r.Context()); err != nil {
		out.Whisper = svc{Error: err.Error()}
	} else {
		out.Whisper.OK = true
	}
	out.Ollama = a.ollama.Status(r.Context())
	writeJSON(w, http.StatusOK, out)
}

func (a *API) events(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "streaming no soportado")
		return
	}
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	h.Set("X-Accel-Buffering", "no")
	fmt.Fprint(w, "retry: 2000\n\n")
	fl.Flush()
	ch, cancel := a.hub.Subscribe()
	defer cancel()
	tick := time.NewTicker(20 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case e := <-ch:
			fmt.Fprintf(w, "event: %s\ndata: %s\n\n", e.Name, e.Data)
			fl.Flush()
		case <-tick.C:
			fmt.Fprint(w, ": ping\n\n")
			fl.Flush()
		}
	}
}

func (a *API) listSessions(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, a.store.List())
}

func (a *API) createSession(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Title string `json:"title"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&in)
	title := strings.TrimSpace(in.Title)
	if title == "" {
		title = "Nueva sesión"
	}
	sess := a.store.Create(title)
	data, _ := a.store.Snapshot(sess.ID)
	writeRaw(w, http.StatusCreated, data)
}

func (a *API) getSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if data, ok := a.store.Snapshot(id); ok {
		writeRaw(w, http.StatusOK, data)
		return
	}
	writeErr(w, http.StatusNotFound, "sesión no encontrada")
}

func (a *API) renameSession(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Title string `json:"title"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "JSON inválido")
		return
	}
	title := strings.TrimSpace(in.Title)
	if title == "" || len(title) > 200 {
		writeErr(w, http.StatusBadRequest, "el título debe tener entre 1 y 200 caracteres")
		return
	}
	if !a.store.Update(r.PathValue("id"), func(s *Session) { s.Title, s.TitleAuto = title, false }) {
		writeErr(w, http.StatusNotFound, "sesión no encontrada")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) deleteSession(w http.ResponseWriter, r *http.Request) {
	if !a.store.Delete(r.PathValue("id")) {
		writeErr(w, http.StatusNotFound, "sesión no encontrada")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) exportSession(w http.ResponseWriter, r *http.Request) {
	var md, title string
	if !a.store.Read(r.PathValue("id"), func(s *Session) { md, title = s.Markdown(), s.Title }) {
		writeErr(w, http.StatusNotFound, "sesión no encontrada")
		return
	}
	w.Header().Set("Content-Type", "text/markdown; charset=utf-8")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s.md"`, safeName(title)))
	_, _ = io.WriteString(w, md)
}

var extRe = regexp.MustCompile(`^\.[a-z0-9]{1,6}$`)

func (a *API) upload(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !a.store.Read(id, func(*Session) {}) {
		writeErr(w, http.StatusNotFound, "sesión no encontrada")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, a.cfg.MaxUploadBytes)
	mr, err := r.MultipartReader()
	if err != nil {
		writeErr(w, http.StatusBadRequest, "se esperaba multipart/form-data")
		return
	}
	if err := os.MkdirAll(a.store.audioDir(id), 0o755); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	var items []*Item
	cleanup := func() {
		for _, it := range items {
			_ = os.Remove(a.store.AudioPath(id, it.File))
		}
	}
	for {
		part, err := mr.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			cleanup()
			var mbe *http.MaxBytesError
			if errors.As(err, &mbe) {
				writeErr(w, http.StatusRequestEntityTooLarge, "la subida es demasiado grande")
				return
			}
			writeErr(w, http.StatusBadRequest, "subida inválida")
			return
		}
		if part.FormName() != "files" || part.FileName() == "" {
			continue
		}
		name := filepath.Base(strings.ReplaceAll(part.FileName(), "\\", "/"))
		ext := strings.ToLower(filepath.Ext(name))
		if !extRe.MatchString(ext) {
			ext = ".bin"
		}
		itemID := randHex(4)
		file := itemID + ext
		out, err := os.Create(a.store.AudioPath(id, file))
		if err != nil {
			cleanup()
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		n, err := io.Copy(out, part)
		out.Close()
		if err != nil {
			_ = os.Remove(a.store.AudioPath(id, file))
			cleanup()
			writeErr(w, http.StatusBadRequest, "no se pudo recibir el archivo")
			return
		}
		items = append(items, &Item{ID: itemID, Name: name, File: file, Size: n, Status: StatusQueued, AddedAt: time.Now()})
	}
	if len(items) == 0 {
		writeErr(w, http.StatusBadRequest, "no se recibió ningún archivo")
		return
	}
	// Dentro de una misma subida, orden natural por nombre (WhatsApp numera por fecha).
	sort.SliceStable(items, func(i, j int) bool { return naturalLess(items[i].Name, items[j].Name) })
	ids := make([]string, len(items))
	for i, it := range items {
		ids[i] = it.ID
	}
	if !a.store.Update(id, func(s *Session) { s.Items = append(s.Items, items...) }) {
		cleanup()
		_ = os.RemoveAll(a.store.sessionDir(id)) // la sesión se borró durante la subida
		writeErr(w, http.StatusNotFound, "sesión no encontrada")
		return
	}
	if err := a.worker.Enqueue(batch{session: id, items: ids}); err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	data, _ := a.store.Snapshot(id)
	writeRaw(w, http.StatusAccepted, data)
}

func (a *API) retryItem(w http.ResponseWriter, r *http.Request) {
	id, itemID := r.PathValue("id"), r.PathValue("item")
	found, retryable := false, false
	a.store.Update(id, func(s *Session) {
		it := s.item(itemID)
		if it == nil {
			return
		}
		found = true
		switch {
		case it.Status == StatusError:
			it.Status, it.Error, retryable = StatusQueued, "", true
		case it.Status == StatusDone && it.SummaryError != "":
			it.Status, it.SummaryError, retryable = StatusTranscribed, "", true
		}
	})
	switch {
	case !found:
		writeErr(w, http.StatusNotFound, "audio no encontrado")
	case !retryable:
		writeErr(w, http.StatusConflict, "este audio no necesita reintento")
	default:
		if err := a.worker.Enqueue(batch{session: id, items: []string{itemID}}); err != nil {
			writeErr(w, http.StatusServiceUnavailable, err.Error())
			return
		}
		w.WriteHeader(http.StatusAccepted)
	}
}

func (a *API) retryGlobal(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !a.store.Update(id, func(s *Session) { s.Global.Hash = "" }) {
		writeErr(w, http.StatusNotFound, "sesión no encontrada")
		return
	}
	if err := a.worker.Enqueue(batch{session: id}); err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	w.WriteHeader(http.StatusAccepted)
}

// spa sirve la web compilada; cualquier ruta desconocida cae en index.html.
func spa(dir string) http.Handler {
	files := http.FileServer(http.Dir(dir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := filepath.Join(dir, filepath.Clean("/"+r.URL.Path))
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			if strings.HasPrefix(r.URL.Path, "/assets/") {
				w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
			} else {
				w.Header().Set("Cache-Control", "no-cache")
			}
			files.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-cache")
		http.ServeFile(w, r, filepath.Join(dir, "index.html"))
	})
}

// runRetention borra las sesiones sin actividad desde hace más de RetentionDays.
func runRetention(ctx context.Context, store *Store, maxAge time.Duration) {
	if maxAge <= 0 {
		slog.Info("borrado automático desactivado")
		return
	}
	sweep := func() {
		for _, id := range store.Expired(maxAge, time.Now()) {
			if store.Delete(id) {
				slog.Info("sesión caducada borrada", "id", id)
			}
		}
	}
	sweep()
	t := time.NewTicker(time.Hour)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			sweep()
		}
	}
}
