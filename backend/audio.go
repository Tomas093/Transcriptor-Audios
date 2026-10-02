package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"os/exec"
	"strings"
)

const waveBins = 48

// convertToWav pasa cualquier audio (opus, ogg, m4a, mp3…) a WAV 16 kHz mono, el formato
// que espera whisper.cpp. Devuelve la duración en segundos y una forma de onda de waveBins
// barras (0–100) para dibujar el audio en la interfaz.
func convertToWav(ctx context.Context, in, out string) (float64, []int, error) {
	cmd := exec.CommandContext(ctx, "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
		"-threads", "1", "-i", in, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", out)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return 0, nil, ctx.Err()
		}
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return 0, nil, fmt.Errorf("no se pudo leer el audio (¿formato no soportado?): %s", truncate(msg, 160))
	}
	raw, err := os.ReadFile(out)
	if err != nil {
		return 0, nil, err
	}
	pcm := wavPCM(raw)
	const bytesPerSec = 16000 * 2
	return float64(len(pcm)) / bytesPerSec, waveform(pcm, waveBins), nil
}

// wavPCM devuelve los datos PCM del WAV, saltando la cabecera (que con ffmpeg puede incluir
// un bloque LIST de longitud variable).
func wavPCM(raw []byte) []byte {
	i := bytes.Index(raw, []byte("data"))
	if i < 0 || i+8 > len(raw) {
		return nil
	}
	size := int(binary.LittleEndian.Uint32(raw[i+4 : i+8]))
	data := raw[i+8:]
	if size > 0 && size <= len(data) {
		data = data[:size]
	}
	return data[:len(data)/2*2]
}

// waveform reduce el audio a n barras con el volumen RMS de cada tramo, normalizado a 0–100
// (con raíz cuadrada para que los tramos suaves también se vean).
func waveform(pcm []byte, n int) []int {
	samples := len(pcm) / 2
	if samples < n {
		return nil
	}
	sums := make([]float64, n)
	counts := make([]int, n)
	for i := 0; i < samples; i++ {
		v := float64(int16(binary.LittleEndian.Uint16(pcm[2*i:])))
		b := i * n / samples
		sums[b] += v * v
		counts[b]++
	}
	rms := make([]float64, n)
	peak := 0.0
	for b := range rms {
		if counts[b] > 0 {
			rms[b] = math.Sqrt(sums[b] / float64(counts[b]))
		}
		peak = math.Max(peak, rms[b])
	}
	if peak == 0 {
		return nil
	}
	out := make([]int, n)
	for b := range out {
		out[b] = int(math.Round(100 * math.Sqrt(rms[b]/peak)))
	}
	return out
}
