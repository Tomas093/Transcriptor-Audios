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
	box := NewInbox(in, e.store, e.worker, nil)
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
	clock = clock.Add(61 * time.Minute) // la ventana por defecto es de 60 min
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
	box := NewInbox(in, e.store, e.worker, nil)
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

// Los audios de una misma hora se quedan en una sola sesión aunque la app se apague y se encienda
// entre uno y otro (el agente en segundo plano lo hace), y la ventana se cambia en Configuración.
func TestInboxGroupsAcrossRestartsAndHonorsWindow(t *testing.T) {
	e := newEnv(t)
	in := t.TempDir()
	settings := NewSettingsStore(t.TempDir())
	clock := time.Now().Add(time.Hour)
	newBox := func() *Inbox { // «reiniciar»: un Inbox nuevo sin memoria, sobre el mismo almacén
		b := NewInbox(in, e.store, e.worker, settings)
		b.now = func() time.Time { return clock }
		return b
	}
	old := time.Now().Add(-time.Minute)
	drop := func(name string, hz int) {
		p := filepath.Join(in, name)
		os.WriteFile(p, tone(t, name+".wav", hz), 0o644)
		os.Chtimes(p, old, old)
	}
	ingest := func() { b := newBox(); b.scan(); b.scan() }
	setWindow := func(min int) {
		s := defaultSettings()
		s.Inbox.GroupMin = min
		if err := settings.Set(s); err != nil {
			t.Fatal(err)
		}
	}

	setWindow(5)
	drop("a.wav", 300)
	ingest()
	clock = clock.Add(4 * time.Minute) // menos de 5 min después, con la app «reiniciada»
	drop("b.wav", 500)
	ingest()
	if n := len(e.store.List()); n != 1 {
		t.Fatalf("sesiones = %d, quiero 1 (4 min < ventana de 5)", n)
	}
	clock = clock.Add(6 * time.Minute) // más de 5 min desde el último audio
	drop("c.wav", 700)
	ingest()
	if n := len(e.store.List()); n != 2 {
		t.Fatalf("sesiones = %d, quiero 2 (6 min > ventana de 5)", n)
	}

	// Con una ventana de una hora, el siguiente audio (a los 40 min) sigue en la misma sesión.
	setWindow(60)
	clock = clock.Add(40 * time.Minute)
	drop("d.wav", 900)
	ingest()
	if n := len(e.store.List()); n != 2 {
		t.Fatalf("sesiones = %d, quiero 2 (40 min < ventana de 60)", n)
	}

	// 0 = una sesión por tanda.
	setWindow(0)
	clock = clock.Add(time.Minute)
	drop("e.wav", 1100)
	ingest()
	if n := len(e.store.List()); n != 3 {
		t.Fatalf("sesiones = %d, quiero 3 (ventana 0)", n)
	}
}

func TestLatestFromIgnoresManualSessions(t *testing.T) {
	e := newEnv(t)
	manual := e.store.Create("a mano")
	_ = manual
	if id := e.store.LatestFrom(inboxSource, time.Hour, time.Now()); id != "" {
		t.Fatalf("una sesión creada a mano no debe recibir audios de la entrada: %s", id)
	}
	auto := e.store.CreateFrom("Entrada", inboxSource)
	if id := e.store.LatestFrom(inboxSource, time.Hour, time.Now()); id != auto.ID {
		t.Fatalf("debería encontrar la de la entrada: %q", id)
	}
	if id := e.store.LatestFrom(inboxSource, time.Hour, time.Now().Add(2*time.Hour)); id != "" {
		t.Fatalf("fuera de la ventana no debe devolver nada: %q", id)
	}
}
