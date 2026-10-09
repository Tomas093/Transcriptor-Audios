package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Config se rellena desde variables de entorno (ver docker-compose.yml).
type Config struct {
	Addr            string
	DataDir         string
	WebDir          string
	TmpDir          string
	WhisperURL      string
	WhisperLang     string
	WhisperPrompt   string
	OllamaURL       string
	OllamaModel     string
	OllamaKeepAlive string
	OllamaNumCtx    int
	RetentionDays   int
	MaxUploadBytes  int64
	AllowedHosts    []string
	InboxDir        string // carpeta vigilada; vacío = desactivada
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func loadConfig() Config {
	return Config{
		Addr:        env("ADDR", ":4747"),
		DataDir:     env("DATA_DIR", "/data"),
		WebDir:      env("WEB_DIR", "/app/web"),
		TmpDir:      env("TMP_DIR", filepath.Join(os.TempDir(), "transcriptor")),
		WhisperURL:  env("WHISPER_URL", "http://host.docker.internal:8178"),
		WhisperLang: env("WHISPER_LANG", "es"),
		// El prompt inicial ayuda a Whisper con el spanglish: le da vocabulario en inglés
		// frecuente en clase para que no lo "españolice" ni cambie de idioma a mitad de audio.
		WhisperPrompt: env("WHISPER_PROMPT",
			"Transcripción en español con algunos términos en inglés (spanglish): meeting, deadline, feedback, "+
				"review, commit, deploy, backend, frontend, paper, quiz, homework, slides."),
		OllamaURL:       env("OLLAMA_URL", "http://host.docker.internal:11434"),
		OllamaModel:     env("OLLAMA_MODEL", "qwen2.5:7b"),
		OllamaKeepAlive: env("OLLAMA_KEEP_ALIVE", "60s"),
		OllamaNumCtx:    envInt("OLLAMA_NUM_CTX", 12288),
		RetentionDays:   envInt("RETENTION_DAYS", 1),
		MaxUploadBytes:  int64(envInt("MAX_UPLOAD_MB", 1024)) << 20,
		AllowedHosts:    splitList(env("ALLOWED_HOSTS", "localhost,127.0.0.1,::1")),
		InboxDir:        env("INBOX_DIR", ""),
	}
}

func (c Config) retention() time.Duration {
	return time.Duration(c.RetentionDays) * 24 * time.Hour
}
