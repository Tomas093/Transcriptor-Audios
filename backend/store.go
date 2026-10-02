package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"
)

// Estados de un audio. El flujo normal es
// queued → converting → transcribing → transcribed → summarizing → done.
const (
	StatusQueued       = "queued"
	StatusConverting   = "converting"
	StatusTranscribing = "transcribing"
	StatusTranscribed  = "transcribed"
	StatusSummarizing  = "summarizing"
	StatusDone         = "done"
	StatusError        = "error"
)

// Estados del resumen general.
const (
	GlobalIdle    = "idle"
	GlobalWorking = "working"
	GlobalDone    = "done"
	GlobalError   = "error"
)

var idRe = regexp.MustCompile(`^\d{8}-\d{4}-[0-9a-f]{8}$`)

func validID(id string) bool { return idRe.MatchString(id) }

type Item struct {
	ID             string    `json:"id"`
	Name           string    `json:"name"`
	File           string    `json:"file"`
	Size           int64     `json:"size"`
	Status         string    `json:"status"`
	Text           string    `json:"text"`
	Summary        string    `json:"summary"`
	SummarySkipped bool      `json:"summarySkipped,omitempty"`
	Error          string    `json:"error,omitempty"`
	SummaryError   string    `json:"summaryError,omitempty"`
	DurationSec    float64   `json:"durationSec,omitempty"`
	Wave           []int     `json:"wave,omitempty"`
	AddedAt        time.Time `json:"addedAt"`
}

type Global struct {
	Status string `json:"status"`
	Text   string `json:"text"`
	Error  string `json:"error,omitempty"`
	Hash   string `json:"hash,omitempty"`
	Items  int    `json:"items"`
}

type Session struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	TitleAuto bool      `json:"titleAuto"`
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
	Items     []*Item   `json:"items"`
	Global    Global    `json:"global"`
}

type SessionInfo struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
	ItemCount int       `json:"itemCount"`
	Busy      bool      `json:"busy"`
}

func isBusyStatus(s string) bool {
	switch s {
	case StatusQueued, StatusConverting, StatusTranscribing, StatusTranscribed, StatusSummarizing:
		return true
	}
	return false
}

func (s *Session) busy() bool {
	if s.Global.Status == GlobalWorking {
		return true
	}
	for _, it := range s.Items {
		if isBusyStatus(it.Status) {
			return true
		}
	}
	return false
}

func (s *Session) info() SessionInfo {
	return SessionInfo{ID: s.ID, Title: s.Title, CreatedAt: s.CreatedAt, UpdatedAt: s.UpdatedAt,
		ItemCount: len(s.Items), Busy: s.busy()}
}

func (s *Session) item(id string) *Item {
	for _, it := range s.Items {
		if it.ID == id {
			return it
		}
	}
	return nil
}

func randHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// Store guarda las sesiones en memoria y las persiste como carpetas en disco:
//
//	<dir>/sessions/<id>/session.json   estado completo
//	<dir>/sessions/<id>/audio/         audios originales
//	<dir>/sessions/<id>/texto/         transcripción + resumen de cada audio (.txt)
//	<dir>/sessions/<id>/resumen-general.txt
type Store struct {
	root     string
	hub      *Hub
	mu       sync.RWMutex
	sessions map[string]*Session
}

func NewStore(dataDir string, hub *Hub) (*Store, error) {
	st := &Store{root: filepath.Join(dataDir, "sessions"), hub: hub, sessions: map[string]*Session{}}
	if err := os.MkdirAll(st.root, 0o755); err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(st.root)
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		if !e.IsDir() || !validID(e.Name()) {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(st.root, e.Name(), "session.json"))
		if err != nil {
			continue
		}
		var sess Session
		if err := json.Unmarshal(raw, &sess); err != nil {
			slog.Warn("sesión ilegible, se ignora", "id", e.Name(), "err", err)
			continue
		}
		if sess.Items == nil {
			sess.Items = []*Item{}
		}
		st.sessions[sess.ID] = &sess
	}
	return st, nil
}

func (s *Store) sessionDir(id string) string { return filepath.Join(s.root, id) }
func (s *Store) audioDir(id string) string   { return filepath.Join(s.sessionDir(id), "audio") }

func (s *Store) AudioPath(sessionID, file string) string {
	return filepath.Join(s.audioDir(sessionID), filepath.Base(file))
}

func (s *Store) persistLocked(sess *Session) error {
	dir := s.sessionDir(sess.ID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(sess, "", "  ")
	if err != nil {
		return err
	}
	tmp := filepath.Join(dir, "session.json.tmp")
	if err := os.WriteFile(tmp, raw, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(dir, "session.json"))
}

func (s *Store) publish(sess *Session) {
	data, err := json.Marshal(sess)
	if err == nil {
		s.hub.Publish(Event{Name: "session", Data: data})
	}
}

func (s *Store) Create(title string) *Session {
	now := time.Now()
	sess := &Session{
		ID:        now.Format("20060102-1504") + "-" + randHex(4),
		Title:     title,
		TitleAuto: true,
		CreatedAt: now,
		UpdatedAt: now,
		Items:     []*Item{},
		Global:    Global{Status: GlobalIdle},
	}
	s.mu.Lock()
	s.sessions[sess.ID] = sess
	if err := s.persistLocked(sess); err != nil {
		slog.Error("no se pudo guardar la sesión", "id", sess.ID, "err", err)
	}
	s.mu.Unlock()
	s.publish(sess)
	return sess
}

// Update aplica fn bajo bloqueo, persiste y avisa a los clientes. Devuelve false si la
// sesión ya no existe (p. ej. se borró mientras se procesaba).
func (s *Store) Update(id string, fn func(*Session)) bool {
	s.mu.Lock()
	sess, ok := s.sessions[id]
	if !ok {
		s.mu.Unlock()
		return false
	}
	fn(sess)
	sess.UpdatedAt = time.Now()
	if err := s.persistLocked(sess); err != nil {
		slog.Error("no se pudo guardar la sesión", "id", id, "err", err)
	}
	data, _ := json.Marshal(sess)
	s.mu.Unlock()
	s.hub.Publish(Event{Name: "session", Data: data})
	return true
}

// Read ejecuta fn con la sesión bloqueada para lectura.
func (s *Store) Read(id string, fn func(*Session)) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	sess, ok := s.sessions[id]
	if ok {
		fn(sess)
	}
	return ok
}

func (s *Store) Snapshot(id string) ([]byte, bool) {
	var data []byte
	ok := s.Read(id, func(sess *Session) { data, _ = json.Marshal(sess) })
	return data, ok
}

func (s *Store) List() []SessionInfo {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]SessionInfo, 0, len(s.sessions))
	for _, sess := range s.sessions {
		out = append(out, sess.info())
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UpdatedAt.After(out[j].UpdatedAt) })
	return out
}

func (s *Store) Delete(id string) bool {
	s.mu.Lock()
	_, ok := s.sessions[id]
	delete(s.sessions, id)
	s.mu.Unlock()
	if !ok {
		return false
	}
	if err := os.RemoveAll(s.sessionDir(id)); err != nil {
		slog.Error("no se pudo borrar la carpeta de la sesión", "id", id, "err", err)
	}
	data, _ := json.Marshal(map[string]string{"id": id})
	s.hub.Publish(Event{Name: "deleted", Data: data})
	return true
}

// Expired devuelve las sesiones sin actividad desde hace más de maxAge y que no están
// procesando nada.
func (s *Store) Expired(maxAge time.Duration, now time.Time) []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var ids []string
	for id, sess := range s.sessions {
		if now.Sub(sess.UpdatedAt) > maxAge && !sess.busy() {
			ids = append(ids, id)
		}
	}
	return ids
}

// Pending lista, por sesión, los audios que quedaron a medias (p. ej. tras un reinicio)
// y los deja listos para reprocesarse.
func (s *Store) Pending() map[string][]string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string][]string{}
	for id, sess := range s.sessions {
		changed := false
		for _, it := range sess.Items {
			switch it.Status {
			case StatusConverting, StatusTranscribing:
				it.Status, changed = StatusQueued, true
			case StatusSummarizing:
				it.Status, changed = StatusTranscribed, true
			}
			if isBusyStatus(it.Status) {
				out[id] = append(out[id], it.ID)
			}
		}
		if sess.Global.Status == GlobalWorking {
			sess.Global.Status, sess.Global.Hash, changed = GlobalIdle, "", true
			if _, ok := out[id]; !ok {
				out[id] = []string{}
			}
		}
		if changed {
			_ = s.persistLocked(sess)
		}
	}
	return out
}

func safeName(name string) string {
	name = strings.TrimSuffix(name, filepath.Ext(name))
	var b strings.Builder
	for _, r := range name {
		switch {
		case unicode.IsLetter(r) || unicode.IsDigit(r) || r == '-' || r == '_' || r == '.':
			b.WriteRune(r)
		default:
			b.WriteRune('_')
		}
	}
	out := b.String()
	if len(out) > 60 {
		out = out[:60]
	}
	if out == "" {
		out = "audio"
	}
	return out
}

// ExportFiles escribe en la carpeta de la sesión versiones .txt legibles desde el Finder.
func (s *Store) ExportFiles(id string) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	sess, ok := s.sessions[id]
	if !ok {
		return
	}
	dir := filepath.Join(s.sessionDir(id), "texto")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		slog.Error("no se pudo crear la carpeta de texto", "err", err)
		return
	}
	for i, it := range sess.Items {
		if it.Text == "" {
			continue
		}
		body := it.Text + "\n"
		if it.Summary != "" && !it.SummarySkipped {
			body += "\n--- Resumen ---\n" + it.Summary + "\n"
		}
		file := filepath.Join(dir, fmt.Sprintf("%02d-%s.txt", i+1, safeName(it.Name)))
		if err := os.WriteFile(file, []byte(body), 0o644); err != nil {
			slog.Error("no se pudo escribir la transcripción", "err", err)
		}
	}
	general := filepath.Join(s.sessionDir(id), "resumen-general.txt")
	if sess.Global.Status == GlobalDone && sess.Global.Text != "" {
		_ = os.WriteFile(general, []byte(sess.Global.Text+"\n"), 0o644)
	} else {
		_ = os.Remove(general)
	}
}

// Markdown devuelve la sesión completa como texto, para copiar o descargar.
func (sess *Session) Markdown() string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n", sess.Title)
	if sess.Global.Status == GlobalDone && sess.Global.Text != "" {
		fmt.Fprintf(&b, "## Resumen general\n\n%s\n\n", sess.Global.Text)
	}
	for i, it := range sess.Items {
		fmt.Fprintf(&b, "## %d. %s\n\n", i+1, it.Name)
		if it.Summary != "" && !it.SummarySkipped {
			fmt.Fprintf(&b, "**Resumen:** %s\n\n", it.Summary)
		}
		if it.Text != "" {
			fmt.Fprintf(&b, "%s\n\n", it.Text)
		} else if it.Error != "" {
			fmt.Fprintf(&b, "_Sin transcripción: %s_\n\n", it.Error)
		}
	}
	return b.String()
}
