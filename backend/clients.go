package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"
)

// friendly convierte errores de red en mensajes que el usuario pueda entender y accionar.
func friendly(service string, err error) error {
	var ne *net.OpError
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return fmt.Errorf("%s tardó demasiado en responder", service)
	case errors.Is(err, context.Canceled):
		return err
	case errors.As(err, &ne):
		return fmt.Errorf("no se pudo conectar con %s: ¿está en marcha? Ejecuta `make up`", service)
	}
	return fmt.Errorf("%s: %w", service, err)
}

// ---------- Whisper (whisper.cpp server) ----------

type Whisper struct {
	base   string
	lang   string
	prompt string
	hc     *http.Client
}

func NewWhisper(cfg Config) *Whisper {
	return &Whisper{base: strings.TrimRight(cfg.WhisperURL, "/"), lang: cfg.WhisperLang,
		prompt: cfg.WhisperPrompt, hc: &http.Client{}}
}

// Ping devuelve nil si el servidor responde (cualquier respuesta HTTP vale).
func (w *Whisper) Ping(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, w.base+"/", nil)
	resp, err := w.hc.Do(req)
	if err != nil {
		return friendly("Whisper", err)
	}
	resp.Body.Close()
	return nil
}

var noiseRe = regexp.MustCompile(`(?i)\[(blank_audio|música|musica|music|silencio|silence)\]|\((música|musica|music|silencio|silence)\)`)

// cleanTranscript quita marcas de ruido de Whisper y normaliza los espacios.
func cleanTranscript(s string) string {
	s = noiseRe.ReplaceAllString(s, "")
	return strings.Join(strings.Fields(s), " ")
}

// Transcribe envía un WAV de 16 kHz mono a whisper-server y devuelve el texto limpio.
func (w *Whisper) Transcribe(ctx context.Context, wavPath string) (string, error) {
	f, err := os.Open(wavPath)
	if err != nil {
		return "", err
	}
	pr, pw := io.Pipe()
	mw := multipart.NewWriter(pw)
	go func() {
		defer f.Close()
		err := func() error {
			fw, err := mw.CreateFormFile("file", "audio.wav")
			if err != nil {
				return err
			}
			if _, err := io.Copy(fw, f); err != nil {
				return err
			}
			fields := map[string]string{
				"response_format": "json",
				"temperature":     "0.0",
				"temperature_inc": "0.2",
				"language":        w.lang,
			}
			if w.prompt != "" {
				fields["prompt"] = w.prompt
			}
			for k, v := range fields {
				if err := mw.WriteField(k, v); err != nil {
					return err
				}
			}
			return mw.Close()
		}()
		pw.CloseWithError(err)
	}()
	defer pr.Close()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.base+"/inference", pr)
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	resp, err := w.hc.Do(req)
	if err != nil {
		return "", friendly("Whisper", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	var out struct {
		Text  string `json:"text"`
		Error string `json:"error"`
	}
	_ = json.Unmarshal(body, &out)
	if resp.StatusCode != http.StatusOK || out.Error != "" {
		msg := out.Error
		if msg == "" {
			msg = strings.TrimSpace(string(body))
		}
		return "", fmt.Errorf("Whisper respondió %d: %s", resp.StatusCode, truncate(msg, 200))
	}
	return cleanTranscript(out.Text), nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// ---------- Ollama ----------

type Ollama struct {
	base      string
	model     string
	keepAlive string
	numCtx    int
	hc        *http.Client
}

func NewOllama(cfg Config) *Ollama {
	return &Ollama{base: strings.TrimRight(cfg.OllamaURL, "/"), model: cfg.OllamaModel,
		keepAlive: cfg.OllamaKeepAlive, numCtx: cfg.OllamaNumCtx, hc: &http.Client{}}
}

type OllamaStatus struct {
	OK         bool   `json:"ok"`
	Model      string `json:"model"`
	ModelReady bool   `json:"modelReady"`
	Error      string `json:"error,omitempty"`
}

func (o *Ollama) Status(ctx context.Context) OllamaStatus {
	st := OllamaStatus{Model: o.model}
	ctx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, o.base+"/api/tags", nil)
	resp, err := o.hc.Do(req)
	if err != nil {
		st.Error = friendly("Ollama", err).Error()
		return st
	}
	defer resp.Body.Close()
	var tags struct {
		Models []struct {
			Name string `json:"name"`
		} `json:"models"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tags); err != nil {
		st.Error = "respuesta inesperada de Ollama"
		return st
	}
	st.OK = true
	for _, m := range tags.Models {
		if m.Name == o.model || strings.HasPrefix(m.Name, o.model+":") {
			st.ModelReady = true
		}
	}
	if !st.ModelReady {
		st.Error = fmt.Sprintf("falta el modelo %s: ejecuta `ollama pull %s`", o.model, o.model)
	}
	return st
}

// Chat hace una petición no-streaming. keep_alive corto descarga el modelo de la RAM
// poco después de resumir, para que el Mac no lo mantenga cargado sin necesidad.
func (o *Ollama) Chat(ctx context.Context, system, user string) (string, error) {
	payload, _ := json.Marshal(map[string]any{
		"model":      o.model,
		"stream":     false,
		"keep_alive": o.keepAlive,
		"messages": []map[string]string{
			{"role": "system", "content": system},
			{"role": "user", "content": user},
		},
		"options": map[string]any{"temperature": 0.2, "num_ctx": o.numCtx},
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, o.base+"/api/chat", bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := o.hc.Do(req)
	if err != nil {
		return "", friendly("Ollama", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	var out struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
		Error string `json:"error"`
	}
	_ = json.Unmarshal(body, &out)
	if resp.StatusCode != http.StatusOK || out.Error != "" {
		msg := out.Error
		if msg == "" {
			msg = strings.TrimSpace(string(body))
		}
		return "", fmt.Errorf("Ollama respondió %d: %s", resp.StatusCode, truncate(msg, 200))
	}
	return strings.TrimSpace(out.Message.Content), nil
}
