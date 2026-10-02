package main

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	systemItem = "Eres un asistente que resume mensajes de voz de WhatsApp transcritos automáticamente. " +
		"El texto puede tener errores de transcripción y mezclar español con inglés (spanglish). " +
		"Escribe SIEMPRE en español y conserva tal cual los términos en inglés. " +
		"No inventes datos: si algo no queda claro, no lo afirmes. " +
		"Responde solo con el resumen, sin introducciones, sin encabezados y sin negritas."

	// Por encima de este tamaño el resumen general se hace sobre los resúmenes de cada
	// audio en lugar de sobre las transcripciones completas, para no desbordar el contexto.
	maxGlobalChars = 24000
	maxItemChars   = 30000
	minWordsToSum  = 20
)

type batch struct {
	session string
	items   []string
}

// Worker procesa las tandas de audios de una en una. Primero transcribe todos los audios
// de la tanda y después los resume, para no alternar entre Whisper y el LLM (así solo hay
// un modelo trabajando a la vez y el Mac no se carga de más).
type Worker struct {
	store   *Store
	whisper *Whisper
	ollama  *Ollama
	dataDir string
	jobs    chan batch
}

func NewWorker(store *Store, whisper *Whisper, ollama *Ollama, dataDir string) *Worker {
	return &Worker{store: store, whisper: whisper, ollama: ollama, dataDir: dataDir, jobs: make(chan batch, 512)}
}

func (w *Worker) Enqueue(b batch) error {
	select {
	case w.jobs <- b:
		return nil
	default:
		return errors.New("la cola está llena, espera a que termine el trabajo actual")
	}
}

func (w *Worker) Run(ctx context.Context) {
	tmp := filepath.Join(w.dataDir, "tmp")
	_ = os.RemoveAll(tmp)
	_ = os.MkdirAll(tmp, 0o755)
	for {
		select {
		case <-ctx.Done():
			return
		case b := <-w.jobs:
			w.process(ctx, b)
		}
	}
}

func (w *Worker) process(ctx context.Context, b batch) {
	start := time.Now()
	for _, id := range b.items {
		w.transcribe(ctx, b.session, id)
	}
	for _, id := range b.items {
		w.summarizeItem(ctx, b.session, id)
	}
	w.summarizeGlobal(ctx, b.session)
	w.store.ExportFiles(b.session)
	slog.Info("tanda procesada", "session", b.session, "audios", len(b.items), "tiempo", time.Since(start).Round(time.Millisecond))
}

type itemSnap struct {
	file, name, text, summary string
	skipped                   bool
	ok                        bool
}

func (w *Worker) snap(sessionID, itemID string) itemSnap {
	var s itemSnap
	w.store.Read(sessionID, func(sess *Session) {
		if it := sess.item(itemID); it != nil {
			s = itemSnap{file: it.File, name: it.Name, text: it.Text, summary: it.Summary, skipped: it.SummarySkipped, ok: true}
		}
	})
	return s
}

func (w *Worker) setItem(sessionID, itemID string, fn func(*Session, *Item)) bool {
	return w.store.Update(sessionID, func(sess *Session) {
		if it := sess.item(itemID); it != nil {
			fn(sess, it)
		}
	})
}

func (w *Worker) transcribe(ctx context.Context, sessionID, itemID string) {
	s := w.snap(sessionID, itemID)
	if !s.ok || s.text != "" || ctx.Err() != nil {
		return
	}
	w.setItem(sessionID, itemID, func(_ *Session, it *Item) { it.Status, it.Error = StatusConverting, "" })

	fail := func(err error) {
		slog.Warn("falló la transcripción", "session", sessionID, "item", itemID, "err", err)
		w.setItem(sessionID, itemID, func(_ *Session, it *Item) { it.Status, it.Error = StatusError, err.Error() })
	}

	wav, err := os.CreateTemp(filepath.Join(w.dataDir, "tmp"), "audio-*.wav")
	if err != nil {
		fail(err)
		return
	}
	wavPath := wav.Name()
	wav.Close()
	defer os.Remove(wavPath)

	cctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	dur, err := convertToWav(cctx, w.store.AudioPath(sessionID, s.file), wavPath)
	cancel()
	if err != nil {
		fail(err)
		return
	}
	w.setItem(sessionID, itemID, func(_ *Session, it *Item) { it.Status, it.DurationSec = StatusTranscribing, dur })

	tctx, cancel := context.WithTimeout(ctx, 20*time.Minute)
	text, err := w.whisper.Transcribe(tctx, wavPath)
	cancel()
	if err != nil {
		fail(err)
		return
	}
	if text == "" {
		fail(errors.New("no se detectó voz en el audio"))
		return
	}
	w.setItem(sessionID, itemID, func(sess *Session, it *Item) {
		if sess.TitleAuto && sess.firstTranscript() == nil {
			sess.Title = titleFrom(text)
		}
		it.Text, it.Status, it.Error = text, StatusTranscribed, ""
	})
}

func (s *Session) firstTranscript() *Item {
	for _, it := range s.Items {
		if it.Text != "" {
			return it
		}
	}
	return nil
}

// titleFrom usa las primeras palabras de la transcripción como título provisional.
func titleFrom(text string) string {
	words := strings.Fields(text)
	if len(words) > 7 {
		return strings.Join(words[:7], " ") + "…"
	}
	return strings.Join(words, " ")
}

func (w *Worker) summarizeItem(ctx context.Context, sessionID, itemID string) {
	s := w.snap(sessionID, itemID)
	if !s.ok || s.text == "" || ctx.Err() != nil {
		return
	}
	if s.summary != "" || s.skipped {
		w.setItem(sessionID, itemID, func(_ *Session, it *Item) { it.Status = StatusDone })
		return
	}
	if len(strings.Fields(s.text)) < minWordsToSum {
		w.setItem(sessionID, itemID, func(_ *Session, it *Item) {
			it.Status, it.SummarySkipped, it.SummaryError = StatusDone, true, ""
		})
		return
	}
	w.setItem(sessionID, itemID, func(_ *Session, it *Item) { it.Status, it.SummaryError = StatusSummarizing, "" })

	text := s.text
	if len(text) > maxItemChars {
		text = text[:maxItemChars]
	}
	user := "Resume este audio en 2 a 4 frases (máximo 60 palabras). " +
		"Si menciona tareas, fechas, horas, lugares o cosas que hacer, añádelas al final como lista con guiones (\"- \").\n\n" +
		"Transcripción:\n<<<\n" + text + "\n>>>"

	cctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	summary, err := w.ollama.Chat(cctx, systemItem, user)
	cancel()
	if err == nil && summary == "" {
		err = errors.New("el modelo devolvió un resumen vacío")
	}
	if err != nil {
		slog.Warn("falló el resumen", "session", sessionID, "item", itemID, "err", err)
		w.setItem(sessionID, itemID, func(_ *Session, it *Item) { it.Status, it.SummaryError = StatusDone, err.Error() })
		return
	}
	w.setItem(sessionID, itemID, func(_ *Session, it *Item) { it.Summary, it.Status, it.SummaryError = summary, StatusDone, "" })
}

type globalInput struct {
	prompt string
	hash   string
	count  int
}

func buildGlobalInput(sess *Session) globalInput {
	var texts, sums []string
	total := 0
	for _, it := range sess.Items {
		if it.Text == "" {
			continue
		}
		texts = append(texts, it.Text)
		sum := it.Summary
		if sum == "" {
			sum = it.Text
		}
		sums = append(sums, sum)
		total += len(it.Text)
	}
	in := globalInput{count: len(texts)}
	if in.count < 2 {
		return in
	}
	source, label := texts, "transcripciones"
	if total > maxGlobalChars {
		source, label = sums, "resúmenes individuales"
	}
	var b strings.Builder
	for i, t := range source {
		fmt.Fprintf(&b, "[Audio %d]\n%s\n\n", i+1, t)
	}
	in.prompt = fmt.Sprintf("A continuación hay %d audios de WhatsApp consecutivos (%s), en orden cronológico. "+
		"Resume la conversación completa como si fuera una sola. Primero un párrafo de 3 a 5 frases con la idea general. "+
		"Después, si las hay, una lista con guiones (\"- \") con puntos clave, tareas, fechas y horas. "+
		"No repitas audio por audio.\n\n%s", in.count, label, strings.TrimSpace(b.String()))
	sum := sha1.Sum([]byte(in.prompt))
	in.hash = hex.EncodeToString(sum[:])
	return in
}

func (w *Worker) summarizeGlobal(ctx context.Context, sessionID string) {
	var in globalInput
	var prev Global
	if !w.store.Read(sessionID, func(sess *Session) { in, prev = buildGlobalInput(sess), sess.Global }) || ctx.Err() != nil {
		return
	}
	if in.count < 2 {
		if prev.Status != GlobalIdle {
			w.store.Update(sessionID, func(sess *Session) { sess.Global = Global{Status: GlobalIdle} })
		}
		return
	}
	if prev.Status == GlobalDone && prev.Hash == in.hash {
		return // nada cambió desde el último resumen general
	}
	w.store.Update(sessionID, func(sess *Session) {
		sess.Global = Global{Status: GlobalWorking, Items: in.count, Text: sess.Global.Text}
	})

	cctx, cancel := context.WithTimeout(ctx, 15*time.Minute)
	text, err := w.ollama.Chat(cctx, systemItem, in.prompt)
	cancel()
	if err == nil && text == "" {
		err = errors.New("el modelo devolvió un resumen vacío")
	}
	if err != nil {
		slog.Warn("falló el resumen general", "session", sessionID, "err", err)
		w.store.Update(sessionID, func(sess *Session) {
			sess.Global = Global{Status: GlobalError, Error: err.Error(), Items: in.count}
		})
		return
	}
	w.store.Update(sessionID, func(sess *Session) {
		sess.Global = Global{Status: GlobalDone, Text: text, Hash: in.hash, Items: in.count}
	})
}
