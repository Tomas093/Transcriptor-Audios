package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// convertToWav pasa cualquier audio (opus, ogg, m4a, mp3…) a WAV 16 kHz mono, el formato
// que espera whisper.cpp. Devuelve la duración en segundos (calculada del tamaño del WAV).
func convertToWav(ctx context.Context, in, out string) (float64, error) {
	cmd := exec.CommandContext(ctx, "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
		"-threads", "1", "-i", in, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", out)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return 0, ctx.Err()
		}
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return 0, fmt.Errorf("no se pudo leer el audio (¿formato no soportado?): %s", truncate(msg, 160))
	}
	st, err := os.Stat(out)
	if err != nil {
		return 0, err
	}
	const bytesPerSec = 16000 * 2
	return float64(st.Size()-44) / bytesPerSec, nil
}
