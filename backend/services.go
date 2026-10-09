package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Modo nativo (sin Docker): la app arranca Whisper y Ollama como procesos hijos y los apaga al
// salir, así `up`/`down` son un solo proceso que encender o parar. Si ya estaban en marcha (por
// ejemplo la app de Ollama), se reutilizan y no se tocan. En Docker (MANAGE_SERVICES vacío) los
// lanzan los scripts del host, como antes.

// ServiceSpec describe un servicio nativo a supervisar.
type ServiceSpec struct {
	Name     string   // "whisper" | "ollama": también nombre del log y del fichero .pid
	Bin      string   // ejecutable
	Args     []string // argumentos
	Env      []string // variables extra
	Health   string   // URL que responde cuando está listo
	Wait     time.Duration
	LowPrio  bool // prioridad baja (Whisper): el equipo sigue fluido mientras transcribe
	LogDir   string
	pidFile  string
	cmd      *exec.Cmd
	exited   chan struct{}
	adopted  int // pid de un proceso nuestro que sobrevivió a una salida brusca de la app
	reused   bool
	stopping bool
}

func serviceSpecs(c Config) ([]*ServiceSpec, error) {
	wport, err := urlPort(c.WhisperURL)
	if err != nil {
		return nil, fmt.Errorf("WHISPER_URL: %w", err)
	}
	oport, err := urlPort(c.OllamaURL)
	if err != nil {
		return nil, fmt.Errorf("OLLAMA_URL: %w", err)
	}
	if c.WhisperModel == "" {
		return nil, errors.New("falta WHISPER_MODEL (ruta al modelo de Whisper)")
	}
	wargs := []string{"-m", c.WhisperModel, "--host", "127.0.0.1", "--port", wport, "-t", strconv.Itoa(c.WhisperThreads)}
	wargs = append(wargs, strings.Fields(c.WhisperFlags)...)
	return []*ServiceSpec{
		{Name: "whisper", Bin: c.WhisperBin, Args: wargs, Health: strings.TrimRight(c.WhisperURL, "/") + "/", Wait: 120 * time.Second, LowPrio: true, LogDir: c.LogDir},
		{Name: "ollama", Bin: c.OllamaBin, Args: []string{"serve"}, Health: strings.TrimRight(c.OllamaURL, "/") + "/api/tags", Wait: 45 * time.Second, LogDir: c.LogDir,
			// Un solo modelo en memoria, sin paralelismo y descarga rápida cuando no se usa.
			Env: []string{"OLLAMA_HOST=127.0.0.1:" + oport, "OLLAMA_KEEP_ALIVE=30s", "OLLAMA_MAX_LOADED_MODELS=1", "OLLAMA_NUM_PARALLEL=1"}},
	}, nil
}

func urlPort(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", err
	}
	if p := u.Port(); p != "" {
		return p, nil
	}
	return "", fmt.Errorf("sin puerto en %q", raw)
}

func httpUp(ctx context.Context, u string) bool {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return false
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return true
}

// Start deja el servicio listo: lo reutiliza si ya responde o lo arranca y espera a que responda.
func (s *ServiceSpec) Start(ctx context.Context) error {
	s.pidFile = filepath.Join(s.LogDir, s.Name+".pid")
	if httpUp(ctx, s.Health) {
		// ¿Es un hijo nuestro de una ejecución anterior que terminó mal? Entonces es nuestro y se apaga al salir.
		if pid := readPid(s.pidFile); pid > 0 && processAlive(pid) {
			s.adopted = pid
			slog.Info("servicio ya en marcha (de una ejecución anterior)", "servicio", s.Name, "pid", pid)
		} else {
			s.reused = true
			slog.Info("servicio ya en marcha: se reutiliza y no se apagará", "servicio", s.Name)
		}
		return nil
	}
	bin, err := exec.LookPath(s.Bin)
	if err != nil {
		return fmt.Errorf("no encuentro %s (%q): ejecuta setup", s.Name, s.Bin)
	}
	logf, err := os.OpenFile(filepath.Join(s.LogDir, s.Name+".log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer logf.Close() // el hijo ya tiene su copia del descriptor
	cmd := exec.Command(bin, s.Args...)
	cmd.Dir = filepath.Dir(bin) // en Windows, whisper-server busca sus DLL junto al exe
	cmd.Env = append(os.Environ(), s.Env...)
	cmd.Stdout, cmd.Stderr = logf, logf
	detach(cmd, s.LowPrio)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("no pude arrancar %s: %w", s.Name, err)
	}
	afterStart(cmd, s.LowPrio)
	s.cmd = cmd
	s.exited = make(chan struct{})
	go func() { _ = cmd.Wait(); close(s.exited) }()
	_ = os.WriteFile(s.pidFile, []byte(strconv.Itoa(cmd.Process.Pid)+"\n"), 0o644)
	slog.Info("arrancando servicio", "servicio", s.Name, "pid", cmd.Process.Pid)

	deadline := time.Now().Add(s.Wait)
	for time.Now().Before(deadline) {
		if httpUp(ctx, s.Health) {
			slog.Info("servicio listo", "servicio", s.Name)
			return nil
		}
		select {
		case <-s.exited:
			os.Remove(s.pidFile)
			return fmt.Errorf("%s terminó al arrancar; mira %s", s.Name, filepath.Join(s.LogDir, s.Name+".log"))
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
	return fmt.Errorf("%s no respondió en %s; mira %s", s.Name, s.Wait, filepath.Join(s.LogDir, s.Name+".log"))
}

// Stop apaga el servicio si lo arrancamos nosotros (con sus hijos: Ollama lanza un proceso por modelo).
func (s *ServiceSpec) Stop() {
	switch {
	case s.reused:
		return
	case s.cmd != nil:
		killTree(s.cmd.Process.Pid)
		select {
		case <-s.exited:
		case <-time.After(5 * time.Second):
			_ = s.cmd.Process.Kill()
		}
	case s.adopted > 0:
		killTree(s.adopted)
	default:
		return
	}
	os.Remove(s.pidFile)
	slog.Info("servicio detenido", "servicio", s.Name)
}

func readPid(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	return n
}

// Services agrupa los servicios supervisados.
type Services struct{ list []*ServiceSpec }

// StartServices arranca Whisper y Ollama (en paralelo). Si uno falla, la app sigue sirviendo la
// web, que muestra el aviso de que ese servicio no responde.
func StartServices(ctx context.Context, c Config) *Services {
	specs, err := serviceSpecs(c)
	if err != nil {
		slog.Error("servicios nativos", "err", err)
		return &Services{}
	}
	os.MkdirAll(c.LogDir, 0o755)
	errs := make(chan error, len(specs))
	for _, s := range specs {
		go func(s *ServiceSpec) { errs <- s.Start(ctx) }(s)
	}
	for range specs {
		if err := <-errs; err != nil {
			slog.Error("servicio no disponible", "err", err)
		}
	}
	return &Services{list: specs}
}

func (s *Services) Stop() {
	for _, sp := range s.list {
		sp.Stop()
	}
}

// localAddr avisa si la app quedaría expuesta a la red (en nativo no hay Docker que la limite a 127.0.0.1).
func localAddr(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return host == "localhost" || (ip != nil && ip.IsLoopback())
}
