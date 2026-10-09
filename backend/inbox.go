package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	inboxPoll   = 3 * time.Second
	inboxWindow = 10 * time.Minute // audios que llegan con menos de esto entre sí van a la misma sesión
	inboxDone   = "procesados"
)

var inboxExts = map[string]bool{
	".opus": true, ".ogg": true, ".oga": true, ".m4a": true, ".mp3": true, ".wav": true, ".aac": true,
	".mp4": true, ".webm": true, ".amr": true, ".flac": true, ".3gp": true, ".caf": true, ".wma": true,
}

type fileSig struct {
	size int64
	mod  time.Time
}

// Inbox vigila una carpeta: todo audio que cae ahí se copia a una sesión y se procesa solo.
// Los originales se mueven a <carpeta>/procesados. Sondea en vez de usar eventos del sistema
// (que no funcionan bien a través de los volúmenes de Docker) y espera a que cada fichero
// deje de crecer, para no tomar una descarga a medias.
type Inbox struct {
	dir     string
	store   *Store
	worker  *Worker
	prev    map[string]fileSig // estado en el sondeo anterior
	skip    map[string]fileSig // ya procesados que no se pudieron mover: no se repiten
	current string             // sesión que se está llenando
	lastAt  time.Time
	now     func() time.Time
}

func NewInbox(dir string, store *Store, worker *Worker) *Inbox {
	return &Inbox{dir: dir, store: store, worker: worker, prev: map[string]fileSig{}, skip: map[string]fileSig{}, now: time.Now}
}

func (in *Inbox) Run(ctx context.Context) {
	if err := os.MkdirAll(filepath.Join(in.dir, inboxDone), 0o755); err != nil {
		slog.Error("carpeta de entrada no disponible", "dir", in.dir, "err", err)
		return
	}
	slog.Info("vigilando carpeta de entrada", "dir", in.dir)
	t := time.NewTicker(inboxPoll)
	defer t.Stop()
	for {
		in.scan()
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// scan hace un sondeo: toma los audios estables (mismo tamaño y fecha que en el sondeo anterior).
func (in *Inbox) scan() {
	entries, err := os.ReadDir(in.dir)
	if err != nil {
		return
	}
	cur := map[string]fileSig{}
	var ready []string
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || strings.HasPrefix(name, ".") || !inboxExts[strings.ToLower(filepath.Ext(name))] {
			continue
		}
		info, err := e.Info()
		if err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
			continue
		}
		sig := fileSig{info.Size(), info.ModTime()}
		if k, ok := in.skip[name]; ok && k == sig {
			continue
		}
		delete(in.skip, name)
		cur[name] = sig
		if p, ok := in.prev[name]; ok && p == sig && in.now().Sub(sig.mod) > 2*time.Second {
			ready = append(ready, name)
		}
	}
	in.prev = cur
	if len(ready) == 0 {
		return
	}
	sort.SliceStable(ready, func(i, j int) bool { return naturalLess(ready[i], ready[j]) })
	in.ingest(ready)
}

func (in *Inbox) ingest(names []string) {
	id := in.current
	if id == "" || in.now().Sub(in.lastAt) > inboxWindow || !in.store.Read(id, func(*Session) {}) {
		sess := in.store.Create("Entrada " + in.now().Format("02/01 15:04"))
		id = sess.ID
	}
	if err := os.MkdirAll(in.store.audioDir(id), 0o755); err != nil {
		slog.Error("entrada: no se pudo crear la carpeta de audio", "err", err)
		return
	}
	var items []*Item
	var origins []string
	for _, name := range names {
		it, err := in.copyIn(id, name)
		if err != nil {
			slog.Error("entrada: no se pudo copiar", "archivo", name, "err", err)
			delete(in.prev, name) // se reintenta en el próximo sondeo
			continue
		}
		items = append(items, it)
		origins = append(origins, name)
	}
	if len(items) == 0 {
		return
	}
	var res mergeResult
	if !in.store.Update(id, func(s *Session) { res = mergeItems(s, items) }) {
		for _, it := range items {
			_ = os.Remove(in.store.AudioPath(id, it.File))
		}
		in.current = ""
		return
	}
	for _, f := range res.drop {
		_ = os.Remove(in.store.AudioPath(id, f))
	}
	for _, name := range origins {
		in.archive(name)
	}
	in.current, in.lastAt = id, in.now()
	if len(res.process) > 0 {
		if err := in.worker.Enqueue(batch{session: id, items: res.process}); err != nil {
			slog.Error("entrada: no se pudo encolar", "err", err)
		}
	}
	slog.Info("entrada: audios recibidos", "session", id, "nuevos", len(res.added), "repetidos", len(res.skipped), "reemplazados", len(res.replaced))
}

func (in *Inbox) copyIn(sessionID, name string) (*Item, error) {
	src, err := os.Open(filepath.Join(in.dir, name))
	if err != nil {
		return nil, err
	}
	defer src.Close()
	ext := strings.ToLower(filepath.Ext(name))
	itemID := randHex(4)
	file := itemID + ext
	dst, err := os.Create(in.store.AudioPath(sessionID, file))
	if err != nil {
		return nil, err
	}
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(dst, h), src)
	if cerr := dst.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = os.Remove(in.store.AudioPath(sessionID, file))
		return nil, err
	}
	return &Item{ID: itemID, Name: name, File: file, Size: n, Hash: hex.EncodeToString(h.Sum(nil)),
		Status: StatusQueued, AddedAt: in.now()}, nil
}

// archive mueve el original a procesados/ (sin pisar uno con el mismo nombre). Si no puede moverlo
// lo recuerda para no reprocesarlo en cada sondeo; el audio ya está copiado en la sesión.
func (in *Inbox) archive(name string) {
	src := filepath.Join(in.dir, name)
	dir := filepath.Join(in.dir, inboxDone)
	dst := filepath.Join(dir, name)
	if _, err := os.Stat(dst); err == nil {
		ext := filepath.Ext(name)
		dst = filepath.Join(dir, fmt.Sprintf("%s-%s%s", strings.TrimSuffix(name, ext), in.now().Format("20060102-150405"), ext))
	}
	sig := in.prev[name]
	err := os.MkdirAll(dir, 0o755)
	if err == nil {
		err = os.Rename(src, dst)
	}
	if err != nil {
		slog.Warn("entrada: no se pudo mover a procesados (el audio ya se procesó)", "archivo", name, "err", err)
		in.skip[name] = sig
	}
	delete(in.prev, name)
}
