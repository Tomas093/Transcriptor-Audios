package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSettingsDefaultsAndRoundTrip(t *testing.T) {
	e := newEnv(t)
	_, body := e.do(t, "GET", "/api/settings", nil, "")
	var got struct {
		Settings Settings       `json:"settings"`
		WhatsApp WhatsAppStatus `json:"whatsapp"`
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatal(err)
	}
	if got.Settings.WhatsApp.Mode != "off" || got.Settings.WhatsApp.BacklogMin != 60 || got.Settings.Background.IdleMin != 10 || got.Settings.Background.Enabled || got.Settings.Inbox.GroupMin != 60 {
		t.Fatalf("defaults inesperados: %+v", got.Settings)
	}
	if got.WhatsApp.Running {
		t.Fatal("sin script no debe figurar en marcha")
	}

	in := `{"whatsapp":{"mode":"chats","chats":["180839614816436@lid"," 999@g.us ","180839614816436@lid"],"backlogMin":30},"background":{"enabled":true,"idleMin":15,"quitDocker":true}}`
	resp, body := e.do(t, "PUT", "/api/settings", []byte(in), "application/json")
	if resp.StatusCode != 200 {
		t.Fatalf("PUT = %d %s", resp.StatusCode, body)
	}
	_, body = e.do(t, "GET", "/api/settings", nil, "")
	json.Unmarshal(body, &got)
	if g := got.Settings.WhatsApp; g.Mode != "chats" || len(g.Chats) != 2 || g.Chats[1] != "999@g.us" || g.BacklogMin != 30 {
		t.Fatalf("no se guardó bien: %+v", g)
	}
	conf, err := os.ReadFile(filepath.Join(e.cfg.DataDir, "whatsapp.conf"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"WHATSAPP_MODE=chats\n", "WHATSAPP_CHATS=180839614816436@lid,999@g.us\n", "WHATSAPP_BACKLOG_MIN=30\n", "BACKGROUND_ENABLED=1\n", "BACKGROUND_IDLE_MIN=15\n", "BACKGROUND_QUIT_DOCKER=1\n"} {
		if !strings.Contains(string(conf), want) {
			t.Fatalf("falta %q en whatsapp.conf:\n%s", want, conf)
		}
	}

	// "todos" y "apagado" generan la lista vacía o "all".
	e.do(t, "PUT", "/api/settings", []byte(`{"whatsapp":{"mode":"all","chats":[],"backlogMin":0},"background":{"idleMin":10}}`), "application/json")
	conf, _ = os.ReadFile(filepath.Join(e.cfg.DataDir, "whatsapp.conf"))
	if !strings.Contains(string(conf), "WHATSAPP_CHATS=all\n") || !strings.Contains(string(conf), "BACKGROUND_ENABLED=0\n") {
		t.Fatalf("conf de 'all' inesperada:\n%s", conf)
	}
}

func TestSettingsRejectInvalid(t *testing.T) {
	e := newEnv(t)
	bad := map[string]string{
		"modo":         `{"whatsapp":{"mode":"x","backlogMin":0},"background":{"idleMin":10}}`,
		"id con shell": `{"whatsapp":{"mode":"chats","chats":["a;rm -rf /"],"backlogMin":0},"background":{"idleMin":10}}`,
		"id con salto": `{"whatsapp":{"mode":"chats","chats":["a\nWHATSAPP_CHATS=all"],"backlogMin":0},"background":{"idleMin":10}}`,
		"chat all":     `{"whatsapp":{"mode":"chats","chats":["all"],"backlogMin":0},"background":{"idleMin":10}}`,
		"sin chats":    `{"whatsapp":{"mode":"chats","chats":[],"backlogMin":0},"background":{"idleMin":10}}`,
		"backlog":      `{"whatsapp":{"mode":"off","backlogMin":99999},"background":{"idleMin":10}}`,
		"inactividad":  `{"whatsapp":{"mode":"off","backlogMin":0},"background":{"idleMin":0}}`,
		"agrupar":      `{"whatsapp":{"mode":"off","backlogMin":0},"background":{"idleMin":10},"inbox":{"groupMin":99999}}`,
		"no json":      `nope`,
	}
	for name, in := range bad {
		resp, body := e.do(t, "PUT", "/api/settings", []byte(in), "application/json")
		if resp.StatusCode != 400 {
			t.Errorf("%s: esperaba 400, fue %d %s", name, resp.StatusCode, body)
		}
	}
	if _, err := os.Stat(filepath.Join(e.cfg.DataDir, "whatsapp.conf")); err == nil {
		t.Fatal("no debe escribirse la conf con ajustes inválidos")
	}
}

func TestWhatsAppStatusFreshnessAndDetect(t *testing.T) {
	e := newEnv(t)
	now := time.Now().Unix()
	write := func(updated int64) {
		b, _ := json.Marshal(map[string]any{"host": "agent", "stack": "on", "updatedAt": updated, "error": "x", "detected": "123@lid", "detectedAt": now, "copied": 3})
		os.WriteFile(filepath.Join(e.cfg.DataDir, "whatsapp-status.json"), b, 0o644)
	}
	get := func() WhatsAppStatus {
		_, body := e.do(t, "GET", "/api/settings", nil, "")
		var g struct{ WhatsApp WhatsAppStatus }
		json.Unmarshal(body, &g)
		return g.WhatsApp
	}
	write(now)
	if s := get(); !s.Running || s.Host != "agent" || s.Stack != "on" || s.Detected != "123@lid" || s.Copied != 3 {
		t.Fatalf("estado fresco: %+v", s)
	}
	write(now - 600)
	if s := get(); s.Running || s.Host != "" || s.Stack != "" {
		t.Fatalf("un estado viejo no debe figurar en marcha: %+v", s)
	}

	resp, _ := e.do(t, "POST", "/api/whatsapp/detect", nil, "")
	if resp.StatusCode != 204 {
		t.Fatalf("detect = %d", resp.StatusCode)
	}
	if b, err := os.ReadFile(filepath.Join(e.cfg.DataDir, "whatsapp-detect")); err != nil || len(strings.TrimSpace(string(b))) < 9 {
		t.Fatalf("falta el fichero de detección: %v %q", err, b)
	}
}

func TestSettingsDefaultsFromEnv(t *testing.T) {
	t.Setenv("WHATSAPP_CHATS", "111@g.us, 222@lid")
	t.Setenv("WHATSAPP_BACKLOG_MIN", "30")
	t.Setenv("BACKGROUND_ENABLED", "1")
	t.Setenv("BACKGROUND_IDLE_MIN", "5")
	s := defaultSettings()
	if s.WhatsApp.Mode != "chats" || len(s.WhatsApp.Chats) != 2 || s.WhatsApp.Chats[1] != "222@lid" || s.WhatsApp.BacklogMin != 30 || !s.Background.Enabled || s.Background.IdleMin != 5 {
		t.Fatalf("no tomó el .env: %+v", s)
	}
	t.Setenv("WHATSAPP_CHATS", "all")
	if s := defaultSettings(); s.WhatsApp.Mode != "all" {
		t.Fatalf("all: %+v", s.WhatsApp)
	}
	t.Setenv("WHATSAPP_CHATS", "a;rm -rf /") // inválido: se ignora el .env entero
	if s := defaultSettings(); s.WhatsApp.Mode != "off" || s.Background.Enabled {
		t.Fatalf("inválido: %+v", s)
	}
}
