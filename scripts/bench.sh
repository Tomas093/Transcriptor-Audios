#!/usr/bin/env bash
# Mide cuánto tarda y cuánto consume procesar un audio de verdad (con tus servicios reales).
# Uso: scripts/bench.sh ruta/al/audio.opus
set -euo pipefail

FILE="${1:?Uso: scripts/bench.sh ruta/al/audio.opus}"
BASE="http://127.0.0.1:${PORT:-4747}"
[[ -f "$FILE" ]] || { echo "No existe $FILE" >&2; exit 1; }
curl -fsS "$BASE/api/health" >/dev/null || { echo "La app no responde en $BASE. Ejecuta: make up" >&2; exit 1; }

ID=$(curl -fsS -X POST "$BASE/api/sessions" -H 'Content-Type: application/json' -d '{"title":"bench"}' | sed -E 's/.*"id":"([^"]+)".*/\1/')
trap 'curl -fsS -X DELETE "$BASE/api/sessions/$ID" >/dev/null || true' EXIT

echo "Procesando $(basename "$FILE")…  (se borra al terminar)"
START=$(date +%s)
curl -fsS -F "files=@$FILE" "$BASE/api/sessions/$ID/audios" >/dev/null

PEAK_CPU=0; PEAK_RSS=0
while true; do
  # pico de CPU (%) y memoria (MB) entre whisper-server y ollama
  read -r CPU RSS < <(ps -axo pcpu,rss,comm | awk '/whisper-server|ollama/ {c+=$1; r+=$2} END {printf "%.0f %.0f\n", c, r/1024}')
  (( ${CPU:-0} > PEAK_CPU )) && PEAK_CPU=$CPU
  (( ${RSS:-0} > PEAK_RSS )) && PEAK_RSS=$RSS
  BUSY=$(curl -fsS "$BASE/api/sessions" | grep -o "\"id\":\"$ID\"[^}]*\"busy\":[a-z]*" | sed -E 's/.*"busy"://')
  [[ "$BUSY" == "false" ]] && break
  sleep 1
done
END=$(date +%s)

echo "Tiempo total:        $((END - START)) s"
echo "Pico de CPU:         ${PEAK_CPU}% (suma de procesos; 100% = un núcleo)"
echo "Pico de memoria:     ${PEAK_RSS} MB (whisper-server + ollama)"
echo "Si el Mac se calienta: baja WHISPER_THREADS (p. ej. 2) o usa OLLAMA_MODEL=qwen2.5:3b."
