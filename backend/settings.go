package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Ajustes que se cambian desde la web. Se guardan en <DATA_DIR>/settings.json y, además, en
// <DATA_DIR>/whatsapp.conf (CLAVE=valor), que es lo que lee el script nativo de macOS
// (scripts/whatsapp.sh) porque la app corre en Docker y no puede mirar la carpeta de WhatsApp.
type Settings struct {
	WhatsApp   WhatsAppSettings   `json:"whatsapp"`
	Background BackgroundSettings `json:"background"`
}

type WhatsAppSettings struct {
	Mode       string   `json:"mode"` // off | all | chats
	Chats      []string `json:"chats"`
	BacklogMin int      `json:"backlogMin"` // al encender, incluir audios de los últimos N min (0 = solo nuevos)
}

type BackgroundSettings struct {
	Enabled    bool `json:"enabled"`    // agente: escucha en segundo plano y enciende todo cuando llega un audio
	IdleMin    int  `json:"idleMin"`    // apagar todo tras N min sin actividad
	QuitDocker bool `json:"quitDocker"` // al apagar, cerrar también Docker Desktop (solo si no hay otros contenedores)
}

func defaultSettings() Settings {
	return Settings{
		WhatsApp:   WhatsAppSettings{Mode: "off", Chats: []string{}, BacklogMin: 60},
		Background: BackgroundSettings{IdleMin: 10},
	}
}

var chatIDRe = regexp.MustCompile(`^[A-Za-z0-9._@-]{1,80}$`)

// validate normaliza y valida; el resultado se escribe en un fichero que lee un script de shell,
// así que los ids solo admiten caracteres seguros.
func (s *Settings) validate() error {
	switch s.WhatsApp.Mode {
	case "off", "all", "chats":
	default:
		return errors.New("modo de WhatsApp no válido")
	}
	seen := map[string]bool{}
	chats := []string{}
	for _, c := range s.WhatsApp.Chats {
		c = strings.TrimSpace(c)
		if c == "" || seen[c] {
			continue
		}
		if !chatIDRe.MatchString(c) || strings.EqualFold(c, "all") {
			return fmt.Errorf("id de chat no válido: %q", c)
		}
		seen[c] = true
		chats = append(chats, c)
	}
	if len(chats) > 50 {
		return errors.New("demasiados chats")
	}
	s.WhatsApp.Chats = chats
	if s.WhatsApp.Mode == "chats" && len(chats) == 0 {
		return errors.New("elige al menos un chat o cambia el modo")
	}
	if s.WhatsApp.BacklogMin < 0 || s.WhatsApp.BacklogMin > 24*60 {
		return errors.New("los minutos hacia atrás deben estar entre 0 y 1440")
	}
	if s.Background.IdleMin < 1 || s.Background.IdleMin > 240 {
		return errors.New("los minutos de inactividad deben estar entre 1 y 240")
	}
	return nil
}

func (s Settings) conf() string {
	chats := ""
	switch s.WhatsApp.Mode {
	case "all":
		chats = "all"
	case "chats":
		chats = strings.Join(s.WhatsApp.Chats, ",")
	}
	b2i := func(b bool) string {
		if b {
			return "1"
		}
		return "0"
	}
	return "# Generado por la app desde Configuración. No lo edites a mano: se sobrescribe.\n" +
		"WHATSAPP_MODE=" + s.WhatsApp.Mode + "\n" +
		"WHATSAPP_CHATS=" + chats + "\n" +
		"WHATSAPP_BACKLOG_MIN=" + strconv.Itoa(s.WhatsApp.BacklogMin) + "\n" +
		"BACKGROUND_ENABLED=" + b2i(s.Background.Enabled) + "\n" +
		"BACKGROUND_IDLE_MIN=" + strconv.Itoa(s.Background.IdleMin) + "\n" +
		"BACKGROUND_QUIT_DOCKER=" + b2i(s.Background.QuitDocker) + "\n"
}

// SettingsStore guarda los ajustes y lee el estado que deja el script de WhatsApp.
type SettingsStore struct {
	mu  sync.Mutex
	dir string
	now func() time.Time
}

func NewSettingsStore(dir string) *SettingsStore { return &SettingsStore{dir: dir, now: time.Now} }

func (st *SettingsStore) path(name string) string { return filepath.Join(st.dir, name) }

func (st *SettingsStore) Get() Settings {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.getLocked()
}

func (st *SettingsStore) getLocked() Settings {
	s := defaultSettings()
	data, err := os.ReadFile(st.path("settings.json"))
	if err != nil {
		return s
	}
	if json.Unmarshal(data, &s) != nil || s.validate() != nil {
		return defaultSettings()
	}
	return s
}

func (st *SettingsStore) Set(s Settings) error {
	if err := s.validate(); err != nil {
		return err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	data, _ := json.MarshalIndent(s, "", "  ")
	if err := writeAtomic(st.path("settings.json"), data); err != nil {
		return err
	}
	return writeAtomic(st.path("whatsapp.conf"), []byte(s.conf()))
}

func writeAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// WhatsAppStatus es lo que escribe scripts/whatsapp.sh en <DATA_DIR>/whatsapp-status.json. Es un
// fichero externo: se lee a una estructura tipada y nada de él se interpreta.
type WhatsAppStatus struct {
	Running    bool   `json:"running"` // calculado aquí: el script actualizó el estado hace poco
	Host       string `json:"host"`    // "agent" (en segundo plano) | "stack" (lo lanzó make up) | ""
	Stack      string `json:"stack"`   // "on" | "off": si la app y los modelos están encendidos
	UpdatedAt  int64  `json:"updatedAt"`
	Error      string `json:"error"`
	LastChat   string `json:"lastChat"` // chat del último audio copiado
	LastAt     int64  `json:"lastAt"`
	Detected   string `json:"detected"` // chat del último audio visto durante una detección
	DetectedAt int64  `json:"detectedAt"`
	Copied     int    `json:"copied"` // audios copiados desde que arrancó
}

const statusFresh = 90 * time.Second

func (st *SettingsStore) Status() WhatsAppStatus {
	var out WhatsAppStatus
	data, err := os.ReadFile(st.path("whatsapp-status.json"))
	if err != nil || json.Unmarshal(data, &out) != nil {
		return WhatsAppStatus{}
	}
	out.Running = st.now().Sub(time.Unix(out.UpdatedAt, 0)) < statusFresh
	if !out.Running {
		out.Stack, out.Host = "", ""
	}
	for _, p := range []*string{&out.Error, &out.LastChat, &out.Detected} {
		if len(*p) > 300 {
			*p = (*p)[:300]
		}
	}
	return out
}

// Detect pide al script que, durante unos minutos, mire todos los chats y anote de cuál es el
// último audio que aparece (así el usuario elige un chat reproduciendo un audio suyo).
func (st *SettingsStore) Detect() error {
	st.mu.Lock()
	defer st.mu.Unlock()
	return writeAtomic(st.path("whatsapp-detect"), []byte(strconv.FormatInt(st.now().Unix(), 10)+"\n"))
}
