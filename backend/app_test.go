package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestNaturalLess(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"audio2.opus", "audio10.opus", true},
		{"audio10.opus", "audio2.opus", false},
		{"PTT-20261002-WA0002.opus", "PTT-20261002-WA0010.opus", true},
		{"PTT-20261001-WA0099.opus", "PTT-20261002-WA0001.opus", true},
		{"a", "a", false},
		{"a", "ab", true},
		{"WhatsApp Audio 2026-10-02 at 09.05.11.opus", "WhatsApp Audio 2026-10-02 at 17.41.03.opus", true},
	}
	for _, c := range cases {
		if got := naturalLess(c.a, c.b); got != c.want {
			t.Errorf("naturalLess(%q,%q)=%v, want %v", c.a, c.b, got, c.want)
		}
	}
}

func TestCleanTranscript(t *testing.T) {
	got := cleanTranscript(" Hola\n  mundo [BLANK_AUDIO] (música) ok ")
	if got != "Hola mundo ok" {
		t.Fatalf("got %q", got)
	}
}

type fakes struct {
	whisper, ollama *httptest.Server
	whisperCalls    atomic.Int32
	chatCalls       atomic.Int32
	failWhisperOnce atomic.Bool
	mu              sync.Mutex
	prompts         []string
}

func newFakes(t *testing.T) *fakes {
	f := &fakes{}
	f.whisper = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/inference" {
			fmt.Fprint(w, "ok")
			return
		}
		f.whisperCalls.Add(1)
		if err := r.ParseMultipartForm(32 << 20); err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		if r.FormValue("language") != "es" || r.FormValue("response_format") != "json" {
			http.Error(w, "parámetros incorrectos", 400)
			return
		}
		if f.failWhisperOnce.CompareAndSwap(true, false) {
			http.Error(w, `{"error":"boom"}`, 500)
			return
		}
		json.NewEncoder(w).Encode(map[string]string{"text": " Hola, esto es una prueba larga del audio para comprobar que la transcripción funciona " +
			"correctamente y que el resumen se genera sin problemas con más de veinte palabras en total. [BLANK_AUDIO]"})
	}))
	f.ollama = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/tags":
			fmt.Fprint(w, `{"models":[{"name":"qwen2.5:7b"}]}`)
		case "/api/chat":
			f.chatCalls.Add(1)
			var req struct {
				Messages  []struct{ Role, Content string } `json:"messages"`
				Stream    bool                             `json:"stream"`
				KeepAlive string                           `json:"keep_alive"`
			}
			json.NewDecoder(r.Body).Decode(&req)
			if req.Stream || req.KeepAlive == "" {
				http.Error(w, "stream/keep_alive incorrectos", 400)
				return
			}
			f.mu.Lock()
			f.prompts = append(f.prompts, req.Messages[1].Content)
			f.mu.Unlock()
			json.NewEncoder(w).Encode(map[string]any{"message": map[string]string{"content": "Resumen de prueba."}})
		}
	}))
	t.Cleanup(func() { f.whisper.Close(); f.ollama.Close() })
	return f
}

type testEnv struct {
	srv   *httptest.Server
	store *Store
	cfg   Config
	f     *fakes
}

func newEnv(t *testing.T) *testEnv {
	t.Helper()
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg no instalado")
	}
	f := newFakes(t)
	dir := t.TempDir()
	web := filepath.Join(dir, "web")
	os.MkdirAll(web, 0o755)
	os.WriteFile(filepath.Join(web, "index.html"), []byte("<html>app</html>"), 0o644)
	cfg := Config{DataDir: dir, TmpDir: filepath.Join(dir, "tmp"), WebDir: web, WhisperURL: f.whisper.URL, WhisperLang: "es", WhisperPrompt: "x",
		OllamaURL: f.ollama.URL, OllamaModel: "qwen2.5:7b", OllamaKeepAlive: "30s", OllamaNumCtx: 8192,
		RetentionDays: 7, MaxUploadBytes: 64 << 20, AllowedHosts: []string{"localhost", "127.0.0.1", "::1"}}
	hub := NewHub()
	store, err := NewStore(dir, hub)
	if err != nil {
		t.Fatal(err)
	}
	worker := NewWorker(store, NewWhisper(cfg), NewOllama(cfg), cfg.TmpDir)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go worker.Run(ctx)
	api := &API{cfg: cfg, store: store, worker: worker, hub: hub, whisper: NewWhisper(cfg), ollama: NewOllama(cfg)}
	srv := httptest.NewServer(api.Handler())
	t.Cleanup(srv.Close)
	return &testEnv{srv: srv, store: store, cfg: cfg, f: f}
}

func makeAudio(t *testing.T, dir, name string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	cmd := exec.Command("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", p)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("ffmpeg: %v %s", err, out)
	}
	return p
}

func (e *testEnv) do(t *testing.T, method, path string, body []byte, ctype string) (*http.Response, []byte) {
	t.Helper()
	req, _ := http.NewRequest(method, e.srv.URL+path, bytes.NewReader(body))
	if ctype != "" {
		req.Header.Set("Content-Type", ctype)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var buf bytes.Buffer
	buf.ReadFrom(resp.Body)
	return resp, buf.Bytes()
}

func (e *testEnv) createSession(t *testing.T) Session {
	resp, body := e.do(t, "POST", "/api/sessions", []byte(`{}`), "application/json")
	if resp.StatusCode != 201 {
		t.Fatalf("crear sesión: %d %s", resp.StatusCode, body)
	}
	var s Session
	json.Unmarshal(body, &s)
	return s
}

func (e *testEnv) upload(t *testing.T, id string, files map[string]string) {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for name, path := range files {
		fw, _ := mw.CreateFormFile("files", name)
		raw, _ := os.ReadFile(path)
		fw.Write(raw)
	}
	mw.Close()
	resp, body := e.do(t, "POST", "/api/sessions/"+id+"/audios", buf.Bytes(), mw.FormDataContentType())
	if resp.StatusCode != 202 {
		t.Fatalf("subida: %d %s", resp.StatusCode, body)
	}
}

func (e *testEnv) wait(t *testing.T, id string, cond func(*Session) bool) Session {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		var s Session
		resp, body := e.do(t, "GET", "/api/sessions/"+id, nil, "")
		if resp.StatusCode == 200 {
			json.Unmarshal(body, &s)
			if cond(&s) {
				return s
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("timeout esperando a la sesión")
	return Session{}
}

func allSettled(s *Session) bool {
	if len(s.Items) == 0 || s.busy() {
		return false
	}
	return true
}

func TestPipelineMultipleAudios(t *testing.T) {
	e := newEnv(t)
	tmp := t.TempDir()
	a := makeAudio(t, tmp, "a.wav")
	sess := e.createSession(t)
	e.upload(t, sess.ID, map[string]string{
		"PTT-20261002-WA0010.opus": a, "PTT-20261002-WA0002.opus": a, "PTT-20261002-WA0001.opus": a,
	})
	s := e.wait(t, sess.ID, allSettled)

	if len(s.Items) != 3 {
		t.Fatalf("items=%d", len(s.Items))
	}
	want := []string{"PTT-20261002-WA0001.opus", "PTT-20261002-WA0002.opus", "PTT-20261002-WA0010.opus"}
	for i, it := range s.Items {
		if it.Name != want[i] {
			t.Errorf("orden: pos %d = %s, want %s", i, it.Name, want[i])
		}
		if it.Status != StatusDone || it.Text == "" || it.Summary != "Resumen de prueba." {
			t.Errorf("item %d incompleto: %+v", i, it)
		}
		if strings.Contains(it.Text, "BLANK_AUDIO") {
			t.Errorf("texto sin limpiar: %q", it.Text)
		}
		if it.DurationSec < 0.9 || it.DurationSec > 1.1 {
			t.Errorf("duración %v", it.DurationSec)
		}
		if len(it.Wave) != waveBins {
			t.Errorf("forma de onda de %d barras, quería %d", len(it.Wave), waveBins)
		}
	}
	if s.Global.Status != GlobalDone || s.Global.Text == "" || s.Global.Items != 3 {
		t.Errorf("resumen general: %+v", s.Global)
	}
	if !strings.HasPrefix(s.Title, "Hola, esto es una prueba") || s.TitleAuto != true {
		t.Errorf("título automático: %q", s.Title)
	}
	if got := e.f.chatCalls.Load(); got != 4 {
		t.Errorf("llamadas al LLM = %d, quería 4 (3 audios + 1 general)", got)
	}
	// El último prompt es el general e incluye los 3 audios en orden.
	last := e.f.prompts[len(e.f.prompts)-1]
	if !strings.Contains(last, "[Audio 3]") || !strings.Contains(last, "3 audios") {
		t.Errorf("prompt general inesperado: %.200s", last)
	}
	// Archivos visibles en la carpeta de la sesión.
	dir := filepath.Join(e.cfg.DataDir, "sessions", sess.ID)
	for _, p := range []string{"session.json", "resumen-general.txt", "texto/01-PTT-20261002-WA0001.txt", "audio"} {
		if _, err := os.Stat(filepath.Join(dir, p)); err != nil {
			t.Errorf("falta %s: %v", p, err)
		}
	}
	// El WAV temporal se borra.
	if left, _ := os.ReadDir(e.cfg.TmpDir); len(left) != 0 {
		t.Errorf("quedaron temporales: %v", left)
	}

	// Segunda subida: el resumen general se recalcula con los 4 audios.
	e.upload(t, sess.ID, map[string]string{"PTT-20261003-WA0001.opus": a})
	s = e.wait(t, sess.ID, func(s *Session) bool {
		return allSettled(s) && len(s.Items) == 4 && s.Global.Items == 4 && s.Global.Status == GlobalDone
	})
	if s.Items[3].Name != "PTT-20261003-WA0001.opus" {
		t.Errorf("el nuevo audio debe ir al final")
	}

	// Borrado manual.
	resp, _ := e.do(t, "DELETE", "/api/sessions/"+sess.ID, nil, "")
	if resp.StatusCode != 204 {
		t.Fatalf("delete: %d", resp.StatusCode)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("la carpeta debería haberse borrado")
	}
	if resp, _ := e.do(t, "GET", "/api/sessions/"+sess.ID, nil, ""); resp.StatusCode != 404 {
		t.Errorf("GET tras borrar: %d", resp.StatusCode)
	}
}

func TestSingleAudioHasNoGlobalSummary(t *testing.T) {
	e := newEnv(t)
	a := makeAudio(t, t.TempDir(), "a.wav")
	sess := e.createSession(t)
	e.upload(t, sess.ID, map[string]string{"solo.opus": a})
	s := e.wait(t, sess.ID, allSettled)
	if s.Global.Status != GlobalIdle || e.f.chatCalls.Load() != 1 {
		t.Errorf("global=%+v llamadas=%d", s.Global, e.f.chatCalls.Load())
	}
}

func TestRetryAfterWhisperFailure(t *testing.T) {
	e := newEnv(t)
	a := makeAudio(t, t.TempDir(), "a.wav")
	e.f.failWhisperOnce.Store(true)
	sess := e.createSession(t)
	e.upload(t, sess.ID, map[string]string{"x.opus": a})
	s := e.wait(t, sess.ID, allSettled)
	if s.Items[0].Status != StatusError || !strings.Contains(s.Items[0].Error, "boom") {
		t.Fatalf("esperaba error: %+v", s.Items[0])
	}
	resp, _ := e.do(t, "POST", "/api/sessions/"+sess.ID+"/items/"+s.Items[0].ID+"/retry", nil, "")
	if resp.StatusCode != 202 {
		t.Fatalf("retry: %d", resp.StatusCode)
	}
	s = e.wait(t, sess.ID, func(s *Session) bool { return allSettled(s) && s.Items[0].Status == StatusDone })
	if s.Items[0].Text == "" || s.Items[0].Error != "" {
		t.Errorf("tras reintento: %+v", s.Items[0])
	}
	if resp, _ := e.do(t, "POST", "/api/sessions/"+sess.ID+"/items/"+s.Items[0].ID+"/retry", nil, ""); resp.StatusCode != 409 {
		t.Errorf("reintentar algo ya correcto debe dar 409, dio %d", resp.StatusCode)
	}
}

func TestUnreachableServicesGiveActionableErrors(t *testing.T) {
	e := newEnv(t)
	e.f.whisper.Close()
	a := makeAudio(t, t.TempDir(), "a.wav")
	sess := e.createSession(t)
	e.upload(t, sess.ID, map[string]string{"x.opus": a})
	s := e.wait(t, sess.ID, allSettled)
	if s.Items[0].Status != StatusError || !strings.Contains(s.Items[0].Error, "make up") {
		t.Errorf("error poco útil: %+v", s.Items[0])
	}
}

func TestSummaryFailureKeepsTranscript(t *testing.T) {
	e := newEnv(t)
	e.f.ollama.Close()
	a := makeAudio(t, t.TempDir(), "a.wav")
	sess := e.createSession(t)
	e.upload(t, sess.ID, map[string]string{"x.opus": a})
	s := e.wait(t, sess.ID, allSettled)
	it := s.Items[0]
	if it.Text == "" || it.Status != StatusDone || it.SummaryError == "" {
		t.Errorf("la transcripción debe sobrevivir al fallo del resumen: %+v", it)
	}
}

func TestInvalidAudioFails(t *testing.T) {
	e := newEnv(t)
	bad := filepath.Join(t.TempDir(), "bad.opus")
	os.WriteFile(bad, []byte("esto no es audio"), 0o644)
	sess := e.createSession(t)
	e.upload(t, sess.ID, map[string]string{"bad.opus": bad})
	s := e.wait(t, sess.ID, allSettled)
	if s.Items[0].Status != StatusError || !strings.Contains(s.Items[0].Error, "no se pudo leer el audio") {
		t.Errorf("%+v", s.Items[0])
	}
	if e.f.whisperCalls.Load() != 0 {
		t.Errorf("no debe llamar a Whisper con audio inválido")
	}
}

func TestRetention(t *testing.T) {
	hub := NewHub()
	store, _ := NewStore(t.TempDir(), hub)
	old := store.Create("vieja")
	fresh := store.Create("nueva")
	busy := store.Create("ocupada")
	store.Update(busy.ID, func(s *Session) { s.Items = append(s.Items, &Item{ID: "x", Status: StatusTranscribing}) })
	// Retrasamos UpdatedAt a mano (Update lo refresca, así que tocamos el mapa directamente).
	store.mu.Lock()
	store.sessions[old.ID].UpdatedAt = time.Now().Add(-8 * 24 * time.Hour)
	store.sessions[busy.ID].UpdatedAt = time.Now().Add(-8 * 24 * time.Hour)
	store.mu.Unlock()
	ids := store.Expired(7*24*time.Hour, time.Now())
	if len(ids) != 1 || ids[0] != old.ID {
		t.Fatalf("expired=%v (solo la vieja y sin trabajo en curso)", ids)
	}
	_ = fresh
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { runRetention(ctx, store, 7*24*time.Hour); close(done) }()
	time.Sleep(100 * time.Millisecond)
	cancel()
	<-done
	if len(store.List()) != 2 {
		t.Errorf("tras el barrido debería haber 2 sesiones, hay %d", len(store.List()))
	}
}

func TestPersistenceAndResume(t *testing.T) {
	dir := t.TempDir()
	hub := NewHub()
	st, _ := NewStore(dir, hub)
	sess := st.Create("x")
	st.Update(sess.ID, func(s *Session) {
		s.Items = []*Item{{ID: "a", Status: StatusTranscribing}, {ID: "b", Status: StatusSummarizing, Text: "t"}, {ID: "c", Status: StatusDone}}
	})
	st2, err := NewStore(dir, hub)
	if err != nil {
		t.Fatal(err)
	}
	pending := st2.Pending()
	if got := pending[sess.ID]; len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Fatalf("pendientes=%v", got)
	}
	st2.Read(sess.ID, func(s *Session) {
		if s.Items[0].Status != StatusQueued || s.Items[1].Status != StatusTranscribed {
			t.Errorf("estados tras reiniciar: %s %s", s.Items[0].Status, s.Items[1].Status)
		}
	})
}

func TestOriginProtectionAndSPA(t *testing.T) {
	e := newEnv(t)
	req, _ := http.NewRequest("POST", e.srv.URL+"/api/sessions", strings.NewReader(`{}`))
	req.Header.Set("Origin", "https://evil.example")
	resp, _ := http.DefaultClient.Do(req)
	if resp.StatusCode != 403 {
		t.Errorf("origen ajeno debe dar 403, dio %d", resp.StatusCode)
	}
	resp, body := e.do(t, "GET", "/alguna/ruta/del/cliente", nil, "")
	if resp.StatusCode != 200 || !strings.Contains(string(body), "app") {
		t.Errorf("SPA fallback: %d %s", resp.StatusCode, body)
	}
	resp, _ = e.do(t, "GET", "/api/sessions/no-existe", nil, "")
	if resp.StatusCode != 404 {
		t.Errorf("sesión inexistente: %d", resp.StatusCode)
	}
}

func TestHealth(t *testing.T) {
	e := newEnv(t)
	_, body := e.do(t, "GET", "/api/health", nil, "")
	var h struct {
		Whisper struct{ OK bool } `json:"whisper"`
		Ollama  OllamaStatus      `json:"ollama"`
	}
	json.Unmarshal(body, &h)
	if !h.Whisper.OK || !h.Ollama.OK || !h.Ollama.ModelReady {
		t.Errorf("health: %s", body)
	}
}

func TestLargeGlobalFallsBackToSummaries(t *testing.T) {
	long := strings.Repeat("palabra ", 4000) // 32k caracteres
	sess := &Session{Items: []*Item{
		{ID: "1", Text: long, Summary: "RESUMEN-UNO"},
		{ID: "2", Text: "texto corto", Summary: "RESUMEN-DOS"},
	}}
	in := buildGlobalInput(sess)
	if !strings.Contains(in.prompt, "RESUMEN-UNO") || strings.Contains(in.prompt, "palabra palabra") {
		t.Errorf("con mucho texto debe usar los resúmenes individuales")
	}
}

func TestWaveformIsJSONArray(t *testing.T) {
	raw, _ := json.Marshal(Item{Wave: []int{0, 50, 100}})
	if !strings.Contains(string(raw), `"wave":[0,50,100]`) {
		t.Fatalf("la forma de onda debe serializarse como array JSON: %s", raw)
	}
}

func TestDNSRebindingIsBlocked(t *testing.T) {
	e := newEnv(t)
	for host, want := range map[string]int{
		"evil.example.com":      403,
		"evil.example.com:8080": 403,
		"localhost:8080":        200,
		"127.0.0.1:9":           200,
		"[::1]:8080":            200,
	} {
		req, _ := http.NewRequest("GET", e.srv.URL+"/api/sessions", nil)
		req.Host = host
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != want {
			t.Errorf("Host %q → %d, quería %d", host, resp.StatusCode, want)
		}
	}
}
