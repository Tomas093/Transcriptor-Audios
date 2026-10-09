package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestInboxIngestsStableAudioIntoOneSession(t *testing.T) {
	e := newEnv(t)
	in := filepath.Join(t.TempDir(), "entrada")
	os.MkdirAll(in, 0o755)
	box := NewInbox(in, e.store, e.worker)
	clock := time.Now().Add(time.Hour)
	box.now = func() time.Time { return clock }

	// Un audio y un fichero que no es audio.
	src := makeAudio(t, t.TempDir(), "a.wav")
	data, _ := os.ReadFile(src)
	old := time.Now().Add(-time.Minute)
	put := func(name string, b []byte) {
		p := filepath.Join(in, name)
		os.WriteFile(p, b, 0o644)
		os.Chtimes(p, old, old)
	}
	put("PTT-1.wav", data)
	put("notas.txt", []byte("no soy audio"))

	box.scan() // primer sondeo: aún no es estable
	if sessions := e.store.List(); len(sessions) != 0 {
		t.Fatalf("no debería crear sesión con un fichero recién visto: %d", len(sessions))
	}
	box.scan() // estable → se toma
	sessions := e.store.List()
	if len(sessions) != 1 {
		t.Fatalf("sesiones = %d, quiero 1", len(sessions))
	}
	id := sessions[0].ID
	s := e.wait(t, id, func(s *Session) bool { return len(s.Items) == 1 && s.Items[0].Status == StatusDone })
	if s.Items[0].Name != "PTT-1.wav" {
		t.Fatalf("nombre = %q", s.Items[0].Name)
	}
	if _, err := os.Stat(filepath.Join(in, "PTT-1.wav")); !os.IsNotExist(err) {
		t.Fatal("el original debería haberse movido")
	}
	if _, err := os.Stat(filepath.Join(in, inboxDone, "PTT-1.wav")); err != nil {
		t.Fatalf("falta en procesados: %v", err)
	}
	if _, err := os.Stat(filepath.Join(in, "notas.txt")); err != nil {
		t.Fatal("el fichero que no es audio no se debe tocar")
	}

	// Otro audio poco después → misma sesión. Uno idéntico al primero → se descarta.
	clock = clock.Add(2 * time.Minute)
	other := tone(t, "b.wav", 880)
	put("PTT-2.wav", other)
	put("PTT-3.wav", data)
	box.scan()
	box.scan()
	if n := len(e.store.List()); n != 1 {
		t.Fatalf("sesiones = %d, quiero 1 (misma ventana)", n)
	}
	s = e.wait(t, id, func(s *Session) bool { return len(s.Items) == 2 && s.Items[1].Status == StatusDone })
	if s.Items[1].Name != "PTT-2.wav" {
		t.Fatalf("segundo = %q", s.Items[1].Name)
	}

	// Pasada la ventana → sesión nueva.
	clock = clock.Add(inboxWindow + time.Minute)
	put("PTT-4.wav", tone(t, "c.wav", 1320))
	box.scan()
	box.scan()
	if n := len(e.store.List()); n != 2 {
		t.Fatalf("sesiones = %d, quiero 2 (ventana vencida)", n)
	}
}

func TestInboxWaitsForGrowingFile(t *testing.T) {
	e := newEnv(t)
	in := t.TempDir()
	box := NewInbox(in, e.store, e.worker)
	p := filepath.Join(in, "grande.wav")
	old := time.Now().Add(-time.Minute)
	os.WriteFile(p, []byte("1234"), 0o644)
	os.Chtimes(p, old, old)
	box.scan()
	os.WriteFile(p, []byte("12345678"), 0o644) // sigue creciendo
	os.Chtimes(p, old, old)
	box.scan()
	if n := len(e.store.List()); n != 0 {
		t.Fatalf("no debe tomar un fichero que aún crece (sesiones = %d)", n)
	}
}

func tone(t *testing.T, name string, hz int) []byte {
	t.Helper()
	b, err := os.ReadFile(makeTone(t, t.TempDir(), name, hz))
	if err != nil {
		t.Fatal(err)
	}
	return b
}
